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

    // MARK: - Stored Properties

    var modelContainer: ModelContainer?
    let registry: ToolRegistry
    var permissions: PermissionEngine
    let renderer: StreamRenderer
    let auditLogger: ToolAuditLogger?
    public internal(set) var history: ConversationHistory
    let maxToolIterations: Int
    var autoApproveAllTools: Bool = false
    var sessionApprovedToolCommands: Set<String> = []
    var useSandbox: Bool
    var modelPath: String
    let memoryLimit: Int?
    let cacheLimit: Int?
    let dryRun: Bool
    let hooks: HookPipeline
    let memoryPromptSection: String?
    let customizationPromptSection: String?
    let skillsMetadata: [SkillMetadata]
    var promptSectionTokenEstimates: [PromptSection: Int]
    let workspace: String
    let projectWorkspaceRoot: String
    let buildCheckManager: BuildCheckManager
    var gitOrchestrationManager: GitOrchestrationManager?
    
    // Tracking parameters to avoid unnecessary reloads
    var loadedModelPath: String?
    var loadedMemoryLimit: Int?
    var loadedCacheLimit: Int?
    var loadedKVBits: Int?
    var pendingReload: Bool = false
    var pendingImages: [URL] = []

    public internal(set) var mode: WorkingMode = .plan
    public internal(set) var thinkingLevel: ThinkingLevel = .low
    public internal(set) var taskType: TaskType = .general
    public internal(set) var currentMode: ModelMode = .planLow
    
    var interactiveInput: InteractiveInput?
    
    var currentGenerationConfig: GenerationEngine.Config
    let condensationConfig = ToolResultCondensationConfig()
    let contextReserveTokens: Int = 1024
    /// Number of most-recent conversation turns to always keep verbatim during compaction.
    let contextKeepRecentTurns: Int = 6

    /// Messages injected between turns during the current run (checked before each generation step).
    var steeringQueue: [String] = []
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
        modelContainer: ModelContainer,
        registry: ToolRegistry,
        permissions: PermissionEngine,
        generationConfig: GenerationEngine.Config,
        renderer: StreamRenderer,
        systemPrompt: String,
        modelPath: String,
        workspace: String = ".",
        useSandbox: Bool = false,
        auditLogger: ToolAuditLogger? = nil,
        dryRun: Bool = false,
        hooks: HookPipeline = HookPipeline(),
        memoryPromptSection: String? = nil,
        customizationPromptSection: String? = nil,
        skillsMetadata: [SkillMetadata] = [],
        promptSectionTokenEstimates: [PromptSection: Int] = [:],
        maxToolIterations: Int = 20,
        memoryLimit: Int? = nil,
        cacheLimit: Int? = nil
    ) {
        self.modelContainer = modelContainer
        self.registry = registry
        self.permissions = permissions
        self.currentGenerationConfig = generationConfig
        self.renderer = renderer
        self.history = ConversationHistory(systemPrompt: systemPrompt)
        self.auditLogger = auditLogger
        self.maxToolIterations = maxToolIterations
        self.modelPath = modelPath
        self.workspace = workspace
        self.projectWorkspaceRoot = permissions.workspaceRoot
        self.buildCheckManager = BuildCheckManager()
        self.useSandbox = useSandbox
        self.dryRun = dryRun
        self.hooks = hooks
        self.memoryPromptSection = memoryPromptSection
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
        if taskType == .coding && gitOrchestrationManager == nil {
            await initializeGitOrchestration(userMessage: message)
        }

        // 2. Check for long context and trigger KV quantization if needed
        checkAndApplyLongContextQuantization()

        // 3. Reload now if long context just triggered it
        if pendingReload {
            try await reloadModel()
            pendingReload = false
        }

        var iterations = 0
        var fileModificationToolsExecuted = false
        var modifiedFilePaths = Set<String>()
        var lastReadFileSignature: String?
        var sameReadFileStreak = 0
        var readLoopSteeredPaths = Set<String>()
        var lastReadOnlyToolSignature: String?
        var sameReadOnlyToolStreak = 0
        var readOnlyLoopSteeredSignatures = Set<String>()

        while iterations < maxToolIterations {
            iterations += 1
            await applyDeterministicContextCompactionIfNeeded(reason: "before_generation")

            // Generate response
            let generationResult = try await generateResponse()
            let response = generationResult.text
            let writer = generationResult.writer

            // Get streamed tool calls from the writer
            let streamedCalls = writer.drainCompletedCalls()

            // Parse tool calls from text and remove ones already captured via streaming.
            let parsedToolCalls = ToolCallParser.parse(response)
            let toolCalls = deduplicateToolCalls(parsed: parsedToolCalls, streamed: streamedCalls)

            if toolCalls.isEmpty && streamedCalls.isEmpty {
                // No tool calls — this is the final response
                history.addAssistant(response)
                
                // Check builds if write/edit tools were executed in agent/coding mode
                if fileModificationToolsExecuted && mode == .agent && taskType == .coding {
                    await performBuildCheckIfNeeded(modifiedPaths: modifiedFilePaths)
                    if let manager = gitOrchestrationManager {
                        do {
                            try await presentMergeApprovalFlow(manager: manager)
                        } catch {
                            renderer.printStatus("⚠️  Git completion flow failed: \(error.localizedDescription)")
                        }
                    }
                }
                
                print() // newline after response
                return
            }

            // Add the assistant's response (including tool calls) to history
            history.addAssistant(response)

            // Handle streamed tool calls first (content already written to .tmp files)
            for streamedCall in streamedCalls {
                renderer.printToolCall(name: streamedCall.toolName, arguments: ["path": streamedCall.path, "content": "[streamed to tmp]"])
                
                let streamResult = await handleStreamedToolCall(streamedCall)
                renderer.printToolResult(streamResult)
                
                // Track file modifications
                if !streamResult.isError {
                    fileModificationToolsExecuted = true
                    modifiedFilePaths.insert(streamedCall.path)
                }
                
                let userGoal = history.latestUserMessage ?? ""
                let toolResponse = try await makeToolResponseForHistory(
                    toolName: streamedCall.toolName,
                    result: streamResult,
                    userGoal: userGoal
                )
                history.addToolResponse(toolResponse, toolCallId: streamedCall.toolName)
            }

            // Execute each tool call from text parsing
            for call in toolCalls {
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
            }

            // After processing all tool calls for this turn, drain the steering queue.
            // Steering messages redirect the agent on the next generation turn.
            if !steeringQueue.isEmpty {
                let pending = steeringQueue
                steeringQueue.removeAll()
                for msg in pending {
                    renderer.printStatus("↩️  Steering: \(msg)")
                    history.addUser(msg)
                    await hooks.emit(.steeringInjected(message: msg))
                }
            }
        }

        renderer.printError("Exceeded maximum tool iterations (\(maxToolIterations))")
    }

    // MARK: - Private Helpers (used only by processUserMessage)

    /// Initializes git orchestration for coding tasks.
    private func initializeGitOrchestration(userMessage: String) async {
        do {
            self.gitOrchestrationManager = try await GitOrchestrationManager.create(projectRoot: projectWorkspaceRoot)
            let (branchName, baseBranch, warning) = try await gitOrchestrationManager!.prepareTask(userMessage: userMessage)
            renderer.printStatus("📋 Proposed branch: \(branchName) (base: \(baseBranch))")
            
            // Prompt for custom branch name
            if let interactiveInput = self.interactiveInput {
                let branchOptions = ["Use this name", "No, suggest changes (esc)"]
                print("")
                if let selected = await interactiveInput.selectOption(
                    prompt: "Branch name options",
                    options: branchOptions,
                    escSelectsLastOption: true
                ) {
                    if selected == 1 {
                        // User wants to suggest an alternative branch name
                        if let customName = await interactiveInput.promptForText(
                            prompt: "[branch] Blocked. Suggest changes (or press Enter to keep proposed):",
                            placeholder: branchName,
                            validate: { name in
                                if !BranchNamer.isValidCustomBranchName(name) {
                                    throw GitError.invalidCustomBranchName(name)
                                }
                                return true
                            }
                        ) {
                            try await gitOrchestrationManager!.updateBranchName(customName)
                            renderer.printStatus("✅ Using custom branch: \(customName)")
                        } else {
                            renderer.printStatus("Using proposed branch: \(branchName)")
                        }
                    } else {
                        renderer.printStatus("Using branch: \(branchName)")
                    }
                }
            }
            
            // Create worktree immediately
            try await gitOrchestrationManager!.createWorktreeNow()
            let currentBranch = await gitOrchestrationManager!.getCurrentBranchName() ?? branchName
            let worktreePath = await gitOrchestrationManager!.getWorktreePath() ?? "current directory"
            renderer.printStatus("🌿 Worktree created at: \(worktreePath) (branch: \(currentBranch))")
            
            // Update permissions to use worktree as effective workspace
            if let worktreePath = await gitOrchestrationManager!.getWorktreePath() {
                await switchSessionWorkspace(to: worktreePath, changeDirectory: false)
                renderer.printStatus("📁 Files will be edited in worktree")
            }
            
            if let warning, !warning.isEmpty {
                renderer.printStatus("⚠️  Git setup warning: \(warning)")
            }
        } catch {
            renderer.printStatus("⚠️  Git initialization failed: \(error.localizedDescription)")
        }
    }

    /// Checks for long context and triggers KV quantization if needed.
    private func checkAndApplyLongContextQuantization() {
        let currentTokens = history.estimatedTokenCount
        if currentTokens > currentGenerationConfig.longContextThreshold
            && (currentGenerationConfig.kvBits == nil || currentGenerationConfig.kvBits! > 4)
            && !modelPath.lowercased().contains("gemma-4")
        {
            renderer.printStatus("\u{001B}[33m[Warning]\u{001B}[0m Long context detected (\(currentTokens) tokens).")
            renderer.printStatus("Switching to 4-bit KV cache to save VRAM...")
            
            // Update config to 4-bit
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
                kvBits: 4, 
                kvGroupSize: currentGenerationConfig.kvGroupSize,
                quantizedKVStart: currentGenerationConfig.quantizedKVStart,
                longContextThreshold: currentGenerationConfig.longContextThreshold,
                turboQuantBits: currentGenerationConfig.turboQuantBits
            )
            self.pendingReload = true
        }
    }

    /// Deduplicates parsed tool calls against streamed tool calls.
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

            guard !streamed.isEmpty else { return true }

            let key = normalizedToolCallKey(name: call.name, path: path)
            if let count = streamedCallCounts[key], count > 0 {
                streamedCallCounts[key] = count - 1
                return false
            }

            // Safety net: if any streamed calls were captured this turn,
            // suppress remaining parsed content-bearing calls to avoid duplicates.
            return false
        }
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
        renderer.printToolCall(name: call.name, arguments: call.arguments)

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
        let isFileModificationTool = (call.name == "write_file" || call.name == "edit_file" || call.name == "append_file" || call.name == "patch")
        
        var result: ToolResult

        let targetPath = extractPolicyTargetPath(from: call.arguments)
        let policyDecision = permissions.evaluateToolPolicy(toolName: call.name, targetPath: targetPath)
        if case .denied(let denyReason) = policyDecision {
            let deniedResult = ToolResult.error(denyReason)
            renderer.printToolResult(deniedResult)

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
        
        // Check if tool is allowed in current mode
        let isDestructive = isDestructiveToolCall(call)
        
        let approval: (approved: Bool, suggestion: String?)
        if isDestructive {
            await hooks.emit(.permissionRequest(toolName: call.name, isPlanMode: mode == .plan))
            if mode == .plan {
                approval = await askForToolApproval(name: call.name, arguments: call.arguments, isPlanMode: true)
                if approval.approved {
                    await setMode(.agent)
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
                    steeringQueue.append("You are repeatedly calling read_file for '\(blockedPath)'. Reuse prior read output from history, or read a different file/line range only if needed.")
                }
            } else if let blockedSignature = blockedRepeatedReadOnlySignature {
                result = .error("Detected repeated \(call.name) loop with the same arguments. Reuse prior tool output in history and continue without re-running it.")
                if !readOnlyLoopSteeredSignatures.contains(blockedSignature) {
                    readOnlyLoopSteeredSignatures.insert(blockedSignature)
                    steeringQueue.append("You are repeatedly calling \(call.name) with identical arguments. Reuse the existing tool output and move to the final answer.")
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
                        renderer.printStatus("[auto-correct] \(call.name): \(correction)")
                    }
                    await auditLogger?.logParameterCorrection(
                        toolName: call.name,
                        originalArgumentsJSON: serializedArgumentsPreview(call.arguments),
                        correctedArgumentsJSON: serializedArgumentsPreview(correctionResult.correctedArguments),
                        corrections: correctionResult.corrections
                    )
                }

                let resolvedTool = await registry.tool(named: call.name)
                let missingRequiredArgs = LoopDetectionService.missingRequiredArgumentNames(
                    required: resolvedTool?.parameters.required,
                    arguments: correctionResult.correctedArguments
                )
                if !missingRequiredArgs.isEmpty {
                    let joined = missingRequiredArgs.joined(separator: ", ")
                    result = .error("Missing required argument(s) for \(call.name): \(joined)")
                    steeringQueue.append("Your last \(call.name) call was invalid. Include required argument(s): \(joined).")
                } else if isDestructive && dryRun {
                    result = .success("Dry-run mode: skipped execution of destructive tool '\(call.name)'. Arguments: \(correctionResult.correctedArguments)")
                } else if let tool = resolvedTool {
                    let showToolSpinner = (call.name == "web_search" || call.name == "web_fetch")
                    let toolSpinner = Spinner(message: "Executing \(call.name)...")
                    if showToolSpinner {
                        await toolSpinner.start()
                    }
                    defer {
                        if showToolSpinner {
                            Task { await toolSpinner.stop(clearLine: true) }
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
                        renderer.printStatus("[auto-correct] edit_file: reusing preserved new_text for \(path)")
                    }

                    // [String: Any] is not Sendable; take an explicit unsafe snapshot
                    // before crossing isolation boundaries into tool execution.
                    nonisolated(unsafe) let isolatedExecutionArguments = executionArguments

                    do {
                        if let progressTool = tool as? ProgressReportingTool {
                            result = try await progressTool.execute(arguments: isolatedExecutionArguments) { phase in
                                if showToolSpinner {
                                    Task { await toolSpinner.updateMessage("\(call.name): \(phase)") }
                                }
                            }
                        } else {
                            result = try await tool.execute(arguments: isolatedExecutionArguments)
                        }
                    } catch {
                        result = .error("Tool execution failed: \(error.localizedDescription)")
                    }

                    // Semantic correction: if edit_file failed due to old_text mismatch, use LLM to fix it
                    if result.isError && call.name == "edit_file" {
                        let currentArgs = executionArguments
                        let currentResult = result
                        if let correction = await attemptSemanticCorrection(
                            toolName: call.name,
                            arguments: currentArgs,
                            errorResult: currentResult
                        ) {
                            renderer.printStatus("[auto-correct] Retrying with corrected arguments...")
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

        renderer.printToolResult(result)
        
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

        return result
    }
}
