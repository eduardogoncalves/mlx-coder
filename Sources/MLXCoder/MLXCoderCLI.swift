// Sources/MLXCoder/MLXCoderCLI.swift
// Entry point for the mlx-coder terminal agent

import ArgumentParser
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Darwin
#if canImport(FoundationModels)
import FoundationModels
#endif

@main
struct MLXCoderCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mlx-coder",
        abstract: "Swift terminal agent for Apple Silicon — loads LLM in-process via MLX-Swift",
        version: "0.1.0.202604091520",
        subcommands: [ChatCommand.self, RunCommand.self, ListToolsCommand.self, ShowAuditCommand.self, ShowConfigCommand.self, DoctorCommand.self],
        defaultSubcommand: ChatCommand.self
    )

    @OptionGroup var testAbsorber: TestAbsorber
}

// MARK: - Test flags absorber

struct TestAbsorber: ParsableArguments, Sendable {
    // Silently absorb flags that the XCTest harness passes when it
    // re-invokes the binary after running tests.  Without this, ArgumentParser
    // exits with code 1 and `swift test` reports failure even if all tests pass.
    
    @Option(name: .customLong("test-bundle-path"), help: .hidden)
    var testBundlePath: String?

    @Option(name: .customLong("configuration"), help: .hidden)
    var testConfiguration: String?

    @Option(name: .customLong("testing-library"), help: .hidden)
    var testLibrary: String?

    var isTestInvocation: Bool {
        testBundlePath != nil || testConfiguration != nil || testLibrary != nil
    }
}

// MARK: - Shared model arguments

struct ModelArguments: ParsableArguments, Sendable {
    @Option(name: .long, help: "Path to the model directory")
    var model: String = "~/models/Qwen/Qwen3.5-9B-4bit"

    @Option(name: .long, help: "Workspace root directory for tool operations")
    var workspace: String = "."

    @Option(name: .long, help: "Maximum number of tokens to generate per turn")
    var maxTokens: Int = 4096

    @Option(name: .long, help: "Sampling temperature")
    var temperature: Float = 0.6

    @Option(name: .long, help: "Top-p sampling")
    var topP: Float = 1.0

    @Option(name: .long, help: "KV cache quantization bits (nil = no quantization)")
    var kvBits: Int?

    @Option(name: .long, help: "KV cache quantization group size (default: chip profile value, typically 64)")
    var kvGroupSize: Int?

    @Option(name: .long, help: "First transformer layer to apply KV cache quantization (0 = all layers)")
    var quantizedKVStart: Int?

    @Option(name: .long, help: "Enable TurboQuant KV cache compression. Specify bits per element (e.g. 3). Mutually exclusive with --kv-bits.")
    var turboQuantBits: Int?

    @Flag(name: .long, inversion: .prefixedNo, help: "Enable macOS seatbelt sandboxing for shell commands")
    var sandbox: Bool = true

    @Option(name: .long, help: "Approval mode for destructive tools: default, auto-edit, yolo")
    var approvalMode: String = "default"

    @Option(name: .long, help: "Optional audit log file path for tool decisions/executions (default: ~/.mlx-coder/audit.log.jsonl)")
    var auditLogPath: String?

    @Option(name: .long, help: "Optional JSON policy file for per-tool/per-path allow/deny rules")
    var policyFile: String?

    @Flag(name: .long, help: "Enable dry-run mode for destructive tools (write/edit/patch/bash/task).")
    var dryRun: Bool = false

    @Option(name: .long, help: "Optional path to auto-save markdown history when chat exits")
    var autoSaveHistory: String?

    @Option(name: .long, help: "Optional path to auto-save JSON history when chat exits")
    var autoSaveHistoryJSON: String?

    @Option(name: .long, help: "Optional MCP server HTTP endpoint (JSON-RPC)")
    var mcpEndpoint: String?

    @Option(name: .long, help: "Logical MCP server name used in tool prefixes")
    var mcpName: String = "remote"

    @Option(name: .long, help: "MCP request timeout in seconds")
    var mcpTimeout: Int = 30

    @Option(name: .long, help: "Comma-separated MCP server names to include (overrides config allow list)")
    var mcpInclude: String?

    @Option(name: .long, help: "Comma-separated MCP server names to exclude (applied after include)")
    var mcpExclude: String?

    @Flag(name: .long, help: "Show verbose output including thinking blocks")
    var verbose: Bool = false

    @Option(name: .long, help: "Initial working mode (agent or plan)")
    var mode: String = "plan"

    @OptionGroup var testAbsorber: TestAbsorber
}

// MARK: - Chat subcommand (interactive REPL)

