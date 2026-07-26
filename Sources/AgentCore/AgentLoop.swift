// Sources/AgentCore/AgentLoop.swift
// Main inference loop: prompt → generate → parse → execute → repeat

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import Darwin

/// The main agent loop that orchestrates generation and tool execution.
///
/// This actor is decomposed across multiple files for maintainability:
/// - `AgentLoop+Types.swift` — Enum types (WorkingMode, ThinkingLevel, etc.)
/// - `AgentLoop+ModeConfiguration.swift` — Mode/config management
/// - `AgentLoop+ModelLifecycle.swift` — Model loading/reloading
/// - `AgentLoop+Generation.swift` — Token generation & streaming
/// - `AgentLoop+ToolApproval.swift` — Terminal approval UI
/// - `AgentLoop+ToolExecution.swift` — Tool execution & registration
/// - `AgentLoop+ToolCondensation.swift` — Result condensation
/// - `AgentLoop+GitOrchestration.swift` — Git workflows
/// - `AgentLoop+ContextManagement.swift` — Compaction, steering, transforms
/// - `AgentLoop+History.swift` — History management & diagnostics
/// - `AgentLoop+SystemPrompt.swift` — Prompt composition
/// - `AgentLoop+SemanticCorrection.swift` — LLM-based correction
/// - `AgentLoop+BuildCheck.swift` — Build relevance checking
/// - `DiffGenerator.swift` — Pure diff utility
/// - `LoopDetectionService.swift` — Pure loop detection utility
public actor AgentLoop {

    public struct DraftModelHandle: @unchecked Sendable {
        public let model: any LanguageModel
        public init(model: any LanguageModel) {
            self.model = model
        }
    }

    // MARK: - Stored Properties

    var modelContainer: ModelContainer?
    var draftModel: DraftModelHandle?
    let registry: ToolRegistry
    /// Stable identifier for this conversation, sent as `session_id` on remote
    /// (OpenRouter) requests so all generations in one run are grouped together
    /// for tracing multi-step agent chains.
    let sessionId: String = UUID().uuidString
    var permissions: PermissionEngine
    var frontend: any AgentFrontend
    /// When true, AgentCore emits debug-level status events.
    let verbose: Bool
    /// When true, emit a per-turn prompt-cache indicator (reused vs. freshly
    /// prefilled token counts) so cross-turn KV reuse can be validated live.
    let promptCacheStats: Bool
    let auditLogger: ToolAuditLogger?
    public internal(set) var history: ConversationHistory
    let maxToolIterations: Int
    var autoApproveAllTools: Bool = false
    var sessionApprovedToolCommands: Set<String> = []
    var useSandbox: Bool
    var modelPath: String

    /// Interpreted view of `modelPath`. `modelPath` is the carrier (it round-trips
    /// through `InferenceBackend(modelPath:)`); strings prefixed with `<provider>:`
    /// are online providers, everything else is a local MLX model path.
    public var backend: InferenceBackend { InferenceBackend(modelPath: modelPath) }
    let memoryLimit: Int?
    let cacheLimit: Int?
    let dryRun: Bool
    let useShadowContextForToolResults: Bool
    let hooks: HookPipeline
    let memoryPromptSection: String?
    /// Optional pluggable long-term memory backend. When non-nil, AgentLoop
    /// fires a best-effort `reflect(.turnCompleted)` at the end of every
    /// turn so the provider can mine the conversation for new memories.
    /// Defaults to nil, which preserves legacy behaviour (no reflection).
    let memoryProvider: (any MemoryProvider)?
    let customizationPromptSection: String?
    let skillsMetadata: [SkillMetadata]
    var promptSectionTokenEstimates: [PromptSection: Int]
    let workspace: String
    let projectWorkspaceRoot: String
    let buildCheckManager: BuildCheckManager
    var gitOrchestrationManager: GitOrchestrationManager?
    var skipGitOrchestrationInitialization: Bool = false
    
    // Tracking parameters to avoid unnecessary reloads
    var toolCallDialect: ToolCallDialect = .qwen
    var loadedModelPath: String?
    var loadedMemoryLimit: Int?
    var loadedCacheLimit: Int?
    var loadedKVBits: Int?
    var loadedKVGroupSize: Int?
    var loadedQuantizedKVStart: Int?
    var loadedTurboQuantBits: Int?
    var pendingReload: Bool = false
    var pendingImages: [URL] = []
    /// One-shot override consumed at the top of `generateResponse()`: when
    /// true, thinking is force-disabled for the *next* local generation call
    /// regardless of `thinkingLevel`, then reset back to false. Set after a
    /// thinking-budget breach (see `ThinkingBudget.swift` /
    /// `AgentLoop+Generation.swift`) so the immediate follow-up turn doesn't
    /// just blow through the same budget again while the model is still
    /// mid-deliberation on the same problem.
    var forceThinkingOffNextTurn: Bool = false

    /// Persistent cross-turn KV (prompt) cache for the plain-text generation path.
    /// Holds the previous turn's KV cache plus the exact tokens it represents so
    /// each turn only prefills the new suffix. Lives here (rather than as a local
    /// in `generateResponse`) so the cache survives between turns; all reads and
    /// mutations happen inside the `ModelContainer.perform` closure — see
    /// `PromptCacheStore` for the Sendable rationale.
    let promptCache = PromptCacheStore()

    public internal(set) var mode: WorkingMode = .plan
    public internal(set) var thinkingLevel: ThinkingLevel = .low
    public internal(set) var taskType: TaskType = .general
    public internal(set) var currentMode: ModelMode = .planLow

    /// `nil` for the top-level orchestrator instance; the profile name
    /// (e.g. "planner", "executor", "filesystem") for a `TaskTool`-constructed
    /// sub-agent. Drives whether the system prompt exposes only orchestration
    /// tools (`task`, `todo`, `plan_file`) or the sub-agent's own full registry —
    /// see `currentToolPromptFilter()` in AgentLoop+SystemPrompt.swift.
    public let role: String?

    /// Absolute/workspace-relative paths modified by tool calls during the
    /// current turn (both streamed and parsed paths). Reset at the start of each
    /// turn. Read by `TaskTool` after a sub-agent run so the parent orchestrator
    /// can bridge file modifications into its own build-check/git flow.
    public internal(set) var turnModifiedFiles: Set<String> = []
    
    var interactiveInput: InteractiveInput?
    
    var currentGenerationConfig: GenerationEngine.Config
    let condensationConfig = ToolResultCondensationConfig()
    let contextReserveTokens: Int = 1024
    /// Number of most-recent conversation turns to always keep verbatim during compaction.
    let contextKeepRecentTurns: Int = 6

    /// Percent-of-window usage at which the proactive mid-run compaction watchdog
    /// fires (see `AgentLoop+ContextManagement.swift: applyContextWatchdogIfNeeded`
    /// and `ContextWatchdog`). Mirrors little-coder's `context-watchdog`
    /// `DEFAULT_PERCENT`. Denominated against `currentGenerationConfig.longContextThreshold`,
    /// treated as the effective context window.
    let contextWatchdogThresholdPercent: Double = 80
    /// Set when a watchdog-triggered compaction ran but failed to free enough
    /// headroom (or found nothing left to compact) — see `ContextWatchdog.compactionHelped`.
    /// Prevents immediately firing a second, likely-doomed compaction back-to-back
    /// (little-coder issue #68). Cleared automatically once usage drops back below
    /// `contextWatchdogThresholdPercent` (hysteresis; see `ContextWatchdog.shouldReArm`).
    var contextWatchdogPaused: Bool = false

    /// A steering message queued for injection between turns, tagged with its origin so the
    /// drain knows whether to inject it as a human user turn or an agent-authored control notice.
    struct QueuedSteering: Sendable {
        let message: String
        let origin: Message.Origin
    }

    /// Messages injected between turns during the current run (checked before each generation step).
    var steeringQueue: [QueuedSteering] = []
    /// Messages queued for automatic processing after the current run finishes.
    var followUpQueue: [String] = []

    // MARK: - Context transforms

    /// A function that receives the current message list and returns a (possibly modified) copy.
    /// Transforms are applied in registration order before every model generation call.
    /// They operate on a **snapshot** — the stored history is never mutated by transforms.
    public typealias ContextTransform = @Sendable ([Message]) async -> [Message]

    var contextTransforms: [ContextTransform] = []

    /// Tmp files whose `new_text` was preserved after a failed streamed `edit_file` call,
    /// keyed by the target file path. Injected automatically on the next retry so the LLM
    /// never has to regenerate the unchanged content.
    var preservedEditTmpFiles: [String: URL] = [:]

    // MARK: - Initializer

    public init(
        modelContainer: ModelContainer?,
        registry: ToolRegistry,
        permissions: PermissionEngine,
        generationConfig: GenerationEngine.Config,
        frontend: any AgentFrontend,
        verbose: Bool = false,
        promptCacheStats: Bool = false,
        systemPrompt: String,
        modelPath: String,
        workspace: String = ".",
        useSandbox: Bool = false,
        useShadowContextForToolResults: Bool = true,
        auditLogger: ToolAuditLogger? = nil,
        dryRun: Bool = false,
        hooks: HookPipeline = HookPipeline(),
        memoryPromptSection: String? = nil,
        memoryProvider: (any MemoryProvider)? = nil,
        customizationPromptSection: String? = nil,
        skillsMetadata: [SkillMetadata] = [],
        promptSectionTokenEstimates: [PromptSection: Int] = [:],
        maxToolIterations: Int = 20,
        memoryLimit: Int? = nil,
        cacheLimit: Int? = nil,
        draftModel: DraftModelHandle? = nil,
        role: String? = nil
    ) {
        self.role = role
        self.modelContainer = modelContainer
        self.draftModel = draftModel
        self.registry = registry
        self.permissions = permissions
        self.currentGenerationConfig = generationConfig
        self.frontend = frontend
        self.verbose = verbose
        self.promptCacheStats = promptCacheStats
        self.history = ConversationHistory(systemPrompt: systemPrompt)
        // Surface prompt-cache lifecycle (cleared / initialized) in the terminal.
        // Captured by value so the store — which lives past `init` — never touches
        // `self`; `AgentFrontend` is `Sendable`, so this is safe from the closure.
        let cacheLogFrontend = frontend
        self.promptCache.log = { message in
            cacheLogFrontend.emitStatus(message)
        }
        self.auditLogger = auditLogger
        self.maxToolIterations = maxToolIterations
        self.modelPath = modelPath
        self.toolCallDialect = ToolCallDialect.detect(modelPath: modelPath)
        self.workspace = workspace
        self.projectWorkspaceRoot = permissions.workspaceRoot
        self.buildCheckManager = BuildCheckManager()
        self.useSandbox = useSandbox
        self.dryRun = dryRun
        self.useShadowContextForToolResults = useShadowContextForToolResults
        self.hooks = hooks
        self.memoryPromptSection = memoryPromptSection
        self.memoryProvider = memoryProvider
        self.customizationPromptSection = customizationPromptSection
        self.skillsMetadata = skillsMetadata
        self.promptSectionTokenEstimates = promptSectionTokenEstimates
        self.memoryLimit = memoryLimit
        self.cacheLimit = cacheLimit
        
        // Initialize interactive input for branch name prompting
        self.interactiveInput = InteractiveInput()
        
        // Ensure initial config matches default mode/thinking/task
        self.currentGenerationConfig = AgentLoop.calculateGenerationConfig(
            current: generationConfig,
            thinkingLevel: self.thinkingLevel,
            taskType: self.taskType,
            mode: self.mode
        )
        
        // Ensure currentMode is synced with initial mode/thinking/task settings
        let initialThinkingLevel = self.thinkingLevel
        switch self.mode {
        case .plan:
            switch initialThinkingLevel {
            case .high, .medium:
                self.currentMode = .planHigh
            case .fast, .minimal, .low:
                self.currentMode = .planLow
            }
        case .agent:
            if self.taskType == .coding {
                switch initialThinkingLevel {
                case .fast, .minimal:
                    self.currentMode = .agentCodingFast
                case .low, .medium:
                    self.currentMode = .agentCodingLow
                case .high:
                    self.currentMode = .agentCodingHigh
                }
            } else {
                switch initialThinkingLevel {
                case .fast, .minimal:
                    self.currentMode = .agentGeneralFast
                case .low, .medium, .high:
                    self.currentMode = .agentGeneralLow
                }
            }
        }
    }

    // MARK: - Main Agent Loop

    /// Process a user message through the agent loop state machine.
    ///
    /// This is the core orchestration loop that drives the agentic workflow:
    /// 1. **Model Reload Check** — Apply any pending model/KV cache configuration changes
    /// 2. **Context Management** — Monitor token count and trigger KV quantization if context is long
    /// 3. **Generation Loop** (up to maxToolIterations iterations):
    ///    - Generate a response from the language model
    ///    - Parse tool calls from the response
    ///    - If no tool calls: return final response and exit
    ///    - Execute each tool call (with permission checks and mode restrictions)
    ///    - Condense tool results if needed (long outputs truncated)
    ///    - Add results back to conversation history
    /// 4. **Cancellation** — Respect ESC key interrupts via CancelController
    ///
    /// - Parameter message: The user's input message to process
    /// - Throws: On model loading errors, generation timeouts, or permission denials
    public func processUserMessage(_ message: String) async throws {
        try await processUserMessage(message, images: [])
    }

    /// Process a user message, optionally with image attachments.
    ///
    /// - Parameters:
    ///   - message: The user's input message (with `@path` tokens already stripped).
    ///   - images: Resolved image file URLs parsed from `@path` tokens.
    /// - Throws: On model loading errors, generation timeouts, or permission denials.
    public func processUserMessage(_ message: String, images: [URL] = []) async throws {
        // 1. Handle any pending reloads from previous mode changes
        if pendingReload {
            try await reloadModel()
            pendingReload = false
        }

        // Discard preserved new_text buffers from previous turns — they are stale once
        // the user sends a new message.
        for url in preservedEditTmpFiles.values {
            try? FileManager.default.removeItem(at: url)
        }
        preservedEditTmpFiles.removeAll()
        
        pendingImages = images
        history.addUser(message)
        await applyDeterministicContextCompactionIfNeeded(reason: "after_user_message")
        
        // Initialize git orchestration for coding tasks
        if taskType == .coding && gitOrchestrationManager == nil && !skipGitOrchestrationInitialization {
            await initializeGitOrchestration(userMessage: message)
        }

        // 2. Check for long context and trigger KV quantization if needed
        checkAndApplyLongContextQuantization()

        // 3. Reload now if long context just triggered it
        if pendingReload {
            try await reloadModel()
            pendingReload = false
        }

        let turnHistorySnapshot = history
        let turnPendingImagesSnapshot = pendingImages
        let turnPreservedEditTmpFilesSnapshot = preservedEditTmpFiles

        var iterations = 0
        var fileModificationToolsExecuted = false
        var turnTotalPromptTokens = 0
        var turnTotalCompletionTokens = 0
        var turnTotalElapsed: TimeInterval = 0
        var hasTurnStats = false
        var modifiedFilePaths = Set<String>()
        // Mirror into the instance-level property on every exit path so a
        // `TaskTool`-invoking parent (or a caller after this run) can read which
        // files this turn touched — see `turnModifiedFiles` in AgentLoop.swift.
        turnModifiedFiles = []
        defer { turnModifiedFiles = modifiedFilePaths }
        var lastReadFileSignature: String?
        var sameReadFileStreak = 0
        var readLoopSteeredPaths = Set<String>()
        var lastReadOnlyToolSignature: String?
        var sameReadOnlyToolStreak = 0
        var readOnlyLoopSteeredSignatures = Set<String>()
        var hasRetriedFailedTurn = false
        // Tracks the same tool call failing identically turn after turn (e.g. a
        // malformed/hallucinated call the model keeps re-emitting). Lets us abandon
        // the turn instead of grinding to `maxToolIterations`.
        var lastFailedCallSignature: String?
        var sameFailedCallStreak = 0
        var repeatedFailureAbortName: String?

        while iterations < maxToolIterations {
            await applyDeterministicContextCompactionIfNeeded(reason: "before_generation")
            await applyContextWatchdogIfNeeded()

            // Flush any pending steering messages before generating. The post-execution
            // drain below handles the normal path, but the malformed-tool-call path uses
            // `continue` to skip it — so we drain here too to guarantee the model sees
            // the correction prompt on its next attempt.
            _ = await drainSteeringQueue()

            // Generate response
            let generationResult: (text: String, writer: StreamingToolCallWriter, startedThinking: Bool, turnStats: (promptTokens: Int, completionTokens: Int, elapsed: TimeInterval, tokensPerSecond: Double?)?, finishReason: String?, thinkingBudgetBreached: Bool)
            do {
                generationResult = try await generateResponse()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if !hasRetriedFailedTurn {
                    hasRetriedFailedTurn = true
                    frontend.harnessIntervention(
                        "generation failed (\(error.localizedDescription)) — retrying the current turn once instead of surfacing the failure immediately.",
                        severity: .warning
                    )
                    // If a context-overflow error was thrown, force aggressive compaction
                    // before the retry attempt so the reshape crash (local) or the same
                    // oversized request (remote) cannot recur.
                    let isLocalContextOverflow = (error as NSError).domain == "AgentLoop"
                        && (error as NSError).code == 9
                    let remoteOverflowError = (error as? OpenRouterError)?.isContextOverflow == true
                        ? (error as? OpenRouterError)
                        : nil
                    if isLocalContextOverflow || remoteOverflowError != nil {
                        frontend.harnessIntervention(
                            "the context is too large for a retry — forcing compaction before attempting it again.",
                            severity: .warning
                        )
                        // Abandon in-flight recovery artifacts so the emergency
                        // compaction is unblocked (it skips while transient messages
                        // exist) and so malformed attempts never enter a summary.
                        history.purgeTransient()
                        await applyDeterministicContextCompactionIfNeeded(
                            reason: "context_overflow_recovery",
                            overrideThreshold: remoteOverflowError?.reportedContextWindow
                        )
                    }
                    pendingImages = images
                    continue
                }

                frontend.emitError("Generation failed again: \(error.localizedDescription)")
                history = turnHistorySnapshot
                pendingImages = turnPendingImagesSnapshot
                preservedEditTmpFiles = turnPreservedEditTmpFilesSnapshot
                return
            }

            let response = generationResult.text
            let writer = generationResult.writer
            let startedThinking = generationResult.startedThinking
            let finishReason = generationResult.finishReason
            if let stats = generationResult.turnStats {
                turnTotalPromptTokens += stats.promptTokens
                turnTotalCompletionTokens += stats.completionTokens
                turnTotalElapsed += stats.elapsed
                hasTurnStats = true
                // Per-message stats: surface this round's own cost right after
                // its assistant message so the user can see which step spent
                // what. The turn-complete line still shows the running sum of
                // every round (see the `hasTurnStats` block on the exit path).
                let roundTps = stats.tokensPerSecond
                    ?? (stats.elapsed > 0 ? Double(stats.completionTokens) / stats.elapsed : 0)
                frontend.emit(.stats(StatsSnapshot(
                    generationTokens: stats.completionTokens,
                    tokensPerSecond: roundTps,
                    promptTokens: stats.promptTokens,
                    promptTokensPerSecond: 0,
                    elapsed: stats.elapsed
                )))
            }

            // Get streamed tool calls from the writer
            let streamedCalls = writer.drainCompletedCalls()
            let failedStreamedCalls = writer.drainFailedCalls()
            // If generation ended while a content stream was in progress (model
            // hit max_tokens mid-write), recover the partial bytes from the tmp
            // file so we don't force a full regeneration.
            let truncatedStream = writer.drainTruncatedStream()

            // Parse tool calls from text and remove ones already captured via streaming.
            let parsedToolCalls = await parseToolCallsUsingProcessor(
                response: response,
                startedThinking: startedThinking
            )
            let toolCalls = deduplicateToolCalls(parsed: parsedToolCalls, streamed: streamedCalls)

            // Try to recover a truncated streamed write before we declare the
            // tool call malformed. write_file and append_file tolerate an
            // incremental commit, so we save what was streamed and instruct
            // the model to finish the file with an append_file call instead
            // of regenerating the whole thing.
            if let truncated = truncatedStream,
               truncated.bytesWritten > 0,
               truncated.toolName == "write_file" || truncated.toolName == "append_file" {
                await recoverTruncatedStreamedWrite(
                    truncated: truncated,
                    response: response,
                    fileModificationToolsExecuted: &fileModificationToolsExecuted,
                    modifiedFilePaths: &modifiedFilePaths
                )
                continue
            } else if let truncated = truncatedStream {
                // Not a recoverable tool — discard the partial tmp file so it
                // doesn't accumulate, then fall through to the malformed path.
                try? FileManager.default.removeItem(at: truncated.contentFile)
            }

            // Detect bare-JSON responses with no tool-call markers as malformed
            // too. Smaller models (e.g. LFM2) sometimes reach for a free-form
            // `{"todo":..., "commands":[...]}`-style blob instead of using our
            // wire format. Accepting it silently would let the agent stall.
            let responseLooksLikeBareJSONToolCall = toolCalls.isEmpty
                && streamedCalls.isEmpty
                && Self.responseIsBareJSON(response, startsThinking: startedThinking)

            let hasMalformedToolCall = !failedStreamedCalls.isEmpty ||
                (toolCalls.isEmpty && streamedCalls.isEmpty && ToolCallParser.containsToolCall(response, dialect: toolCallDialect, startsThinking: startedThinking))
                || responseLooksLikeBareJSONToolCall

            if toolCalls.isEmpty && streamedCalls.isEmpty && generationResult.thinkingBudgetBreached && !hasMalformedToolCall {
                // The model blew through its thinking-token budget
                // (`thinkingLevel.budgetTokens`, plus tolerance — see
                // `ThinkingBudget.swift`) without ever closing its `<think>`
                // block. `generateResponse()` already force-closed the think
                // block and stopped consuming further thinking tokens this
                // round — treat the fragment as transient (it's raw
                // reasoning, not a real answer), make sure the intervention
                // is visible, and force thinking off for the immediate
                // follow-up so it doesn't just re-enter the same spiral.
                history.addAssistant(response, transient: true)
                frontend.harnessIntervention(
                    "the model has thought long enough (past its \(thinkingLevel.displayName) budget without concluding) — stopping deliberation and pushing it to implement now.",
                    severity: .warning
                )
                forceThinkingOffNextTurn = true
                steeringQueue.append(.init(
                    message: "You have spent too long thinking without reaching a conclusion. Stop deliberating now and respond with your best answer or make the tool call you were working toward.",
                    origin: .automated))
                iterations += 1
                continue
            }

            if toolCalls.isEmpty && streamedCalls.isEmpty && finishReason == "length" && !hasMalformedToolCall {
                // Generation was cut off by the server's token limit mid-thought, before
                // any tool call was emitted. Treat the fragment as transient and ask the
                // model to continue — otherwise a truncated line is accepted as the final
                // answer (and, for sub-agents, becomes the digest summary).
                history.addAssistant(response, transient: true)
                frontend.harnessIntervention(
                    "the model's response was cut off by the length limit — asking it to continue instead of accepting the fragment as final.",
                    severity: .warning
                )
                steeringQueue.append(.init(
                    message: "Your previous response was cut off because it hit the length limit. Continue from where you left off and complete your response, then make any tool call you intended.",
                    origin: .automated))
                iterations += 1
                continue
            }

            if toolCalls.isEmpty && streamedCalls.isEmpty {
                if hasMalformedToolCall {
                    // Rejected generation attempt — kept in context so the model can
                    // recover on the retry, but marked transient so it is purged from
                    // persistent history once the turn produces a valid path.
                    history.addAssistant(response, transient: true)
                    frontend.harnessIntervention(
                        "the model's tool call was malformed — rejecting it and asking for a strict retry instead of executing anything.",
                        severity: .warning
                    )
                    let example: String
                    switch toolCallDialect {
                    case .qwen:
                        example = "<tool_call>{\"name\":\"tool_name\",\"arguments\":{...}}</tool_call>"
                    case .lfm2:
                        example = "<|tool_call_start|>[tool_name(param='value')]<|tool_call_end|>"
                    case .glm4:
                        example = "<tool_call>tool_name<arg_key>param</arg_key><arg_value>value</arg_value></tool_call>"
                    }
                    let bareJSONNote = responseLooksLikeBareJSONToolCall
                        ? " Your last response was a bare JSON object — that is NOT a tool call and will never execute. Discard that shape entirely."
                        : ""
                    // The orchestrator only has task/todo/plan_file. A malformed
                    // attempt at one of those is easy to "fix" the wrong way —
                    // by falling back to a direct tool it doesn't have — so
                    // reiterate the constraint here rather than let a generic
                    // format reminder send it in circles.
                    let orchestratorNote = role == nil
                        ? " Remember: you are the orchestrator and only have task/todo/plan_file — do not fall back to calling read_file or any other tool directly; fix and re-emit the task(...) call."
                        : ""
                    steeringQueue.append(.init(message: "Your previous tool call was malformed and could not be parsed.\(bareJSONNote)\(orchestratorNote) Re-emit only the tool call using the exact \(example) format. Use one of the tool names listed in the system prompt. Do not add explanation text, code fences, or any JSON outside the tool-call markers.", origin: .automated))
                    iterations += 1
                    continue
                }

                // No tool calls — this is the final response
                history.addAssistant(response)

                // If the user queued steering while this plain reply was streaming, don't
                // finalize the turn — keep the reply in history, drain the queue, and loop
                // so the model responds now instead of waiting for the next user message.
                if await drainSteeringQueue() {
                    iterations += 1
                    continue
                }

                // Turn completed successfully: drop the ephemeral recovery artifacts
                // (malformed attempts, failed tool-call iterations, automated steering)
                // accumulated during it, so only the successful execution path persists.
                let hadTransient = history.purgeTransient()
                if hadTransient {
                    // The ChatML prompt for the next turn will be shorter (failed
                    // iterations removed). Invalidate the KV cache so the next turn
                    // re-prefills from the clean history rather than relying on
                    // trim/checkpoint to reconcile the divergence.
                    promptCache.invalidate(reason: "transient turn artifacts purged — history diverged")
                }

                // Check builds if write/edit tools were executed in agent/coding mode
                if fileModificationToolsExecuted && mode == .agent && taskType == .coding {
                    await performBuildCheckIfNeeded(modifiedPaths: modifiedFilePaths)
                    if let manager = gitOrchestrationManager {
                        do {
                            try await presentMergeApprovalFlow(manager: manager)
                        } catch {
                            frontend.emitStatus("⚠️  Git completion flow failed: \(error.localizedDescription)")
                        }
                    }
                }

                // Best-effort end-of-turn reflection. Fires on a detached
                // task so the user-visible turn has already returned by the
                // time embedding / extraction work runs. Errors are
                // swallowed inside the provider — never re-thrown here.
                // TODO: also wire per-turn `recallForTurn` injection once
                // ConversationHistory supports a mutable system-prompt slot.
                if let provider = memoryProvider {
                    let snapshot = ReflectionInput(
                        trigger: .turnCompleted(turnIndex: history.messages.count),
                        projectRoot: projectWorkspaceRoot,
                        recentAssistantText: [response],
                        recentUserText: history.latestUserMessage.map { [$0] } ?? []
                    )
                    Task.detached(priority: .utility) { [provider] in
                        await provider.reflect(snapshot)
                    }
                }

                // Emit accumulated token stats for the whole turn (all rounds summed).
                if hasTurnStats {
                    let tps = turnTotalElapsed > 0
                        ? Double(turnTotalCompletionTokens) / turnTotalElapsed : nil
                    frontend.emitStatus(AgentLoop.formatGenerationStats(
                        promptTokens: turnTotalPromptTokens,
                        completionTokens: turnTotalCompletionTokens,
                        elapsed: turnTotalElapsed,
                        tokensPerSecond: tps
                    ))
                }

                // Audible + visible completion cue for terminal users — only
                // for the top-level orchestrator (role == nil). A sub-agent
                // finishing is an internal step the orchestrator will react
                // to next, not something the human is waiting on directly, so
                // it gets a plain status line with no bell/notification.
                if role == nil {
                    frontend.emitStatus("Turn complete.\u{0007}", severity: .success)
                } else {
                    frontend.emitStatus("Sub-task complete.", severity: .success)
                }
                return
            }

            // Record the history boundary before this iteration's assistant message so
            // we can retroactively mark the whole iteration transient if any tool fails.
            let iterationStartIndex = history.messages.count
            var iterationAnyToolFailed = false

            // Add the assistant's response (including tool calls) to history
            history.addAssistant(response)

            // Handle streamed tool calls first (content already written to .tmp files).
            // Stop at the first failure: remaining calls are deferred and the model is
            // steered to fix the failed call before re-emitting the skipped ones.
            var streamedCallFailed = false
            for (streamIndex, streamedCall) in streamedCalls.enumerated() {
                frontend.emit(.toolCallStarted(ToolCallSnapshot(name: streamedCall.toolName, arguments: stringifyArgs(["path": streamedCall.path, "content": "[streamed to tmp]"]))))
                let streamResult = await handleStreamedToolCall(streamedCall)
                frontend.emit(.toolCallResult(makeDisplaySnapshot(toolName: streamedCall.toolName, result: streamResult)))
                if streamResult.isError {
                    iterationAnyToolFailed = true
                    streamedCallFailed = true
                    let failure = registerFailedCall(
                        name: streamedCall.toolName,
                        arguments: ["path": streamedCall.path],
                        lastSignature: &lastFailedCallSignature,
                        streak: &sameFailedCallStreak
                    )
                    if let steer = failure.steer {
                        steeringQueue.append(.init(message: steer, origin: .automated))
                    }
                    if failure.abort { repeatedFailureAbortName = streamedCall.toolName }
                }

                // Track file modifications
                if !streamResult.isError {
                    fileModificationToolsExecuted = true
                    modifiedFilePaths.insert(streamedCall.path)
                    // A streamed write/edit changed a file on disk, so a follow-up
                    // read_file of the same path is a legitimate re-read of new
                    // content — not a loop. Streamed calls bypass executeToolCall,
                    // which is where read-loop state is normally reset, so clear it
                    // here to avoid a false "Detected repeated read loop".
                    lastReadFileSignature = nil
                    sameReadFileStreak = 0
                }

                let userGoal = history.latestUserMessage ?? ""
                let toolResponse = try await makeToolResponseForHistory(
                    toolName: streamedCall.toolName,
                    result: streamResult,
                    userGoal: userGoal
                )
                history.addToolResponse(toolResponse, toolCallId: streamedCall.toolName)

                if streamedCallFailed {
                    // Collect remaining unexecuted calls (rest of streamed + all parsed).
                    let deferredNames = streamedCalls[(streamIndex + 1)...].map(\.toolName)
                        + toolCalls.map(\.name)
                    if !deferredNames.isEmpty {
                        let list = deferredNames.map { "'\($0)'" }.joined(separator: ", ")
                        steeringQueue.append(.init(
                            message: "Tool '\(streamedCall.toolName)' failed (see result above). The following tool calls were deferred and not executed: [\(list)]. Fix '\(streamedCall.toolName)' first, then re-emit the deferred calls in your next response.",
                            origin: .automated
                        ))
                    }
                    break
                }
            }

            // Execute each tool call from text parsing, stopping at the first failure.
            // If a streamed call already failed, all parsed calls are also deferred.
            if !streamedCallFailed {
                for (callIndex, call) in toolCalls.enumerated() {
                    let result = await executeToolCall(
                        call: call,
                        lastReadFileSignature: &lastReadFileSignature,
                        sameReadFileStreak: &sameReadFileStreak,
                        readLoopSteeredPaths: &readLoopSteeredPaths,
                        lastReadOnlyToolSignature: &lastReadOnlyToolSignature,
                        sameReadOnlyToolStreak: &sameReadOnlyToolStreak,
                        readOnlyLoopSteeredSignatures: &readOnlyLoopSteeredSignatures,
                        fileModificationToolsExecuted: &fileModificationToolsExecuted,
                        modifiedFilePaths: &modifiedFilePaths
                    )

                    let userGoal = history.latestUserMessage ?? ""
                    let toolResponse = try await makeToolResponseForHistory(
                        toolName: call.name,
                        result: result,
                        userGoal: userGoal
                    )
                    history.addToolResponse(toolResponse, toolCallId: call.name)

                    if result.isError {
                        iterationAnyToolFailed = true
                        let failure = registerFailedCall(
                            name: call.name,
                            arguments: call.arguments,
                            lastSignature: &lastFailedCallSignature,
                            streak: &sameFailedCallStreak
                        )
                        if let steer = failure.steer {
                            steeringQueue.append(.init(message: steer, origin: .automated))
                        }
                        if failure.abort { repeatedFailureAbortName = call.name }
                        let deferredNames = toolCalls[(callIndex + 1)...].map(\.name)
                        if !deferredNames.isEmpty {
                            let list = deferredNames.map { "'\($0)'" }.joined(separator: ", ")
                            steeringQueue.append(.init(
                                message: "Tool '\(call.name)' failed (see result above). The following tool calls were deferred and not executed: [\(list)]. Fix '\(call.name)' first, then re-emit the deferred calls in your next response.",
                                origin: .automated
                            ))
                        }
                        break
                    }
                }
            }

            // If any tool in this iteration failed, mark the whole iteration (assistant
            // message + all tool responses) as transient. The model still sees them
            // during the current turn for recovery context, but purgeTransient() will
            // remove them when the turn completes so only the successful path persists.
            if iterationAnyToolFailed {
                history.markTransient(from: iterationStartIndex)
                iterations += 1
            } else {
                iterations = 0
                // A clean iteration breaks any identical-failure streak.
                lastFailedCallSignature = nil
                sameFailedCallStreak = 0
            }

            // The model has re-emitted the same failing call too many times in a
            // row and shows no sign of recovering. Abandon the turn instead of
            // spending the rest of the iteration budget on it.
            if let abortName = repeatedFailureAbortName {
                let hadTransient = history.purgeTransient()
                if hadTransient {
                    promptCache.invalidate(reason: "transient turn artifacts purged — repeated tool failure abort")
                }
                frontend.harnessInterventionError("stopping the turn — '\(abortName)' failed identically \(sameFailedCallStreak) times in a row and the model couldn't recover. Try rephrasing your request.")
                return
            }

            // After processing all tool calls for this turn, drain the steering queue.
            // Steering messages redirect the agent on the next generation turn.
            _ = await drainSteeringQueue()
        }

        // Turn is ending (iteration cap reached); still drop transient recovery
        // artifacts so they don't leak into persistent history.
        let hadTransientAtCap = history.purgeTransient()
        if hadTransientAtCap {
            promptCache.invalidate(reason: "transient turn artifacts purged — history diverged")
        }
        frontend.harnessInterventionError("stopping the turn — it exceeded the \(maxToolIterations)-iteration tool budget without finishing.")
    }

    // MARK: - Private Helpers (used only by processUserMessage)

    /// Drains queued steering messages into history, emitting a harness
    /// intervention notice (user-visible only — never the text added to
    /// history below, which the model reads verbatim) plus the audit hook.
    /// Returns true if anything was drained.
    ///
    /// This is the single live channel for surfacing a steering injection to
    /// the user. There used to be a second, dead code path here: the
    /// `AgentEvent.steeringInjected` frontend event had dedicated rendering
    /// in both TUI adapters but nothing ever constructed it, so it could
    /// never actually double-print — but it was exactly the kind of
    /// same-named, unwired duplicate (`AgentHookEvent.steeringInjected` below
    /// is a *different*, audit-only channel) that invites a real double
    /// announcement the next time someone touches this code. That dead event
    /// case has been removed; `hooks.emit(.steeringInjected(...))` below is
    /// intentionally kept — it's the audit-log trail, not a UI channel.
    private func drainSteeringQueue() async -> Bool {
        guard !steeringQueue.isEmpty else { return false }
        let pending = steeringQueue
        steeringQueue.removeAll()
        for item in pending {
            frontend.harnessIntervention("steering the model — \(item.message)")
            switch item.origin {
            case .human:     history.addUser(item.message)
            case .automated: history.addAutomated(item.message)
            }
            await hooks.emit(.steeringInjected(message: item.message))
        }
        return true
    }

    /// Commits a partially-streamed write to its target path, records the
    /// recovery as an assistant turn + tool response, and steers the model to
    /// append the remainder instead of regenerating the entire content on the
    /// next turn. Mutates the file-modification trackers on success.
    private func recoverTruncatedStreamedWrite(
        truncated: TruncatedStreamedToolCall,
        response: String,
        fileModificationToolsExecuted: inout Bool,
        modifiedFilePaths: inout Set<String>
    ) async {
        history.addAssistant(response)
        frontend.harnessIntervention(
            "recovering \(truncated.bytesWritten) truncated bytes for \(truncated.path) from disk instead of discarding the partial write.",
            severity: .warning
        )

        frontend.emit(.toolCallStarted(ToolCallSnapshot(
            name: truncated.toolName,
            arguments: stringifyArgs([
                "path": truncated.path,
                "content": "[streamed to tmp - truncated]"
            ])
        )))

        let commit = await commitTruncatedStreamedWrite(truncated)
        frontend.emit(.toolCallResult(makeDisplaySnapshot(toolName: truncated.toolName, result: commit.result)))

        if !commit.result.isError {
            fileModificationToolsExecuted = true
            modifiedFilePaths.insert(truncated.path)
        }

        let userGoal = history.latestUserMessage ?? ""
        if let toolResponse = try? await makeToolResponseForHistory(
            toolName: truncated.toolName,
            result: commit.result,
            userGoal: userGoal
        ) {
            history.addToolResponse(toolResponse, toolCallId: truncated.toolName)
        }

        guard !commit.result.isError else { return }

        let tailHint = commit.tail.isEmpty ? "" : "\n\nThe file currently ends with:\n```\n\(commit.tail)\n```"
        let steeringMessage = "Your previous \(truncated.toolName) call to \(truncated.path) was cut off after \(truncated.bytesWritten) bytes because the token budget ran out mid-content. The partial content was already saved to disk — do NOT regenerate it. To finish the file, call append_file with path \"\(truncated.path)\" and only the REMAINING content needed to complete it.\(tailHint)"

        frontend.harnessIntervention("steering the model — \(steeringMessage)")
        history.addAutomated(steeringMessage)
        await hooks.emit(.steeringInjected(message: steeringMessage))
    }

    /// Initializes git orchestration for coding tasks.
    private func initializeGitOrchestration(userMessage: String) async {
        do {
            let manager = try await GitOrchestrationManager.create(projectRoot: projectWorkspaceRoot)

            guard let interactiveInput = self.interactiveInput else {
                let setup = try await manager.prepareTask(userMessage: userMessage)
                try await finalizePreparedGitSetup(
                    manager: manager,
                    preferredBranchName: setup.branchName,
                    warning: setup.warning
                )
                return
            }

            let setupOptions = [
                "Continue from existing worktree branch",
                "Create a new branch (auto name)",
                "Create a new branch (custom name)",
                "Continue without creating a branch"
            ]

            guard let selected = await frontendSelectOption(
                prompt: "Coding mode git setup",
                options: setupOptions,
                escSelectsLastOption: true
            ) else {
                frontend.emitStatus("⚠️  Git setup skipped (no option selected).")
                return
            }

            switch selected {
            case 0:
                let worktrees = try await manager.listAvailableWorktrees()
                guard !worktrees.isEmpty else {
                    frontend.emitStatus("⚠️  No git worktrees found. Falling back to auto-named branch creation.")
                    let setup = try await manager.prepareTask(userMessage: userMessage)
                    try await finalizePreparedGitSetup(
                        manager: manager,
                        preferredBranchName: setup.branchName,
                        warning: setup.warning
                    )
                    return
                }

                let currentDir = URL(filePath: FileManager.default.currentDirectoryPath).standardized.path()
                let options = worktrees.map { info in
                    let normalizedPath = URL(filePath: info.path).standardized.path()
                    let branch = info.branch ?? "detached HEAD"
                    let marker = normalizedPath == currentDir ? " (current)" : ""
                    return "\(branch) — \(normalizedPath)\(marker)"
                }

                guard let worktreeIndex = await frontendSelectOption(
                    prompt: "Select existing worktree branch",
                    options: options,
                    escSelectsLastOption: true
                ) else {
                    frontend.emitStatus("⚠️  Worktree selection cancelled.")
                    return
                }

                let selectedWorktree = worktrees[worktreeIndex]
                let connected = try await manager.connectToExistingWorktree(path: selectedWorktree.path)
                skipGitOrchestrationInitialization = false
                gitOrchestrationManager = manager
                let normalizedPath = URL(filePath: connected.path).standardized.path()
                await switchSessionWorkspace(to: normalizedPath, changeDirectory: false)
                frontend.emitStatus("📁 Using existing worktree: \(normalizedPath)")
                frontend.emitStatus("🌿 Active branch: \(connected.branch)")

            case 1:
                let setup = try await manager.prepareTask(userMessage: userMessage)
                try await finalizePreparedGitSetup(
                    manager: manager,
                    preferredBranchName: setup.branchName,
                    warning: setup.warning
                )

            case 2:
                let setup = try await manager.prepareTask(userMessage: userMessage)
                frontend.emitStatus("📋 Proposed branch: \(setup.branchName) (base: \(setup.baseBranch))")

                let customBranch = await interactiveInput.promptForText(
                    prompt: "Branch name (or Enter to keep proposed):",
                    placeholder: setup.branchName,
                    validate: { name in
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty {
                            return true
                        }
                        if !BranchNamer.isValidCustomBranchName(trimmed) {
                            throw GitError.invalidCustomBranchName(trimmed)
                        }
                        return true
                    }
                )?.trimmingCharacters(in: .whitespacesAndNewlines)

                let finalBranch = (customBranch?.isEmpty == false) ? customBranch! : setup.branchName
                if finalBranch != setup.branchName {
                    try await manager.updateBranchName(finalBranch)
                }

                try await finalizePreparedGitSetup(
                    manager: manager,
                    preferredBranchName: finalBranch,
                    warning: setup.warning
                )

            default:
                skipGitOrchestrationInitialization = true
                gitOrchestrationManager = nil
                frontend.emitStatus("⏭️  Continuing without git orchestration. No branch/worktree was created.")
            }
        } catch {
            frontend.emitStatus("⚠️  Git initialization failed: \(error.localizedDescription)")
        }
    }

    private func finalizePreparedGitSetup(
        manager: GitOrchestrationManager,
        preferredBranchName: String,
        warning: String?
    ) async throws {
        try await manager.createWorktreeNow()
        skipGitOrchestrationInitialization = false
        gitOrchestrationManager = manager

        let currentBranch = await manager.getCurrentBranchName() ?? preferredBranchName
        let worktreePath = await manager.getWorktreePath() ?? "current directory"
        frontend.emitStatus("🌿 Worktree created at: \(worktreePath) (branch: \(currentBranch))")

        if let resolvedWorktree = await manager.getWorktreePath() {
            await switchSessionWorkspace(to: resolvedWorktree, changeDirectory: false)
            frontend.emitStatus("📁 Files will be edited in worktree")
        }

        if let warning, !warning.isEmpty {
            frontend.emitStatus("⚠️  Git setup warning: \(warning)")
        }
    }

    /// Bridges an option-select prompt through `frontend` so TUI mode shows the
    /// picker in the renderer footer instead of using raw-terminal print calls.
    func frontendSelectOption(
        prompt: String,
        options: [String],
        escSelectsLastOption: Bool = false
    ) async -> Int? {
        let req = OptionSelectRequest(prompt: prompt, options: options, escSelectsLastOption: escSelectsLastOption)
        let resp = await frontend.request(.optionSelect(req))
        if case .optionSelect(let idx) = resp { return idx }
        return nil
    }

    /// Checks for long context and enables TurboQuant KV cache compression if not already active.
    ///
    /// Standard mlx-lm `kvBits` quantization is stripped before each generation call because
    /// `QuantizedKVCache.update()` crashes several model types (Gemma2, DeepseekV3, etc.).
    /// TurboQuant is the safe alternative: it decompresses back to float16 so every model
    /// sees normal KV arrays, and it creates per-generation caches without needing a reload.
    private func checkAndApplyLongContextQuantization() {
        let currentTokens = history.estimatedTokenCount
        guard currentTokens > currentGenerationConfig.longContextThreshold,
              currentGenerationConfig.turboQuantBits == nil,
              !modelPath.lowercased().contains("gemma-4")
        else { return }

        frontend.emitStatus(
            "\u{001B}[33m[Long context]\u{001B}[0m \(currentTokens) tokens — "
            + "enabling TurboQuant KV cache (3-bit) to reduce decode memory bandwidth."
        )
        self.currentGenerationConfig = GenerationEngine.Config(
            maxTokens: currentGenerationConfig.maxTokens,
            temperature: currentGenerationConfig.temperature,
            topP: currentGenerationConfig.topP,
            topK: currentGenerationConfig.topK,
            minP: currentGenerationConfig.minP,
            repetitionPenalty: currentGenerationConfig.repetitionPenalty,
            repetitionContextSize: currentGenerationConfig.repetitionContextSize,
            presencePenalty: currentGenerationConfig.presencePenalty,
            presenceContextSize: currentGenerationConfig.presenceContextSize,
            frequencyPenalty: currentGenerationConfig.frequencyPenalty,
            frequencyContextSize: currentGenerationConfig.frequencyContextSize,
            kvBits: currentGenerationConfig.kvBits,
            kvGroupSize: currentGenerationConfig.kvGroupSize,
            quantizedKVStart: currentGenerationConfig.quantizedKVStart,
            longContextThreshold: currentGenerationConfig.longContextThreshold,
            turboQuantBits: 3,
            numDraftTokens: currentGenerationConfig.numDraftTokens
        )
        // No pendingReload: TurboQuant creates per-generation caches, not at model-load time.
        // Invalidate the prompt cache: TurboQuant and cross-turn caching are mutually exclusive.
        promptCache.invalidate(reason: "TurboQuant auto-enabled at long context")
    }

    /// Deduplicates parsed tool calls against streamed tool calls.
    /// Parse tool calls from `response` using `ToolCallProcessor` (mlx-swift-lm) as the
    /// primary path, with `ToolCallParser` as a fallback for JSON the processor rejects
    /// but our sanitiser can recover (e.g. literal newlines inside string values).
    ///
    /// Using the processor gives us:
    /// - Whitelist validation against the registered tool schemas
    /// - Type-aware argument coercion (string `"42"` → Int)
    /// - Automatic double-decode for models that stringify the arguments object
    private func parseToolCallsUsingProcessor(
        response: String,
        startedThinking: Bool
    ) async -> [ToolCallParser.ParsedToolCall] {
        let promptFilter = currentToolPromptFilter()
        let schemas = await registry.toolSchemasForProcessor(filter: promptFilter)

        let format: ToolCallFormat = switch toolCallDialect {
        case .qwen: .json
        case .lfm2: .lfm2
        case .glm4: .glm4
        }

        let processor = ToolCallProcessor(format: format, tools: schemas.isEmpty ? nil : schemas)

        // ToolCallProcessor doesn't suppress tags inside <think>…</think>.
        // Mirror ToolCallParser's logic: if thinking is unclosed (no </think>), all
        // remaining content is still internal monologue — return empty immediately.
        // Only strip closed thinking blocks before feeding to the processor.
        if startedThinking && !response.contains(ToolCallPattern.thinkClose) {
            return []
        }
        let text = startedThinking ? ToolCallParser.stripThinking(response) : response
        _ = processor.processChunk(text)
        processor.processEOS()

        if !processor.toolCalls.isEmpty {
            return processor.toolCalls.map { call in
                ToolCallParser.ParsedToolCall(
                    name: call.function.name,
                    arguments: call.function.arguments.mapValues { $0.anyValue }
                )
            }
        }

        // Fallback: processor found nothing — retry with the hand-rolled parser whose
        // sanitiser can recover JSON with literal newlines and trailing-brace truncation.
        return ToolCallParser.parse(response, dialect: toolCallDialect, startsThinking: startedThinking)
    }

    private func deduplicateToolCalls(
        parsed: [ToolCallParser.ParsedToolCall],
        streamed: [StreamedToolCall]
    ) -> [ToolCallParser.ParsedToolCall] {
        func normalizedToolCallKey(name: String, path: String) -> String {
            let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(normalizedName)|\(normalizedPath)"
        }

        var streamedCallCounts: [String: Int] = [:]
        for streamedCall in streamed {
            let key = normalizedToolCallKey(name: streamedCall.toolName, path: streamedCall.path)
            streamedCallCounts[key, default: 0] += 1
        }

        return parsed.filter { call in
            let path = (call.arguments["path"] as? String) ?? (call.arguments["file_path"] as? String)
            let hasStreamablePayload = call.arguments["content"] != nil ||
                call.arguments["file_content"] != nil ||
                call.arguments["new_text"] != nil

            guard hasStreamablePayload, let path else { return true }

            let key = normalizedToolCallKey(name: call.name, path: path)
            if let count = streamedCallCounts[key], count > 0 {
                streamedCallCounts[key] = count - 1
                return false
            }

            return true
        }
    }

    /// Records that a tool call failed and evaluates the identical-failure streak.
    /// Returns a one-shot corrective steering message (when the streak first crosses
    /// the steer threshold) and an `abort` flag once the model has clearly stalled on
    /// the same broken call. Shared by the streamed and text-parsed execution paths.
    private func registerFailedCall(
        name: String,
        arguments: [String: Any],
        lastSignature: inout String?,
        streak: inout Int
    ) -> (steer: String?, abort: Bool) {
        let state = LoopDetectionService.evaluateFailedCallLoop(
            callName: name,
            arguments: arguments,
            previousSignature: lastSignature,
            previousStreak: streak
        )
        lastSignature = state.nextSignature
        streak = state.nextStreak

        if state.shouldBreak {
            return (nil, true)
        }
        guard state.shouldSteer else {
            return (nil, false)
        }

        var message = "You have called '\(name)' with the same arguments \(state.nextStreak) times and it failed identically every time. STOP repeating this exact call. Re-read the error above, then either emit a corrected call in the required \(ToolCallPattern.toolCallOpen){\"name\": \"<tool>\", \"arguments\": {…}}\(ToolCallPattern.toolCallClose) format, or take a different action."
        // A tool name that is itself a JSON object is the classic "double-wrapped"
        // mistake — point the model straight at it.
        if name.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            message += " The tool name you sent is itself a JSON object — put the tool's real name (e.g. \"todo\") in the \"name\" field and its parameters in \"arguments\", not a nested JSON string."
        }
        return (message, false)
    }

    /// Executes a single parsed tool call with all checks (policy, approval, loop detection, corrections).
    private func executeToolCall(
        call: ToolCallParser.ParsedToolCall,
        lastReadFileSignature: inout String?,
        sameReadFileStreak: inout Int,
        readLoopSteeredPaths: inout Set<String>,
        lastReadOnlyToolSignature: inout String?,
        sameReadOnlyToolStreak: inout Int,
        readOnlyLoopSteeredSignatures: inout Set<String>,
        fileModificationToolsExecuted: inout Bool,
        modifiedFilePaths: inout Set<String>
    ) async -> ToolResult {
        frontend.emit(.toolCallStarted(ToolCallSnapshot(name: call.name, arguments: stringifyArgs(call.arguments))))

        // The top-level orchestrator only ever has task/todo/plan_file — everything
        // else must be delegated. This is a HARD guard, not just a prompt hint:
        // smaller/local models don't always respect a trimmed tool list, and since
        // every tool stays registered (so `task` can hand them to sub-agents), an
        // unguarded call would otherwise execute successfully despite not being
        // advertised. Only fires for tools that are actually registered — a truly
        // hallucinated name still falls through to the normal "Unknown tool" path.
        if role == nil, !AgentLoop.orchestratorAllowedToolNames.contains(call.name), await registry.tool(named: call.name) != nil {
            let deniedResult = ToolResult.error("'\(call.name)' is not available to you directly — you are the orchestrator and only have task/todo/plan_file. Delegate this work instead, e.g. task(profile: \"executor\", description: \"...\") to read/write files or run shell commands, task(profile: \"planner\", description: \"...\") to research/plan, or task(profile: \"reviewer\", description: \"...\") to review.")
            frontend.emit(.toolCallResult(makeDisplaySnapshot(toolName: call.name, result: deniedResult, arguments: call.arguments)))

            let userGoal = history.latestUserMessage ?? ""
            let toolResponse = try! await makeToolResponseForHistory(
                toolName: call.name,
                result: deniedResult,
                userGoal: userGoal
            )
            history.addToolResponse(toolResponse, toolCallId: call.name)
            return deniedResult
        }

        let readLoopState = LoopDetectionService.evaluateReadFileLoop(
            callName: call.name,
            arguments: call.arguments,
            previousSignature: lastReadFileSignature,
            previousStreak: sameReadFileStreak
        )
        lastReadFileSignature = readLoopState.nextSignature
        sameReadFileStreak = readLoopState.nextStreak
        let blockedRepeatedReadPath = readLoopState.shouldBlock ? readLoopState.rawPath : nil
        let blockedRepeatedReadNormalizedPath = readLoopState.shouldBlock ? readLoopState.normalizedPath : nil

        let readOnlyLoopState = LoopDetectionService.evaluateReadOnlyToolLoop(
            callName: call.name,
            arguments: call.arguments,
            previousSignature: lastReadOnlyToolSignature,
            previousStreak: sameReadOnlyToolStreak
        )
        lastReadOnlyToolSignature = readOnlyLoopState.nextSignature
        sameReadOnlyToolStreak = readOnlyLoopState.nextStreak
        let blockedRepeatedReadOnlySignature = readOnlyLoopState.shouldBlock ? readOnlyLoopState.signature : nil
        
        // Track file modifications for build checking
        let isFileModificationTool = isFileModificationToolName(call)
        
        var result: ToolResult

        let targetPath: String? = if call.name == "plan_file" {
            URL(fileURLWithPath: permissions.workspaceRoot)
                .appendingPathComponent(PlanFileTool.planFileName)
                .standardizedFileURL
                .path
        } else {
            extractPolicyTargetPath(from: call.arguments)
        }
        let policyDecision = permissions.evaluateToolPolicy(toolName: call.name, targetPath: targetPath)
        if case .denied(let denyReason) = policyDecision {
            let deniedResult = ToolResult.error(denyReason)
            frontend.emit(.toolCallResult(makeDisplaySnapshot(toolName: call.name, result: deniedResult, arguments: call.arguments)))

            await auditLogger?.logExecutionResult(
                toolName: call.name,
                arguments: call.arguments,
                approved: false,
                isError: true,
                resultPreview: deniedResult.content
            )

            let userGoal = history.latestUserMessage ?? ""
            let toolResponse = try! await makeToolResponseForHistory(
                toolName: call.name,
                result: deniedResult,
                userGoal: userGoal
            )
            history.addToolResponse(toolResponse, toolCallId: call.name)
            return deniedResult
        }
        
        // Resolve early so permission prompts are never shown for hallucinated tool names.
        let resolvedTool = await registry.tool(named: call.name)

        // Check if tool is allowed in current mode
        let isDestructive = resolvedTool != nil && isDestructiveToolCall(call)
        let allowReadOnlyBashInPlanMode = mode == .plan && isReadOnlyBashCall(call)

        // plan_file's 'read' action is non-mutating and falls through to the
        // same auto-approved path as any other read-only tool below; only
        // 'write'/'edit' get the special plan-mode-friendly handling.
        let isMutatingPlanFileCall = call.name == "plan_file" && (call.arguments["action"] as? String) != "read"

        let approval: (approved: Bool, suggestion: String?)
        if resolvedTool == nil {
            // Unknown tool — auto-approve so execution reaches the "Unknown tool" error
            // branch without prompting the user over a hallucinated call.
            approval = (true, nil)
        } else if isMutatingPlanFileCall && mode == .plan {
            approval = (true, nil)
        } else if isMutatingPlanFileCall {
            approval = await askForToolApproval(name: call.name, arguments: call.arguments, isPlanMode: false)
        } else if isDestructive {
            await hooks.emit(.permissionRequest(toolName: call.name, isPlanMode: mode == .plan && !allowReadOnlyBashInPlanMode))
            if mode == .plan && !allowReadOnlyBashInPlanMode {
                approval = await askForToolApproval(name: call.name, arguments: call.arguments, isPlanMode: true)
                if approval.approved {
                    await setMode(.agent, taskType: .coding)
                }
            } else {
                approval = await askForToolApproval(name: call.name, arguments: call.arguments, isPlanMode: false)
            }
        } else {
            approval = (true, nil)
        }

        if approval.approved {
            await hooks.emit(.preToolUse(toolName: call.name, argumentsPreview: serializedArgumentsPreview(call.arguments)))

            if let blockedPath = blockedRepeatedReadPath {
                result = .error("Detected repeated read loop for '\(blockedPath)'. Stop re-reading the same file and use the existing tool output in history.")
                if let normalizedPath = blockedRepeatedReadNormalizedPath,
                   !readLoopSteeredPaths.contains(normalizedPath) {
                    readLoopSteeredPaths.insert(normalizedPath)
                    steeringQueue.append(.init(message: "You are repeatedly calling read_file for '\(blockedPath)'. Reuse prior read output from history, or read a different file/line range only if needed.", origin: .automated))
                }
            } else if let blockedSignature = blockedRepeatedReadOnlySignature {
                result = .error("Detected repeated \(call.name) loop with the same arguments. Reuse prior tool output in history and continue without re-running it.")
                if !readOnlyLoopSteeredSignatures.contains(blockedSignature) {
                    readOnlyLoopSteeredSignatures.insert(blockedSignature)
                    steeringQueue.append(.init(message: "You are repeatedly calling \(call.name) with identical arguments. Reuse the existing tool output and move to the final answer.", origin: .automated))
                }
            } else {
                // Apply automatic parameter correction before execution
                let correctionResult = await ParameterCorrectionService.correct(
                    toolName: call.name,
                    arguments: call.arguments,
                    workspaceRoot: permissions.effectiveWorkspaceRoot
                )
                
                // Log corrections if any were made
                if correctionResult.wasCorrected {
                    for correction in correctionResult.corrections {
                        frontend.harnessIntervention("auto-corrected \(call.name)'s arguments — \(correction)")
                    }
                    await auditLogger?.logParameterCorrection(
                        toolName: call.name,
                        originalArgumentsJSON: serializedArgumentsPreview(call.arguments),
                        correctedArgumentsJSON: serializedArgumentsPreview(correctionResult.correctedArguments),
                        corrections: correctionResult.corrections
                    )
                }

                let missingRequiredArgs = LoopDetectionService.missingRequiredArgumentNames(
                    required: resolvedTool?.parameters.required,
                    arguments: correctionResult.correctedArguments
                )
                if !missingRequiredArgs.isEmpty {
                    let joined = missingRequiredArgs.joined(separator: ", ")
                    result = .error("Missing required argument(s) for \(call.name): \(joined)")
                    steeringQueue.append(.init(message: "Your last \(call.name) call was invalid. Include required argument(s): \(joined).", origin: .automated))
                } else if isDestructive && dryRun {
                    result = .success("Dry-run mode: skipped execution of destructive tool '\(call.name)'. Arguments: \(correctionResult.correctedArguments)")
                } else if let tool = resolvedTool {
                    let showToolSpinner = (call.name == "web_search" || call.name == "web_fetch")
                    let toolSpinner = Spinner(message: "Executing \(call.name)...")
                    if showToolSpinner {
                        toolSpinner.start()
                    }
                    defer {
                        if showToolSpinner {
                            toolSpinner.stop(clearLine: true)
                        }
                    }

                    // Reuse preserved new_text from a previous failed streamed edit_file
                    // so the LLM doesn't waste tokens regenerating unchanged content.
                    var executionArguments = correctionResult.correctedArguments
                    if call.name == "edit_file",
                       let path = executionArguments["path"] as? String,
                       let tmpURL = preservedEditTmpFiles[path],
                       let savedNewText = try? String(contentsOf: tmpURL, encoding: .utf8) {
                        executionArguments["new_text"] = savedNewText
                        preservedEditTmpFiles.removeValue(forKey: path)
                        try? FileManager.default.removeItem(at: tmpURL)
                        frontend.harnessIntervention("reusing the previously generated new_text for \(path) instead of asking the model to regenerate it.")
                    }

                    // [String: Any] is not Sendable; take an explicit unsafe snapshot
                    // before crossing isolation boundaries into tool execution.
                    nonisolated(unsafe) let isolatedExecutionArguments = executionArguments

                    // Loop-level watchdog: a leaf tool that hangs (e.g. a `bash`
                    // call stuck on a stalled network request) must never freeze
                    // the whole turn. Race the tool call against a hard wall-clock
                    // deadline; on expiry, cancel it and record a failed result so
                    // the loop keeps going. `task` is exempt — it delegates to a
                    // full sub-agent loop whose own leaf tool calls are each
                    // watchdog-bounded, and legitimate delegations can run long,
                    // so the leaf ceiling would wrongly kill valid work. See
                    // ToolWatchdog.swift.
                    let watchdogSeconds = ToolWatchdogConfig.seconds
                    let watchdogToolName = call.name
                    let applyWatchdog = call.name != "task"
                    let toolStart = Date()
                    ToolWatchdogConfig.log("dispatching tool \(watchdogToolName)\(applyWatchdog ? " (watchdog \(Int(watchdogSeconds))s)" : " (no watchdog)")")
                    let invoke: @Sendable () async throws -> ToolResult = {
                        if let progressTool = tool as? ProgressReportingTool {
                            return try await progressTool.execute(arguments: isolatedExecutionArguments) { phase in
                                if showToolSpinner {
                                    toolSpinner.updateMessage("\(watchdogToolName): \(phase)")
                                }
                            }
                        } else {
                            return try await tool.execute(arguments: isolatedExecutionArguments)
                        }
                    }
                    do {
                        if applyWatchdog {
                            result = try await runWithToolWatchdog(seconds: watchdogSeconds, toolName: watchdogToolName, operation: invoke)
                        } else {
                            result = try await invoke()
                        }
                    } catch let timeout as ToolWatchdogTimeout {
                        result = .error("Tool '\(timeout.toolName)' exceeded the \(Int(timeout.seconds))s watchdog and was cancelled — it likely hung on a network or subprocess call. The turn is continuing; retry with a smaller scope or a shorter timeout.")
                    } catch {
                        result = .error("Tool execution failed: \(error.localizedDescription)")
                    }
                    ToolWatchdogConfig.log("tool \(watchdogToolName) returned after \(String(format: "%.1f", Date().timeIntervalSince(toolStart)))s isError=\(result.isError)")

                    // Semantic correction: if edit_file failed due to old_text mismatch, use LLM to fix it
                    if result.isError && call.name == "edit_file" {
                        let currentArgs = executionArguments
                        let currentResult = result
                        if let correction = await attemptSemanticCorrection(
                            toolName: call.name,
                            arguments: currentArgs,
                            errorResult: currentResult
                        ) {
                            frontend.harnessIntervention("retrying \(call.name) with auto-corrected arguments instead of failing the call.")
                            do {
                                result = try await tool.execute(arguments: ["path": correction.path, "old_text": correction.oldText, "new_text": correction.newText])
                            } catch {
                                result = .error("Tool execution failed after semantic correction: \(error.localizedDescription)")
                            }
                        }
                    }
                } else {
                    result = .error("Unknown tool: \(call.name)")
                }
            }
        } else {
            if let suggestion = approval.suggestion {
                result = .error("User denied permission and provided this feedback/suggestion: \(suggestion)")
            } else {
                result = .error("User denied permission to execute this tool.")
            }
        }

        await hooks.emit(.postToolUse(
            toolName: call.name,
            isError: result.isError,
            resultPreview: String(result.content.prefix(220))
        ))

        frontend.emit(.toolCallResult(makeDisplaySnapshot(toolName: call.name, result: result, arguments: call.arguments)))
        
        // Track if file modification tools executed successfully
        if isFileModificationTool && !result.isError && approval.approved {
            fileModificationToolsExecuted = true
            if let filepath = (call.arguments["path"] as? String) ?? (call.arguments["file_path"] as? String) {
                modifiedFilePaths.insert(filepath)
            }
            
            // Integrate with git orchestration (lazy worktree creation)
            if let manager = gitOrchestrationManager, taskType == .coding {
                do {
                    let filepath = (call.arguments["path"] as? String) ?? (call.arguments["file_path"] as? String)
                    try await manager.onFirstFileModification(filename: filepath)
                    await manager.trackToolExecution(toolName: call.name, modifiedFiles: filepath.map { [$0] } ?? [])
                } catch {
                    // Git operations are non-fatal
                }
            }
        }

        if isDestructive {
            await auditLogger?.logExecutionResult(
                toolName: call.name,
                arguments: call.arguments,
                approved: approval.approved,
                isError: result.isError,
                resultPreview: result.content
            )
        }

        // Bridge files a delegated sub-agent modified (task(profile: executor), …)
        // into this loop's own tracking, so the post-turn build-check and git
        // merge-approval flow (which only look at `fileModificationToolsExecuted`
        // / `modifiedFilePaths`) still fire when the actual edits happened one
        // level down instead of via a direct write/edit/patch call here.
        if call.name == "task" && !result.isError && approval.approved {
            let subAgentModifiedFiles = TaskTool.parseModifiedFiles(fromDigest: result.content)
            if !subAgentModifiedFiles.isEmpty {
                fileModificationToolsExecuted = true
                for filepath in subAgentModifiedFiles {
                    modifiedFilePaths.insert(filepath)
                }

                if let manager = gitOrchestrationManager, taskType == .coding {
                    do {
                        for filepath in subAgentModifiedFiles {
                            try await manager.onFirstFileModification(filename: filepath)
                        }
                        await manager.trackToolExecution(toolName: call.name, modifiedFiles: subAgentModifiedFiles)
                    } catch {
                        // Git operations are non-fatal
                    }
                }
            }
        }

        return result
    }
}

