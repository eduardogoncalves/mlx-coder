// Sources/MLXCoder/ChatCommand.swift
// Interactive REPL subcommand — the main chat loop with slash commands.

import ArgumentParser
import Foundation
import MLXLMCommon

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

        // Build layered system prompt with optional skills metadata and memory restoration.
        let skillsRegistry = SkillsRegistry(workspaceRoot: absWorkspace)
        let skillMetadata = await skillsRegistry.listMetadata()
        let hooks = HookPipeline()
        await hooks.register(AuditHook(logger: auditLogger))
        
        // Restore memory from previous sessions
        let memorySection = await restoreMemorySection(workspaceRoot: absWorkspace, renderer: renderer)
        
        let promptComposition = await AgentLoop.buildSystemPromptComposition(
            registry: registry,
            maxTokens: args.maxTokens,
            mode: .plan,
            thinkingLevel: .low,
            taskType: .general,
            memorySection: memorySection,
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
                printREPLHelp()
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
                await agentLoop.clearHistoryWithCheckpoint()
                continue
            }
            if trimmed.hasPrefix("/model") {
                await handleModelCommand(
                    trimmed: trimmed,
                    agentLoop: agentLoop,
                    renderer: renderer,
                    interactiveInput: interactiveInput,
                    selectedModel: &selectedModel,
                    announcedGeneralFastFoundationRoute: &announcedGeneralFastFoundationRoute
                )
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

            // Memory commands
            if trimmed.hasPrefix("/memory") {
                await handleMemoryCommand(
                    trimmed: trimmed,
                    workspaceRoot: absWorkspace,
                    renderer: renderer
                )
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

    // MARK: - Slash Command Helpers

    private func handleModelCommand(
        trimmed: String,
        agentLoop: AgentLoop,
        renderer: StreamRenderer,
        interactiveInput: InteractiveInput,
        selectedModel: inout String,
        announcedGeneralFastFoundationRoute: inout Bool
    ) async {
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
            return
        }

        guard let modelID = parseUserModelIdentifier(modelArg) else {
            renderer.printError("Invalid model identifier '\(modelArg)'. Use format 'user/model'.")
            return
        }

        let modelPath = "~/models/\(modelID)"
        guard localModelExists(modelPath) else {
            renderer.printError("Model not found at \(modelPath). Use /model to list installed models.")
            return
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
    }
}

// MARK: - REPL Help Text

func printREPLHelp() {
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
      \u{001B}[32m/memory <cmd>\u{001B}[0m  Memory commands: save, log, search, list, undo, status, snippet
      \u{001B}[32mEsc\u{001B}[0m            Cancel current generation
      \u{001B}[32mShift+Tab\u{001B}[0m      Cycle modes (default starts at Plan low):
                     Plan (low) → Plan (high) → General (fast) →
                     General (low) → Coding (fast) → Coding (low) → Coding (high)
      \u{001B}[32mCtrl+C\u{001B}[0m         Exit REPL
      
    """)
}

// MARK: - Memory Restoration

func restoreMemorySection(workspaceRoot: String, renderer: StreamRenderer) async -> String? {
    let store = KnowledgeStore.shared
    
    // Initialize store (safe to call multiple times)
    do {
        try await store.initialize()
    } catch {
        // Silently fail - memory is optional
        return nil
    }
    
    // Prune expired entries
    do {
        try await store.pruneExpired()
    } catch {
        // Non-fatal
    }
    
    // Detect surface
    let surface = SurfaceDetector.detectSurface(workspacePath: workspaceRoot)
    let branch = SurfaceDetector.currentBranch(in: workspaceRoot)
    
    // Build restore context
    let context = RestoreContext(
        projectRoot: workspaceRoot,
        surface: surface,
        branch: branch
    )
    
    // Retrieve entries
    do {
        let result = try await KnowledgeRetriever.retrieve(from: store, context: context)
        
        if !result.entries.isEmpty {
            renderer.printStatus("Restored \(result.entries.count) knowledge entries (\(result.tokenEstimate) tokens)")
            return MemoryFormatter.formatRestoredContext(result)
        }
        
        return nil
    } catch {
        // Non-fatal
        return nil
    }
}

// MARK: - Memory Command Handler

func handleMemoryCommand(
    trimmed: String,
    workspaceRoot: String,
    renderer: StreamRenderer
) async {
    let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
    
    guard parts.count >= 2 else {
        renderer.printError("Usage: /memory <subcommand> [args]")
        print("""
        
        Memory subcommands:
          /memory save "<message>"                  Save a session state checkpoint
          /memory log "<message>" --type <type>     Log typed knowledge (decision|gotcha|plan|pattern)
          /memory search "<query>"                  FTS5 keyword search
          /memory list [--type <type>]              Browse recent entries
          /memory undo                              Delete last entry
          /memory status                            Entry counts and DB stats
          /memory snippet [--today|--week]          Generate work summary
        
        """)
        return
    }
    
    let subcommand = String(parts[1])
    let store = KnowledgeStore.shared
    
    // Initialize store
    do {
        try await store.initialize()
    } catch {
        renderer.printError("Failed to initialize memory store: \(error)")
        return
    }
    
    switch subcommand {
    case "save":
        guard parts.count >= 3 else {
            renderer.printError("Usage: /memory save \"<message>\"")
            return
        }
        let message = String(parts[2]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        await handleMemorySave(message: message, workspaceRoot: workspaceRoot, store: store, renderer: renderer)
        
    case "log":
        guard parts.count >= 3 else {
            renderer.printError("Usage: /memory log \"<message>\" --type <type>")
            return
        }
        let fullArgs = String(parts[2])
        await handleMemoryLog(args: fullArgs, workspaceRoot: workspaceRoot, store: store, renderer: renderer)
        
    case "search":
        guard parts.count >= 3 else {
            renderer.printError("Usage: /memory search \"<query>\"")
            return
        }
        let query = String(parts[2]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        await handleMemorySearch(query: query, workspaceRoot: workspaceRoot, store: store, renderer: renderer)
        
    case "list":
        let typeFilter = parts.count >= 3 ? String(parts[2]) : nil
        await handleMemoryList(typeFilter: typeFilter, workspaceRoot: workspaceRoot, store: store, renderer: renderer)
        
    case "undo":
        await handleMemoryUndo(workspaceRoot: workspaceRoot, store: store, renderer: renderer)
        
    case "status":
        await handleMemoryStatus(store: store, renderer: renderer)
        
    case "snippet":
        let windowArg = parts.count >= 3 ? String(parts[2]) : nil
        await handleMemorySnippet(window: windowArg, workspaceRoot: workspaceRoot, store: store, renderer: renderer)
        
    default:
        renderer.printError("Unknown memory subcommand: \(subcommand)")
    }
}

func handleMemorySave(message: String, workspaceRoot: String, store: KnowledgeStore, renderer: StreamRenderer) async {
    let surface = SurfaceDetector.detectSurface(workspacePath: workspaceRoot)
    let branch = SurfaceDetector.currentBranch(in: workspaceRoot)
    let expiresAt = Date().addingTimeInterval(48 * 3600) // 48h TTL
    
    let entry = KnowledgeEntry(
        type: .sessionState,
        content: message,
        surface: surface,
        branch: branch,
        projectRoot: workspaceRoot,
        expiresAt: expiresAt
    )
    
    do {
        try await store.insert(entry)
        renderer.printStatus("Session state saved")
    } catch {
        renderer.printError("Failed to save: \(error)")
    }
}

func handleMemoryLog(args: String, workspaceRoot: String, store: KnowledgeStore, renderer: StreamRenderer) async {
    // Parse: "<message>" --type <type>
    let components = args.components(separatedBy: "--type")
    guard components.count == 2 else {
        renderer.printError("Usage: /memory log \"<message>\" --type <type>")
        return
    }
    
    let message = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    let typeStr = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
    
    guard let type = KnowledgeType(rawValue: typeStr) else {
        renderer.printError("Invalid type. Use: decision, gotcha, plan, pattern, session_state")
        return
    }
    
    let surface = SurfaceDetector.detectSurface(workspacePath: workspaceRoot)
    let branch = SurfaceDetector.currentBranch(in: workspaceRoot)
    
    let entry = KnowledgeEntry(
        type: type,
        content: message,
        surface: surface,
        branch: branch,
        projectRoot: workspaceRoot,
        expiresAt: type == .sessionState ? Date().addingTimeInterval(48 * 3600) : nil
    )
    
    do {
        try await store.insert(entry)
        renderer.printStatus("Knowledge logged as \(type.rawValue)")
    } catch {
        renderer.printError("Failed to log: \(error)")
    }
}

func handleMemorySearch(query: String, workspaceRoot: String, store: KnowledgeStore, renderer: StreamRenderer) async {
    do {
        let entries = try await store.search(query: query, projectRoot: workspaceRoot)
        
        if entries.isEmpty {
            print("\nNo results found.\n")
            return
        }
        
        print("\nSearch results (\(entries.count)):\n")
        for entry in entries.prefix(20) {
            print("[\(entry.type.rawValue)] \(entry.content)")
            if let surface = entry.surface {
                print("  surface: \(surface)")
            }
            print("")
        }
    } catch {
        renderer.printError("Search failed: \(error)")
    }
}

func handleMemoryList(typeFilter: String?, workspaceRoot: String, store: KnowledgeStore, renderer: StreamRenderer) async {
    do {
        let type: KnowledgeType?
        if let typeFilter {
            let typeStr = typeFilter.replacingOccurrences(of: "--type ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            type = KnowledgeType(rawValue: typeStr)
            if type == nil {
                renderer.printError("Invalid type: \(typeStr)")
                return
            }
        } else {
            type = nil
        }
        
        let entries = try await store.list(projectRoot: workspaceRoot, type: type, limit: 50)
        
        if entries.isEmpty {
            print("\nNo entries found.\n")
            return
        }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short
        
        print("\nKnowledge entries (\(entries.count)):\n")
        for entry in entries.prefix(20) {
            print("[\(entry.type.rawValue)] \(dateFormatter.string(from: entry.createdAt))")
            print("  \(entry.content)")
            if let surface = entry.surface {
                print("  surface: \(surface)")
            }
            print("")
        }
    } catch {
        renderer.printError("List failed: \(error)")
    }
}

func handleMemoryUndo(workspaceRoot: String, store: KnowledgeStore, renderer: StreamRenderer) async {
    do {
        let entries = try await store.list(projectRoot: workspaceRoot, limit: 1)
        
        guard let lastEntry = entries.first else {
            renderer.printError("No entries to undo")
            return
        }
        
        try await store.delete(id: lastEntry.id)
        renderer.printStatus("Deleted last entry")
    } catch {
        renderer.printError("Undo failed: \(error)")
    }
}

func handleMemoryStatus(store: KnowledgeStore, renderer: StreamRenderer) async {
    do {
        let stats = try await store.stats()
        print("""
        
        Memory Status:
        - Entries: \(stats.entryCount)
        - DB size: \(stats.dbSizeBytes / 1024) KB
        
        """)
    } catch {
        renderer.printError("Status failed: \(error)")
    }
}

func handleMemorySnippet(window: String?, workspaceRoot: String, store: KnowledgeStore, renderer: StreamRenderer) async {
    let timeWindow: SnippetGenerator.TimeWindow
    
    if let window {
        switch window {
        case "--today":
            timeWindow = .today
        case "--week":
            timeWindow = .week
        default:
            timeWindow = .all
        }
    } else {
        timeWindow = .today
    }
    
    do {
        let snippet = try await SnippetGenerator.generate(
            from: store,
            projectRoot: workspaceRoot,
            window: timeWindow,
            format: .markdown
        )
        print("\n\(snippet)\n")
    } catch {
        renderer.printError("Snippet generation failed: \(error)")
    }
}