struct ChatCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chat",
        abstract: "Start an interactive chat session with the agent"
    )

    @OptionGroup var args: ModelArguments

    mutating func run() async throws {
        guard !args.testAbsorber.isTestInvocation else { return }
        let renderer = StreamRenderer(verbose: args.verbose)

        var selectedModel = args.model

        // Detect chip and configure memory
        let chipInfo = ChipDetector.detect()
        let profile = ParameterProfile.forChip(chipInfo)
        let budget = MemoryGuard.budgetFor(chip: chipInfo)
        MemoryGuard.configure(budget: budget)

        renderer.printStatus("Detected \(chipInfo.family.rawValue) with \(String(format: "%.0f", chipInfo.totalMemoryGB)) GB RAM")
        renderer.printStatus("Memory budget: \(budget.totalBytes / 1_000_000) MB")

        // If no local model exists, ask whether to download a recommended MLX model.
        if !localModelExists(selectedModel) && !looksLikeHubModelID(selectedModel) {
            renderer.printStatus("No local model found at \(selectedModel).")
            if let chosenHubModel = promptForRecommendedModelDownload() {
                selectedModel = chosenHubModel
                renderer.printStatus("Selected model: \(selectedModel)")
            } else {
                renderer.printStatus("Falling back to Apple Foundation model in general mode.")
                if await runAppleFoundationChatFallback(renderer: renderer) {
                    return
                }
                renderer.printError("Apple Foundation model is unavailable on this system. Re-run and choose a download option, or pass --model with a local model path/Hub ID.")
                return
            }
        }

        // Load model
        renderer.printStatus("Loading model from \(selectedModel)...")
        let modelContainer: ModelContainer
        do {
            modelContainer = try await loadModelWithCancellation(
                from: selectedModel,
                memoryLimit: budget.totalBytes,
                cacheLimit: budget.cacheBytes,
                renderer: renderer
            )
        } catch is CancellationError {
            return
        } catch {
            renderer.printError("Failed to load model: \(error.localizedDescription)")
            return
        }
        renderer.printStatus("Model loaded successfully")

        // Set up permissions
        let workspacePath = NSString(string: args.workspace).expandingTildeInPath
        let absWorkspace = workspacePath.hasPrefix("/") ? workspacePath : FileManager.default.currentDirectoryPath + "/" + workspacePath
        let runtimeConfig = RuntimeConfigLoader.loadMerged(workspaceRoot: absWorkspace)
        let effectiveApprovalMode = resolvedApprovalMode(from: args.approvalMode, runtimeConfig: runtimeConfig)
        let effectivePolicyFile = args.policyFile ?? runtimeConfig.defaultPolicyFile
        let effectiveAuditLogPath = args.auditLogPath ?? runtimeConfig.defaultAuditLogPath
        let effectiveSandbox = resolvedSandbox(cliSandbox: args.sandbox, runtimeConfig: runtimeConfig)
        let effectiveDryRun = resolvedDryRun(cliDryRun: args.dryRun, runtimeConfig: runtimeConfig)
        let ignorePatterns = loadIgnorePatterns(workspaceRoot: absWorkspace)

        let permissions = PermissionEngine(
            workspaceRoot: absWorkspace,
            approvalMode: effectiveApprovalMode,
            policy: loadPermissionPolicy(explicitPath: effectivePolicyFile, workspaceRoot: absWorkspace, renderer: renderer),
            ignoredPathPatterns: ignorePatterns
        )
        let auditLogger = ToolAuditLogger(
            logFilePath: effectiveAuditLogPath,
            workspaceRoot: absWorkspace,
            approvalMode: permissions.approvalMode.rawValue
        )

        // Build generation config earlier for ToolRegistry
        let config = GenerationEngine.Config(
            maxTokens: args.maxTokens,
            temperature: args.temperature,
            topP: args.topP,
            kvBits: args.kvBits ?? profile.kvBits,
            kvGroupSize: args.kvGroupSize ?? profile.kvGroupSize,
            quantizedKVStart: args.quantizedKVStart ?? profile.quantizedKVStart,
            longContextThreshold: profile.longContextThreshold,
            turboQuantBits: args.turboQuantBits
        )

        // Set up tool registry
        let registry = ToolRegistry()
        let runtimeMCPConfigs = runtimeMCPServerConfigs(
            from: runtimeConfig,
            includeOverride: args.mcpInclude,
            excludeOverride: args.mcpExclude
        )
        await registerAllTools(
            registry: registry,
            permissions: permissions,
            modelContainer: modelContainer,
            modelPath: selectedModel,
            useSandbox: effectiveSandbox,
            config: config,
            renderer: renderer,
            mcpConfigs: mergedMCPConfigs(
                runtimeConfigs: runtimeMCPConfigs,
                cliConfig: makeMCPServerConfig(from: args)
            )
        )

        let toolCount = await registry.count
        renderer.printStatus("Registered \(toolCount) tools")

        // Build layered system prompt with optional skills metadata.
        let skillsRegistry = SkillsRegistry(workspaceRoot: absWorkspace)
        let skillMetadata = await skillsRegistry.listMetadata()
        let hooks = HookPipeline()
        await hooks.register(AuditHook(logger: auditLogger))
        let promptComposition = await AgentLoop.buildSystemPromptComposition(
            registry: registry,
            maxTokens: args.maxTokens,
            mode: .plan,
            thinkingLevel: .low,
            taskType: .general,
            skillsMetadata: skillMetadata
        )

        let agentLoop = AgentLoop(
            modelContainer: modelContainer,
            registry: registry,
            permissions: permissions,
            generationConfig: config,
            renderer: renderer,
            systemPrompt: promptComposition.prompt,
            modelPath: selectedModel,
            workspace: absWorkspace,
            useSandbox: args.sandbox,
            auditLogger: auditLogger,
            dryRun: effectiveDryRun,
            hooks: hooks,
            skillsMetadata: skillMetadata,
            promptSectionTokenEstimates: promptComposition.sectionTokenEstimates,
            memoryLimit: budget.totalBytes,
            cacheLimit: budget.cacheBytes
        )

        // Clear the 5 startup status lines to make the UI cleaner
        renderer.clearPreviousLines(count: 5)
        
        let currentVersion = MLXCoderCLI.configuration.version

        // REPL Header
        print("mlx-coder \u{001B}[2m(v\(currentVersion))\u{001B}[0m")
        print("\u{001B}[2mModel: \(selectedModel)\u{001B}[0m")
        print("\u{001B}[2mWorkspace: \(absWorkspace)\u{001B}[0m\n")
        renderer.printStatus("[Key mode] Editing input. Enter sends, Shift+Tab cycles mode, Ctrl+C exits.")

        let interactiveInput = InteractiveInput()
        var sandboxEnabled = effectiveSandbox
        var announcedGeneralFastFoundationRoute = false
        
        // Set initial mode from arguments
        if args.mode.lowercased() == "agent" {
            await agentLoop.setMode(.agent, silent: true)
        }
        // Default is already planLow from AgentLoop initializer

        while true {
            // Ensure no background stdin listener competes with interactive editing.
            await CancelController.shared.suspendListening()

            let currentModeName = await agentLoop.currentMode.rawValue
            guard let input = await interactiveInput.readInteractive(
                sandboxEnabled: sandboxEnabled, 
                version: currentVersion, 
                mode: currentModeName,
                onModeToggle: {
                    return await agentLoop.cycleMode()
                }
            ) else {
                break
            }

            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed == "exit" || trimmed == "quit" { break }
            if trimmed == "?" {
                print("""
                
                \u{1B}[1mShortcuts:\u{001B}[0m
                  \u{001B}[32m?\u{001B}[0m              Show this help message
                  \u{001B}[32mexit/quit\u{001B}[0m      Exit the application
                  \u{001B}[32m/clear\u{001B}[0m         Clear conversation history and free memory
                  \u{001B}[32m/model [id]\u{001B}[0m    List/select local models in ~/models, or switch via user/model
                  \u{001B}[32m/context\u{001B}[0m       Show context usage breakdown (estimated tokens)
                  \u{001B}[32m/skills\u{001B}[0m        List discovered skills metadata
                  \u{001B}[32m/hooks\u{001B}[0m         List active hook pipeline entries
                  \u{001B}[32m/transforms\u{001B}[0m    Show/clear context transforms (no arg = list count)
                  \u{001B}[32m/save-history [path]\u{001B}[0m Export chat transcript as Markdown (default: session-history.md)
                  \u{001B}[32m/save-history-json [path]\u{001B}[0m Export resumable JSON transcript (default: session-history.json)
                  \u{001B}[32m/load-history-json [path]\u{001B}[0m Load JSON transcript into current session
                  \u{001B}[32m/undo, /revert\u{001B}[0m Undo the last conversation turn
                  \u{001B}[32m/plan\u{001B}[0m          Switch to PLAN MODE (read-only, safe browsing)
                  \u{001B}[32m/agent\u{001B}[0m         Switch to AGENT MODE (full filesystem/shell access)
                  \u{001B}[32m/task [type]\u{001B}[0m   Set task type: general, coding, reasoning
                  \u{001B}[32m/thinking [lvl]\u{001B}[0m Set thinking budget: fast/off, minimal, low, medium, high (default: low)
                  \u{001B}[32m/steer [msg]\u{001B}[0m   Queue a steering message injected between agent turns (no arg = list queue)
                  \u{001B}[32m/followup [msg]\u{001B}[0m Queue a follow-up run after the current task (no arg = list queue)
                  \u{001B}[32m/merge-approval\u{001B}[0m Trigger the "Awaiting approval before merge" flow
                  \u{001B}[32m/gittree\u{001B}[0m       List git worktrees and switch workspace/branch to one
                  \u{001B}[32m/sandbox\u{001B}[0m       Toggle macOS Seatbelt sandbox for shell commands
                  \u{001B}[32mEsc\u{001B}[0m            Cancel current generation
                  \u{001B}[32mShift+Tab\u{001B}[0m      Cycle modes (default starts at Plan low):
                                 Plan (low) → Plan (high) → General (fast) →
                                 General (low) → Coding (fast) → Coding (low) → Coding (high)
                  \u{001B}[32mCtrl+C\u{001B}[0m         Exit REPL
                  
                """)
                continue
            }
            if trimmed == "/undo" || trimmed == "/revert" {
                await agentLoop.undoLastTurn()
                continue
            }
            if trimmed == "/merge-approval" {
                await agentLoop.runMergeApprovalShortcutFlow()
                continue
            }
            if trimmed == "/gittree" {
                await agentLoop.runGitTreeShortcutFlow()
                continue
            }
            if trimmed == "/clear" {
                await agentLoop.clearHistory()
                continue
            }
            if trimmed.hasPrefix("/model") {
                let modelArg = String(trimmed.dropFirst("/model".count)).trimmingCharacters(in: .whitespacesAndNewlines)

                if modelArg.isEmpty {
                    let localModels = listHomeModelsAsRepoIDs()
                    if localModels.isEmpty {
                        print("\nNo local models found under ~/models.\n")
                    } else {
                        if let selectedIndex = await interactiveInput.selectOption(prompt: "Available local models (user/model)", options: localModels) {
                            let modelID = localModels[selectedIndex]
                            let modelPath = "~/models/\(modelID)"
                            do {
                                renderer.printStatus("Switching model to \(modelID)...")
                                try await agentLoop.switchModel(to: modelPath)
                                selectedModel = modelPath
                                announcedGeneralFastFoundationRoute = false
                                renderer.printStatus("Active model: \(selectedModel)")
                            } catch {
                                renderer.printError("Failed to switch model: \(error.localizedDescription)")
                            }
                        } else {
                            renderer.printStatus("Model selection cancelled.")
                        }
                    }
                    continue
                }

                guard let modelID = parseUserModelIdentifier(modelArg) else {
                    renderer.printError("Invalid model identifier '\(modelArg)'. Use format 'user/model'.")
                    continue
                }

                let modelPath = "~/models/\(modelID)"
                guard localModelExists(modelPath) else {
                    renderer.printError("Model not found at \(modelPath). Use /model to list installed models.")
                    continue
                }

                do {
                    renderer.printStatus("Switching model to \(modelID)...")
                    try await agentLoop.switchModel(to: modelPath)
                    selectedModel = modelPath
                    announcedGeneralFastFoundationRoute = false
                    renderer.printStatus("Active model: \(selectedModel)")
                } catch {
                    renderer.printError("Failed to switch model: \(error.localizedDescription)")
                }
                continue
            }
            if trimmed == "/context" {
                let report = await agentLoop.contextUsageReport()
                print("\n\(report)\n")
                continue
            }
            if trimmed == "/skills" {
                if skillMetadata.isEmpty {
                    print("\nNo skills discovered in workspace.\n")
                } else {
                    print("\nDiscovered skills (\(skillMetadata.count)):")
                    for skill in skillMetadata {
                        let tags = skill.tags.isEmpty ? "" : " [tags: \(skill.tags.joined(separator: ", "))]"
                        print("- \(skill.name): \(skill.description) (\(skill.filePath))\(tags)")
                    }
                    print("")
                }
                continue
            }
            if trimmed == "/hooks" {
                let names = await hooks.registeredHookNames()
                if names.isEmpty {
                    print("\nNo hooks registered.\n")
                } else {
                    print("\nActive hooks (\(names.count)):")
                    for name in names {
                        print("- \(name)")
                    }
                    print("")
                }
                continue
            }
            if trimmed.hasPrefix("/transforms") {
                let arg = String(trimmed.dropFirst("/transforms".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if arg == "clear" {
                    await agentLoop.removeAllContextTransforms()
                    renderer.printStatus("All context transforms removed.")
                } else {
                    let count = await agentLoop.contextTransformCount
                    if count == 0 {
                        print("\nNo context transforms registered.\n")
                    } else {
                        print("\nContext transforms registered: \(count)")
                        print("Use '/transforms clear' to remove all.\n")
                    }
                }
                continue
            }
            if trimmed.hasPrefix("/save-history-json") {
                let parts = trimmed.split(separator: " ", maxSplits: 1)
                let outputPath = parts.count > 1 ? String(parts[1]) : "session-history.json"
                do {
                    _ = try await agentLoop.exportHistoryJSON(to: outputPath)
                } catch {
                    renderer.printError("Failed to export JSON history: \(error.localizedDescription)")
                }
                continue
            }
            if trimmed.hasPrefix("/save-history") {
                let parts = trimmed.split(separator: " ", maxSplits: 1)
                let outputPath = parts.count > 1 ? String(parts[1]) : "session-history.md"
                do {
                    _ = try await agentLoop.exportHistory(to: outputPath)
                } catch {
                    renderer.printError("Failed to export history: \(error.localizedDescription)")
                }
                continue
            }
            if trimmed.hasPrefix("/load-history-json") {
                let parts = trimmed.split(separator: " ", maxSplits: 1)
                let inputPath = parts.count > 1 ? String(parts[1]) : "session-history.json"
                do {
                    _ = try await agentLoop.loadHistoryJSON(from: inputPath)
                } catch {
                    renderer.printError("Failed to load JSON history: \(error.localizedDescription)")
                }
                continue
            }
            if trimmed == "/sandbox" {
                sandboxEnabled.toggle()
                await agentLoop.setSandbox(sandboxEnabled)
                continue
            }
            if trimmed == "/plan" {
                await agentLoop.setMode(.plan)
                continue
            }
            if trimmed == "/agent" {
                await agentLoop.setMode(.agent)
                continue
            }
            if trimmed.hasPrefix("/task") {
                let parts = trimmed.split(separator: " ")
                if parts.count > 1 {
                    let type = parts[1].lowercased()
                    if type == "general" {
                        await agentLoop.setTaskType(.general)
                    } else if type == "coding" {
                        await agentLoop.setTaskType(.coding)
                    } else if type == "reasoning" {
                        await agentLoop.setTaskType(.reasoning)
                    } else {
                        renderer.printError("Invalid task type: \(type). Use 'general', 'coding', or 'reasoning'.")
                    }
                } else {
                    renderer.printStatus("Current task type: \(await agentLoop.taskType.rawValue)")
                }
                continue
            }
            if trimmed.hasPrefix("/thinking") {
                let parts = trimmed.split(separator: " ")
                if parts.count > 1 {
                    let level = parts[1].lowercased()
                    switch level {
                    case "fast", "off":
                        await agentLoop.setThinkingLevel(.fast)
                    case "minimal":
                        await agentLoop.setThinkingLevel(.minimal)
                    case "low":
                        await agentLoop.setThinkingLevel(.low)
                    case "medium":
                        await agentLoop.setThinkingLevel(.medium)
                    case "high":
                        await agentLoop.setThinkingLevel(.high)
                    default:
                        renderer.printError("Invalid thinking level: \(level). Use 'fast/off', 'minimal', 'low', 'medium', or 'high'.")
                    }
                } else {
                    // Show current level and budget when no argument given
                    let current = await agentLoop.thinkingLevel
                    renderer.printStatus("Thinking level: \(current.displayName)")
                }
                continue
            }
            if trimmed.hasPrefix("/steer") {
                let msg = String(trimmed.dropFirst("/steer".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !msg.isEmpty {
                    await agentLoop.steer(msg)
                    renderer.printStatus("↩️  Steering message queued: \"\(msg)\"")
                } else {
                    let pending = await agentLoop.pendingSteeringMessages()
                    if pending.isEmpty {
                        renderer.printStatus("No steering messages queued.")
                    } else {
                        print("\nQueued steering messages (\(pending.count)):")
                        for (i, m) in pending.enumerated() { print("  \(i + 1). \(m)") }
                        print("")
                    }
                }
                continue
            }
            if trimmed.hasPrefix("/followup") {
                let msg = String(trimmed.dropFirst("/followup".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !msg.isEmpty {
                    await agentLoop.queueFollowUp(msg)
                    renderer.printStatus("🔄 Follow-up queued: \"\(msg)\"")
                } else {
                    let pending = await agentLoop.pendingFollowUps()
                    if pending.isEmpty {
                        renderer.printStatus("No follow-ups queued.")
                    } else {
                        print("\nQueued follow-ups (\(pending.count)):")
                        for (i, m) in pending.enumerated() { print("  \(i + 1). \(m)") }
                        print("")
                    }
                }
                continue
            }

            do {
                let activeMode = await agentLoop.currentMode
                if activeMode == .agentGeneralFast && isAppleFoundationModelAvailable() {
                    if !announcedGeneralFastFoundationRoute {
                        renderer.printStatus("AGENT (general/fast) is using Apple Foundation model when available.")
                        announcedGeneralFastFoundationRoute = true
                    }

                    if await runAppleFoundationSinglePromptWithTools(
                        prompt: trimmed,
                        registry: registry,
                        renderer: renderer
                    ) {
                        continue
                    }

                    renderer.printStatus("Apple Foundation model was not available for this turn. Falling back to local MLX model.")
                }

                renderer.printStatus("[Key mode] Generation active. Press Esc to cancel.")
                let task = Task {
                    let parsed = ImageAttachmentParser.parse(prompt: trimmed)
                    if !parsed.imageURLs.isEmpty {
                        renderer.printStatus("Attaching \(parsed.imageURLs.count) image(s): \(parsed.imageURLs.map(\.lastPathComponent).joined(separator: ", "))")
                    }
                    try await agentLoop.processUserMessage(parsed.cleanedPrompt, images: parsed.imageURLs)
                }
                await CancelController.shared.setTask(task)
                try await task.value
                await CancelController.shared.setTask(nil)

                // Auto-process any queued follow-ups after the run completes.
                // drainFollowUpQueue() collects all entries in O(1) preserving insertion order.
                let pendingFollowUps = await agentLoop.drainFollowUpQueue()
                for followUp in pendingFollowUps {
                    renderer.printStatus("🔄 Auto follow-up: \"\(followUp)\"")
                    await hooks.emit(.followUpStarted(message: followUp))
                    let followUpTask = Task {
                        try await agentLoop.processUserMessage(followUp)
                    }
                    await CancelController.shared.setTask(followUpTask)
                    do {
                        try await followUpTask.value
                    } catch is CancellationError {
                        renderer.printError("Follow-up cancelled.")
                        await agentLoop.clearFollowUpQueue()
                        await CancelController.shared.setTask(nil)
                        break
                    } catch {
                        renderer.printError("Follow-up error: \(error.localizedDescription)")
                        await agentLoop.clearFollowUpQueue()
                        await CancelController.shared.setTask(nil)
                        break
                    }
                    await CancelController.shared.setTask(nil)
                }
            } catch is CancellationError {
                renderer.printError("Generation cancelled by user.")
                await CancelController.shared.setTask(nil)
            } catch {
                renderer.printError(error.localizedDescription)
                await CancelController.shared.setTask(nil)
            }
        }

        if let output = args.autoSaveHistory?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
            do {
                _ = try await agentLoop.exportHistory(to: output)
            } catch {
                renderer.printError("Failed to auto-save markdown history: \(error.localizedDescription)")
            }
        }

        if let outputJSON = args.autoSaveHistoryJSON?.trimmingCharacters(in: .whitespacesAndNewlines), !outputJSON.isEmpty {
            do {
                _ = try await agentLoop.exportHistoryJSON(to: outputJSON)
            } catch {
                renderer.printError("Failed to auto-save JSON history: \(error.localizedDescription)")
            }
        }

        await DotnetLSPService.shared.shutdown()

        print("\nGoodbye!")
    }
}

// MARK: - Run subcommand (single prompt, non-interactive)

struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a single prompt and exit"
    )

    @OptionGroup var args: ModelArguments

    @Option(name: .shortAndLong, help: "The prompt to send to the agent")
    var prompt: String

    @Option(name: .long, help: "Optional path to export markdown session history after run")
    var saveHistory: String?

    @Option(name: .long, help: "Optional path to export JSON session history after run")
    var saveHistoryJSON: String?

    mutating func run() async throws {
        guard !args.testAbsorber.isTestInvocation else { return }
        let renderer = StreamRenderer(verbose: args.verbose)
        defer {
            Task {
                await DotnetLSPService.shared.shutdown()
            }
        }

        // Detect chip and configure memory
        let chipInfo = ChipDetector.detect()
        let budget = MemoryGuard.budgetFor(chip: chipInfo)
        MemoryGuard.configure(budget: budget)

        let selectedModel = args.model
        if !localModelExists(selectedModel) && !looksLikeHubModelID(selectedModel) {
            renderer.printStatus("No local model found at \(selectedModel).")
            renderer.printStatus("Using Apple Foundation fallback for this single prompt.")
            if await runAppleFoundationSinglePromptFallback(prompt: prompt, renderer: renderer) {
                return
            }
            renderer.printError("Apple Foundation model is unavailable. Use --model with a local model path or a Hugging Face model ID.")
            renderer.printStatus("Suggested IDs: mlx-community/Qwen3.5-9B-MLX-4bit, Tesslate/OmniCoder-9B")
            return
        }

        // Load model
        renderer.printStatus("Loading model...")
        let modelContainer: ModelContainer
        do {
            modelContainer = try await loadModelWithCancellation(
                from: selectedModel,
                memoryLimit: budget.totalBytes,
                cacheLimit: budget.cacheBytes,
                renderer: renderer
            )
        } catch is CancellationError {
            return
        } catch {
            renderer.printError("Failed to load model: \(error.localizedDescription)")
            return
        }

        // Run single prompt setup
        let profile = ParameterProfile.forChip(chipInfo)
        let config = GenerationEngine.Config(
            maxTokens: args.maxTokens,
            temperature: args.temperature,
            topP: args.topP,
            kvBits: args.kvBits ?? profile.kvBits,
            kvGroupSize: args.kvGroupSize ?? profile.kvGroupSize,
            quantizedKVStart: args.quantizedKVStart ?? profile.quantizedKVStart,
            longContextThreshold: profile.longContextThreshold,
            turboQuantBits: args.turboQuantBits
        )
        
        // Set up tools
        let workspacePath = NSString(string: args.workspace).expandingTildeInPath
        let absWorkspace = workspacePath.hasPrefix("/") ? workspacePath : FileManager.default.currentDirectoryPath + "/" + workspacePath
        let runtimeConfig = RuntimeConfigLoader.loadMerged(workspaceRoot: absWorkspace)
        let effectiveApprovalMode = resolvedApprovalMode(from: args.approvalMode, runtimeConfig: runtimeConfig)
        let effectivePolicyFile = args.policyFile ?? runtimeConfig.defaultPolicyFile
        let effectiveAuditLogPath = args.auditLogPath ?? runtimeConfig.defaultAuditLogPath
        let effectiveSandbox = resolvedSandbox(cliSandbox: args.sandbox, runtimeConfig: runtimeConfig)
        let effectiveDryRun = resolvedDryRun(cliDryRun: args.dryRun, runtimeConfig: runtimeConfig)
        let ignorePatterns = loadIgnorePatterns(workspaceRoot: absWorkspace)

        let permissions = PermissionEngine(
            workspaceRoot: absWorkspace,
            approvalMode: effectiveApprovalMode,
            policy: loadPermissionPolicy(explicitPath: effectivePolicyFile, workspaceRoot: absWorkspace, renderer: renderer),
            ignoredPathPatterns: ignorePatterns
        )
        let auditLogger = ToolAuditLogger(
            logFilePath: effectiveAuditLogPath,
            workspaceRoot: absWorkspace,
            approvalMode: permissions.approvalMode.rawValue
        )

        let registry = ToolRegistry()
        let runtimeMCPConfigs = runtimeMCPServerConfigs(
            from: runtimeConfig,
            includeOverride: args.mcpInclude,
            excludeOverride: args.mcpExclude
        )
        await registerAllTools(
            registry: registry,
            permissions: permissions,
            modelContainer: modelContainer,
            modelPath: selectedModel,
            useSandbox: effectiveSandbox,
            config: config,
            renderer: renderer,
            mcpConfigs: mergedMCPConfigs(
                runtimeConfigs: runtimeMCPConfigs,
                cliConfig: makeMCPServerConfig(from: args)
            )
        )

        let skillsRegistry = SkillsRegistry(workspaceRoot: absWorkspace)
        let skillMetadata = await skillsRegistry.listMetadata()
        let hooks = HookPipeline()
        await hooks.register(AuditHook(logger: auditLogger))
        let promptComposition = await AgentLoop.buildSystemPromptComposition(
            registry: registry,
            maxTokens: args.maxTokens,
            mode: .plan,
            thinkingLevel: .low,
            taskType: .general,
            skillsMetadata: skillMetadata
        )

        let agentLoop = AgentLoop(
            modelContainer: modelContainer,
            registry: registry,
            permissions: permissions,
            generationConfig: config,
            renderer: renderer,
            systemPrompt: promptComposition.prompt,
            modelPath: selectedModel,
            workspace: absWorkspace,
            useSandbox: effectiveSandbox,
            auditLogger: auditLogger,
            dryRun: effectiveDryRun,
            hooks: hooks,
            skillsMetadata: skillMetadata,
            promptSectionTokenEstimates: promptComposition.sectionTokenEstimates,
            memoryLimit: budget.totalBytes,
            cacheLimit: budget.cacheBytes
        )

        let parsedPrompt = ImageAttachmentParser.parse(prompt: prompt)
        if !parsedPrompt.imageURLs.isEmpty {
            renderer.printStatus("Attaching \(parsedPrompt.imageURLs.count) image(s): \(parsedPrompt.imageURLs.map(\.lastPathComponent).joined(separator: ", "))")
        }
        renderer.printStatus("Generation active. Press Esc or Ctrl+C to cancel.")
        let runTask = Task {
            try await agentLoop.processUserMessage(parsedPrompt.cleanedPrompt, images: parsedPrompt.imageURLs)
        }
        await CancelController.shared.setTask(runTask, forceExitOnEscape: true)
        do {
            try await runTask.value
            await CancelController.shared.setTask(nil)
        } catch is CancellationError {
            await CancelController.shared.setTask(nil)
            renderer.printError("Generation cancelled by user.")
            return
        } catch {
            await CancelController.shared.setTask(nil)
            throw error
        }

        if let output = saveHistory?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
            _ = try await agentLoop.exportHistory(to: output)
        }

        if let outputJSON = saveHistoryJSON?.trimmingCharacters(in: .whitespacesAndNewlines), !outputJSON.isEmpty {
            _ = try await agentLoop.exportHistoryJSON(to: outputJSON)
        }
    }
}

// MARK: - List tools subcommand

struct ListToolsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-tools",
        abstract: "List available tools without loading a model"
    )

    @Option(name: .long, help: "Workspace root directory used for environment-sensitive tools")
    var workspace: String = "."

    @Flag(name: .long, help: "Emit machine-readable JSON output")
    var json: Bool = false

    @Flag(name: .long, help: "Treat MCP discovery errors as command failure")
    var strict: Bool = false

    @Option(name: .long, help: "Optional MCP server HTTP endpoint (JSON-RPC) for discovery")
    var mcpEndpoint: String?

    @Option(name: .long, help: "Logical MCP server name used in discovered tool prefixes")
    var mcpName: String = "remote"

    @Option(name: .long, help: "MCP request timeout in seconds")
    var mcpTimeout: Int = 30

    @Option(name: .long, help: "Comma-separated MCP server names to include (overrides config allow list)")
    var mcpInclude: String?

    @Option(name: .long, help: "Comma-separated MCP server names to exclude (applied after include)")
    var mcpExclude: String?

    @OptionGroup var testAbsorber: TestAbsorber

    mutating func run() async throws {
        guard !testAbsorber.isTestInvocation else { return }

        let workspacePath = NSString(string: workspace).expandingTildeInPath
        let rawWorkspace = workspacePath.hasPrefix("/")
            ? workspacePath
            : FileManager.default.currentDirectoryPath + "/" + workspacePath
        let absWorkspace = NSString(string: rawWorkspace).standardizingPath

        let runtimeConfig = RuntimeConfigLoader.loadMerged(workspaceRoot: absWorkspace)
        let detector = DotnetWorkspaceDetector()
        let isDotnetWorkspace = await detector.isDotnetWorkspace(absWorkspace)
        let cliMCPConfig: MCPClient.ServerConfig? = {
            guard let endpoint = mcpEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines), !endpoint.isEmpty else {
                return nil
            }
            return MCPClient.ServerConfig(
                name: mcpName,
                command: endpoint,
                endpointURL: endpoint,
                timeoutSeconds: max(1, mcpTimeout)
            )
        }()

        let result = await buildListToolsPayload(
            workspaceRoot: absWorkspace,
            isDotnetWorkspace: isDotnetWorkspace,
            runtimeConfig: runtimeConfig,
            cliMCPConfig: cliMCPConfig,
            mcpIncludeOverride: mcpInclude,
            mcpExcludeOverride: mcpExclude,
            discoverMCPTools: { config in
                try await MCPClient.connect(to: config)
            }
        )
        let payload = result.payload
        let mcpErrorMessages = result.mcpErrorMessages

        for message in mcpErrorMessages where !json {
            print("MCP discovery failed (\(message))")
        }

        if !mcpErrorMessages.isEmpty && !json {
            print("")
        }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)
            if let output = String(data: data, encoding: .utf8) {
                print(output)
            }
            if listToolsShouldFail(mcpErrorMessages: mcpErrorMessages, strict: strict) {
                throw ExitCode.failure
            }
            return
        }

        print("Workspace: \(payload.workspace)")
        print(".NET workspace: \(payload.dotnetWorkspace ? "yes" : "no")")
        print("Skills discovered: \(payload.skills.count)")
        print("")
        for tool in payload.tools {
            print("- \(tool.name) [\(tool.category)]")
            print("  \(tool.description)")
        }

        if !payload.skills.isEmpty {
            print("")
            print("Skills:")
            for skill in payload.skills {
                let tags = skill.tags.isEmpty ? "" : " [tags: \(skill.tags.joined(separator: ", "))]"
                print("- \(skill.name): \(skill.description) (\(skill.filePath))\(tags)")
            }
        }

        print("")
        print("Task capabilities:")
        print("- profiles: \(payload.taskCapabilities.profiles.joined(separator: ", "))")
        print("- isolation options: \(payload.taskCapabilities.isolationOptions.joined(separator: ", "))")

        if listToolsShouldFail(mcpErrorMessages: mcpErrorMessages, strict: strict) {
            throw ExitCode.failure
        }
    }
}