extension AgentLoop {
    /// Swap the active front-end. Used by ChatCommand when the user picks
    /// `--ui tui` after the agent has been constructed with the legacy
    /// terminal adapter.
    public func swapFrontend(_ newFrontend: any AgentFrontend) {
        self.frontend = newFrontend
    }

    /// True when the assistant response (after stripping any think block) is
    /// essentially just a JSON object or array — i.e. the model emitted
    /// free-form structured output instead of an actual tool call. Used to
    /// nudge weaker models back to the dialect's wire format on retry.
    static func responseIsBareJSON(_ response: String, startsThinking: Bool) -> Bool {
        var text = response
        if startsThinking, let closeRange = text.range(of: ToolCallPattern.thinkClose) {
            text = String(text[closeRange.upperBound...])
        } else {
            text = ToolCallParser.stripThinking(text)
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip a single ```json … ``` fence so models that wrap their JSON
        // in a code fence still get caught.
        let candidate: String
        if trimmed.hasPrefix("```") {
            let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
            guard lines.count >= 3, lines.last?.trimmingCharacters(in: .whitespaces) == "```" else {
                return false
            }
            candidate = lines.dropFirst().dropLast().joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            candidate = trimmed
        }

        guard let first = candidate.first, first == "{" || first == "[" else {
            return false
        }
        guard let data = candidate.data(using: .utf8),
              let _ = try? JSONSerialization.jsonObject(with: data) else {
            return false
        }
        return true
    }
}

extension AgentLoop {
    /// Tools whose raw output should never be displayed in the console —
    /// the content is large/HTML and is processed in a background context
    /// before any condensed summary reaches the main history.
    private static let backgroundContextTools: Set<String> = ["web_fetch", "web_search"]

