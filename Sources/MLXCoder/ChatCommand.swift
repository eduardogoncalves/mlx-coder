// Sources/MLXCoder/ChatCommand.swift
// Interactive REPL subcommand — the main chat loop with slash commands.

import ArgumentParser
import Foundation
import MLXLMCommon
import SwiftCoderTUI
#if canImport(Speech)
import Speech
#endif

struct ChatCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chat",
        abstract: "Start an interactive chat session with the agent"
    )

    @OptionGroup var args: ModelArguments

    mutating func run() async throws {
        guard !args.testAbsorber.isTestInvocation else { return }
        let renderer = StreamRenderer(verbose: args.verbose)
        let interactiveInput = InteractiveInput()
        interactiveInput.voiceSilenceTimeout = args.voiceSilenceTimeout
        interactiveInput.voiceLocale = args.resolvedVoiceLocale
        let frontend = LegacyTerminalFrontend(renderer: renderer, interactiveInput: interactiveInput)

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

        // Start update check in background so it runs in parallel with the rest of setup.
        // We'll collect the result right before the REPL header so the notice always
        // prints to a clean line, never into the interactive input box.
        let currentVersion = MLXCoderCLI.configuration.version
        let updateCheckTask = Task<UpdateInfo?, Never> {
            await UpdateChecker.checkForUpdate(currentVersion: currentVersion)
        }

        // Set up permissions
        let workspacePath = NSString(string: args.workspace).expandingTildeInPath
        let rawWorkspace = workspacePath.hasPrefix("/") ? workspacePath : FileManager.default.currentDirectoryPath + "/" + workspacePath
        // Canonicalize to eliminate trailing slashes, /. components, and symlink variants
        // so that project_root values are consistent across sessions.
        let absWorkspace = URL(fileURLWithPath: rawWorkspace).standardized.path
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
            frontend: frontend,
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
            workspaceRoot: absWorkspace,
            memorySection: memorySection,
            skillsMetadata: skillMetadata
        )

        let agentLoop = AgentLoop(
            modelContainer: modelContainer,
            registry: registry,
            permissions: permissions,
            generationConfig: config,
            frontend: frontend,
            verbose: args.verbose,
            systemPrompt: promptComposition.prompt,
            modelPath: selectedModel,
            workspace: absWorkspace,
            useSandbox: args.sandbox,
            useShadowContextForToolResults: args.shadowContext,
            auditLogger: auditLogger,
            dryRun: effectiveDryRun,
            hooks: hooks,
            skillsMetadata: skillMetadata,
            promptSectionTokenEstimates: promptComposition.sectionTokenEstimates,
            memoryLimit: budget.totalBytes,
            cacheLimit: budget.cacheBytes
        )

        // Wire up raw-terminal approval UI for the legacy (non-TUI) path.
        // The TUI path (SwiftCoderTUIFrontend) handles approvals via renderer.requestApproval.
        frontend.approvalHandler = { request in
            await agentLoop.rawTerminalApprovalInteraction(request: request)
        }

        // Clear the 5 startup status lines to make the UI cleaner
        renderer.clearPreviousLines(count: 5)

        // Collect update check result (already running in background since model load).
        // Race against a 2-second deadline so startup is never blocked.
        let pendingUpdate: UpdateInfo? = await withTaskGroup(of: UpdateInfo?.self) { group in
            group.addTask { await updateCheckTask.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return nil
            }
            let first = await group.next()
            group.cancelAll()
            return first ?? nil
        }

        // REPL Header
        print("""
                       )/_
             _.--..---"-,--c_
        \\L..'           ._O__)_
,-.     _.+  _  \\..--( /    
  `\\.--''__.-' \\ (     \\_    MLX-Coder  
    `'''       `\\__   /\\
                ')
""")
        print("\u{001B}[2mModel: \(selectedModel)\u{001B}[0m")
        print("\u{001B}[2mWorkspace: \(absWorkspace)\u{001B}[0m")
        if let info = pendingUpdate {
            print("⬆️  mlx-coder \(info.latestVersion) is available. Run \u{001B}[1mmlx-coder update\u{001B}[0m to install.\n")
        }
        renderer.printStatus("[Key mode] Editing input. Enter sends, Shift+Tab cycles mode, Ctrl+C exits.")

        var sandboxEnabled = effectiveSandbox
        var announcedGeneralFastFoundationRoute = false
        var voicePrefill: String? = nil
        // Mutable session override for STT locale; starts from the CLI arg value.
        var sessionVoiceLocale: Locale? = args.resolvedVoiceLocale
        
        // Set initial mode from arguments
        if args.mode.lowercased() == "agent" {
            await agentLoop.setMode(.agent, silent: true)
        }
        // Default is already planLow from AgentLoop initializer

        // Debug front-end branch — logs every AgentEvent with timestamps so you
        // can validate that events arrive per-token and not batched.
        // Run a second terminal with: tail -f /tmp/mlx-coder-events.log
        if args.ui.lowercased() == "debug" {
            let debugFrontend = DebugEventFrontend()
            await agentLoop.swapFrontend(debugFrontend)
            print("[debug] Type your message and press Enter. Type 'exit' to quit.")
            while true {
                print("[debug] > ", terminator: "")
                fflush(stdout)
                guard let line = readLine(), !line.isEmpty else { continue }
                if line == "exit" || line == "quit" { break }
                try await agentLoop.processUserMessage(line)
            }
            return
        }

        // SwiftCoderTUI front-end branch — when --ui tui is selected, replace
        // the agent's frontend with the SwiftCoderTUI adapter and run the
        // dedicated TUI session loop. This bypasses the legacy slash-command
        // dispatch below; the TUI session handles its own (minimal) command
        // set today.
        if args.ui.lowercased() == "tui" {
            let localModelIDs = listHomeModelsAsRepoIDs()
            var modelConfigs = localModelIDs.map { AppConfig.ModelConfig(id: $0, label: $0) }
            if !modelConfigs.contains(where: { $0.id.caseInsensitiveCompare(selectedModel) == .orderedSame }) {
                modelConfigs.insert(AppConfig.ModelConfig(id: selectedModel, label: selectedModel), at: 0)
            }
            let defaultModelIndex = modelConfigs.firstIndex {
                $0.id.caseInsensitiveCompare(selectedModel) == .orderedSame
            } ?? 0
            let tuiAppConfig = SwiftCoderTUIAppConfigBuilder.build(
                version: MLXCoderCLI.configuration.version ?? "dev",
                models: modelConfigs,
                defaultModelIndex: defaultModelIndex
            )
            let tuiRenderer = Renderer(config: tuiAppConfig, terminal: ProcessTerminal())
            let tuiFrontend = SwiftCoderTUIFrontend(renderer: tuiRenderer, appConfig: tuiAppConfig)
            await agentLoop.swapFrontend(tuiFrontend)
            await CancelController.shared.setPrintHandler { _ in } // TUI owns the terminal
            await runSwiftCoderTUISession(
                agentLoop: agentLoop,
                frontend: tuiFrontend,
                skillMetadata: skillMetadata,
                hooks: hooks,
                initialSandboxEnabled: effectiveSandbox
            )
            await DotnetLSPService.shared.shutdown()
            print("\nGoodbye!")
            return
        }

        while true {
            // Ensure no background stdin listener competes with interactive editing.
            await CancelController.shared.suspendListening()

            let currentModeName = await agentLoop.currentMode.rawValue
            let prefill = voicePrefill
            voicePrefill = nil
            guard let input = await interactiveInput.readInteractive(
                sandboxEnabled: sandboxEnabled, 
                version: currentVersion, 
                mode: currentModeName,
                initialText: prefill ?? "",
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
            if trimmed == "/voice" {
                #if canImport(Speech)
                renderer.printStatus("🎤 Starting voice input…")
                do {
                    let transcription = try await VoiceInput.transcribe(
                        silenceTimeout: args.voiceSilenceTimeout,
                        locale: sessionVoiceLocale
                    )
                    renderer.printStatus("🎤 \"\(transcription)\"")
                    voicePrefill = transcription
                } catch {
                    renderer.printError("Voice input: \(error.localizedDescription)")
                }
                #else
                renderer.printError("Voice input requires macOS with the Speech framework.")
                #endif
                continue
            }
            if trimmed.hasPrefix("/voice-locale") {
                #if canImport(Speech)
                let parts = trimmed.split(separator: " ", maxSplits: 1)
                if parts.count == 1 {
                    // List available locales, marking the current one.
                    let current = sessionVoiceLocale?.identifier ?? Locale.current.identifier
                    let supported = SFSpeechRecognizer.supportedLocales()
                        .sorted { $0.identifier < $1.identifier }
                    var lines = ["🗣 Available STT locales (current: \u{001B}[1m\(current)\u{001B}[0m):"]
                    for loc in supported {
                        let tag = loc.identifier == current ? " \u{001B}[32m←\u{001B}[0m" : ""
                        let name = Locale.current.localizedString(forIdentifier: loc.identifier) ?? loc.identifier
                        let padded = loc.identifier.padding(toLength: 14, withPad: " ", startingAt: 0)
                        lines.append("  \(padded)\(name)\(tag)")
                    }
                    renderer.printStatus(lines.joined(separator: "\n"))
                } else {
                    let identifier = String(parts[1]).trimmingCharacters(in: .whitespaces)
                    let locale = Locale(identifier: identifier)
                    if let r = SFSpeechRecognizer(locale: locale), r.isAvailable {
                        sessionVoiceLocale = locale
                        interactiveInput.voiceLocale = locale
                        renderer.printStatus("🗣 STT locale set to \(identifier)")
                    } else {
                        renderer.printError("Locale '\(identifier)' is not available for speech recognition. Use /voice-locale to list supported locales.")
                    }
                }
                #else
                renderer.printError("Voice input requires macOS with the Speech framework.")
                #endif
                continue
            }
            if trimmed == "/plan" {
                let isInPlan = await agentLoop.mode == .plan
                if isInPlan {
                    await agentLoop.setMode(.agent, taskType: .coding)
                } else {
                    await agentLoop.setMode(.plan)
                }
                continue
            }
            if trimmed == "/autopilot" {
                let currentMode = await agentLoop.mode
                let currentTaskType = await agentLoop.taskType
                let isAutopilot = currentMode != .plan && currentTaskType == .general
                if isAutopilot {
                    await agentLoop.setMode(.agent, taskType: .coding)
                } else {
                    await agentLoop.setMode(.agent, taskType: .general)
                }
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
            if trimmed.hasPrefix("/effort") || trimmed.hasPrefix("/thinking") {
                let isLegacyAlias = trimmed.hasPrefix("/thinking")
                let parts = trimmed.split(separator: " ")
                if parts.count > 1 {
                    let level = parts[1].lowercased()
                    switch level {
                    case "off", "fast":
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
                        renderer.printError("Invalid effort level: \(level). Use 'off', 'minimal', 'low', 'medium', or 'high'.")
                    }
                    if isLegacyAlias {
                        renderer.printStatus("Tip: /thinking is a legacy alias. Prefer /effort.")
                    }
                } else {
                    let current = await agentLoop.thinkingLevel
                    let effort = current == .fast ? "off" : current.rawValue
                    renderer.printStatus("Reasoning effort: \(effort)")
                    if isLegacyAlias {
                        renderer.printStatus("Tip: /thinking is a legacy alias. Prefer /effort.")
                    }
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

            if trimmed.hasPrefix("/btw ") {
                let question = String(trimmed.dropFirst("/btw ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if question.isEmpty {
                    renderer.printError("Usage: /btw <question>")
                } else {
                    renderer.printStatus("[btw] Side question (main context will be restored after).")
                    renderer.printStatus("[Key mode] Generation active. Press Esc to cancel.")
                    let task = Task {
                        try await agentLoop.processEphemeralMessage(question)
                        renderer.printStatus("[btw] Side question answered. Main context restored.")
                    }
                    await CancelController.shared.setTask(task)
                    do {
                        try await task.value
                    } catch is CancellationError {
                        renderer.printError("[btw] Generation cancelled.")
                    } catch {
                        renderer.printError(error.localizedDescription)
                    }
                    await CancelController.shared.setTask(nil)
                }
                continue
            }

            // Memory commands
            if trimmed.hasPrefix("/memory") {
                await handleMemoryCommand(
                    trimmed: trimmed,
                    workspaceRoot: absWorkspace,
                    frontend: frontend
                )
                continue
            }

            // /init [description] — scaffold .planning/ context files for this workspace
            if trimmed.hasPrefix("/init") {
                let description = String(trimmed.dropFirst("/init".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                let initPrompt = buildInitWorkflowPrompt(description: description, workspaceRoot: absWorkspace)
                renderer.printStatus("[init] Scaffolding project planning structure…")
                renderer.printStatus("[Key mode] Generation active. Press Esc to cancel.")
                let initTask = Task { try await agentLoop.processUserMessage(initPrompt) }
                await CancelController.shared.setTask(initTask)
                do { try await initTask.value } catch is CancellationError {
                    renderer.printError("[init] Cancelled.")
                } catch { renderer.printError(error.localizedDescription) }
                await CancelController.shared.setTask(nil)
                continue
            }

            // /debug [issue] — structured debugging session using the scientific method
            if trimmed.hasPrefix("/debug") {
                let issue = String(trimmed.dropFirst("/debug".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                let debugPrompt = buildDebugWorkflowPrompt(issue: issue)
                renderer.printStatus("[debug] Starting structured debugging session…")
                renderer.printStatus("[Key mode] Generation active. Press Esc to cancel.")
                let debugTask = Task { try await agentLoop.processUserMessage(debugPrompt) }
                await CancelController.shared.setTask(debugTask)
                do { try await debugTask.value } catch is CancellationError {
                    renderer.printError("[debug] Cancelled.")
                } catch { renderer.printError(error.localizedDescription) }
                await CancelController.shared.setTask(nil)
                continue
            }

            // /review [scope] — structured code review across correctness, security, performance
            if trimmed.hasPrefix("/review") {
                let scope = String(trimmed.dropFirst("/review".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                let reviewPrompt = buildReviewWorkflowPrompt(scope: scope, workspaceRoot: absWorkspace)
                renderer.printStatus("[review] Starting code review…")
                renderer.printStatus("[Key mode] Generation active. Press Esc to cancel.")
                let reviewTask = Task { try await agentLoop.processUserMessage(reviewPrompt) }
                await CancelController.shared.setTask(reviewTask)
                do { try await reviewTask.value } catch is CancellationError {
                    renderer.printError("[review] Cancelled.")
                } catch { renderer.printError(error.localizedDescription) }
                await CancelController.shared.setTask(nil)
                continue
            }

            // /todo [add <text> | done <n> | list] — manage .planning/todos.md
            if trimmed.hasPrefix("/todo") {
                let todoArg = String(trimmed.dropFirst("/todo".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                let todoPrompt = buildTodoWorkflowPrompt(arg: todoArg, workspaceRoot: absWorkspace)
                renderer.printStatus("[todo] Managing task list…")
                renderer.printStatus("[Key mode] Generation active. Press Esc to cancel.")
                let todoTask = Task { try await agentLoop.processUserMessage(todoPrompt) }
                await CancelController.shared.setTask(todoTask)
                do { try await todoTask.value } catch is CancellationError {
                    renderer.printError("[todo] Cancelled.")
                } catch { renderer.printError(error.localizedDescription) }
                await CancelController.shared.setTask(nil)
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
                    // Expand @file references to inline content, then parse image attachments.
                    let expanded = AtFileReferenceExpander.expand(trimmed, workspaceRoot: absWorkspace)
                    let parsed = ImageAttachmentParser.parse(prompt: expanded)
                    if !parsed.imageURLs.isEmpty {
                        renderer.printStatus("Attaching \(parsed.imageURLs.count) image(s): \(parsed.imageURLs.map(\.lastPathComponent).joined(separator: ", "))")
                    }
                    try await agentLoop.processUserMessage(parsed.cleanedPrompt, images: parsed.imageURLs)
                }
                await CancelController.shared.setTask(task)
                try await task.value
                await CancelController.shared.setTask(nil)

                // Auto-process queued follow-ups in FIFO order.
                while let followUp = await agentLoop.dequeueFollowUp() {
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
      \u{001B}[32m@file.swift\u{001B}[0m    Attach a file — content is inlined into the prompt
      \u{001B}[32m@~/path\u{001B}[0m        Tilde-expanded paths are supported
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
      \u{001B}[32m/plan\u{001B}[0m          Toggle PLAN MODE on/off (off => coding mode)
      \u{001B}[32m/autopilot\u{001B}[0m     Toggle AUTOPILOT on/off (off => coding mode)
      \u{001B}[32m/agent\u{001B}[0m         Switch to AGENT MODE (full filesystem/shell access)
      \u{001B}[32m/task [type]\u{001B}[0m   Set task type: general, coding, reasoning
      \u{001B}[32m/effort [lvl]\u{001B}[0m  Set reasoning effort: off, minimal, low, medium, high (default: low)
      \u{001B}[32m/thinking [lvl]\u{001B}[0m Legacy alias for /effort
      \u{001B}[32m/steer [msg]\u{001B}[0m   Queue a steering message injected between agent turns (no arg = list queue)
      \u{001B}[32m/followup [msg]\u{001B}[0m Queue a follow-up run after the current task (no arg = list queue)
      \u{001B}[32m/btw <question>\u{001B}[0m Ask a quick side question without affecting the main conversation
      \u{001B}[32m/merge-approval\u{001B}[0m Trigger the "Awaiting approval before merge" flow
      \u{001B}[32m/gittree\u{001B}[0m       List git worktrees and switch workspace/branch to one
      \u{001B}[32m/sandbox\u{001B}[0m       Toggle macOS Seatbelt sandbox for shell commands
      \u{001B}[32m/voice, Ctrl+V\u{001B}[0m  Voice input (STT) — fills transcription into input box for editing
      \u{001B}[32m/voice-locale [id]\u{001B}[0m Set STT language (no arg = list all available locales)
      \u{001B}[32mCtrl+J, Option+Enter, \\+Enter\u{001B}[0m Insert newline in input box
      \u{001B}[32mCommand+V\u{001B}[0m      Paste text into input box (multiline supported)
      \u{001B}[32m/memory <cmd>\u{001B}[0m  Memory commands: save, log, search, list, undo, status, snippet

    \u{1B}[1mWorkflow Commands:\u{001B}[0m
      \u{001B}[32m/init [description]\u{001B}[0m Scaffold .planning/ context files (PROJECT.md, REQUIREMENTS.md, ROADMAP.md, STATE.md, todos.md)
      \u{001B}[32m/todo [add <text> | done <n> | list]\u{001B}[0m Manage .planning/todos.md; 'add' also offers to open a worktree branch
      \u{001B}[32m/debug [issue]\u{001B}[0m  Scientific-method debugging: symptoms → hypotheses → isolate → fix → commit
      \u{001B}[32m/review [scope]\u{001B}[0m Code review covering correctness, security, performance, and tests

      \u{001B}[32mEsc\u{001B}[0m            Cancel current generation
      \u{001B}[32mShift+Tab\u{001B}[0m      Cycle modes (default starts at Plan low):
                     Plan (low) → Plan (high) → General (fast) →
                     General (low) → Coding (fast) → Coding (low) → Coding (high)
      \u{001B}[32mCtrl+C\u{001B}[0m         Exit REPL
      
    """)
}

// MARK: - Workflow Command Prompts

func buildInitWorkflowPrompt(description: String, workspaceRoot: String) -> String {
    let descLine = description.isEmpty
        ? "No description provided — infer from the existing codebase."
        : "Project description: \(description)"
    return """
    You are running the /init workflow. Your goal is to scaffold a .planning/ directory for this workspace so future sessions can load context efficiently.

    Workspace: \(workspaceRoot)
    \(descLine)

    Steps:
    1. Read the existing codebase structure (top-level directories, Package.swift / package.json / Cargo.toml / etc., README if present). Do NOT skip this — the files you create must reflect what actually exists.
    2. Create .planning/ if it does not exist.
    3. Create or update the following files (use write_file or patch if they already exist):

    .planning/PROJECT.md
    ────────────────────
    # Project: <name>

    ## Vision
    <one paragraph describing what this project does and why it matters>

    ## Tech Stack
    <language, framework, key dependencies>

    ## Constraints
    <performance targets, OS requirements, coding conventions>

    .planning/REQUIREMENTS.md
    ──────────────────────────
    # Requirements

    ## In Scope (v1)
    - [ ] <requirement 1>

    ## Out of Scope / Future
    - <future idea>

    .planning/ROADMAP.md
    ─────────────────────
    # Roadmap

    ## Phase 1: <name>
    **Goal:** <what this phase achieves>
    **Status:** not started
    **Delivers:**
    - <deliverable>

    .planning/STATE.md
    ───────────────────
    # Project State

    **Current phase:** 1
    **Last updated:** <today's date>

    ## Open Decisions
    | Decision | Options | Due |
    |----------|---------|-----|

    ## Blockers
    None

    .planning/todos.md
    ───────────────────
    # Todo List

    | # | Task | Priority | Status | Branch |
    |---|------|----------|--------|--------|

    4. After writing the files, print a short summary of what was created and suggest: "Run /todo add <first task> to add a task, or just describe what you'd like to build."
    """
}

func buildDebugWorkflowPrompt(issue: String) -> String {
    let issueLine = issue.isEmpty
        ? "No issue description provided — ask the user to describe the problem before proceeding."
        : "Issue: \(issue)"
    return """
    You are running the /debug workflow. Follow the scientific method strictly — do not guess or apply fixes before confirming the root cause.

    \(issueLine)

    Steps:
    1. GATHER SYMPTOMS — If not fully described in the issue, ask:
       a. Expected behavior: what should happen?
       b. Actual behavior: what happens instead? (include exact error messages or stack traces)
       c. Reproduction steps: how do you trigger it reliably?
       d. When did it start? Was it ever working?

    2. COLLECT EVIDENCE — Before forming a hypothesis:
       - Read the relevant code path(s) end-to-end
       - Run the reproduction steps via bash; capture exact output
       - Check recent git history for related changes: git log --oneline -10

    3. FORM HYPOTHESES — List 2–3 candidate root causes in order of likelihood:
       Hypothesis 1: <most likely>
       Hypothesis 2: <second candidate>
       Hypothesis 3: <edge case>

    4. TEST & ELIMINATE — For each hypothesis (most likely first):
       - Design the minimal test (targeted log, assertion, or isolated repro)
       - Execute it
       - Record result: confirmed / eliminated / inconclusive
       Continue until one hypothesis is confirmed.

    5. FIX — Make the minimal change that addresses the confirmed root cause. Do NOT over-engineer.
       - Modify only what is needed
       - Add a regression test if the test infrastructure allows it
       - Run the full build/test suite to verify

    6. COMMIT — git add + git commit with message:
       fix: <concise description>

       Root cause: <one sentence>
       Fix: <one sentence>

    7. REPORT — Summarize: root cause, fix applied, files changed, test result, commit hash.
    """
}

func buildReviewWorkflowPrompt(scope: String, workspaceRoot: String) -> String {
    let scopeLine: String
    if scope.isEmpty {
        scopeLine = "No scope provided — review recent changes: run `git diff HEAD~1` to find them, or ask the user what to review."
    } else {
        scopeLine = "Review scope: \(scope)"
    }
    return """
    You are running the /review workflow. Perform a thorough code review; be specific and actionable.

    Workspace: \(workspaceRoot)
    \(scopeLine)

    Steps:
    1. DETERMINE SCOPE — If scope is a file/directory, read it. If scope refers to recent changes, run `git diff HEAD~1` or `git diff main`. Read all relevant tests too.

    2. REVIEW ACROSS FOUR DIMENSIONS for each file:

       CORRECTNESS
       - Edge cases: nil/null, empty collections, boundary values, concurrent access
       - Error handling: are errors caught, propagated, and surfaced correctly?
       - Logic: off-by-one errors, inverted conditions, wrong comparisons

       SECURITY
       - Input validation and sanitization (user input, file paths, shell arguments)
       - Injection risks (shell, SQL, path traversal)
       - Sensitive data: secrets, tokens, PII — are they logged or exposed?
       - Permission checks before privileged operations

       PERFORMANCE
       - Unnecessary allocations in hot paths
       - N+1 or missing batch operations
       - Large structures copied when they could be referenced or streamed
       - Missing caching for expensive repeated operations

       TESTS & MAINTAINABILITY
       - Critical paths and error paths covered by tests?
       - Tests deterministic and independent?
       - Naming clear and consistent with project conventions?
       - Functions single-purpose and under ~40 lines?
       - Duplicated logic that should be extracted?

    3. WRITE THE REVIEW:

       ## Code Review: <scope>

       ### Summary
       <2–3 sentences on overall quality>

       ### Critical (must fix)
       - **<file>:<line>** <issue> — Suggestion: <concrete fix>

       ### Improvements (should fix)
       - **<file>:<line>** <issue> — Suggestion: <concrete fix>

       ### Notes (consider)
       - **<file>:<line>** <minor observation>

       ### Positives
       - <what is done well — be specific>

    4. OFFER NEXT STEPS — Ask: "Should I apply any of these fixes? Describe which ones or type a specific fix."
    """
}

func buildTodoWorkflowPrompt(arg: String, workspaceRoot: String) -> String {
    let todosPath = "\(workspaceRoot)/.planning/todos.md"
    if arg.hasPrefix("add ") {
        let text = String(arg.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        You are running /todo add. Add a new task to the todo list and optionally open a git worktree branch for it.

        Task to add: \(text)
        Todos file: \(todosPath)

        Steps:
        1. Read \(todosPath). If it does not exist, create .planning/ and the file with this header:
           # Todo List
           | # | Task | Priority | Status | Branch |
           |---|------|----------|--------|--------|
        2. Determine the next sequence number (count existing rows + 1).
        3. Append a new row:
           | <n> | \(text) | medium | pending | — |
        4. Ask the user: "Open a git worktree branch for this task? (yes/no)"
           - If yes: suggest a branch name derived from the task text (lowercase, hyphens, max 40 chars),
             confirm with the user, then create the worktree branch:
             git worktree add -b <branch-name> ../<worktree-dir> <base-branch>
             Update the Branch column in todos.md with the branch name.
           - If no: leave Branch as —.
        5. Report: task added at row #<n>, branch (if created).
        """
    } else if arg == "list" || arg.isEmpty {
        return """
        You are running /todo list. Display the current task list.

        Todos file: \(todosPath)

        Steps:
        1. Read \(todosPath). If it does not exist, print: "No todo list found. Run /todo add <task> to create one." and stop.
        2. Print the table contents in a readable format, grouping by status (pending first, then in-progress, then done).
        3. Show a summary line: "<n> tasks — <p> pending, <i> in-progress, <d> done."
        4. If any pending tasks have an associated branch, note: "Use /gittree to switch to a task branch."
        """
    } else if arg.hasPrefix("done ") {
        let numStr = String(arg.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        You are running /todo done. Mark a task as complete.

        Task number to mark done: \(numStr)
        Todos file: \(todosPath)

        Steps:
        1. Read \(todosPath). If the file does not exist, print: "No todo list found." and stop.
        2. Find the row with # = \(numStr). If not found, print: "Task #\(numStr) not found." and stop.
        3. Update that row's Status column from its current value to "done".
        4. If the row has an associated branch, ask: "Do you want to trigger the merge-approval flow for branch <branch>? (yes/no)"
           - If yes: finalize the branch using the same merge-approval flow as /merge-approval.
        5. Save the updated todos.md.
        6. Report: task #\(numStr) marked done.
        """
    } else {
        return """
        You are running /todo. Unknown sub-command: "\(arg)"

        Usage:
          /todo              — list all tasks
          /todo list         — list all tasks
          /todo add <text>   — add a new task (offers to open a worktree branch)
          /todo done <n>     — mark task #n as done (offers merge-approval if it has a branch)
        """
    }
}

// MARK: - Memory Restoration
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
    frontend: any AgentFrontend
) async {
    let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
    
    guard parts.count >= 2 else {
        frontend.emit(.memoryEvent(.status(lines: [
            "Usage: /memory <subcommand> [args]",
            "",
            "Memory subcommands:",
            "  /memory save \"<message>\"                  Save a session state checkpoint",
            "  /memory log \"<message>\" --type <type>     Log typed knowledge (decision|gotcha|plan|pattern)",
            "  /memory search \"<query>\"                  FTS5 keyword search",
            "  /memory list [--type <type>]              Browse recent entries",
            "  /memory undo                              Delete last entry",
            "  /memory status                            Entry counts and DB stats",
            "  /memory snippet [--today|--week]          Generate work summary",
        ])))
        return
    }
    
    let subcommand = String(parts[1])
    let store = KnowledgeStore.shared
    
    // Initialize store
    do {
        try await store.initialize()
    } catch {
        frontend.emit(.memoryEvent(.error("Failed to initialize memory store: \(error)")))
        return
    }
    
    switch subcommand {
    case "save":
        guard parts.count >= 3 else {
            frontend.emit(.memoryEvent(.error("Usage: /memory save \"<message>\"")))
            return
        }
        let message = String(parts[2]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        await handleMemorySave(message: message, workspaceRoot: workspaceRoot, store: store, frontend: frontend)
        
    case "log":
        guard parts.count >= 3 else {
            frontend.emit(.memoryEvent(.error("Usage: /memory log \"<message>\" --type <type>")))
            return
        }
        let fullArgs = String(parts[2])
        await handleMemoryLog(args: fullArgs, workspaceRoot: workspaceRoot, store: store, frontend: frontend)
        
    case "search":
        guard parts.count >= 3 else {
            frontend.emit(.memoryEvent(.error("Usage: /memory search \"<query>\"")))
            return
        }
        let query = String(parts[2]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        await handleMemorySearch(query: query, workspaceRoot: workspaceRoot, store: store, frontend: frontend)
        
    case "list":
        let typeFilter = parts.count >= 3 ? String(parts[2]) : nil
        await handleMemoryList(typeFilter: typeFilter, workspaceRoot: workspaceRoot, store: store, frontend: frontend)
        
    case "undo":
        await handleMemoryUndo(workspaceRoot: workspaceRoot, store: store, frontend: frontend)
        
    case "status":
        await handleMemoryStatus(store: store, frontend: frontend)
        
    case "snippet":
        let windowArg = parts.count >= 3 ? String(parts[2]) : nil
        await handleMemorySnippet(window: windowArg, workspaceRoot: workspaceRoot, store: store, frontend: frontend)
        
    default:
        frontend.emit(.memoryEvent(.error("Unknown memory subcommand: \(subcommand)")))
    }
}

func handleMemorySave(message: String, workspaceRoot: String, store: KnowledgeStore, frontend: any AgentFrontend) async {
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
        frontend.emit(.memoryEvent(.checkpointSaved(summary: message)))
    } catch {
        frontend.emit(.memoryEvent(.checkpointFailed(reason: "\(error)")))
    }
}

func handleMemoryLog(args: String, workspaceRoot: String, store: KnowledgeStore, frontend: any AgentFrontend) async {
    let components = args.components(separatedBy: "--type")
    guard components.count == 2 else {
        frontend.emit(.memoryEvent(.error("Usage: /memory log \"<message>\" --type <type>")))
        return
    }
    
    let message = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    let typeStr = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
    
    guard let type = KnowledgeType(rawValue: typeStr) else {
        frontend.emit(.memoryEvent(.error("Invalid type. Use: decision, gotcha, plan, pattern, session_state")))
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
        frontend.emit(.memoryEvent(.factSaved(subject: type.rawValue, fact: message)))
    } catch {
        frontend.emit(.memoryEvent(.error("Failed to log: \(error)")))
    }
}

func handleMemorySearch(query: String, workspaceRoot: String, store: KnowledgeStore, frontend: any AgentFrontend) async {
    do {
        let entries = try await store.search(query: query, projectRoot: workspaceRoot)
        
        if entries.isEmpty {
            frontend.emit(.memoryEvent(.searchResults(query: query, lines: ["No results found."])))
            return
        }
        
        var lines: [String] = ["Search results (\(entries.count)):"]
        for entry in entries.prefix(20) {
            lines.append("[\(entry.type.rawValue)] \(entry.content)")
            if let surface = entry.surface {
                lines.append("  surface: \(surface)")
            }
        }
        frontend.emit(.memoryEvent(.searchResults(query: query, lines: lines)))
    } catch {
        frontend.emit(.memoryEvent(.error("Search failed: \(error)")))
    }
}

func handleMemoryList(typeFilter: String?, workspaceRoot: String, store: KnowledgeStore, frontend: any AgentFrontend) async {
    do {
        let type: KnowledgeType?
        if let typeFilter {
            let typeStr = typeFilter.replacingOccurrences(of: "--type ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            type = KnowledgeType(rawValue: typeStr)
            if type == nil {
                frontend.emit(.memoryEvent(.error("Invalid type: \(typeStr)")))
                return
            }
        } else {
            type = nil
        }
        
        let entries = try await store.list(projectRoot: workspaceRoot, type: type, limit: 50)
        
        if entries.isEmpty {
            frontend.emit(.memoryEvent(.factsListed(count: 0, lines: ["No entries found."])))
            return
        }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short
        
        var lines: [String] = ["Knowledge entries (\(entries.count)):"]
        for entry in entries.prefix(20) {
            lines.append("[\(entry.type.rawValue)] \(dateFormatter.string(from: entry.createdAt))")
            lines.append("  \(entry.content)")
            if let surface = entry.surface {
                lines.append("  surface: \(surface)")
            }
        }
        frontend.emit(.memoryEvent(.factsListed(count: entries.count, lines: lines)))
    } catch {
        frontend.emit(.memoryEvent(.error("List failed: \(error)")))
    }
}

func handleMemoryUndo(workspaceRoot: String, store: KnowledgeStore, frontend: any AgentFrontend) async {
    do {
        let entries = try await store.list(projectRoot: workspaceRoot, limit: 1)
        
        guard let lastEntry = entries.first else {
            frontend.emit(.memoryEvent(.error("No entries to undo")))
            return
        }
        
        try await store.delete(id: lastEntry.id)
        frontend.emit(.memoryEvent(.undone(message: "Deleted last entry")))
    } catch {
        frontend.emit(.memoryEvent(.error("Undo failed: \(error)")))
    }
}

func handleMemoryStatus(store: KnowledgeStore, frontend: any AgentFrontend) async {
    do {
        let stats = try await store.stats()
        frontend.emit(.memoryEvent(.status(lines: [
            "Memory Status:",
            "- Entries: \(stats.entryCount)",
            "- DB size: \(stats.dbSizeBytes / 1024) KB",
        ])))
    } catch {
        frontend.emit(.memoryEvent(.error("Status failed: \(error)")))
    }
}

func handleMemorySnippet(window: String?, workspaceRoot: String, store: KnowledgeStore, frontend: any AgentFrontend) async {
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
        frontend.emit(.memoryEvent(.status(lines: snippet.split(separator: "\n").map(String.init))))
    } catch {
        frontend.emit(.memoryEvent(.error("Snippet generation failed: \(error)")))
    }
}