// MARK: - Show audit subcommand

struct ShowAuditCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show-audit",
        abstract: "Show recent tool audit events"
    )

    @Option(name: .long, help: "Path to audit log file")
    var path: String = "~/.mlx-coder/audit.log.jsonl"

    @Option(name: .long, help: "Number of most recent lines to print")
    var tail: Int = 50

    @OptionGroup var testAbsorber: TestAbsorber

    mutating func run() async throws {
        guard !testAbsorber.isTestInvocation else { return }

        let expandedPath = NSString(string: path).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            print("Audit log not found: \(expandedPath)")
            return
        }

        let text = try String(contentsOfFile: expandedPath, encoding: .utf8)
        let lines = text
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        let count = max(1, tail)
        let output = Array(lines.suffix(count))
        print(output.joined(separator: "\n"))
    }
}

// MARK: - Show config subcommand

struct ShowConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show-config",
        abstract: "Show merged runtime config from user and workspace files"
    )

    @Option(name: .long, help: "Workspace root used for resolving workspace config")
    var workspace: String = "."

    @Flag(name: .long, help: "Emit machine-readable JSON output")
    var json: Bool = false

    @OptionGroup var testAbsorber: TestAbsorber

    mutating func run() async throws {
        guard !testAbsorber.isTestInvocation else { return }

        let workspacePath = NSString(string: workspace).expandingTildeInPath
        let rawWorkspace = workspacePath.hasPrefix("/")
            ? workspacePath
            : FileManager.default.currentDirectoryPath + "/" + workspacePath
        let absWorkspace = URL(filePath: rawWorkspace).standardized.path()

        let merged = RuntimeConfigLoader.loadMerged(workspaceRoot: absWorkspace)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(merged)
        let serialized = String(decoding: data, as: UTF8.self)

        if json {
            print(serialized)
            return
        }

        print("Workspace: \(absWorkspace)")
        print("Merged runtime config:")
        print(serialized)
    }
}