    /// Returns a `ToolResultSnapshot` suitable for display.
    ///
    /// For background-context tools (`web_fetch`, `web_search`) the raw
    /// content is replaced with a single status line so it doesn't flood
    /// the console or the main conversation history.  Error results are
    /// always passed through unchanged so the user can see failure details.
    func makeDisplaySnapshot(toolName: String, result: ToolResult, arguments: [String: Any] = [:]) -> ToolResultSnapshot {
        guard Self.backgroundContextTools.contains(toolName), !result.isError else {
            return ToolResultSnapshot(
                toolName: toolName,
                isError: result.isError,
                content: result.content,
                truncationMarker: result.truncationMarker
            )
        }
        let byteCount = result.content.count + (result.truncationMarker.map { $0.count + 1 } ?? 0)
        let urlHint: String
        if let url = arguments["url"] as? String, !url.isEmpty {
            urlHint = " from \(url)"
        } else {
            urlHint = ""
        }
        // Indicate if HTML parsing was applied
        let parseHint: String
        if toolName == "web_fetch" {
            let textOnly = arguments["text_only"] as? Bool ?? false
            // Heuristic: if the content doesn't contain HTML tags it was stripped
            let contentLooksStripped = !result.content.contains("<") || textOnly
            parseHint = contentLooksStripped ? " [HTML→text]" : ""
        } else {
            parseHint = ""
        }
        let preview = "[\(toolName): \(byteCount) chars\(urlHint)\(parseHint) — content processed in background context]"
        return ToolResultSnapshot(toolName: toolName, isError: false, content: preview, truncationMarker: nil)
    }
}
