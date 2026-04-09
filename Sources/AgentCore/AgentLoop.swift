// Sources/AgentCore/AgentLoop.swift
// Main inference loop: prompt → generate → parse → execute → repeat

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import Darwin

/// The main agent loop that orchestrates generation and tool execution.
public actor AgentLoop {

    private var modelContainer: ModelContainer?
    private let registry: ToolRegistry
    private let permissions: PermissionEngine
    private let renderer: StreamRenderer
    private let auditLogger: ToolAuditLogger?
    public private(set) var history: ConversationHistory
    private let maxToolIterations: Int
    private var autoApproveAllTools: Bool = false
    private var useSandbox: Bool
    private var modelPath: String
    private let memoryLimit: Int?
    private let cacheLimit: Int?
    private let dryRun: Bool
    private let hooks: HookPipeline
    private let memoryPromptSection: String?
    private let customizationPromptSection: String?
    private let skillsMetadata: [SkillMetadata]
    private var promptSectionTokenEstimates: [PromptSection: Int]
    private let workspace: String
    private let buildCheckManager: BuildCheckManager
    private var gitOrchestrationManager: GitOrchestrationManager?
    
    // Tracking parameters to avoid unnecessary reloads
    private var loadedModelPath: String?
    private var loadedMemoryLimit: Int?
    private var loadedCacheLimit: Int?
    private var loadedKVBits: Int?
    private var pendingReload: Bool = false
    private var pendingImages: [URL] = []
    
    public enum WorkingMode: String, Codable, Sendable {
        case agent
        case plan
    }
    
    public enum ThinkingLevel: String, Codable, Sendable {
        /// No thinking blocks — fastest, deterministic responses.
        case fast
        /// ~100-token thinking budget — one or two sentences of internal reasoning.
        case minimal
        /// ~300-token thinking budget — concise reasoning focused on the key insight.
        case low
        /// ~600-token thinking budget — moderate depth, balances speed and quality.
        case medium
        /// ~2000-token thinking budget — deep reasoning, explores multiple approaches.
        case high

        /// Approximate token budget for the thinking block at this level.
        public var budgetTokens: Int {
            switch self {
            case .fast:    return 0
            case .minimal: return 100
            case .low:     return 300
            case .medium:  return 600
            case .high:    return 2000
            }
        }

        /// Human-readable label shown in status messages and the REPL.
        public var displayName: String {
            switch self {
            case .fast:    return "fast (off)"
            case .minimal: return "minimal (~\(budgetTokens) tokens)"
            case .low:     return "low (~\(budgetTokens) tokens)"
            case .medium:  return "medium (~\(budgetTokens) tokens)"
            case .high:    return "high (~\(budgetTokens) tokens)"
            }
        }
    }
    
    public enum TaskType: String, Codable, Sendable {
        case general
        case coding
        case reasoning
    }

    public enum ModelMode: String, Codable, Sendable, CaseIterable {
        case planLow = "Plan (low)"
        case planHigh = "Plan (high)"
        case agentGeneralFast = "Agent (general/fast)"
        case agentGeneralLow = "Agent (general/low)"
        case agentCodingFast = "Agent (coding/fast)"
        case agentCodingLow = "Agent (coding/low)"
        case agentCodingHigh = "Agent (coding/high)"
    }
    
    public private(set) var mode: WorkingMode = .plan
    public private(set) var thinkingLevel: ThinkingLevel = .low
    public private(set) var taskType: TaskType = .general
    public private(set) var currentMode: ModelMode = .planLow
    
    private var currentGenerationConfig: GenerationEngine.Config
    private let condensationConfig = ToolResultCondensationConfig()
    private let contextReserveTokens: Int = 1024
    /// Number of most-recent conversation turns to always keep verbatim during compaction.
    private let contextKeepRecentTurns: Int = 6

    /// Messages injected between turns during the current run (checked before each generation step).
    private var steeringQueue: [String] = []
    /// Messages queued for automatic processing after the current run finishes.
    private var followUpQueue: [String] = []

    // MARK: - Context transforms

    /// A function that receives the current message list and returns a (possibly modified) copy.
    /// Transforms are applied in registration order before every model generation call.
    /// They operate on a **snapshot** — the stored history is never mutated by transforms.
    public typealias ContextTransform = @Sendable ([Message]) async -> [Message]

    private var contextTransforms: [ContextTransform] = []

    /// Tmp files whose `new_text` was preserved after a failed streamed `edit_file` call,
    /// keyed by the target file path. Injected automatically on the next retry so the LLM
    /// never has to regenerate the unchanged content.
    private var preservedEditTmpFiles: [String: URL] = [:]

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
        
        // Initial loaded state
        self.loadedModelPath = modelPath
        self.loadedMemoryLimit = memoryLimit
        self.loadedCacheLimit = cacheLimit
        self.loadedKVBits = generationConfig.kvBits
        
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
    /// **Mode Interactions**:
    /// - `.plan` mode: Destructive operations (write_file, bash, etc.) require explicit approval before switching to `.agent`
    /// - `.agent` mode: Tool execution requires approval but doesn't change mode
    ///
    /// **Tool Result Condensation**: Long tool outputs are automatically truncated and marked with
    /// truncation markers to keep context within model limits.
    ///
    /// - Parameter message: The user's input message to process
    /// - Throws: On model loading errors, generation timeouts, or permission denials
    public func processUserMessage(_ message: String) async throws {
        try await processUserMessage(message, images: [])
    }

    /// Process a user message, optionally with image attachments.
    ///
    /// When `images` is non-empty the request is routed through the VLM code path:
    /// the conversation history and images are packaged as a `UserInput`, passed to
    /// `modelContainer.prepare(input:)`, and the resulting `LMInput` (which contains
    /// encoded pixel data) is forwarded to `generateTokens`.  Text-only calls
    /// (`images` is empty) use the existing `LMInput(tokens:)` path unchanged.
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
            do {
                self.gitOrchestrationManager = try await GitOrchestrationManager.create(projectRoot: workspace)
                let (branchName, baseBranch, warning) = try await gitOrchestrationManager!.prepareTask(userMessage: message)
                renderer.printStatus("📋 Git branch prepared: \(branchName) (base: \(baseBranch))")
                if let warning, !warning.isEmpty {
                    renderer.printStatus("⚠️  Git setup warning: \(warning)")
                }
            } catch {
                renderer.printStatus("⚠️  Git initialization failed: \(error.localizedDescription)")
                // Continue anyway - git orchestration is optional
            }
        }

        // 2. Check for long context and trigger KV quantization if needed
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
            func normalizedToolCallKey(name: String, path: String) -> String {
                let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
                return "\(normalizedName)|\(normalizedPath)"
            }

            var streamedCallCounts: [String: Int] = [:]
            for streamedCall in streamedCalls {
                let key = normalizedToolCallKey(name: streamedCall.toolName, path: streamedCall.path)
                streamedCallCounts[key, default: 0] += 1
            }

            let toolCalls = parsedToolCalls.filter { call in
                let path = (call.arguments["path"] as? String) ?? (call.arguments["file_path"] as? String)
                let hasStreamablePayload = call.arguments["content"] != nil ||
                    call.arguments["file_content"] != nil ||
                    call.arguments["new_text"] != nil

                guard hasStreamablePayload, let path else { return true }

                guard !streamedCalls.isEmpty else { return true }

                let key = normalizedToolCallKey(name: call.name, path: path)
                if let count = streamedCallCounts[key], count > 0 {
                    streamedCallCounts[key] = count - 1
                    return false
                }

                // Safety net: if any streamed calls were captured this turn,
                // suppress remaining parsed content-bearing calls to avoid duplicates.
                return false
            }

            if toolCalls.isEmpty && streamedCalls.isEmpty {
                // No tool calls — this is the final response
                history.addAssistant(response)
                
                // Check builds if write/edit tools were executed in agent/coding mode
                if fileModificationToolsExecuted && mode == .agent && taskType == .coding {
                    await performBuildCheckIfNeeded(modifiedPaths: modifiedFilePaths)
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
                renderer.printToolCall(name: call.name, arguments: call.arguments)

                let readLoopState = Self.evaluateReadFileLoop(
                    callName: call.name,
                    arguments: call.arguments,
                    previousSignature: lastReadFileSignature,
                    previousStreak: sameReadFileStreak
                )
                lastReadFileSignature = readLoopState.nextSignature
                sameReadFileStreak = readLoopState.nextStreak
                let blockedRepeatedReadPath = readLoopState.shouldBlock ? readLoopState.rawPath : nil
                let blockedRepeatedReadNormalizedPath = readLoopState.shouldBlock ? readLoopState.normalizedPath : nil
                
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
                    let toolResponse = try await makeToolResponseForHistory(
                        toolName: call.name,
                        result: deniedResult,
                        userGoal: userGoal
                    )
                    history.addToolResponse(toolResponse, toolCallId: call.name)
                    continue
                }
                
                // Check if tool is allowed in current mode
                let isDestructive = isDestructiveToolCall(call)
                
                let approval: (approved: Bool, suggestion: String?)
                if isDestructive {
                    await hooks.emit(.permissionRequest(toolName: call.name, isPlanMode: mode == .plan))
                    if mode == .plan {
                        approval = await askForToolApproval(name: call.name, isPlanMode: true)
                        if approval.approved {
                            await setMode(.agent)
                        }
                    } else {
                        approval = await askForToolApproval(name: call.name, isPlanMode: false)
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
                    } else {
                        // Apply automatic parameter correction before execution
                        let correctionResult = await ParameterCorrectionService.correct(
                            toolName: call.name,
                            arguments: call.arguments,
                            workspaceRoot: workspace
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
                        let missingRequiredArgs = Self.missingRequiredArgumentNames(
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

    private func extractPolicyTargetPath(from arguments: [String: Any]) -> String? {
        let directKeys = ["path", "file_path", "filePath", "search_path", "directory", "dir", "workspace"]
        for key in directKeys {
            if let value = arguments[key] as? String, !value.isEmpty {
                return value
            }
        }

        if let paths = arguments["paths"] as? [String], let first = paths.first, !first.isEmpty {
            return first
        }

        return nil
    }

    private func isDestructiveToolCall(_ call: ToolCallParser.ParsedToolCall) -> Bool {
        let alwaysDestructiveTools: Set<String> = ["write_file", "edit_file", "append_file", "patch", "bash", "task"]
        if alwaysDestructiveTools.contains(call.name) {
            return true
        }

        if call.name == "lsp_rename" {
            if let apply = call.arguments["apply"] as? Bool {
                return apply
            }
            if let applyNumber = call.arguments["apply"] as? NSNumber {
                return applyNumber.boolValue
            }
        }

        return false
    }

    /// Clears the conversation history and frees MLX memory.
    public func clearHistory() {
        history.clear()
        MLX.Memory.clearCache()
        renderer.printStatus("Conversation history and KV cache cleared")
    }

    /// Reverts the last conversation turn (User + Assistant).
    public func undoLastTurn() {
        if history.revertLastTurn() {
            renderer.printStatus("Reverted the last conversation turn")
        } else {
            renderer.printError("Nothing to undo")
        }
    }

    /// Export conversation history to a markdown transcript in the workspace.
    public func exportHistory(to path: String) throws -> String {
        let resolved = try permissions.validatePath(path)
        let transcript = history.asMarkdownTranscript()
        try transcript.write(toFile: resolved, atomically: true, encoding: .utf8)
        renderer.printStatus("Exported history to \(resolved)")
        return resolved
    }

    /// Export conversation history as JSON for later resume.
    public func exportHistoryJSON(to path: String) throws -> String {
        let resolved = try permissions.validatePath(path)
        let transcript = try history.asJSONTranscript()
        try transcript.write(toFile: resolved, atomically: true, encoding: .utf8)
        renderer.printStatus("Exported JSON history to \(resolved)")
        return resolved
    }

    /// Load conversation history from a JSON transcript.
    public func loadHistoryJSON(from path: String) throws -> String {
        let resolved = try permissions.validatePath(path)
        let data = try Data(contentsOf: URL(filePath: resolved))
        try history.restoreFromJSONTranscript(data)
        renderer.printStatus("Loaded JSON history from \(resolved)")
        return resolved
    }

    /// Returns a human-readable context usage report.
    public func contextUsageReport() -> String {
        var countByRole: [Message.Role: Int] = [:]
        var charsByRole: [Message.Role: Int] = [:]

        for message in history.messages {
            countByRole[message.role, default: 0] += 1
            charsByRole[message.role, default: 0] += message.content.count
        }

        func tokens(for role: Message.Role) -> Int {
            (charsByRole[role, default: 0]) / 4
        }

        let totalChars = history.messages.reduce(0) { $0 + $1.content.count }
        let totalTokens = totalChars / 4

        let systemCount = countByRole[.system, default: 0]
        let userCount = countByRole[.user, default: 0]
        let assistantCount = countByRole[.assistant, default: 0]
        let toolCount = countByRole[.tool, default: 0]

                let systemLayerTokens = promptSectionTokenEstimates[.core, default: 0] +
                        promptSectionTokenEstimates[.runtime, default: 0] +
                        promptSectionTokenEstimates[.customization, default: 0]
                let memoryLayerTokens = promptSectionTokenEstimates[.memory, default: 0]
                let skillsLayerTokens = promptSectionTokenEstimates[.skills, default: 0]
                let toolsLayerTokens = promptSectionTokenEstimates[.tools, default: 0]
                let messageTokens = tokens(for: .user) + tokens(for: .assistant) + tokens(for: .tool)
                let contextThreshold = max(currentGenerationConfig.longContextThreshold, contextReserveTokens + 1)
                let targetBudget = max(256, contextThreshold - contextReserveTokens)
                let toolsWarningThreshold = max(500, targetBudget / 3)
                let toolsWarning = toolsLayerTokens > toolsWarningThreshold
                    ? "- Warnings:\n  - tools section is large (\(toolsLayerTokens) tokens; threshold=\(toolsWarningThreshold))."
                    : "- Warnings: none"

        return """
        Context usage (estimated)
        - Messages: \(history.messages.count)
        - Estimated tokens: \(totalTokens)
                - Budget:
                    - threshold: \(contextThreshold)
                    - reserve: \(contextReserveTokens)
                    - target payload budget: \(targetBudget)
                - By category:
                    - system: \(systemLayerTokens) tokens
                    - tools: \(toolsLayerTokens) tokens
                    - memory: \(memoryLayerTokens) tokens
                    - skills: \(skillsLayerTokens) tokens
                    - messages: \(messageTokens) tokens
                    - reserve: \(contextReserveTokens) tokens
        - By role:
          - system: \(systemCount) msg, \(tokens(for: .system)) tokens
          - user: \(userCount) msg, \(tokens(for: .user)) tokens
          - assistant: \(assistantCount) msg, \(tokens(for: .assistant)) tokens
          - tool: \(toolCount) msg, \(tokens(for: .tool)) tokens
        - Runtime:
          - mode: \(mode.rawValue)
          - thinking: \(thinkingLevel.rawValue)
          - task: \(taskType.rawValue)
          - sandbox: \(useSandbox ? "enabled" : "disabled")
          - dry-run: \(dryRun ? "enabled" : "disabled")
          - context transforms: \(contextTransforms.count)
                \(toolsWarning)
        """
    }

    /// Toggles the sandbox mode and refreshes the system prompt.
    public func setSandbox(_ enabled: Bool) async {
        self.useSandbox = enabled
        
        // Re-register tools with the new sandbox state
        // We reuse the registration logic from MLXCoderCLI
        await registerToolsInternal()
        
        // Update system prompt in history
        let composition = await AgentLoop.buildSystemPromptComposition(
            registry: registry,
            maxTokens: currentGenerationConfig.maxTokens,
            mode: mode,
            thinkingLevel: thinkingLevel,
            taskType: taskType,
            memorySection: memoryPromptSection,
            customizationSection: customizationPromptSection,
            skillsMetadata: skillsMetadata
        )
        promptSectionTokenEstimates = composition.sectionTokenEstimates
        history.updateSystemPrompt(composition.prompt)
        
        let status = enabled ? "\u{001B}[32mEnabled\u{001B}[0m" : "\u{001B}[31mDisabled\u{001B}[0m"
        renderer.printStatus("macOS Seatbelt Sandbox: \(status)")
    }

    /// Sets the working mode (agent/plan) and refreshes the system prompt.
    public func setMode(_ mode: WorkingMode, silent: Bool = false) async {
        self.mode = mode
        syncCurrentModeFromSettings()
        
        // Update task type based on mode if not explicitly set?
        // For now, let's keep it manual or implicit as per the plan:
        // high + agent -> coding
        // high + plan -> general
        // low + agent -> general
        // low + plan -> reasoning
        
        updateGenerationConfig()
        
        // Update system prompt in history
        let composition = await AgentLoop.buildSystemPromptComposition(
            registry: registry,
            maxTokens: currentGenerationConfig.maxTokens,
            mode: mode,
            thinkingLevel: thinkingLevel,
            taskType: taskType,
            memorySection: memoryPromptSection,
            customizationSection: customizationPromptSection,
            skillsMetadata: skillsMetadata
        )
        promptSectionTokenEstimates = composition.sectionTokenEstimates
        history.updateSystemPrompt(composition.prompt)
        
        if !silent {
            let modeStr = mode == .plan ? "\u{001B}[33mPLAN\u{001B}[0m" : "\u{001B}[32mAGENT\u{001B}[0m"
            renderer.printStatus("Working Mode: \(modeStr)")
        }
    }

    /// Sets the thinking level (low/high) and refreshes the system prompt.
    public func setThinkingLevel(_ level: ThinkingLevel) async {
        self.thinkingLevel = level
        syncCurrentModeFromSettings()
        updateGenerationConfig()
        
        // Update system prompt in history
        let composition = await AgentLoop.buildSystemPromptComposition(
            registry: registry,
            maxTokens: currentGenerationConfig.maxTokens,
            mode: mode,
            thinkingLevel: level,
            taskType: taskType,
            memorySection: memoryPromptSection,
            customizationSection: customizationPromptSection,
            skillsMetadata: skillsMetadata
        )
        promptSectionTokenEstimates = composition.sectionTokenEstimates
        history.updateSystemPrompt(composition.prompt)
        
        renderer.printStatus("Thinking Level: \u{001B}[32m\(level.displayName.uppercased())\u{001B}[0m")
    }

    /// Sets the task type (general/coding/reasoning) and updates generation parameters.
    public func setTaskType(_ type: TaskType) async {
        self.taskType = type
        syncCurrentModeFromSettings()
        updateGenerationConfig()
        
        let typeStr = type.rawValue.uppercased()
        renderer.printStatus("Task Type: \u{001B}[32m\(typeStr)\u{001B}[0m")
    }

    // MARK: - Steering & Follow-up

    /// Queues a steering message to be injected before the next generation turn within the
    /// current run. Steering messages let you redirect the agent mid-run — they are consumed
    /// between tool-execution rounds, before the model generates its next response.
    public func steer(_ message: String) {
        steeringQueue.append(message)
    }

    /// Returns the pending steering messages without consuming them.
    public func pendingSteeringMessages() -> [String] {
        steeringQueue
    }

    /// Clears all pending steering messages.
    public func clearSteeringQueue() {
        steeringQueue.removeAll()
    }

    /// Queues a follow-up message for automatic processing after the current run completes.
    /// The CLI drains this queue and calls `processUserMessage` for each entry without
    /// requiring the user to type anything.
    public func queueFollowUp(_ message: String) {
        followUpQueue.append(message)
    }

    /// Dequeues and returns the next follow-up message, or `nil` if the queue is empty.
    public func dequeueFollowUp() -> String? {
        guard !followUpQueue.isEmpty else { return nil }
        return followUpQueue.removeFirst()
    }

    /// Dequeues all pending follow-ups at once and clears the queue in O(1).
    /// Prefer this over calling `dequeueFollowUp()` in a loop.
    public func drainFollowUpQueue() -> [String] {
        let all = followUpQueue
        followUpQueue.removeAll()
        return all
    }

    /// Returns the pending follow-up messages without consuming them.
    public func pendingFollowUps() -> [String] {
        followUpQueue
    }

    /// Clears all pending follow-up messages.
    public func clearFollowUpQueue() {
        followUpQueue.removeAll()
    }

    // MARK: - Context Transforms

    /// Registers a context transform that is applied to the message list before every model
    /// generation call. Transforms are applied in registration order and receive a snapshot —
    /// they never mutate the stored history.
    ///
    /// **Common uses:**
    /// - Memory injection: retrieve relevant documents and prepend them as synthetic user messages.
    /// - Dynamic pruning: drop old tool-result messages that are no longer relevant.
    /// - Context enrichment: inject a live file snapshot, git diff, or environment state.
    ///
    /// Example (memory injection):
    /// ```swift
    /// agentLoop.addContextTransform { messages in
    ///     let query  = messages.last?.content ?? ""
    ///     let recalled = await myVectorStore.retrieve(query: query, topK: 3)
    ///     var out = messages
    ///     let injection = Message(role: .user, content: "[Memory]\n\(recalled.joined(separator: "\n"))")
    ///     out.insert(injection, at: out.endIndex - 1)
    ///     return out
    /// }
    /// ```
    public func addContextTransform(_ transform: @escaping ContextTransform) {
        contextTransforms.append(transform)
    }

    /// Removes all registered context transforms.
    public func removeAllContextTransforms() {
        contextTransforms.removeAll()
    }

    /// Returns the number of currently registered context transforms.
    public var contextTransformCount: Int {
        contextTransforms.count
    }

    /// Cycles to the next available mode (triggered by Shift+Tab).
    public func cycleMode() async -> String {
        let allModes = ModelMode.allCases
        let currentIndex = allModes.firstIndex(of: currentMode) ?? 0
        let nextIndex = (currentIndex + 1) % allModes.count
        let nextMode = allModes[nextIndex]
        
        self.currentMode = nextMode
        
        // Map ModelMode to underlying settings
        switch nextMode {
        case .planLow:
            self.mode = .plan
            self.thinkingLevel = .low
            self.taskType = .general
        case .planHigh:
            self.mode = .plan
            self.thinkingLevel = .high
            self.taskType = .general
        case .agentGeneralFast:
            self.mode = .agent
            self.thinkingLevel = .fast
            self.taskType = .general
        case .agentGeneralLow:
            self.mode = .agent
            self.thinkingLevel = .low
            self.taskType = .general
        case .agentCodingFast:
            self.mode = .agent
            self.thinkingLevel = .fast
            self.taskType = .coding
        case .agentCodingLow:
            self.mode = .agent
            self.thinkingLevel = .low
            self.taskType = .coding
        case .agentCodingHigh:
            self.mode = .agent
            self.thinkingLevel = .high
            self.taskType = .coding
        }
        
        updateGenerationConfig()
        
        // Update system prompt in history
        let composition = await AgentLoop.buildSystemPromptComposition(
            registry: registry,
            maxTokens: currentGenerationConfig.maxTokens,
            mode: self.mode,
            thinkingLevel: self.thinkingLevel,
            taskType: self.taskType,
            memorySection: memoryPromptSection,
            customizationSection: customizationPromptSection,
            skillsMetadata: skillsMetadata
        )
        promptSectionTokenEstimates = composition.sectionTokenEstimates
        history.updateSystemPrompt(composition.prompt)
        
        // Defer reload only if loading parameters changed
        let needsReload = self.modelPath != self.loadedModelPath ||
                          self.memoryLimit != self.loadedMemoryLimit ||
                          self.cacheLimit != self.loadedCacheLimit ||
                          self.currentGenerationConfig.kvBits != self.loadedKVBits
                          
        if needsReload {
            self.pendingReload = true
        }
        
        return nextMode.rawValue
    }

    /// Full model unload and reload to ensure fresh weights/cache.
    public func reloadModel() async throws {
        renderer.printStatus("Reloading model to ensure fresh state...")

        // Drop tool references first so old model-bound tools can be deallocated.
        await registry.clear()
        modelContainer = nil

        // Clear any unreferenced MLX buffers before loading replacement weights.
        MLX.Memory.clearCache()
        
        // Load fresh container
        let newContainer = try await ModelLoader.load(
            from: modelPath,
            memoryLimit: memoryLimit,
            cacheLimit: cacheLimit
        )
        
        self.modelContainer = newContainer
        
        // Update loaded tracking parameters
        self.loadedModelPath = modelPath
        self.loadedMemoryLimit = memoryLimit
        self.loadedCacheLimit = cacheLimit
        self.loadedKVBits = currentGenerationConfig.kvBits
        
        // Re-register tools that depend on modelContainer
        await registerToolsInternal()

        // Sweep again after rebinding to reclaim stale buffers from the old model.
        MLX.Memory.clearCache()
        
        renderer.printStatus("Model reloaded successfully")
    }

    /// Switch to a different model path and immediately reload model and dependent tools.
    public func switchModel(to newModelPath: String) async throws {
        let trimmed = newModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "AgentLoop",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Model path cannot be empty."]
            )
        }

        if trimmed == modelPath {
            renderer.printStatus("Model is already active: \(trimmed)")
            return
        }

        renderer.printStatus("Unloading current model...")
        modelPath = trimmed
        pendingReload = false
        try await reloadModel()
    }

    private func updateGenerationConfig() {
        self.currentGenerationConfig = AgentLoop.calculateGenerationConfig(
            current: currentGenerationConfig,
            thinkingLevel: thinkingLevel,
            taskType: taskType,
            mode: mode
        )
    }

    private func syncCurrentModeFromSettings() {
        switch mode {
        case .plan:
            currentMode = (thinkingLevel == .high || thinkingLevel == .medium) ? .planHigh : .planLow
        case .agent:
            if taskType == .coding {
                switch thinkingLevel {
                case .fast, .minimal:
                    currentMode = .agentCodingFast
                case .low, .medium:
                    currentMode = .agentCodingLow
                case .high:
                    currentMode = .agentCodingHigh
                }
            } else {
                // No dedicated General (high) label exists in ModelMode; keep non-coding labels stable.
                switch thinkingLevel {
                case .fast, .minimal:
                    currentMode = .agentGeneralFast
                case .low, .medium, .high:
                    currentMode = .agentGeneralLow
                }
            }
        }
    }

    private static func calculateGenerationConfig(
        current: GenerationEngine.Config,
        thinkingLevel: ThinkingLevel,
        taskType: TaskType,
        mode: WorkingMode
    ) -> GenerationEngine.Config {
        // Map (thinkingLevel, taskType, mode) to the prescribed parameters
        var temp: Float = 0.6
        var topP: Float = 1.0
        var topK: Int = 0
        let minP: Float = 0.0
        var presencePenalty: Float? = nil
        var repetitionPenalty: Float? = nil
        
        // Prescribed parameter mapping:
        // 1. Thinking mode for general tasks: temperature=1.0, top_p=0.95, top_k=20, min_p=0.0, presence_penalty=1.5, repetition_penalty=1.0
        // 2. Thinking mode for precise coding tasks (e.g. WebDev): temperature=0.6, top_p=0.95, top_k=20, min_p=0.0, presence_penalty=0.0, repetition_penalty=1.0
        // 3. Instruct (or non-thinking) mode for general tasks: temperature=0.7, top_p=0.8, top_k=20, min_p=0.0, presence_penalty=1.5, repetition_penalty=1.0
        // 4. Instruct (or non-thinking) mode for reasoning tasks: temperature=1.0, top_p=0.95, top_k=20, min_p=0.0, presence_penalty=1.5, repetition_penalty=1.0
        
        switch thinkingLevel {
        case .fast:
            // Deterministic, no thinking
            topK = 1
            repetitionPenalty = 1.0
            temp = 0.0
            topP = 1.0
            presencePenalty = 0.0

        case .minimal:
            // Very brief thinking — close to deterministic but allows a short think block
            topK = 5
            repetitionPenalty = 1.0
            temp = 0.3
            topP = 0.85
            presencePenalty = 0.5

        case .low:
            // Instruct-style with concise thinking
            topK = 20
            repetitionPenalty = 1.0
            if mode == .plan || taskType == .reasoning {
                temp = 1.0
                topP = 0.95
                presencePenalty = 1.5
            } else {
                temp = 0.7
                topP = 0.8
                presencePenalty = 1.5
            }

        case .medium:
            // Moderate thinking — balanced depth and speed
            topK = 15
            repetitionPenalty = 1.0
            if mode == .agent || taskType == .coding {
                temp = 0.55
                topP = 0.90
                presencePenalty = 0.0
            } else {
                temp = 0.85
                topP = 0.92
                presencePenalty = 1.0
            }

        case .high:
            // Deep thinking — full reasoning budget
            topP = 0.95
            topK = 20
            repetitionPenalty = 1.0
            if mode == .agent || taskType == .coding {
                // Precise coding tasks
                temp = 0.6
                presencePenalty = 0.0
            } else {
                // General tasks (including reasoning)
                temp = 1.0
                presencePenalty = 1.5
            }
        }
        
        return GenerationEngine.Config(
            maxTokens: current.maxTokens,
            temperature: temp,
            topP: topP,
            topK: topK,
            minP: minP,
            repetitionPenalty: repetitionPenalty,
            repetitionContextSize: current.repetitionContextSize,
            presencePenalty: presencePenalty,
            presenceContextSize: current.presenceContextSize,
            frequencyPenalty: current.frequencyPenalty,
            frequencyContextSize: current.frequencyContextSize,
            kvBits: current.kvBits,
            kvGroupSize: current.kvGroupSize,
            quantizedKVStart: current.quantizedKVStart,
            longContextThreshold: current.longContextThreshold
        )
    }

    private func registerToolsInternal() async {
        guard let modelContainer else { return }

        // Filesystem tools
        await registry.register(ReadFileTool(permissions: permissions))
        await registry.register(WriteFileTool(permissions: permissions))
        await registry.register(AppendFileTool(permissions: permissions))
        await registry.register(EditFileTool(permissions: permissions))
        await registry.register(PatchTool(permissions: permissions))
        await registry.register(ListDirTool(permissions: permissions))
        await registry.register(ReadManyTool(permissions: permissions))

        // Search tools
        await registry.register(GlobTool(permissions: permissions))
        await registry.register(GrepTool(permissions: permissions))
        await registry.register(CodeSearchTool(permissions: permissions))

        // Shell
        await registry.register(BashTool(permissions: permissions, useSandbox: useSandbox))

        // Agent tools
        await registry.register(TaskTool(
            modelContainer: modelContainer,
            permissions: permissions,
            generationConfig: currentGenerationConfig,
            modelPath: modelPath,
            useSandbox: useSandbox,
            parentRegistry: registry,
            renderer: renderer
        ))
        await registry.register(TodoTool(workspaceRoot: permissions.workspaceRoot))
        await registry.register(ProjectExpertLoRATool(modelContainer: modelContainer, workspaceRoot: permissions.workspaceRoot, modelPath: modelPath))

        // Web tools
        await registry.register(WebFetchTool(
            modelContainer: modelContainer,
            generationConfig: currentGenerationConfig
        ))
        await registry.register(WebSearchTool())

        // LSP tools (.NET/C#)
        await registry.register(LSPDiagnosticsTool(permissions: permissions))
        await registry.register(LSPHoverTool(permissions: permissions))
        await registry.register(LSPReferencesTool(permissions: permissions))
        await registry.register(LSPDefinitionTool(permissions: permissions))
        await registry.register(LSPCompletionTool(permissions: permissions))
        await registry.register(LSPSignatureHelpTool(permissions: permissions))
        await registry.register(LSPDocumentSymbolsTool(permissions: permissions))
        await registry.register(LSPRenameTool(permissions: permissions))
    }

    // MARK: - Private

    private func makeToolResponseForHistory(toolName: String, result: ToolResult, userGoal: String) async throws -> String {
        let rawToolResponse = ToolResultCondensationPolicy.joinedToolOutput(result: result)

        guard ToolResultCondensationPolicy.shouldCondense(toolName: toolName, result: result, config: condensationConfig) else {
            return applyFactOnlyPreambleIfNeeded(toolName: toolName, toolResponse: rawToolResponse)
        }

        let beforeTokens = ToolResultCondensationPolicy.estimatedTokenCount(
            for: rawToolResponse,
            charsPerToken: condensationConfig.charsPerTokenEstimate
        )

        do {
            let rawSummary = try await summarizeToolOutputEphemeral(
                toolName: toolName,
                userGoal: userGoal,
                rawToolResponse: rawToolResponse
            )

            let summary = ToolResultCondensationPolicy.sanitizeSummary(
                rawSummary,
                maxChars: condensationConfig.maxSummaryChars
            )

            if renderer.verbose, !summary.isEmpty {
                renderer.printStatus("[debug] Condensed summary for \(toolName):")
                print(summary)
            }

            guard !summary.isEmpty else {
                let fallback = ToolResultCondensationPolicy.boundedFallbackRawMessage(
                    toolName: toolName,
                    raw: rawToolResponse,
                    maxChars: condensationConfig.fallbackRawChars
                )
                let afterTokens = ToolResultCondensationPolicy.estimatedTokenCount(
                    for: fallback,
                    charsPerToken: condensationConfig.charsPerTokenEstimate
                )
                await hooks.emit(.compression(toolName: toolName, beforeTokens: beforeTokens, afterTokens: afterTokens, usedFallback: true))
                if renderer.verbose {
                    renderer.printStatus("[debug] Tool result condensation fallback for \(toolName): before≈\(beforeTokens) tokens, after≈\(afterTokens), saved≈\(max(0, beforeTokens - afterTokens))")
                }
                return fallback
            }

            let condensed = ToolResultCondensationPolicy.formatCondensedToolMessage(toolName: toolName, summary: summary)
            let afterTokens = ToolResultCondensationPolicy.estimatedTokenCount(
                for: condensed,
                charsPerToken: condensationConfig.charsPerTokenEstimate
            )
            await hooks.emit(.compression(toolName: toolName, beforeTokens: beforeTokens, afterTokens: afterTokens, usedFallback: false))
            if renderer.verbose {
                renderer.printStatus("[debug] Tool result condensed for \(toolName): before≈\(beforeTokens) tokens, after≈\(afterTokens), saved≈\(max(0, beforeTokens - afterTokens))")
            }
            return condensed
        } catch {
            let fallback = ToolResultCondensationPolicy.boundedFallbackRawMessage(
                toolName: toolName,
                raw: rawToolResponse,
                maxChars: condensationConfig.fallbackRawChars
            )
            let afterTokens = ToolResultCondensationPolicy.estimatedTokenCount(
                for: fallback,
                charsPerToken: condensationConfig.charsPerTokenEstimate
            )
            await hooks.emit(.compression(toolName: toolName, beforeTokens: beforeTokens, afterTokens: afterTokens, usedFallback: true))
            if renderer.verbose {
                renderer.printStatus("[debug] Tool result condensation failed for \(toolName): \(error.localizedDescription). before≈\(beforeTokens) tokens, after≈\(afterTokens), saved≈\(max(0, beforeTokens - afterTokens))")
            }
            return fallback
        }
    }

    private func summarizeToolOutputEphemeral(toolName: String, userGoal: String, rawToolResponse: String) async throws -> String {
        let effectiveGoal = userGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        let extractionGoal = effectiveGoal.isEmpty
            ? "No explicit user goal is available. Extract only the most relevant facts for likely task completion."
            : effectiveGoal

        let systemPrompt = "You are a precise extraction engine. Return only facts relevant to the current goal."
        let userPrompt = """
        Goal:
        \(extractionGoal)

        Tool:
        \(toolName)

        Instructions:
        - Extract only information relevant to the goal.
        - Keep exact numbers, names, dates, versions, and quoted phrases unchanged.
        - Do not add outside knowledge.
        - If information is missing or ambiguous, explicitly say so.
        - Keep the response under \(condensationConfig.summaryTargetTokens) tokens.

        Raw tool output:
        \(rawToolResponse)
        """

        let extractionConfig = GenerationEngine.Config(
            maxTokens: condensationConfig.summaryTargetTokens,
            temperature: 0.1,
            topP: currentGenerationConfig.topP,
            topK: currentGenerationConfig.topK,
            minP: currentGenerationConfig.minP,
            repetitionPenalty: currentGenerationConfig.repetitionPenalty,
            repetitionContextSize: currentGenerationConfig.repetitionContextSize,
            presencePenalty: 0,
            presenceContextSize: currentGenerationConfig.presenceContextSize,
            frequencyPenalty: 0,
            frequencyContextSize: currentGenerationConfig.frequencyContextSize,
            kvBits: currentGenerationConfig.kvBits,
            kvGroupSize: currentGenerationConfig.kvGroupSize,
            quantizedKVStart: currentGenerationConfig.quantizedKVStart
        )

        let chatML = """
        \(ToolCallPattern.imStart)system
        \(systemPrompt)
        \(ToolCallPattern.imEnd)
        \(ToolCallPattern.imStart)user
        \(userPrompt)
        \(ToolCallPattern.imEnd)
        \(ToolCallPattern.imStart)assistant
        """

        let modelContainer = try requireLoadedModelContainer()
        // Tool-output summarization is text-only; forcing processor.prepare for VLM
        // checkpoints can produce empty prompts and crash in downstream reshape paths.
        let shouldUseProcessorPath = false
        let extracted = try await modelContainer.perform { [shouldUseProcessorPath] context in
            if Task.isCancelled { throw CancellationError() }

            let input: LMInput
            if shouldUseProcessorPath {
                let userInput = UserInput(chat: [.system(systemPrompt), .user(userPrompt)])
                let prepared = try await context.processor.prepare(input: userInput)
                if prepared.text.tokens.size > 0 {
                    input = prepared
                } else {
                    let tokens = try AgentLoop.encodeNonEmptyTokens(
                        primaryText: chatML,
                        fallbackTexts: [userPrompt, "hi", "a"],
                        using: context.tokenizer.encode(text:)
                    )
                    let tokenArray = MLXArray(tokens).expandedDimensions(axis: 0)
                    let mask = ones(like: tokenArray).asType(.int8)
                    input = LMInput(text: .init(tokens: tokenArray, mask: mask), image: nil)
                }
            } else {
                let tokens = try AgentLoop.encodeNonEmptyTokens(
                    primaryText: chatML,
                    fallbackTexts: [userPrompt, "hi", "a"],
                    using: context.tokenizer.encode(text:)
                )
                let tokenArray = MLXArray(tokens).expandedDimensions(axis: 0)
                let mask = ones(like: tokenArray).asType(.int8)
                input = LMInput(text: .init(tokens: tokenArray, mask: mask), image: nil)
            }
            var responseText = ""

            for try await item in try MLXLMCommon.generateTokens(
                input: input,
                parameters: extractionConfig.generateParameters,
                context: context
            ) {
                if Task.isCancelled { throw CancellationError() }
                switch item {
                case .token(let tokenId):
                    responseText += context.tokenizer.decode(tokens: [tokenId], skipSpecialTokens: false)
                case .info:
                    break
                }
            }

            return responseText
        }

        return ToolCallParser.stripThinking(extracted)
            .replacingOccurrences(of: ToolCallPattern.eosToken, with: "")
            .replacingOccurrences(of: ToolCallPattern.imEnd, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func applyFactOnlyPreambleIfNeeded(toolName: String, toolResponse: String) -> String {
        let webToolNames: Set<String> = ["web_search", "web_fetch"]
        guard webToolNames.contains(toolName) else {
            return toolResponse
        }

        let factOnlyPreamble = """
            [INSTRUCTION]
            Act as a Fact-Only Extractor:
            - Exact values only. Never round, convert, or rephrase numbers/names/versions.
            - No conclusions, summaries, or trends unless the source states them explicitly.
            - Do not fill gaps with prior knowledge.
            - If the page is inaccessible or ambiguous, say so before answering.
            - Use the source's exact terminology.
            [INSTRUCTION]

            """
        return factOnlyPreamble + toolResponse
    }

    private func serializedArgumentsPreview(_ arguments: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(arguments),
              let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: arguments)
        }
        return text
    }

    static func makeTokenCountLookup(contents: [String], counts: [Int]) -> [String: Int] {
        var lookup: [String: Int] = [:]
        lookup.reserveCapacity(min(contents.count, counts.count))
        for (content, count) in zip(contents, counts) {
            // Duplicate message content is expected; token count for identical text is identical.
            lookup[content] = count
        }
        return lookup
    }

    private static let repeatedReadFileStreakLimit = 2

    static func evaluateReadFileLoop(
        callName: String,
        arguments: [String: Any],
        previousSignature: String?,
        previousStreak: Int,
        limit: Int = AgentLoop.repeatedReadFileStreakLimit
    ) -> (nextSignature: String?, nextStreak: Int, shouldBlock: Bool, normalizedPath: String?, rawPath: String?) {
        guard callName == "read_file" else {
            return (nil, 0, false, nil, nil)
        }

        let rawPath = ((arguments["path"] as? String) ?? (arguments["file_path"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else {
            return (nil, 0, false, nil, nil)
        }

        let normalizedPath = NSString(string: rawPath).standardizingPath
        let startLineSignature = Self.readFileLoopSignatureValue(arguments["start_line"])
        let endLineSignature = Self.readFileLoopSignatureValue(arguments["end_line"])
        let currentSignature = "\(normalizedPath)|start:\(startLineSignature)|end:\(endLineSignature)"
        let nextStreak = (currentSignature == previousSignature) ? (previousStreak + 1) : 1
        let shouldBlock = nextStreak > limit
        return (currentSignature, nextStreak, shouldBlock, normalizedPath, rawPath)
    }

    private static func readFileLoopSignatureValue(_ value: Any?) -> String {
        switch value {
        case let stringValue as String:
            return stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        case let intValue as Int:
            return String(intValue)
        case nil:
            return "nil"
        default:
            return String(describing: value!)
        }
    }

    static func missingRequiredArgumentNames(required: [String]?, arguments: [String: Any]) -> [String] {
        guard let required, !required.isEmpty else { return [] }
        return required.filter { key in
            guard let value = arguments[key] else { return true }
            if let stringValue = value as? String {
                return stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if let arrayValue = value as? [Any] {
                return arrayValue.isEmpty
            }
            return false
        }
    }

    private func applyDeterministicContextCompactionIfNeeded(reason: String) async {
        let threshold = max(currentGenerationConfig.longContextThreshold, contextReserveTokens + 1)
        let target = max(256, threshold - contextReserveTokens)

        // Use the real tokenizer for accurate token counts when the model is loaded.
        // We snapshot message contents, compute counts inside perform (which is Sendable-safe),
        // then use a lookup table as the tokenCounter closure to avoid capturing non-Sendable state.
        let contentSnapshot = history.messages.map(\.content)
        let tokenCounts: [Int]? = if let modelContainer {
            await modelContainer.perform { context in
                contentSnapshot.map { context.tokenizer.encode(text: $0).count }
            }
        } else {
            nil
        }

        let tokenCounter: ((String) -> Int)?
        if let counts = tokenCounts {
            // Build a lookup from content → token count. Falls back to chars/4 for content not
            // in the snapshot (shouldn't happen, but safe).
            let lookup = Self.makeTokenCountLookup(contents: contentSnapshot, counts: counts)
            tokenCounter = { text in lookup[text] ?? (text.count / 4) }
        } else {
            tokenCounter = nil
        }

        let currentTokens = tokenCounter.map { counter in
            history.messages.reduce(0) { $0 + counter($1.content) }
        } ?? history.estimatedTokenCount

        guard currentTokens > target else { return }

        let before = currentTokens
        let compacted = history.compactByTurns(
            maxTokens: target,
            keepRecentTurns: contextKeepRecentTurns,
            tokenCounter: tokenCounter
        )
        guard compacted else { return }

        // Re-snapshot after compaction for the "after" count.
        let afterContentSnapshot = history.messages.map(\.content)
        let after: Int
        if let modelContainer {
            let afterCounts = await modelContainer.perform { context in
                afterContentSnapshot.map { context.tokenizer.encode(text: $0).count }
            }
            after = afterCounts.reduce(0, +)
        } else {
            after = history.estimatedTokenCount
        }

        renderer.printStatus("[Context] Turn-aware compaction triggered (\(reason)): before≈\(before), after≈\(after), target≈\(target)")
        await hooks.emit(.compression(toolName: "context_history", beforeTokens: before, afterTokens: after, usedFallback: false))
    }

    /// Generate a response from the model using the current conversation history.
    /// Returns the response text and the streaming writer (for streamed tool calls).
    private func generateResponse() async throws -> (text: String, writer: StreamingToolCallWriter) {
        // Apply context transforms (snapshot — does not mutate stored history)
        var transformedMessages = history.messages
        for (index, transform) in contextTransforms.enumerated() {
            let before = transformedMessages.count
            transformedMessages = await transform(transformedMessages)
            let after = transformedMessages.count
            if after != before {
                await hooks.emit(.contextTransformApplied(transformIndex: index, messagesBefore: before, messagesAfter: after))
            }
        }
        // Consume pending images (cleared here so they apply to this turn only).
        // AgentLoop is an actor so there is no concurrent access risk on pendingImages.
        let imageURLs = pendingImages
        pendingImages = []

        let isGemma4Model = modelPath.lowercased().contains("gemma-4")
        // Use the model container to prepare input and generate.
        // Only image turns need the processor path; plain text stays on the direct ChatML path.
        let modelContainer = try requireLoadedModelContainer()
        let isVLM = await modelContainer.isVLM
        // Some local checkpoints report VLM capability but ship without processor metadata.
        // In that case, forcing processor.prepare() on text-only turns can crash at runtime.
        let hasProcessorConfig = modelHasProcessorConfig(modelPath)
        // Use processor path only for image turns; text-only inputs bypass processor to avoid
        // empty token crashes from VLM processor.prepare() on non-image prompts.
        let shouldUseProcessorPath = !imageURLs.isEmpty && (isVLM && hasProcessorConfig)
        let enableThinking = thinkingLevel != .fast && !isGemma4Model
        let chatML = history.formatChatML(messages: transformedMessages, enableThinking: enableThinking)

        // For the processor path, capture the Sendable message data to rebuild Chat.Message inside perform.
        // Chat.Message contains CIImage and is not Sendable, so we reconstruct it in the closure.
        // We use the last user-message index rather than content equality to robustly identify which
        // message should receive the image attachments.
        let vlmMessageData: [(role: String, content: String)]? = shouldUseProcessorPath ?
            transformedMessages.map { ($0.role.rawValue, $0.content) }
            : nil
        let vlmLastUserIndex: Int? = shouldUseProcessorPath ?
            transformedMessages.indices.last(where: { transformedMessages[$0].role == .user })
            : nil

        // Start processing spinner before inference begins
        let spinner = Spinner(message: "Processing...")
        await spinner.start()

        let result = try await modelContainer.perform { [currentGenerationConfig, renderer, chatML, imageURLs, vlmMessageData, vlmLastUserIndex, shouldUseProcessorPath] context in
            if Task.isCancelled { throw CancellationError() }

            // Processor path: for image turns and model families that require processor-driven
            // prompt preparation, use UserInput +
            // processor.prepare so model-specific prompt formatting and tensor shapes are respected.
            // Fallback text-only path tokenizes ChatML directly.
            let tokenizer = context.tokenizer
            let input: LMInput
            if let messageData = vlmMessageData {
                // Reconstruct Chat.Message inside the closure (Chat.Message is not Sendable).
                let chatMessages: [Chat.Message] = messageData.enumerated().map { idx, msg in
                    let (role, content) = msg
                    switch role {
                    case "system":    return .system(content)
                    case "assistant": return .assistant(content)
                    case "tool":      return .tool(content)
                    default:          // user
                        // Use index-based identification to robustly find the last user message.
                        let userImages: [UserInput.Image] = (idx == vlmLastUserIndex) ? imageURLs.map { .url($0) } : []
                        return .user(content, images: userImages)
                    }
                }
                let userInput = UserInput(chat: chatMessages)
                let prepared = try await context.processor.prepare(input: userInput)
                if prepared.text.tokens.size > 0 {
                    input = prepared
                } else if imageURLs.isEmpty {
                    let tokens = try AgentLoop.encodeNonEmptyTokens(
                        primaryText: chatML,
                        fallbackTexts: ["hi", "a"],
                        using: tokenizer.encode(text:)
                    )
                    input = LMInput(tokens: MLXArray(tokens))
                } else {
                    throw NSError(
                        domain: "AgentLoop",
                        code: 5,
                        userInfo: [NSLocalizedDescriptionKey: "Processor produced empty prompt tokens for an image input."]
                    )
                }
            } else {
                let tokens = try AgentLoop.encodeNonEmptyTokens(
                    primaryText: chatML,
                    fallbackTexts: ["hi", "a"],
                    using: tokenizer.encode(text:)
                )
                input = LMInput(tokens: MLXArray(tokens))
            }

            // Clean up stale .tmp files from previous crashed/interrupted sessions.
            let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mlx-coder-streaming")
            try? FileManager.default.removeItem(at: tmpDir)
            // Streaming writer: streams tool call content to .tmp files during generation
            let writer = StreamingToolCallWriter(
                toolCallOpen: ToolCallPattern.toolCallOpen,
                toolCallClose: ToolCallPattern.toolCallClose,
                onStatusChange: { message in
                    Task {
                        await spinner.updateMessage(message)
                        await spinner.start()
                    }
                }
            )
            
            var rawResponseText = ""
            var pendingChunk = ""
            var isThinking = enableThinking
            if isThinking {
                renderer.startThinking()
            }
            var hasShownVisibleOutput = false

            func stopSpinnerOnFirstVisibleOutput() {
                guard !hasShownVisibleOutput else { return }
                hasShownVisibleOutput = true
                let semaphore = DispatchSemaphore(value: 0)
                Task {
                    await spinner.stop(clearLine: true)
                    semaphore.signal()
                }
                semaphore.wait()
            }

            var generationParameters = currentGenerationConfig.generateParameters
            if shouldUseProcessorPath {
                generationParameters.repetitionPenalty = nil
                generationParameters.presencePenalty = nil
                generationParameters.frequencyPenalty = nil
            }

            // Build TurboQuant KV cache when enabled.
            // KVCacheSimple layers are replaced with TurboQuantKVCache (fill phase);
            // sliding-window (RotatingKVCache) and other layers are preserved.
            // TurboQuantKVCache auto-compresses on the first single-token update
            // after prefill, so no upstream changes are required.
            let tqCache: [KVCache]? = currentGenerationConfig.turboQuantBits.map { bits in
                makeTurboQuantCaches(
                    model: context.model,
                    parameters: generationParameters,
                    keyBits: bits,
                    valueBits: bits
                )
            }
            
            // For correct streaming detokenization
            var segmentTokens = [Int]()
            var segment = ""
            
            for try await item in try MLXLMCommon.generateTokens(
                input: input,
                cache: tqCache,
                parameters: generationParameters,
                context: context
            ) {
                if Task.isCancelled {
                    Task { await spinner.stop(clearLine: true) }
                    throw CancellationError()
                }
                
                switch item {
                case .token(let id):
                    segmentTokens.append(id)
                    let newSegment = tokenizer.decode(tokens: segmentTokens, skipSpecialTokens: false)
                    
                    // Skip yielding if incomplete multi-byte sequence
                    if newSegment.last == "\u{fffd}" {
                        continue
                    }
                    
                    let newText = String(newSegment.suffix(newSegment.count - segment.count))
                    rawResponseText += newText
                    
                    // Normalize streamed text (including tool-call content handling)
                    // before adding to response/output buffers.
                    let streamResult = writer.process(newText)
                    let displayText = streamResult.displayText
                    
                    if newText.hasSuffix("\n") {
                        if let lastToken = segmentTokens.last {
                            segmentTokens = [lastToken]
                            segment = tokenizer.decode(tokens: segmentTokens, skipSpecialTokens: false)
                        }
                    } else {
                        segment = newSegment
                    }
                    
                    pendingChunk += displayText
                    
                    while !pendingChunk.isEmpty {
                        if !isThinking {
                            if let range = pendingChunk.range(of: ToolCallPattern.thinkOpen) {
                                let before = String(pendingChunk[..<range.lowerBound])
                                if !before.isEmpty {
                                    stopSpinnerOnFirstVisibleOutput()
                                    renderer.printChunk(before)
                                }
                                renderer.startThinking()
                                isThinking = true
                                pendingChunk = String(pendingChunk[range.upperBound...])
                                if pendingChunk.hasPrefix("\n") { pendingChunk.removeFirst() }
                            } else {
                                // Hold if it might be the start of `<think>`
                                let prefixes = ["<", "<t", "<th", "<thi", "<thin", "<think"]
                                if prefixes.contains(where: pendingChunk.hasSuffix) {
                                    break
                                } else {
                                    stopSpinnerOnFirstVisibleOutput()
                                    renderer.printChunk(pendingChunk)
                                    pendingChunk = ""
                                }
                            }
                        } else {
                            if let range = pendingChunk.range(of: ToolCallPattern.thinkClose) {
                                let before = String(pendingChunk[..<range.lowerBound])
                                if !before.isEmpty {
                                    stopSpinnerOnFirstVisibleOutput()
                                    renderer.printThinkingChunk(before)
                                }
                                renderer.endThinking()
                                isThinking = false
                                pendingChunk = String(pendingChunk[range.upperBound...])
                                if pendingChunk.hasPrefix("\n") { pendingChunk.removeFirst() }
                            } else {
                                // Hold if it might be the start of `</think>`
                                let prefixes = ["<", "</", "</t", "</th", "</thi", "</thin", "</think"]
                                if prefixes.contains(where: pendingChunk.hasSuffix) {
                                    break
                                } else {
                                    stopSpinnerOnFirstVisibleOutput()
                                    renderer.printThinkingChunk(pendingChunk)
                                    pendingChunk = ""
                                }
                            }
                        }
                    }
                case .info(let info):
                    stopSpinnerOnFirstVisibleOutput()
                    print()
                    let statMessage = String(format: "Generated %d tokens (%.1f tok/s), prompt: %d tokens (%.1f tok/s)",
                                             info.generationTokenCount, info.tokensPerSecond,
                                             info.promptTokenCount, info.promptTokensPerSecond)
                    renderer.printStatus(statMessage)
                    print()
                }
            }
            
            // Flush any remaining text in pendingChunk
            if !pendingChunk.isEmpty {
                if isThinking {
                    stopSpinnerOnFirstVisibleOutput()
                    renderer.printThinkingChunk(pendingChunk)
                } else {
                    stopSpinnerOnFirstVisibleOutput()
                    renderer.printChunk(pendingChunk)
                }
            }
            
            // Strip EOS tokens if they leaked into the text
            rawResponseText = rawResponseText.replacingOccurrences(of: ToolCallPattern.eosToken, with: "")
            rawResponseText = rawResponseText.trimmingCharacters(in: .whitespacesAndNewlines)
            
            return (text: rawResponseText, writer: writer)
        }

        // Cleanup spinner if generation failed or returned nothing
        Task { await spinner.stop(clearLine: true) }

        return result
    }

    private func requireLoadedModelContainer() throws -> ModelContainer {
        guard let modelContainer else {
            throw NSError(
                domain: "AgentLoop",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Model is currently unloading or not loaded."]
            )
        }
        return modelContainer
    }

    private func modelHasProcessorConfig(_ path: String) -> Bool {
        let expandedPath = NSString(string: path).expandingTildeInPath
        let fm = FileManager.default
        guard fm.fileExists(atPath: expandedPath) else {
            // Hub IDs are downloaded/resolved by MLX internals; keep existing behavior.
            return true
        }

        let modelURL = URL(filePath: expandedPath)
        let processorConfig = modelURL.appendingPathComponent("processor_config.json").path
        let preprocessorConfig = modelURL.appendingPathComponent("preprocessor_config.json").path
        return fm.fileExists(atPath: processorConfig) || fm.fileExists(atPath: preprocessorConfig)
    }

    private static func encodeNonEmptyTokens(
        primaryText: String,
        fallbackTexts: [String],
        using encode: (String) -> [Int]
    ) throws -> [Int] {
        let primaryTokens = encode(primaryText)
        if !primaryTokens.isEmpty {
            return primaryTokens
        }

        for fallback in fallbackTexts {
            let candidate = encode(fallback)
            if !candidate.isEmpty {
                return candidate
            }
        }

        throw NSError(
            domain: "AgentLoop",
            code: 4,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Tokenizer produced an empty token sequence for all fallback prompts."
            ]
        )
    }

    /// Prompt the user to approve a tool call using raw terminal mode.
    private func askForToolApproval(name: String, isPlanMode: Bool) async -> (approved: Bool, suggestion: String?) {
        // Global auto-approve mode for power users.
        if permissions.approvalMode == .yolo {
            await auditLogger?.logApprovalDecision(
                toolName: name,
                mode: mode.rawValue,
                isPlanModePrompt: isPlanMode,
                approved: true,
                suggestion: nil
            )
            return (true, nil)
        }

        // Auto-approve common edit operations while still guarding shell/task.
        if permissions.approvalMode == .autoEdit && !isPlanMode {
            let autoEditTools: Set<String> = ["write_file", "edit_file", "append_file", "patch"]
            if autoEditTools.contains(name) {
                await auditLogger?.logApprovalDecision(
                    toolName: name,
                    mode: mode.rawValue,
                    isPlanModePrompt: isPlanMode,
                    approved: true,
                    suggestion: nil
                )
                return (true, nil)
            }
        }

        if autoApproveAllTools && !isPlanMode {
            return (true, nil)
        }

        await CancelController.shared.suspendListening()

        func resumeCancelListeningAndReturn(_ result: (approved: Bool, suggestion: String?)) async -> (approved: Bool, suggestion: String?) {
            await CancelController.shared.resumeListeningIfNeeded()
            return result
        }
        
        var originalTermios = termios()
        tcgetattr(STDIN_FILENO, &originalTermios)
        
        var rawTermios = originalTermios
        rawTermios.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG)
        rawTermios.c_cc.16 = 1  // VMIN - wait for at least 1 byte
        rawTermios.c_cc.17 = 0  // VTIME
        tcsetattr(STDIN_FILENO, TCSANOW, &rawTermios)
        
        // Flush any stale bytes from stdin that may have been buffered
        // during async operations like Shift+Tab mode cycling.
        tcflush(STDIN_FILENO, TCIFLUSH)
        
        let options = isPlanMode ? [
            "Switch to AGENT mode and allow",
            "Stay in PLAN mode and deny with suggestion (esc)"
        ] : [
            "Yes, allow once",
            "Yes, allow always in this session",
            "No, suggest changes (esc)"
        ]
        var selectedIndex = 0
        var menuDrawnOnce = false
        var footerHint = "Use 1/2/3, arrows, Enter, or Esc."
        
        func drawMenu() {
            if menuDrawnOnce {
                print("\u{1B}[\(options.count + 1)A", terminator: "")
            } else {
                print() // empty line only once at the start
            }
            
            let message = isPlanMode ? "Tool '\(name)' is blocked in PLAN mode. Switch to AGENT mode?" : "Do you want to proceed?"
            print("\r\u{1B}[K\(message)")
            for (i, option) in options.enumerated() {
                if i == selectedIndex {
                    print("\r\u{1B}[K\u{001B}[32m● \(i + 1). \(option)\u{001B}[0m")
                } else {
                    print("\r\u{1B}[K  \(i + 1). \(option)")
                }
            }
            print("\r\u{1B}[K\(footerHint) Waiting for user confirmation... [\(selectedIndex + 1)/\(options.count)]: ", terminator: "")
            fflush(stdout)
            
            menuDrawnOnce = true
        }
        
        // Hide cursor
        print("\u{1B}[?25l", terminator: "")
        renderer.printStatus("[Key mode] Approval required. \(footerHint)")
        drawMenu()
        
        var finalSelection = -1
        var shouldDrainInputTail = false
        
        while true {
            var byte: UInt8 = 0
            let bytesRead = read(STDIN_FILENO, &byte, 1)
            if bytesRead <= 0 { continue }
            
            if byte == 27 { // ESC or escape sequence
                let seq = TerminalKeyParser.readEscapeSequence()
                let escapeKind = TerminalKeyParser.classifyEscapeSequence(seq)
                if escapeKind == .bare {
                    // Bare ESC — treat as deny/cancel
                    shouldDrainInputTail = true
                    finalSelection = isPlanMode ? 1 : 2
                    break
                }

                if let keypadSelection = TerminalKeyParser.numericSelection(forEscapeSequence: seq, allowThirdOption: !isPlanMode) {
                    selectedIndex = keypadSelection
                    drawMenu()
                    finalSelection = keypadSelection
                    break
                }

                if let direction = TerminalKeyParser.arrowDirection(for: seq) {
                    if direction == .up {
                        selectedIndex = max(0, selectedIndex - 1)
                        footerHint = "Use 1/2/3, arrows, Enter, or Esc."
                        drawMenu()
                    } else if direction == .down {
                        selectedIndex = min(options.count - 1, selectedIndex + 1)
                        footerHint = "Use 1/2/3, arrows, Enter, or Esc."
                        drawMenu()
                    }
                } else {
                    // Alt-key combos or unsupported escape sequences are ignored.
                    shouldDrainInputTail = true
                    footerHint = "Unsupported key. Use 1/2/3, arrows, Enter, or Esc."
                    drawMenu()
                }
            } else if byte == 10 || byte == 13 { // Enter
                finalSelection = selectedIndex
                break
            } else if let numericSelection = TerminalKeyParser.numericSelection(for: byte, allowThirdOption: !isPlanMode) {
                selectedIndex = numericSelection
                footerHint = "Use 1/2/3, arrows, Enter, or Esc."
                drawMenu()
                finalSelection = numericSelection
                break
            } else if byte == 3 { // Ctrl+C
                // Restore terminal and exit completely
                tcsetattr(STDIN_FILENO, TCSANOW, &originalTermios)
                print("\u{1B}[?25h\n")
                exit(1)
            } else {
                footerHint = "Unsupported key. Use 1/2/3, arrows, Enter, or Esc."
                drawMenu()
            }
        }
        
        // Drain buffered tails only when we consumed partial escape sequences.
        if shouldDrainInputTail {
            TerminalKeyParser.drainAvailableInput()
        }
        
        // Restore terminal and show cursor
        tcsetattr(STDIN_FILENO, TCSANOW, &originalTermios)
        print("\u{1B}[?25h\n")
        
        if finalSelection == 0 {
            await auditLogger?.logApprovalDecision(
                toolName: name,
                mode: mode.rawValue,
                isPlanModePrompt: isPlanMode,
                approved: true,
                suggestion: nil
            )
            return await resumeCancelListeningAndReturn((true, nil))
        } else if finalSelection == 1 && !isPlanMode {
            autoApproveAllTools = true
            await auditLogger?.logApprovalDecision(
                toolName: name,
                mode: mode.rawValue,
                isPlanModePrompt: isPlanMode,
                approved: true,
                suggestion: "session_auto_approve_enabled"
            )
            return await resumeCancelListeningAndReturn((true, nil))
        } else {
            // Option 3 or ESC: Suggest changes
            print("[\(name)] Blocked. Suggest changes (or press Enter to deny with no comment): ", terminator: "")
            fflush(stdout)
            guard let suggestion = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespacesAndNewlines), !suggestion.isEmpty else {
                await auditLogger?.logApprovalDecision(
                    toolName: name,
                    mode: mode.rawValue,
                    isPlanModePrompt: isPlanMode,
                    approved: false,
                    suggestion: nil
                )
                return await resumeCancelListeningAndReturn((false, nil))
            }
            await auditLogger?.logApprovalDecision(
                toolName: name,
                mode: mode.rawValue,
                isPlanModePrompt: isPlanMode,
                approved: false,
                suggestion: suggestion
            )
            return await resumeCancelListeningAndReturn((false, suggestion))
        }
    }

    /// Build the system prompt with tool definitions.
    public static func buildSystemPromptComposition(
        registry: ToolRegistry,
        maxTokens: Int? = nil,
        mode: WorkingMode = .agent,
        thinkingLevel: ThinkingLevel = .high,
        taskType: TaskType = .general,
        baseInstructions: String? = nil,
        memorySection: String? = nil,
        customizationSection: String? = nil,
        skillsMetadata: [SkillMetadata] = []
    ) async -> PromptComposition {
        let defaultInstructions = "You are a helpful coding assistant. You have access to tools to interact with the filesystem and execute code. CRITICAL: If you are working through a task list or todo list, YOU MUST ONLY PROCESS ONE ITEM AT A TIME. After completing a single item, YOU MUST exit and wait for the user to explicitly ask you to proceed to the next item. NEVER automatically move to the next task in the list without explicit user permission. ALWAYS check if a file exists before editing it. If the user doesn't mention a specific version for a library, ALWAYS use the latest stable version. If a CLI tool gives an error, you should run the CLI tool's help command (e.g., `--help`, `--help-all`) to learn more. Note that some tools have multiple levels of help, such as `dotnet list --help` and `dotnet list package --help`. When generating files, always build incrementally in small, controlled iterations: scaffold the minimal valid structure first, save to disk, then add one section at a time, saving after each iteration. Never generate large, monolithic files in a single step. Prefer append/update over rewrite. STABILITY: You MUST ONLY MODIFY ONE FILE PER TURN. After modifying a file (using `write_file`, `edit_file`, `append_file`, or `patch`), you MUST run the appropriate build or test command to verify the change and check for new errors. Do not attempt to fix multiple files in a single turn if any of them could affect the build. Always rebuild and check for errors after every single file modification."
        
        var coreInstructions = baseInstructions ?? defaultInstructions
        
        if mode == .plan {
            coreInstructions += "\n\nCRITICAL: You are currently in PLAN MODE. Your goal is to research the codebase and propose a comprehensive plan. DO NOT execute any tools that modify the filesystem (like write_file, edit_file, append_file, patch) or the system (bash) WITHOUT ASKING FIRST. If you call one of these tools, the user will be prompted to switch you to AGENT MODE and execute. You can use this to transition from planning to implementation once your plan is approved. For now, focus on gathering context and designing your approach."
        }
        
        if taskType == .reasoning {
            coreInstructions += "\n\nREASONING TASK: Please reason step by step. If you reach a final mathematical or logical conclusion, put your final answer within \\boxed{}."
        }
        
        if thinkingLevel == .fast {
            coreInstructions += "\n\nTHINKING STYLE: DO NOT USE internal thinking (no <think> blocks). NO PREAMBLE. NO REASONING. RESPOND ONLY WITH THE FINAL ANSWER OR TOOL CALLS IMMEDIATELY. Be extremely concise/direct."
        } else if thinkingLevel == .minimal {
            coreInstructions += "\n\nTHINKING STYLE: Use at most ~\(thinkingLevel.budgetTokens) tokens of internal thinking (between <think> and </think>). One or two sentences of reasoning at most. Jump immediately to your answer or tool call."
        } else if thinkingLevel == .low {
            coreInstructions += "\n\nTHINKING STYLE: Keep your internal thinking (between <think> and </think>) to at most ~\(thinkingLevel.budgetTokens) tokens. Be concise — identify the key insight and proceed to the solution quickly."
        } else if thinkingLevel == .medium {
            coreInstructions += "\n\nTHINKING STYLE: Use moderate internal thinking (between <think> and </think>), targeting ~\(thinkingLevel.budgetTokens) tokens. Reason through the key steps but stay focused. Avoid over-thinking straightforward decisions."
        } else {
            coreInstructions += "\n\nTHINKING STYLE: Feel free to think deeply (target up to ~\(thinkingLevel.budgetTokens) tokens between <think> and </think>). Explore multiple approaches, reason about trade-offs, and plan your steps carefully before responding."
        }
        
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let dateString = formatter.string(from: now)
        
        let runtimeSection = """
        Current time: \(dateString)

        When you need to use a tool, respond with the tool call in this format:
        \(ToolCallPattern.toolCallOpen)
        {"name": "tool_name", "arguments": {"param": "value"}}
        \(ToolCallPattern.toolCallClose)

        You can call multiple tools in a single response. After tool results are returned, continue your reasoning.
        """

        let toolsBlock: String

        do {
            let promptFilter = buildToolPromptFilter(mode: mode, taskType: taskType)
            toolsBlock = try await registry.generateToolsBlock(filter: promptFilter)
        } catch {
            toolsBlock = "<!-- error generating tools block: \(error) -->"
        }

        return PromptComposer.compose(
            coreInstructions: coreInstructions,
            memorySection: memorySection,
            customizationSection: customizationSection,
            runtimeSection: runtimeSection,
            skillsMetadata: skillsMetadata,
            toolsBlock: toolsBlock,
            maxTokens: maxTokens
        )
    }

    private static func buildToolPromptFilter(mode: WorkingMode, taskType: TaskType) -> ToolPromptFilter {
        switch (mode, taskType) {
        case (.plan, _):
            return ToolPromptFilter(modeHint: mode.rawValue, taskTypeHint: taskType.rawValue, maxTools: 14, maxMCPTools: 1)
        case (.agent, .coding):
            return ToolPromptFilter(modeHint: mode.rawValue, taskTypeHint: taskType.rawValue, maxTools: 22, maxMCPTools: 2)
        case (.agent, .reasoning):
            return ToolPromptFilter(modeHint: mode.rawValue, taskTypeHint: taskType.rawValue, maxTools: 16, maxMCPTools: 1)
        case (.agent, .general):
            return ToolPromptFilter(modeHint: mode.rawValue, taskTypeHint: taskType.rawValue, maxTools: 18, maxMCPTools: 2)
        }
    }

    public static func buildSystemPrompt(
        registry: ToolRegistry,
        maxTokens: Int? = nil,
        mode: WorkingMode = .agent,
        thinkingLevel: ThinkingLevel = .high,
        taskType: TaskType = .general,
        baseInstructions: String? = nil,
        memorySection: String? = nil,
        customizationSection: String? = nil,
        skillsMetadata: [SkillMetadata] = []
    ) async -> String {
        let composition = await buildSystemPromptComposition(
            registry: registry,
            maxTokens: maxTokens,
            mode: mode,
            thinkingLevel: thinkingLevel,
            taskType: taskType,
            baseInstructions: baseInstructions,
            memorySection: memorySection,
            customizationSection: customizationSection,
            skillsMetadata: skillsMetadata
        )
        return composition.prompt
    }

    /// Perform automated build check after file modifications in agent/coding mode.
    /// This checks for build errors and attempts fixes if needed.
    private func performBuildCheckIfNeeded(modifiedPaths: Set<String>) async {
        guard shouldRunBuildCheck(for: modifiedPaths) else {
            renderer.printStatus("⏭️  Skipping build check: only non-build files were modified")
            return
        }

        renderer.printStatus("🔧 Checking builds in agent/coding mode...")
        
        let success = await buildCheckManager.checkBeforeCommit(
            workspace: workspace,
            onProgress: { msg in
                // Progress updates from Ralph loop
                self.renderer.printStatus("  → \(msg)")
            },
            streamRenderer: renderer
        )
        
        if success {
            renderer.printStatus("✅ Build check passed - ready for commit!")
        } else {
            // Build check failed even after fix attempts - inform user
            renderer.printStatus("⚠️  Build has errors that need manual fixing")
            renderer.printStatus("Use build_check tool for detailed error information, then fix and commit.")
        }
    }

    private func shouldRunBuildCheck(for modifiedPaths: Set<String>) -> Bool {
        modifiedPaths.contains { isBuildRelevantPath($0) }
    }

    private func isBuildRelevantPath(_ path: String) -> Bool {
        let normalized = path.lowercased()
        let fileName = URL(fileURLWithPath: normalized).lastPathComponent
        let ext = URL(fileURLWithPath: normalized).pathExtension

        let buildRelevantExtensions: Set<String> = [
            "swift", "c", "cc", "cpp", "cxx", "h", "hpp", "hh", "m", "mm",
            "rs", "go", "java", "kt", "kts", "cs", "ts", "tsx", "js", "jsx",
            "py", "rb", "php", "scala"
        ]

        if buildRelevantExtensions.contains(ext) {
            return true
        }

        let buildRelevantFiles: Set<String> = [
            // Swift/C/C++
            "package.swift", "package.resolved", "makefile", "cmakelists.txt",

            // Node.js / TypeScript
            "package.json", "package-lock.json", "npm-shrinkwrap.json", "pnpm-lock.yaml",
            "yarn.lock", "tsconfig.json", "tsconfig.base.json", "vite.config.js", "vite.config.ts",
            "webpack.config.js", "webpack.config.ts", "next.config.js", "next.config.mjs",
            "nuxt.config.js", "nuxt.config.ts", "rollup.config.js", "rollup.config.ts",
            "eslint.config.js", ".eslintrc", ".eslintrc.js", ".eslintrc.cjs", ".eslintrc.json",

            // .NET / C#
            "global.json", "nuget.config", "directory.build.props", "directory.build.targets",

            // JVM / Rust / Go / Python
            "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts",
            "pom.xml", "cargo.toml", "cargo.lock", "go.mod", "go.sum",
            "requirements.txt", "pyproject.toml", "poetry.lock", "pdm.lock"
        ]

        if buildRelevantFiles.contains(fileName) {
            return true
        }

        // Project-level manifests that carry semantics through suffixes.
        if fileName.hasSuffix(".csproj") || fileName.hasSuffix(".vbproj") || fileName.hasSuffix(".fsproj") || fileName.hasSuffix(".sln") {
            return true
        }

        // Generic CI/build pipelines may impact build success.
        if fileName == "dockerfile" || fileName.hasPrefix("dockerfile.") {
            return true
        }

        return false
    }

    // MARK: - Semantic Parameter Correction

    /// Structured result from semantic correction — Sendable-safe.
    private struct SemanticCorrection: Sendable {
        let path: String
        let oldText: String
        let newText: String
    }

    /// Attempts to semantically correct a failed tool call using lightweight LLM inference.
    ///
    /// When `edit_file` fails because `old_text` doesn't match the file, this method:
    /// 1. Reads the actual file content
    /// 2. Sends a focused prompt to the LLM to find the correct `old_text`
    /// 3. Returns corrected arguments (preserving the original `new_text`)
    ///
    /// This avoids wasting tokens on full regeneration — the LLM only provides the
    /// corrected `old_text`, and the agent reuses the previously generated `new_text`.
    private func attemptSemanticCorrection(
        toolName: String,
        arguments: [String: Any],
        errorResult: ToolResult
    ) async -> SemanticCorrection? {
        guard toolName == "edit_file" else { return nil }
        guard let path = arguments["path"] as? String else { return nil }
        guard let oldText = arguments["old_text"] as? String else { return nil }
        guard let newText = arguments["new_text"] as? String else { return nil }

        // Only attempt correction for "old_text not found" type errors
        let errorPreview = errorResult.content.prefix(100).lowercased()
        guard errorPreview.contains("not found") || errorPreview.contains("doesn't match") || errorPreview.contains("make sure") else {
            return nil
        }

        // Read the actual file content
        let resolvedPath = (path as NSString).isAbsolutePath
            ? path
            : (workspace as NSString).appendingPathComponent(path)

        guard FileManager.default.fileExists(atPath: resolvedPath),
              let fileContent = try? String(contentsOfFile: resolvedPath, encoding: .utf8) else {
            return nil
        }

        renderer.printStatus("[auto-correct] \(toolName): old_text not found — using LLM to find correct match...")

        // Build a focused, token-efficient prompt
        let maxFileChars = 8000
        let truncatedFile = fileContent.count > maxFileChars
            ? String(fileContent.prefix(maxFileChars)) + "\n... [file truncated]"
            : fileContent

        let correctionPrompt = """
        You are a precise text matching assistant. Your ONLY task is to find the exact text in the file that corresponds to the user's intended old_text.

        FILE CONTENT:
        ```
        \(truncatedFile)
        ```

        INTENDED OLD_TEXT (what the user tried to match):
        ```
        \(oldText)
        ```

        Return ONLY the exact text from the file that should be replaced. Do not explain, do not add markdown. Return the exact string as it appears in the file, preserving all whitespace and indentation.
        """

        // Generate correction with minimal tokens
        let correctionConfig = GenerationEngine.Config(
            maxTokens: 512,
            temperature: 0.1,
            topP: 0.9,
            topK: 5,
            minP: 0.0,
            repetitionPenalty: 1.0,
            repetitionContextSize: currentGenerationConfig.repetitionContextSize,
            presencePenalty: 0.0,
            presenceContextSize: currentGenerationConfig.presenceContextSize,
            frequencyPenalty: currentGenerationConfig.frequencyPenalty,
            frequencyContextSize: currentGenerationConfig.frequencyContextSize,
            kvBits: currentGenerationConfig.kvBits,
            kvGroupSize: currentGenerationConfig.kvGroupSize,
            quantizedKVStart: currentGenerationConfig.quantizedKVStart,
            longContextThreshold: currentGenerationConfig.longContextThreshold
        )

        guard let modelContainer else { return nil }

        do {
            let correctedOldText = try await modelContainer.perform { context in
                if Task.isCancelled { throw CancellationError() }
                let tokenizer = context.tokenizer
                let tokens = try AgentLoop.encodeNonEmptyTokens(
                    primaryText: correctionPrompt,
                    fallbackTexts: ["a"],
                    using: tokenizer.encode(text:)
                )
                let inputTokens = MLXArray(tokens)
                let input = MLXLMCommon.LMInput(tokens: inputTokens)

                var responseText = ""
                for try await item in try MLXLMCommon.generateTokens(
                    input: input,
                    parameters: correctionConfig.generateParameters,
                    context: context
                ) {
                    if Task.isCancelled { throw CancellationError() }
                    if case .token(let id) = item {
                        let decoded = tokenizer.decode(tokens: [id], skipSpecialTokens: false)
                        responseText += decoded
                        // Early exit if we have enough text
                        if responseText.count > 2000 { break }
                    }
                }
                return responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            // Clean up the response — strip markdown code blocks if present
            var cleanedOldText = correctedOldText
            if cleanedOldText.hasPrefix("```") {
                let lines = cleanedOldText.components(separatedBy: .newlines)
                cleanedOldText = lines.filter { !$0.hasPrefix("```") }.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            // Verify the corrected text actually exists in the file
            guard fileContent.contains(cleanedOldText) else {
                renderer.printStatus("[auto-correct] LLM suggestion didn't match file — skipping correction")
                return nil
            }

            // Verify it's different from the original attempt
            guard cleanedOldText != oldText else {
                renderer.printStatus("[auto-correct] LLM returned same text — skipping correction")
                return nil
            }

            renderer.printStatus("[auto-correct] Found correct old_text (\(cleanedOldText.count) chars vs original \(oldText.count) chars)")

            await auditLogger?.logParameterCorrection(
                toolName: toolName,
                originalArgumentsJSON: serializedArgumentsPreview(arguments),
                correctedArgumentsJSON: serializedArgumentsPreview(["path": path, "old_text": cleanedOldText, "new_text": newText]),
                corrections: ["LLM semantic correction: old_text matched in file"]
            )

            return SemanticCorrection(path: path, oldText: cleanedOldText, newText: newText)

        } catch is CancellationError {
            return nil
        } catch {
            renderer.printStatus("[auto-correct] LLM correction failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Streamed Tool Call Handling

    /// Handles a tool call whose content was streamed to a .tmp file during generation.
    /// Shows a diff to the user and applies the change if approved.
    private func handleStreamedToolCall(_ call: StreamedToolCall) async -> ToolResult {
        let resolvedPath: String
        do {
            resolvedPath = try permissions.validatePath(call.path)
        } catch {
            try? FileManager.default.removeItem(at: call.contentFile)
            return .error(error.localizedDescription)
        }

        // Read the tmp content
        guard let tmpContent = try? String(contentsOf: call.contentFile, encoding: .utf8) else {
            try? FileManager.default.removeItem(at: call.contentFile)
            return .error("Failed to read streamed content for \(call.path)")
        }

        // Read the original file content (if exists)
        let originalContent: String?
        if FileManager.default.fileExists(atPath: resolvedPath) {
            originalContent = try? String(contentsOfFile: resolvedPath, encoding: .utf8)
        } else {
            originalContent = nil
        }

        // Generate and display the diff
        let diff = generateDiff(original: originalContent, new: tmpContent, path: call.path)
        renderer.printStatus("\n\(diff)")

        // Ask for approval
        let approved: Bool
        if permissions.approvalMode == .yolo {
            approved = true
        } else if permissions.approvalMode == .autoEdit && !["write_file", "edit_file", "append_file"].contains(call.toolName) {
            // autoEdit only auto-approves edit tools
            approved = await askForToolApproval(name: call.toolName, isPlanMode: mode == .plan).approved
        } else if autoApproveAllTools {
            approved = true
        } else {
            approved = await askForToolApproval(name: call.toolName, isPlanMode: mode == .plan).approved
        }

        if !approved {
            try? FileManager.default.removeItem(at: call.contentFile)
            return .error("User rejected the file change for \(call.path)")
        }

        // Apply the change
        do {
            switch call.toolName {
            case "write_file":
                // Replace existing file content if present; otherwise move into place.
                let targetURL = URL(fileURLWithPath: resolvedPath)
                let parentDir = targetURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

                if FileManager.default.fileExists(atPath: targetURL.path) {
                    _ = try FileManager.default.replaceItemAt(targetURL, withItemAt: call.contentFile)
                } else {
                    try FileManager.default.moveItem(at: call.contentFile, to: targetURL)
                }
                return .success("Wrote \(call.path) (\(tmpContent.count) bytes)")

            case "edit_file":
                // For edit_file, the tmp contains new_text; we need old_text from otherArgs
                guard let fileContent = originalContent else {
                    // Path not found — preserve new_text so the LLM only needs to fix the path.
                    preservedEditTmpFiles[call.path] = call.contentFile
                    return .error("File not found: \(call.path). new_text is preserved and will be reused automatically; only correct the path.")
                }

                // Streamed calls bypass normal execution-time correction, so run the same
                // deterministic correction pipeline here for aliases and fuzzy old_text fixes.
                var streamedArguments = call.otherArgs
                streamedArguments["path"] = call.path
                streamedArguments["new_text"] = tmpContent
                let correctionResult = await ParameterCorrectionService.correct(
                    toolName: "edit_file",
                    arguments: streamedArguments,
                    workspaceRoot: workspace
                )
                if correctionResult.wasCorrected {
                    for correction in correctionResult.corrections {
                        renderer.printStatus("[auto-correct] edit_file (streamed): \(correction)")
                    }
                }

                guard let oldText = correctionResult.correctedArguments["old_text"] as? String,
                      !oldText.isEmpty else {
                    try? FileManager.default.removeItem(at: call.contentFile)
                    return .error("Missing old_text for edit_file")
                }
                let occurrences = fileContent.components(separatedBy: oldText).count - 1
                if occurrences != 1 {
                    if occurrences == 0 {
                        // Try semantic correction before giving up, passing tmpContent as new_text.
                        let fakeArgs: [String: Any] = ["path": call.path, "old_text": oldText, "new_text": tmpContent]
                        let fakeError = ToolResult.error("old_text not found in \(call.path). Make sure the text matches exactly.")
                        if let correction = await attemptSemanticCorrection(toolName: "edit_file", arguments: fakeArgs, errorResult: fakeError) {
                            renderer.printStatus("[auto-correct] Retrying streamed edit_file with corrected old_text...")
                            let corrected = fileContent.replacingOccurrences(of: correction.oldText, with: tmpContent)
                            do {
                                try corrected.write(toFile: resolvedPath, atomically: true, encoding: .utf8)
                                try? FileManager.default.removeItem(at: call.contentFile)
                                return .success("Applied edit to \(call.path) (old_text auto-corrected)")
                            } catch {
                                // Write failed even after correction — preserve tmp.
                                preservedEditTmpFiles[call.path] = call.contentFile
                                return .error("Failed to write \(call.path) after auto-correction: \(error.localizedDescription). new_text is preserved and will be reused automatically.")
                            }
                        }
                        // Semantic correction unavailable or unsuccessful — preserve tmp.
                        preservedEditTmpFiles[call.path] = call.contentFile
                        return .error("old_text not found in \(call.path). Make sure the text matches exactly, including whitespace. new_text is preserved and will be reused automatically; only correct old_text.")
                    } else {
                        // Duplicate match — preserve tmp and ask for more context.
                        preservedEditTmpFiles[call.path] = call.contentFile
                        return .error("old_text found \(occurrences) times in \(call.path). Must be unique — add more surrounding context to old_text. new_text is preserved and will be reused automatically.")
                    }
                }
                let updatedContent = fileContent.replacingOccurrences(of: oldText, with: tmpContent)
                do {
                    try updatedContent.write(toFile: resolvedPath, atomically: true, encoding: .utf8)
                } catch {
                    // Write failed — preserve tmp for retry.
                    preservedEditTmpFiles[call.path] = call.contentFile
                    return .error("Failed to write \(call.path): \(error.localizedDescription). new_text is preserved and will be reused automatically; only correct the path or permissions.")
                }
                try? FileManager.default.removeItem(at: call.contentFile)
                return .success("Applied edit to \(call.path)")

            case "append_file":
                // Append tmp content to original file
                if let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: resolvedPath)) {
                    try fh.seekToEnd()
                    try fh.write(contentsOf: tmpContent.data(using: .utf8) ?? Data())
                    fh.closeFile()
                } else {
                    try tmpContent.write(toFile: resolvedPath, atomically: true, encoding: .utf8)
                }
                try? FileManager.default.removeItem(at: call.contentFile)
                return .success("Appended to \(call.path) (\(tmpContent.count) bytes)")

            default:
                try? FileManager.default.removeItem(at: call.contentFile)
                return .error("Unsupported streamed tool: \(call.toolName)")
            }
        } catch {
            try? FileManager.default.removeItem(at: call.contentFile)
            return .error("Failed to apply change to \(call.path): \(error.localizedDescription)")
        }
    }

    /// Generate a unified diff between original and new content.
    private func generateDiff(original: String?, new: String, path: String) -> String {
        guard let original = original else {
            // New file — show the first few lines
            let lines = new.components(separatedBy: .newlines)
            let preview = lines.prefix(20).joined(separator: "\n")
            let truncated = lines.count > 20 ? "\n... (\(lines.count - 20) more lines)" : ""
            return "--- /dev/null\n+++ b/\(path)\n@@ -0,0 +1,\(lines.count) @@\n\(preview)\(truncated)"
        }

        let origLines = original.components(separatedBy: .newlines)
        let newLines = new.components(separatedBy: .newlines)

        // Simple unified diff implementation
        var diff = "--- a/\(path)\n+++ b/\(path)\n"
        var i = 0
        var j = 0
        var context: [String] = []
        var changes: [String] = []
        var origStart = 1
        var origCount = 0
        var newStart = 1
        var newCount = 0

        while i < origLines.count || j < newLines.count {
            if i < origLines.count && j < newLines.count && origLines[i] == newLines[j] {
                // Context line
                if !changes.isEmpty {
                    // Flush previous hunk
                    diff += buildHunk(origStart: origStart, origCount: origCount, newStart: newStart, newCount: newCount, changes: changes)
                    changes = []
                    origCount = 0
                    newCount = 0
                }
                context.append(origLines[i])
                if context.count > 3 {
                    context.removeFirst()
                    origStart = i + 2
                    newStart = j + 2
                }
                i += 1
                j += 1
            } else {
                // Change
                if context.isEmpty && changes.isEmpty {
                    origStart = max(1, i)
                    newStart = max(1, j)
                }
                if i < origLines.count {
                    changes.append("-\(origLines[i])")
                    origCount += 1
                    i += 1
                }
                if j < newLines.count {
                    changes.append("+\(newLines[j])")
                    newCount += 1
                    j += 1
                }
                context = []
            }
        }

        if !changes.isEmpty {
            diff += buildHunk(origStart: origStart, origCount: origCount, newStart: newStart, newCount: newCount, changes: changes)
        }

        return diff.isEmpty ? "(no changes)" : diff
    }

    private func buildHunk(origStart: Int, origCount: Int, newStart: Int, newCount: Int, changes: [String]) -> String {
        let origRange = origCount > 0 ? "\(origStart),\(origCount)" : "\(origStart),0"
        let newRange = newCount > 0 ? "\(newStart),\(newCount)" : "\(newStart),0"
        return "@@ -\(origRange) +\(newRange) @@\n" + changes.joined(separator: "\n") + "\n"
    }
}