// MARK: - Doctor subcommand

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Validate workspace, config, policy, ignore patterns, skills discovery, and MCP endpoint settings"
    )

    @Option(name: .long, help: "Workspace root used for resolving workspace checks")
    var workspace: String = "."

    @Option(name: .long, help: "Optional MCP server HTTP endpoint (JSON-RPC) override")
    var mcpEndpoint: String?

    @Option(name: .long, help: "Logical MCP server name used with --mcp-endpoint")
    var mcpName: String = "remote"

    @Option(name: .long, help: "MCP request timeout in seconds")
    var mcpTimeout: Int = 30

    @Flag(name: .long, help: "Emit machine-readable JSON output")
    var json: Bool = false

    @Flag(name: .long, help: "Treat warnings as failures (non-zero exit code when warn/fail checks exist)")
    var strict: Bool = false

    @OptionGroup var testAbsorber: TestAbsorber

    mutating func run() async throws {
        guard !testAbsorber.isTestInvocation else { return }

        let workspacePath = NSString(string: workspace).expandingTildeInPath
        let rawWorkspace = workspacePath.hasPrefix("/")
            ? workspacePath
            : FileManager.default.currentDirectoryPath + "/" + workspacePath
        let absWorkspace = NSString(string: rawWorkspace).standardizingPath

        let runtimeConfig = RuntimeConfigLoader.loadMerged(workspaceRoot: absWorkspace)
        var payload = buildDoctorPayload(
            workspaceRoot: absWorkspace,
            runtimeConfig: runtimeConfig,
            cliMCPConfig: {
                guard let endpoint = mcpEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines), !endpoint.isEmpty else {
                    return nil
                }
                return MCPClient.ServerConfig(
                    name: mcpName,
                    command: endpoint,
                    endpointURL: endpoint,
                    timeoutSeconds: max(1, mcpTimeout)
                )
            }()
        )

        let detector = DotnetWorkspaceDetector()
        let isDotnet = await detector.isDotnetWorkspace(absWorkspace)
        let lspCheck = lspDoctorCheck(
            isDotnetWorkspace: isDotnet,
            csharpLSAvailable: isCommandAvailable("csharp-ls")
        )
        payload = appendDoctorCheck(payload, check: lspCheck)

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)
            print(String(decoding: data, as: UTF8.self))
            if doctorShouldFail(payload: payload, strict: strict) {
                throw ExitCode.failure
            }
            return
        }

        print("Workspace: \(payload.workspace)")
        for check in payload.checks {
            switch check.status {
            case .pass:
                print("[PASS] \(check.name): \(check.message)")
            case .warn:
                print("[WARN] \(check.name): \(check.message)")
            case .fail:
                print("[FAIL] \(check.name): \(check.message)")
            }
        }
        print("")
        print("Summary: pass=\(payload.passCount), warn=\(payload.warnCount), fail=\(payload.failCount)")

        if doctorShouldFail(payload: payload, strict: strict) {
            throw ExitCode.failure
        }
    }
}

// MARK: - Startup model selection and fallback

private let recommendedHubModels = [
    "mlx-community/Qwen3.5-9B-MLX-4bit",
    "NexVeridian/OmniCoder-9B-4bit",
]

private func localModelExists(_ path: String) -> Bool {
    let expanded = NSString(string: path).expandingTildeInPath
    return FileManager.default.fileExists(atPath: expanded)
}

private func looksLikeHubModelID(_ value: String) -> Bool {
    if value.hasPrefix("/") || value.hasPrefix("~") || value.hasPrefix(".") {
        return false
    }
    let parts = value.split(separator: "/")
    return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
}

private func parseUserModelIdentifier(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.hasPrefix(".") {
        return nil
    }

    let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2 else {
        return nil
    }

    let owner = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
    let model = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !owner.isEmpty, !model.isEmpty else {
        return nil
    }

    return "\(owner)/\(model)"
}

private func listHomeModelsAsRepoIDs() -> [String] {
    let fileManager = FileManager.default
    let modelsRoot = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("models", isDirectory: true)

    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: modelsRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        return []
    }

    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isHiddenKey]

    guard let ownerDirs = try? fileManager.contentsOfDirectory(
        at: modelsRoot,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
        return []
    }

    var models: [String] = []
    let sortedOwners = ownerDirs.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

    for ownerURL in sortedOwners {
        guard let ownerValues = try? ownerURL.resourceValues(forKeys: keys),
              ownerValues.isDirectory == true,
              ownerValues.isHidden != true else {
            continue
        }

        guard let modelDirs = try? fileManager.contentsOfDirectory(
            at: ownerURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            continue
        }

        let sortedModels = modelDirs.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for modelURL in sortedModels {
            guard let modelValues = try? modelURL.resourceValues(forKeys: keys),
                  modelValues.isDirectory == true,
                  modelValues.isHidden != true else {
                continue
            }

            models.append("\(ownerURL.lastPathComponent)/\(modelURL.lastPathComponent)")
        }
    }

    return models
}

private func promptForRecommendedModelDownload() -> String? {
    print("\nNo local MLX model found. Download one now?")
    print("  1) \(recommendedHubModels[0])")
    print("  2) \(recommendedHubModels[1])")
    print("  0) Skip download and use Apple Foundation fallback")
    print("Choose [1/2/0]: ", terminator: "")

    guard let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) else {
        return nil
    }

    switch input {
    case "1": return recommendedHubModels[0]
    case "2": return recommendedHubModels[1]
    default: return nil
    }
}

private func runAppleFoundationChatFallback(renderer: StreamRenderer) async -> Bool {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
        do {
            let session = LanguageModelSession()
            print("\nmlx-coder (Apple Foundation fallback)")
            print("Type 'exit' or 'quit' to leave.\n")

            while true {
                print("> ", terminator: "")
                guard let line = readLine() else { break }
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                if trimmed == "exit" || trimmed == "quit" { break }

                let response = try await session.respond(to: trimmed)
                print(response.content)
                print("")
            }

            return true
        } catch {
            renderer.printError("Foundation fallback failed: \(error.localizedDescription)")
            return false
        }
    }
    return false
    #else
    _ = renderer
    return false
    #endif
}

private func runAppleFoundationSinglePromptFallback(prompt: String, renderer: StreamRenderer) async -> Bool {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt)
            print(response.content)
            return true
        } catch {
            renderer.printError("Foundation fallback failed: \(error.localizedDescription)")
            return false
        }
    }
    return false
    #else
    _ = prompt
    _ = renderer
    return false
    #endif
}

private let foundationAllowedToolNames: Set<String> = [
    "glob",
    "grep",
    "list_dir",
    "web_search",
    "web_fetch"
]

private func runAppleFoundationSinglePromptWithTools(
    prompt: String,
    registry: ToolRegistry,
    renderer: StreamRenderer
) async -> Bool {
    if shouldBypassFoundationTools(for: prompt) {
        return await runAppleFoundationSinglePromptFallback(prompt: prompt, renderer: renderer)
    }

    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
        do {
            let session = LanguageModelSession()
            let maxIterations = 6
            var iteration = 0
            var pendingPrompt = foundationSystemToolPrompt(userPrompt: prompt)

            while iteration < maxIterations {
                iteration += 1
                let response = try await session.respond(to: pendingPrompt)
                let raw = response.content
                var toolCalls = ToolCallParser.parse(raw)
                if toolCalls.isEmpty {
                    toolCalls = parseFoundationFallbackToolCalls(from: raw)
                }
                let nonToolText = ToolCallParser.extractNonToolText(ToolCallParser.stripThinking(raw))

                if toolCalls.isEmpty {
                    if !nonToolText.isEmpty {
                        print(nonToolText)
                    } else {
                        print(raw)
                    }
                    return true
                }

                var toolResponses: [String] = []
                toolResponses.reserveCapacity(toolCalls.count)

                for rawCall in toolCalls {
                    let call = normalizeFoundationToolCall(rawCall)
                    renderer.printToolCall(name: call.name, arguments: call.arguments)

                    let result: ToolResult
                    if !foundationAllowedToolNames.contains(call.name) {
                        result = .error("Tool '\(call.name)' is not available in Foundation mode. Allowed tools: glob, grep, list_dir, web_search, web_fetch.")
                    } else if let tool = await registry.tool(named: call.name) {
                        do {
                            result = try await tool.execute(arguments: call.arguments)
                        } catch {
                            result = .error("Tool execution failed: \(error.localizedDescription)")
                        }
                    } else {
                        result = .error("Tool '\(call.name)' is not registered.")
                    }

                    renderer.printToolResult(result)
                    let boundedContent = String(result.content.prefix(8000))
                    let jsonObject: [String: Any] = [
                        "name": call.name,
                        "is_error": result.isError,
                        "content": boundedContent
                    ]

                    if let data = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys]),
                       let json = String(data: data, encoding: .utf8) {
                        toolResponses.append("\(ToolCallPattern.toolResponseOpen)\n\(json)\n\(ToolCallPattern.toolResponseClose)")
                    } else {
                        toolResponses.append("\(ToolCallPattern.toolResponseOpen)\n{\"name\":\"\(call.name)\",\"is_error\":\(result.isError ? "true" : "false"),\"content\":\"serialization_failed\"}\n\(ToolCallPattern.toolResponseClose)")
                    }
                }

                pendingPrompt = """
                Continue the task using these tool results.
                If another tool is required, emit only tool calls in the required format.
                If you have enough information, provide the final answer directly.

                \(toolResponses.joined(separator: "\n"))
                """
            }

            renderer.printError("Foundation tool loop exceeded maximum tool iterations (\(maxIterations)).")
            return false
        } catch {
            renderer.printError("Foundation fallback failed: \(error.localizedDescription)")
            return false
        }
    }
    return false
    #else
    _ = prompt
    _ = registry
    _ = renderer
    return false
    #endif
}

private func foundationSystemToolPrompt(userPrompt: String) -> String {
    """
    You are running in mlx-coder Foundation mode with restricted tools.

    Available tools: glob, grep, list_dir, web_search, web_fetch.

    When a tool is needed, respond with one or more tool calls only, each in this exact format:
    <tool_call>
    {"name":"tool_name","arguments":{...}}
    </tool_call>

    Rules:
    - Do NOT call tools for greetings, acknowledgements, thanks, or casual chat. Reply directly.
    - Do NOT explore files or web content unless the user explicitly asks for that information.
    - Use only the five available tools listed above.
    - Do NOT emit custom tags like <list_dir>...</list_dir> or wrapper calls like tool_call(...).
    - Arguments must be valid JSON objects.
    - Do not include markdown fences around tool call JSON.
    - For list_dir, always provide a non-empty path. Use "." for current directory.
    - If no tool is needed, answer normally.

    User request:
    \(userPrompt)
    """
}

private func shouldBypassFoundationTools(for prompt: String) -> Bool {
    let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if trimmed.isEmpty { return true }

    let compact = trimmed.replacingOccurrences(of: "[^a-z0-9 ]", with: "", options: .regularExpression)
    let words = compact.split(separator: " ")

    let chatter: Set<String> = [
        "hi", "hello", "hey", "yo", "sup", "howdy", "ola",
        "thanks", "thank", "thx", "ok", "okay", "cool", "nice"
    ]

    // Single-token greetings/acknowledgements should never trigger tool usage.
    if words.count == 1, let only = words.first, chatter.contains(String(only)) {
        return true
    }

    // Very short social phrases should also bypass tools.
    if words.count <= 3 {
        let socialPhrases: Set<String> = [
            "good morning", "good afternoon", "good evening", "how are you", "whats up"
        ]
        if socialPhrases.contains(words.joined(separator: " ")) {
            return true
        }
    }

    return false
}

private func parseFoundationFallbackToolCalls(from raw: String) -> [ToolCallParser.ParsedToolCall] {
    var candidates: [String] = []

    // Handle fenced JSON blocks like:
    // ```json
    // {"name":"list_dir","arguments":{...}}
    // ```
    if let regex = try? NSRegularExpression(pattern: "```(?:json)?\\s*([\\s\\S]*?)```", options: [.caseInsensitive]) {
        let nsRaw = raw as NSString
        let matches = regex.matches(in: raw, range: NSRange(location: 0, length: nsRaw.length))
        for match in matches where match.numberOfRanges > 1 {
            let block = nsRaw.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !block.isEmpty {
                candidates.append(block)
            }
        }
    }

    // Also attempt parsing the full response as a raw JSON object.
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") {
        candidates.append(trimmed)
    }

    var parsed: [ToolCallParser.ParsedToolCall] = []
    for candidate in candidates {
        if let call = parseSingleToolCallJSON(candidate) {
            parsed.append(call)
        }
    }

    // Handle custom XML-like tags such as:
    // <list_dir>
    // {"path":"."}
    // </list_dir>
    parsed.append(contentsOf: parseFoundationTagWrappedToolCalls(from: raw))

    // Handle function-like wrappers such as:
    // tool_call(tool: list_dir, path: .)
    parsed.append(contentsOf: parseFoundationFunctionStyleToolCalls(from: raw))

    return parsed
}

private func parseFoundationTagWrappedToolCalls(from raw: String) -> [ToolCallParser.ParsedToolCall] {
    guard let regex = try? NSRegularExpression(
        pattern: "<([a-zA-Z_][a-zA-Z0-9_]*)>\\s*([\\s\\S]*?)\\s*</\\1>",
        options: []
    ) else {
        return []
    }

    let nsRaw = raw as NSString
    let matches = regex.matches(in: raw, range: NSRange(location: 0, length: nsRaw.length))
    var calls: [ToolCallParser.ParsedToolCall] = []

    for match in matches where match.numberOfRanges >= 3 {
        let tagName = nsRaw.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard foundationAllowedToolNames.contains(tagName) else { continue }

        let body = nsRaw.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = body.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            calls.append(ToolCallParser.ParsedToolCall(name: tagName, arguments: object))
        } else {
            // If body is not JSON, pass an empty object so normalization can still run.
            calls.append(ToolCallParser.ParsedToolCall(name: tagName, arguments: [:]))
        }
    }

    return calls
}

private func parseFoundationFunctionStyleToolCalls(from raw: String) -> [ToolCallParser.ParsedToolCall] {
    guard let regex = try? NSRegularExpression(
        pattern: "tool_call\\s*\\(([^)]*)\\)",
        options: [.caseInsensitive]
    ) else {
        return []
    }

    let nsRaw = raw as NSString
    let matches = regex.matches(in: raw, range: NSRange(location: 0, length: nsRaw.length))
    var calls: [ToolCallParser.ParsedToolCall] = []

    for match in matches where match.numberOfRanges >= 2 {
        let paramsText = nsRaw.substring(with: match.range(at: 1))
        let pairs = paramsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        var toolName: String?
        var args: [String: Any] = [:]

        for pair in pairs {
            guard let colonIndex = pair.firstIndex(of: ":") else { continue }
            let rawKey = String(pair[..<colonIndex]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var rawValue = String(pair[pair.index(after: colonIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)

            // Strip optional surrounding quotes.
            if (rawValue.hasPrefix("\"") && rawValue.hasSuffix("\"")) ||
                (rawValue.hasPrefix("'") && rawValue.hasSuffix("'")) {
                rawValue = String(rawValue.dropFirst().dropLast())
            }

            if rawKey == "tool" || rawKey == "name" {
                toolName = rawValue
                continue
            }

            if let intValue = Int(rawValue) {
                args[rawKey] = intValue
            } else if rawValue.lowercased() == "true" {
                args[rawKey] = true
            } else if rawValue.lowercased() == "false" {
                args[rawKey] = false
            } else {
                args[rawKey] = rawValue
            }
        }

        if let toolName, foundationAllowedToolNames.contains(toolName) {
            calls.append(ToolCallParser.ParsedToolCall(name: toolName, arguments: args))
        }
    }

    return calls
}

private func parseSingleToolCallJSON(_ jsonString: String) -> ToolCallParser.ParsedToolCall? {
    guard let data = jsonString.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let name = object["name"] as? String else {
        return nil
    }
    let arguments = object["arguments"] as? [String: Any] ?? [:]
    return ToolCallParser.ParsedToolCall(name: name, arguments: arguments)
}

private func normalizeFoundationToolCall(_ call: ToolCallParser.ParsedToolCall) -> ToolCallParser.ParsedToolCall {
    var args = call.arguments

    switch call.name {
    case "list_dir":
        let path = (args["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if path.isEmpty {
            args["path"] = "."
        }

    case "grep":
        if args["pattern"] == nil, let query = args["query"] as? String, !query.isEmpty {
            args["pattern"] = query
        }
        if let path = args["path"] as? String, path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args["path"] = "."
        }

    case "glob":
        if args["pattern"] == nil, let query = args["query"] as? String, !query.isEmpty {
            args["pattern"] = query
        }
        if let path = args["path"] as? String, path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args["path"] = "."
        }

    case "web_search":
        if args["query"] == nil, let q = args["q"] as? String, !q.isEmpty {
            args["query"] = q
        }

    case "web_fetch":
        if args["url"] == nil,
           let urls = args["urls"] as? [String],
           let first = urls.first,
           !first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args["url"] = first
        }

    default:
        break
    }

    return ToolCallParser.ParsedToolCall(name: call.name, arguments: args)
}

private func isAppleFoundationModelAvailable() -> Bool {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
        return true
    }
    return false
    #else
    return false
    #endif
}

private func loadModelWithCancellation(
    from path: String,
    memoryLimit: Int?,
    cacheLimit: Int?,
    renderer: StreamRenderer
) async throws -> ModelContainer {
    let loadTask = Task {
        try await ModelLoader.load(
            from: path,
            memoryLimit: memoryLimit,
            cacheLimit: cacheLimit
        )
    }

    await CancelController.shared.setTask(loadTask)

    do {
        let container = try await loadTask.value
        await CancelController.shared.setTask(nil)
        return container
    } catch {
        await CancelController.shared.setTask(nil)
        if error is CancellationError {
            renderer.printError("Model loading cancelled by user.")
        }
        throw error
    }
}

private func parseApprovalMode(_ value: String) -> PermissionEngine.ApprovalMode {
    switch value.lowercased() {
    case PermissionEngine.ApprovalMode.autoEdit.rawValue:
        return .autoEdit
    case PermissionEngine.ApprovalMode.yolo.rawValue:
        return .yolo
    default:
        return .default
    }
}

private func loadPermissionPolicy(explicitPath: String?, workspaceRoot: String, renderer: StreamRenderer) -> PermissionEngine.PolicyDocument? {
    let policyPath: String

    if let explicitPath, !explicitPath.isEmpty {
        let expanded = NSString(string: explicitPath).expandingTildeInPath
        policyPath = expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
    } else {
        policyPath = workspaceRoot + "/.mlx-coder-policy.json"
    }

    guard FileManager.default.fileExists(atPath: policyPath) else {
        return nil
    }

    do {
        let data = try Data(contentsOf: URL(filePath: policyPath))
        let decoder = JSONDecoder()
        let document = try decoder.decode(PermissionEngine.PolicyDocument.self, from: data)
        renderer.printStatus("Loaded permission policy: \(policyPath)")
        return document
    } catch {
        renderer.printError("Failed to load policy file '\(policyPath)': \(error.localizedDescription)")
        return nil
    }
}

private func loadIgnorePatterns(workspaceRoot: String) -> [String] {
    let ignorePath = workspaceRoot + "/.mlx-coder-ignore"
    guard let text = try? String(contentsOfFile: ignorePath, encoding: .utf8) else {
        return []
    }

    return text
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .filter { !$0.hasPrefix("#") }
}

private func discoverSkillFiles(workspaceRoot: String) -> [String] {
    let fileManager = FileManager.default
    let roots = [
        workspaceRoot + "/.github/skills",
        workspaceRoot + "/skills"
    ]

    var discovered: [String] = []
    for root in roots {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
            continue
        }

        guard let enumerator = fileManager.enumerator(atPath: root) else {
            continue
        }

        for case let relative as String in enumerator {
            if relative == "SKILL.md" || relative.hasSuffix("/SKILL.md") {
                discovered.append(root + "/" + relative)
            }
        }
    }

    return discovered.sorted()
}

private func makeMCPServerConfig(from args: ModelArguments) -> MCPClient.ServerConfig? {
    guard let endpoint = args.mcpEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines), !endpoint.isEmpty else {
        return nil
    }

    return MCPClient.ServerConfig(
        name: args.mcpName,
        command: endpoint,
        endpointURL: endpoint,
        timeoutSeconds: max(1, args.mcpTimeout)
    )
}

private func runtimeMCPServerConfigs(
    from runtimeConfig: RuntimeConfig,
    includeOverride: String? = nil,
    excludeOverride: String? = nil
) -> [MCPClient.ServerConfig] {
    let allowedServers: Set<String>
    if let includeOverride {
        allowedServers = parseMCPServerNameSet(csv: includeOverride)
    } else {
        allowedServers = Set(
            (runtimeConfig.mcpSettings?.allowedServers ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
    }

    let blockedServers: Set<String>
    if let excludeOverride {
        blockedServers = parseMCPServerNameSet(csv: excludeOverride)
    } else {
        blockedServers = Set(
            (runtimeConfig.mcpSettings?.blockedServers ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
    }

    return runtimeConfig.mcpServers.compactMap { server in
        if server.enabled == false {
            return nil
        }

        let serverName = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = serverName.lowercased()

        if !allowedServers.isEmpty, !allowedServers.contains(normalizedName) {
            return nil
        }

        if blockedServers.contains(normalizedName) {
            return nil
        }

        let command = server.command ?? server.endpoint ?? ""
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return MCPClient.ServerConfig(
            name: serverName,
            command: command,
            arguments: server.arguments ?? [],
            environment: server.environment ?? [:],
            endpointURL: server.endpoint,
            timeoutSeconds: max(1, server.timeoutSeconds ?? 30)
        )
    }
}

private func parseMCPServerNameSet(csv: String) -> Set<String> {
    Set(
        csv
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    )
}

private func resolvedApprovalMode(from cliValue: String, runtimeConfig: RuntimeConfig) -> PermissionEngine.ApprovalMode {
    if cliValue.lowercased() != PermissionEngine.ApprovalMode.default.rawValue {
        return parseApprovalMode(cliValue)
    }

    if let configured = runtimeConfig.defaultApprovalMode {
        return parseApprovalMode(configured)
    }

    return .default
}

private func resolvedSandbox(cliSandbox: Bool, runtimeConfig: RuntimeConfig) -> Bool {
    if cliSandbox == false {
        return false
    }
    return runtimeConfig.defaultSandbox ?? cliSandbox
}

private func resolvedDryRun(cliDryRun: Bool, runtimeConfig: RuntimeConfig) -> Bool {
    if cliDryRun == true {
        return true
    }
    return runtimeConfig.defaultDryRun ?? cliDryRun
}

private func mergedMCPConfigs(runtimeConfigs: [MCPClient.ServerConfig], cliConfig: MCPClient.ServerConfig?) -> [MCPClient.ServerConfig] {
    var merged = runtimeConfigs
    if let cliConfig {
        merged.append(cliConfig)
    }

    // Deduplicate by server name while preserving the latest entry.
    var byName: [String: MCPClient.ServerConfig] = [:]
    for config in merged {
        byName[config.name] = config
    }
    return byName.values.sorted { $0.name < $1.name }
}

enum DoctorStatus: String, Codable, Sendable {
    case pass
    case warn
    case fail
}

struct DoctorCheck: Codable, Sendable {
    let name: String
    let status: DoctorStatus
    let message: String
}

struct DoctorPayload: Codable, Sendable {
    let workspace: String
    let checks: [DoctorCheck]
    let passCount: Int
    let warnCount: Int
    let failCount: Int
}

func appendDoctorCheck(_ payload: DoctorPayload, check: DoctorCheck) -> DoctorPayload {
    let checks = payload.checks + [check]
    let passCount = checks.filter { $0.status == .pass }.count
    let warnCount = checks.filter { $0.status == .warn }.count
    let failCount = checks.filter { $0.status == .fail }.count
    return DoctorPayload(
        workspace: payload.workspace,
        checks: checks,
        passCount: passCount,
        warnCount: warnCount,
        failCount: failCount
    )
}

func doctorShouldFail(payload: DoctorPayload, strict: Bool) -> Bool {
    if payload.failCount > 0 {
        return true
    }
    if strict && payload.warnCount > 0 {
        return true
    }
    return false
}

func lspDoctorCheck(isDotnetWorkspace: Bool, csharpLSAvailable: Bool) -> DoctorCheck {
    if !isDotnetWorkspace {
        return DoctorCheck(name: "lsp", status: .pass, message: "Workspace is not .NET; LSP readiness check skipped.")
    }

    if csharpLSAvailable {
        return DoctorCheck(name: "lsp", status: .pass, message: "Detected .NET workspace and csharp-ls is available.")
    }

    return DoctorCheck(name: "lsp", status: .warn, message: "Detected .NET workspace but csharp-ls is not in PATH.")
}

func buildDoctorPayload(
    workspaceRoot: String,
    runtimeConfig: RuntimeConfig,
    cliMCPConfig: MCPClient.ServerConfig?,
    commandAvailable: (String) -> Bool = isCommandAvailable
) -> DoctorPayload {
    var checks: [DoctorCheck] = []
    let fileManager = FileManager.default

    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: workspaceRoot, isDirectory: &isDirectory), isDirectory.boolValue {
        checks.append(DoctorCheck(name: "workspace", status: .pass, message: "Workspace root exists."))
    } else {
        checks.append(DoctorCheck(name: "workspace", status: .fail, message: "Workspace root does not exist or is not a directory."))
    }

    let userConfigPath = fileManager.homeDirectoryForCurrentUser.path + "/.mlx-coder/config.json"
    let workspaceConfigPath = workspaceRoot + "/.mlx-coder-config.json"
    let userExists = fileManager.fileExists(atPath: userConfigPath)
    let workspaceExists = fileManager.fileExists(atPath: workspaceConfigPath)
    if userExists || workspaceExists {
        checks.append(
            DoctorCheck(
                name: "runtime-config",
                status: .pass,
                message: "Loaded merged config from \(userExists ? "user" : "")\(userExists && workspaceExists ? " + " : "")\(workspaceExists ? "workspace" : "") files."
            )
        )
    } else {
        checks.append(DoctorCheck(name: "runtime-config", status: .warn, message: "No runtime config files found (using built-in defaults)."))
    }

    let ignorePath = workspaceRoot + "/.mlx-coder-ignore"
    if fileManager.fileExists(atPath: ignorePath) {
        if let text = try? String(contentsOfFile: ignorePath, encoding: .utf8) {
            let patterns = text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .filter { !$0.hasPrefix("#") }

            if patterns.isEmpty {
                checks.append(DoctorCheck(name: "ignore", status: .warn, message: ".mlx-coder-ignore exists but has no active patterns."))
            } else {
                checks.append(DoctorCheck(name: "ignore", status: .pass, message: "Loaded \(patterns.count) ignore pattern(s)."))
            }
        } else {
            checks.append(DoctorCheck(name: "ignore", status: .fail, message: "Failed to read .mlx-coder-ignore."))
        }
    } else {
        checks.append(DoctorCheck(name: "ignore", status: .warn, message: "No .mlx-coder-ignore file found."))
    }

    let discoveredSkills = discoverSkillFiles(workspaceRoot: workspaceRoot)
    if discoveredSkills.isEmpty {
        checks.append(DoctorCheck(name: "skills", status: .warn, message: "No workspace skills discovered under .github/skills or skills."))
    } else {
        checks.append(DoctorCheck(name: "skills", status: .pass, message: "Discovered \(discoveredSkills.count) skill definition file(s)."))
    }

    let configuredPolicyPath = runtimeConfig.defaultPolicyFile.map { resolveDoctorPath($0, workspaceRoot: workspaceRoot) }
        ?? (workspaceRoot + "/.mlx-coder-policy.json")
    if fileManager.fileExists(atPath: configuredPolicyPath) {
        do {
            let data = try Data(contentsOf: URL(filePath: configuredPolicyPath))
            _ = try JSONDecoder().decode(PermissionEngine.PolicyDocument.self, from: data)
            checks.append(DoctorCheck(name: "policy", status: .pass, message: "Policy file is valid JSON and decodes correctly."))
        } catch {
            checks.append(DoctorCheck(name: "policy", status: .fail, message: "Policy file is invalid: \(error.localizedDescription)"))
        }
    } else {
        checks.append(DoctorCheck(name: "policy", status: .warn, message: "No policy file found at \(configuredPolicyPath)."))
    }

    let configuredAuditPath = runtimeConfig.defaultAuditLogPath
        .map { resolveDoctorPath($0, workspaceRoot: workspaceRoot) }
        ?? (FileManager.default.homeDirectoryForCurrentUser.path + "/.mlx-coder/audit.log.jsonl")
    let auditDir = (configuredAuditPath as NSString).deletingLastPathComponent
    var auditDirIsDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: auditDir, isDirectory: &auditDirIsDirectory) {
        if auditDirIsDirectory.boolValue {
            checks.append(DoctorCheck(name: "audit-log", status: .pass, message: "Audit log directory is present (\(auditDir))."))
        } else {
            checks.append(DoctorCheck(name: "audit-log", status: .fail, message: "Audit log parent path exists but is not a directory: \(auditDir)."))
        }
    } else {
        checks.append(DoctorCheck(name: "audit-log", status: .warn, message: "Audit log directory is missing: \(auditDir)."))
    }

    let runtimeMCPConfigs = runtimeMCPServerConfigs(from: runtimeConfig)
    let allMCPConfigs = mergedMCPConfigs(runtimeConfigs: runtimeMCPConfigs, cliConfig: cliMCPConfig)
    if allMCPConfigs.isEmpty {
        checks.append(DoctorCheck(name: "mcp", status: .warn, message: "No MCP servers configured."))
    } else {
        var invalidEndpoints: [String] = []
        for config in allMCPConfigs {
            if let endpoint = config.endpointURL, !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let url = URL(string: endpoint), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                    invalidEndpoints.append("\(config.name): invalid endpoint '\(endpoint)'")
                    continue
                }
            } else {
                let command = config.command.trimmingCharacters(in: .whitespacesAndNewlines)
                if command.isEmpty {
                    invalidEndpoints.append("\(config.name): missing endpoint/command")
                    continue
                }

                if !commandAvailable(command) {
                    invalidEndpoints.append("\(config.name): command not found '\(command)'")
                    continue
                }
            }

            if config.timeoutSeconds < 1 {
                invalidEndpoints.append("\(config.name): timeout must be >= 1")
            }
        }

        if invalidEndpoints.isEmpty {
            checks.append(DoctorCheck(name: "mcp", status: .pass, message: "Validated \(allMCPConfigs.count) MCP configuration(s)."))
        } else {
            checks.append(DoctorCheck(name: "mcp", status: .fail, message: invalidEndpoints.joined(separator: " | ")))
        }
    }

    let passCount = checks.filter { $0.status == .pass }.count
    let warnCount = checks.filter { $0.status == .warn }.count
    let failCount = checks.filter { $0.status == .fail }.count
    return DoctorPayload(
        workspace: workspaceRoot,
        checks: checks,
        passCount: passCount,
        warnCount: warnCount,
        failCount: failCount
    )
}

private func resolveDoctorPath(_ value: String, workspaceRoot: String) -> String {
    let expanded = NSString(string: value).expandingTildeInPath
    if expanded.hasPrefix("/") {
        return expanded
    }
    return workspaceRoot + "/" + expanded
}

private func isCommandAvailable(_ command: String) -> Bool {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return false
    }

    if trimmed.contains("/") {
        return access(trimmed, X_OK) == 0
    }

    let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let directories = envPath
        .components(separatedBy: ":")
        .filter { !$0.isEmpty }

    for directory in directories {
        let candidate = (directory as NSString).appendingPathComponent(trimmed)
        if access(candidate, X_OK) == 0 {
            return true
        }
    }

    return false
}

struct ToolCatalogEntry: Codable, Sendable {
    let name: String
    let category: String
    let description: String
}

struct ListToolsPayload: Codable, Sendable {
    let workspace: String
    let dotnetWorkspace: Bool
    let tools: [ToolCatalogEntry]
    let skills: [SkillMetadata]
    let taskCapabilities: TaskCapabilities
    let mcpError: String?
}

struct TaskCapabilities: Codable, Sendable {
    let profiles: [String]
    let isolationOptions: [String]
}

func listToolsShouldFail(mcpErrorMessages: [String], strict: Bool) -> Bool {
    strict && !mcpErrorMessages.isEmpty
}

func buildListToolsPayload(
    workspaceRoot: String,
    isDotnetWorkspace: Bool,
    runtimeConfig: RuntimeConfig,
    cliMCPConfig: MCPClient.ServerConfig?,
    mcpIncludeOverride: String? = nil,
    mcpExcludeOverride: String? = nil,
    discoverMCPTools: @Sendable (MCPClient.ServerConfig) async throws -> [any Tool]
) async -> (payload: ListToolsPayload, mcpErrorMessages: [String]) {
    var tools = builtinToolCatalog(includeDotnetTools: isDotnetWorkspace)
    let skillsRegistry = SkillsRegistry(workspaceRoot: workspaceRoot)
    let skillMetadata = await skillsRegistry.listMetadata()
    let runtimeMCPConfigs = runtimeMCPServerConfigs(
        from: runtimeConfig,
        includeOverride: mcpIncludeOverride,
        excludeOverride: mcpExcludeOverride
    )
    let allMCPConfigs = mergedMCPConfigs(runtimeConfigs: runtimeMCPConfigs, cliConfig: cliMCPConfig)

    var mcpErrorMessages: [String] = []
    for mcpConfig in allMCPConfigs {
        do {
            let remoteTools = try await discoverMCPTools(mcpConfig)
            let mapped: [ToolCatalogEntry] = remoteTools.map {
                ToolCatalogEntry(name: $0.name, category: "mcp", description: $0.description)
            }
            tools.append(contentsOf: mapped)
        } catch {
            mcpErrorMessages.append("\(mcpConfig.name): \(error.localizedDescription)")
        }
    }

    let payload = ListToolsPayload(
        workspace: workspaceRoot,
        dotnetWorkspace: isDotnetWorkspace,
        tools: tools,
        skills: skillMetadata,
        taskCapabilities: TaskCapabilities(
            profiles: TaskTool.supportedProfileNames,
            isolationOptions: ["isolate", "isolation_directory", "cleanup_isolation"]
        ),
        mcpError: mcpErrorMessages.isEmpty ? nil : mcpErrorMessages.joined(separator: " | ")
    )

    return (payload, mcpErrorMessages)
}

private func builtinToolCatalog(includeDotnetTools: Bool) -> [ToolCatalogEntry] {
    var tools: [ToolCatalogEntry] = [
        ToolCatalogEntry(name: "read_file", category: "filesystem", description: "Read files with optional line ranges."),
        ToolCatalogEntry(name: "write_file", category: "filesystem", description: "Create or replace file contents."),
        ToolCatalogEntry(name: "append_file", category: "filesystem", description: "Append text to an existing file."),
        ToolCatalogEntry(name: "edit_file", category: "filesystem", description: "Apply exact search/replace edits in a file."),
        ToolCatalogEntry(name: "patch", category: "filesystem", description: "Apply unified diff patches."),
        ToolCatalogEntry(name: "list_dir", category: "filesystem", description: "List files and directories."),
        ToolCatalogEntry(name: "read_many", category: "filesystem", description: "Read multiple files in a single call."),
        ToolCatalogEntry(name: "glob", category: "search", description: "Find files by glob pattern."),
        ToolCatalogEntry(name: "grep", category: "search", description: "Search text across files."),
        ToolCatalogEntry(name: "code_search", category: "search", description: "Symbol-aware code search."),
        ToolCatalogEntry(name: "bash", category: "shell", description: "Execute shell commands with permission checks."),
        ToolCatalogEntry(name: "task", category: "agent", description: "Delegate a subtask to a sub-agent with specialist profiles and optional isolated execution."),
        ToolCatalogEntry(name: "todo", category: "agent", description: "Manage persistent todo items."),
        ToolCatalogEntry(name: "project_expert_lora", category: "agent", description: "Project LoRA expert tool (experimental)."),
        ToolCatalogEntry(name: "web_fetch", category: "web", description: "Fetch and summarize web content."),
        ToolCatalogEntry(name: "web_search", category: "web", description: "Search the web for recent information.")
    ]

    if includeDotnetTools {
        tools.append(contentsOf: [
            ToolCatalogEntry(name: "lsp_diagnostics", category: "lsp", description: "Get C# diagnostics from language server."),
            ToolCatalogEntry(name: "lsp_hover", category: "lsp", description: "Get C# symbol hover information."),
            ToolCatalogEntry(name: "lsp_references", category: "lsp", description: "Find C# symbol references."),
            ToolCatalogEntry(name: "lsp_definition", category: "lsp", description: "Find C# symbol definition locations."),
            ToolCatalogEntry(name: "lsp_completion", category: "lsp", description: "Get C# completion items at a position."),
            ToolCatalogEntry(name: "lsp_signature_help", category: "lsp", description: "Get C# signature help at a position."),
            ToolCatalogEntry(name: "lsp_document_symbols", category: "lsp", description: "List C# document symbols for a file."),
            ToolCatalogEntry(name: "lsp_rename", category: "lsp", description: "Plan C# symbol rename workspace edits, or apply them with apply=true.")
        ])
    }

    return tools
}

// MARK: - Tool Registration

/// Register all built-in tools with the registry.
private func registerAllTools(
    registry: ToolRegistry,
    permissions: PermissionEngine,
    modelContainer: ModelContainer,
    modelPath: String,
    useSandbox: Bool,
    config: GenerationEngine.Config,
    renderer: StreamRenderer,
    mcpConfigs: [MCPClient.ServerConfig] = []
) async {
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
        generationConfig: config,
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
        generationConfig: config
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

    // Build checking tool
    await registry.register(BuildCheckTool(permissions: permissions))

    // MCP tools (optional)
    for mcpConfig in mcpConfigs {
        do {
            let mcpTools = try await MCPClient.connect(to: mcpConfig)
            for tool in mcpTools {
                await registry.register(tool)
            }
            renderer.printStatus("Registered \(mcpTools.count) MCP tools from \(mcpConfig.name)")
        } catch {
            renderer.printError("Failed to register MCP tools for \(mcpConfig.name): \(error.localizedDescription)")
        }
    }
}
