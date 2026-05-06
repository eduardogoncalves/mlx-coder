// Sources/CLI/SwiftCoderTUISession.swift
// Minimal SwiftCoderTUI-driven REPL for mlx-coder. Wired by ChatCommand
// when the user passes `--ui tui`. The legacy REPL stays the default.
//
// Scope of this initial pass:
//   • Full-screen TUI shell (welcome, footer, scroll area)
//   • Slash-commands `/clear`, `/quit`, `/help`, `/status` handled locally
//   • All other input goes to AgentLoop.processUserMessage, with output
//     streamed via SwiftCoderTUIFrontend
//   • Approval modal driven by Renderer.requestApproval (best-effort —
//     AgentLoop's native raw-mode approval still owns the actual decision
//     until Phase 5 fully replaces it)
//
// Out of scope here (deferred): autocomplete, voice, multi-line input,
// model/mode picker overlays, history persistence.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import MLX
import SwiftCoderTUI

struct TUIShellCommandParseResult: Equatable {
    let command: String?
    let isRepeat: Bool
}

enum TUIShellCommandParser {
    static func parse(_ input: String, lastShellCommand: String) -> TUIShellCommandParseResult {
        if isRepeatCommand(input) {
            return .init(command: lastShellCommand.isEmpty ? nil : lastShellCommand, isRepeat: true)
        }
        if input.hasPrefix("!!"), input.count > 2 {
            return .init(command: String(input.dropFirst(2)).trimmingCharacters(in: .whitespaces), isRepeat: false)
        }
        if input.hasPrefix("!"), input.count > 1 {
            return .init(command: String(input.dropFirst()).trimmingCharacters(in: .whitespaces), isRepeat: false)
        }
        return .init(command: nil, isRepeat: false)
    }

    static func isRepeatCommand(_ input: String) -> Bool {
        guard input.hasPrefix("!!") else { return false }
        guard input.count > 2 else { return true }
        let next = input[input.index(input.startIndex, offsetBy: 2)]
        return next.isWhitespace
    }
}

@MainActor
public func runSwiftCoderTUISession(
    agentLoop: AgentLoop,
    frontend: SwiftCoderTUIFrontend,
    skillMetadata: [SkillMetadata],
    hooks: HookPipeline,
    initialSandboxEnabled: Bool
) async {
    let processTerminal = ProcessTerminal()
    processTerminal.setupRawMode(title: frontend.appConfig.appName)
    defer { processTerminal.restoreMode() }

    let renderer = frontend.renderer

    let staticItems = frontend.appConfig.commands
        .filter { $0.name != "/model" }
        .map {
        AutocompleteItem(value: String($0.name.dropFirst()), label: $0.name, description: $0.description)
    }
    let provider = CombinedAutocompleteProvider(
        commands: [TUIModelSlashCommand(models: frontend.appConfig.models)],
        staticCommands: staticItems
    )
    await renderer.setAutocompleteProvider(provider)

    await renderer.setupScreen()
    await renderer.setSandboxEnabled(initialSandboxEnabled)
    let initialWorkingMode = await agentLoop.mode
    let initialTaskType = await agentLoop.taskType
    let initialThinkingLevel = await agentLoop.thinkingLevel
    if let initialModeIndex = modeIndex(for: initialThinkingLevel, appConfig: frontend.appConfig) {
        await renderer.setCurrentModeIndex(initialModeIndex)
    }
    let initialStatusMode = statusModeLabel(workingMode: initialWorkingMode, taskType: initialTaskType)
    await renderer.setAutopilot(initialStatusMode == "autopilot")
    await renderer.setStatusModeLabel(initialStatusMode)
    await renderer.showWelcome()
    await renderer.renderFooter()

    let inputHistory = InputHistory()
    var activeStreamTask: Task<Void, Never>? = nil
    var sigwinchSource: DispatchSourceSignal? = nil
    var pendingResizeTask: Task<Void, Never>? = nil
    var lastShellCommand: String = ""
    var lastUserPrompt: String?
    let workspaceRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardized.path
    var shouldQuit = false

    signal(SIGWINCH, SIG_IGN)
    let resizeSource = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
    resizeSource.setEventHandler {
        pendingResizeTask?.cancel()
        pendingResizeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000)
            guard !Task.isCancelled else { return }
            let old = await renderer.updateSize()
            await renderer.handleResize(oldRows: old.oldRows, oldCols: old.oldCols)
        }
    }
    resizeSource.resume()
    sigwinchSource = resizeSource

    mainLoop: for await key in InputHandler.keystrokes() {

        // Approval intercept — when the agent has paused for a tool decision.
        if frontend.hasPendingApproval {
            switch key {
            case .character(let ch):
                if let digit = Int(String(ch)), (1...4).contains(digit) {
                    frontend.resolveApproval(decisionForOption(digit - 1))
                }
            case .enter:
                let sel = await renderer.getApprovalSelection()
                frontend.resolveApproval(decisionForOption(sel))
            case .escape:
                frontend.resolveApproval(.deny(suggestion: nil))
            case .arrowUp:
                await renderer.moveApprovalSelection(offset: -1)
            case .arrowDown:
                await renderer.moveApprovalSelection(offset: 1)
            default:
                break
            }
            continue
        }

        switch key {
        case .character(let ch):
            await renderer.appendChar(ch)
            await renderer.renderFooter()

        case .backspace, .delete:
            await renderer.deleteChar()
            await renderer.renderFooter()

        case .arrowLeft:
            await renderer.moveCursorLeft()
            await renderer.renderFooter()

        case .arrowRight:
            await renderer.moveCursorRight()
            await renderer.renderFooter()

        case .arrowUp:
            if await renderer.isAutocompleteActive() {
                await renderer.moveAutocompleteSelection(offset: -1)
                await renderer.renderFooter()
            } else if let prev = inputHistory.previous() {
                await renderer.setInputBuffer(prev)
                await renderer.renderFooter()
            }

        case .arrowDown:
            if await renderer.isAutocompleteActive() {
                await renderer.moveAutocompleteSelection(offset: 1)
                await renderer.renderFooter()
            } else if let next = inputHistory.next() {
                await renderer.setInputBuffer(next)
                await renderer.renderFooter()
            } else {
                await renderer.setInputBuffer("")
                await renderer.renderFooter()
            }

        case .ctrlC:
            activeStreamTask?.cancel()
            await frontend.abortGeneration()

        case .escape:
            if await renderer.isAutocompleteActive() {
                await renderer.clearAutocomplete()
                await renderer.renderFooter()
            } else if await renderer.getIsGenerating() {
                activeStreamTask?.cancel()
                await frontend.abortGeneration()
            }

        case .ctrlL:
            let old = await renderer.updateSize()
            await renderer.handleResize(oldRows: old.oldRows, oldCols: old.oldCols)

        case .tab:
            if await renderer.isAutocompleteActive() {
                await renderer.acceptAutocomplete()
            } else {
                await renderer.openCommandPalette()
            }
            await renderer.renderFooter()

        case .shiftTab:
            _ = await agentLoop.cycleMode()
            await renderer.renderFooter()

        case .enter:
            // Accept any pending ghost/autocomplete suggestion before submitting,
            // so "/q" + Enter expands to "/quit" and executes it.
            if await renderer.isAutocompleteActive() {
                await renderer.acceptAutocomplete()
            }
            let prompt = (await renderer.submitInput()) ?? ""
            let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let commandInput = normalizedCommandInput(from: trimmed)
            if trimmed.isEmpty {
                await renderer.renderFooter()
                continue
            }
            inputHistory.add(trimmed)
            inputHistory.resetCursor()

            if commandInput == "/quit" || commandInput == "exit" || commandInput == "quit" {
                shouldQuit = true
                break mainLoop
            }
            if commandInput == "/clear" {
                await renderer.clearConversation()
                await agentLoop.clearHistoryWithCheckpoint()
                lastUserPrompt = nil
                continue
            }
            if commandInput == "/context" {
                let report = await agentLoop.contextUsageReport()
                for line in report.split(separator: "\n", omittingEmptySubsequences: false) {
                    await renderer.printScrollLine(String(line))
                }
                continue
            }
            if commandInput == "/skills" {
                if skillMetadata.isEmpty {
                    await renderer.printScrollLine("No skills discovered in workspace.")
                } else {
                    await renderer.printScrollLine("Discovered skills (\(skillMetadata.count)):")
                    for skill in skillMetadata {
                        let tags = skill.tags.isEmpty ? "" : " [tags: \(skill.tags.joined(separator: ", "))]"
                        await renderer.printScrollLine("- \(skill.name): \(skill.description) (\(skill.filePath))\(tags)")
                    }
                }
                continue
            }
            if commandInput == "/hooks" {
                let names = await hooks.registeredHookNames()
                if names.isEmpty {
                    await renderer.printScrollLine("No hooks registered.")
                } else {
                    await renderer.printScrollLine("Active hooks (\(names.count)):")
                    for name in names {
                        await renderer.printScrollLine("- \(name)")
                    }
                }
                continue
            }
            if commandInput.hasPrefix("/transforms") {
                let arg = String(commandInput.dropFirst("/transforms".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if arg == "clear" {
                    await agentLoop.removeAllContextTransforms()
                    await renderer.printScrollLine("All context transforms removed.")
                } else {
                    let count = await agentLoop.contextTransformCount
                    if count == 0 {
                        await renderer.printScrollLine("No context transforms registered.")
                    } else {
                        await renderer.printScrollLine("Context transforms registered: \(count)")
                        await renderer.printScrollLine("Use '/transforms clear' to remove all.")
                    }
                }
                continue
            }
            if commandInput.hasPrefix("/save-history-json") {
                let parts = commandInput.split(separator: " ", maxSplits: 1)
                let outputPath = parts.count > 1 ? String(parts[1]) : "session-history.json"
                do {
                    _ = try await agentLoop.exportHistoryJSON(to: outputPath)
                } catch {
                    await renderer.printScrollLine("\(DesignSystem.brightRed)✗ Failed to export JSON history: \(error.localizedDescription)\(DesignSystem.reset)")
                }
                continue
            }
            if commandInput.hasPrefix("/save-history") {
                let parts = commandInput.split(separator: " ", maxSplits: 1)
                let outputPath = parts.count > 1 ? String(parts[1]) : "session-history.md"
                do {
                    _ = try await agentLoop.exportHistory(to: outputPath)
                } catch {
                    await renderer.printScrollLine("\(DesignSystem.brightRed)✗ Failed to export history: \(error.localizedDescription)\(DesignSystem.reset)")
                }
                continue
            }
            if commandInput.hasPrefix("/load-history-json") {
                let parts = commandInput.split(separator: " ", maxSplits: 1)
                let inputPath = parts.count > 1 ? String(parts[1]) : "session-history.json"
                do {
                    _ = try await agentLoop.loadHistoryJSON(from: inputPath)
                    lastUserPrompt = await agentLoop.history.latestUserMessage
                } catch {
                    await renderer.printScrollLine("\(DesignSystem.brightRed)✗ Failed to load JSON history: \(error.localizedDescription)\(DesignSystem.reset)")
                }
                continue
            }
            if commandInput == "/help" || commandInput == "?" {
                for line in helpLines() {
                    await renderer.printScrollLine(line)
                }
                continue
            }
            if commandInput == "/retry" {
                if await renderer.getIsGenerating() {
                    await renderer.printScrollLine("\(DesignSystem.brightRed)✗ /retry unavailable while generation is active. Press Esc first.\(DesignSystem.reset)")
                    continue
                }
                guard let retryPrompt = lastUserPrompt else {
                    await renderer.printScrollLine("\(DesignSystem.brightRed)✗ nothing to retry\(DesignSystem.reset)")
                    continue
                }
                await renderer.printScrollLine("\(DesignSystem.dim)↻ retrying last prompt\(DesignSystem.reset)")
                let userEntry = SessionEntry(role: .user, content: retryPrompt)
                await renderer.printScrollLine(userEntry.render())
                activeStreamTask = Task { @MainActor in
                    defer { activeStreamTask = nil }
                    do {
                        try await agentLoop.processUserMessage(retryPrompt)
                    } catch is CancellationError {
                        // abortGeneration() already printed "· Aborted" and cleaned up the UI.
                    } catch {
                        await renderer.printScrollLine("\(DesignSystem.brightRed)✗ \(error.localizedDescription)\(DesignSystem.reset)")
                    }
                    await renderer.flushStreamLine()
                    await renderer.setPendingCount(0)
                    await renderer.renderFooter()
                }
                continue
            }
            if commandInput == "/undo" || commandInput == "/revert" {
                if await renderer.getIsGenerating() {
                    await renderer.printScrollLine("\(DesignSystem.brightRed)✗ /undo unavailable while generation is active. Press Esc first.\(DesignSystem.reset)")
                    continue
                }
                await agentLoop.undoLastTurn()
                lastUserPrompt = await agentLoop.history.latestUserMessage
                await renderer.setPendingCount(0)
                await renderer.renderFooter()
                continue
            }
            if commandInput == "/plan" {
                let isInPlan = await agentLoop.mode == .plan
                if isInPlan {
                    await agentLoop.setMode(.agent)
                    await agentLoop.setTaskType(.coding)
                } else {
                    await agentLoop.setMode(.plan)
                }
                await renderer.renderFooter()
                continue
            }
            if commandInput == "/autopilot" {
                let currentMode = await agentLoop.mode
                let currentTaskType = await agentLoop.taskType
                let isAutopilot = currentMode != .plan && currentTaskType == .general
                if isAutopilot {
                    await agentLoop.setMode(.agent)
                    await agentLoop.setTaskType(.coding)
                } else {
                    await agentLoop.setMode(.agent)
                    await agentLoop.setTaskType(.general)
                }
                await renderer.renderFooter()
                continue
            }
            if commandInput == "/agent" {
                await agentLoop.setMode(.agent)
                await renderer.renderFooter()
                continue
            }
            if commandInput == "/merge-approval" {
                await agentLoop.runMergeApprovalShortcutFlow()
                continue
            }
            if commandInput.hasPrefix("/gittree") {
                await handleGitTreeCommand(input: commandInput, agentLoop: agentLoop, renderer: renderer)
                continue
            }
            if commandInput.hasPrefix("/memory") {
                await handleMemoryCommand(trimmed: commandInput, workspaceRoot: workspaceRoot, frontend: frontend)
                await renderer.renderFooter()
                continue
            }
            if commandInput.hasPrefix("/steer") {
                let msg = String(commandInput.dropFirst("/steer".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !msg.isEmpty {
                    await agentLoop.steer(msg)
                    await renderer.printScrollLine("↩️  Steering message queued: \"\(msg)\"")
                } else {
                    let pending = await agentLoop.pendingSteeringMessages()
                    if pending.isEmpty {
                        await renderer.printScrollLine("No steering messages queued.")
                    } else {
                        await renderer.printScrollLine("Queued steering messages (\(pending.count)):")
                        for (index, item) in pending.enumerated() {
                            await renderer.printScrollLine("  \(index + 1). \(item)")
                        }
                    }
                }
                continue
            }
            if commandInput.hasPrefix("/followup") {
                let msg = String(commandInput.dropFirst("/followup".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !msg.isEmpty {
                    await agentLoop.queueFollowUp(msg)
                    await renderer.printScrollLine("🔄 Follow-up queued: \"\(msg)\"")
                } else {
                    let pending = await agentLoop.pendingFollowUps()
                    if pending.isEmpty {
                        await renderer.printScrollLine("No follow-ups queued.")
                    } else {
                        await renderer.printScrollLine("Queued follow-ups (\(pending.count)):")
                        for (index, item) in pending.enumerated() {
                            await renderer.printScrollLine("  \(index + 1). \(item)")
                        }
                    }
                }
                continue
            }
            if commandInput.hasPrefix("/model") {
                await handleModelCommand(input: commandInput, appConfig: frontend.appConfig, agentLoop: agentLoop, renderer: renderer)
                continue
            }

            // ! <cmd> — run a shell command; !! — repeat last shell command
            // Also support "!!<cmd>" as shorthand for running "<cmd>".
            let shellCmd = TUIShellCommandParser.parse(commandInput, lastShellCommand: lastShellCommand).command
            if let cmd = shellCmd {
                if cmd.isEmpty {
                    await renderer.printScrollLine("\(DesignSystem.brightRed)✗ no command to run\(DesignSystem.reset)")
                } else {
                    lastShellCommand = cmd
                    await runShellCommand(cmd, renderer: renderer)
                }
                continue
            }

            // Render user turn
            let userEntry = SessionEntry(role: .user, content: trimmed)
            await renderer.printScrollLine(userEntry.render())
            lastUserPrompt = trimmed

            // If a generation is already in flight, queue this prompt as a
            // steering message so AgentCore injects it before the next round.
            // The frontend's spinner-tick task continues uninterrupted.
            if await renderer.getIsGenerating() {
                await agentLoop.steer(trimmed)
                let pending = await agentLoop.pendingSteeringMessages().count
                await renderer.setPendingCount(pending)
                await renderer.renderFooter()
                continue
            }

            activeStreamTask = Task { @MainActor in
                defer { activeStreamTask = nil }
                do {
                    try await agentLoop.processUserMessage(trimmed)
                    while let followUp = await agentLoop.dequeueFollowUp() {
                        await renderer.printScrollLine("🔄 Auto follow-up: \"\(followUp)\"")
                        await hooks.emit(.followUpStarted(message: followUp))
                        do {
                            try await agentLoop.processUserMessage(followUp)
                        } catch is CancellationError {
                            await renderer.printScrollLine("\(DesignSystem.brightRed)✗ Follow-up cancelled.\(DesignSystem.reset)")
                            await agentLoop.clearFollowUpQueue()
                            break
                        } catch {
                            await renderer.printScrollLine("\(DesignSystem.brightRed)✗ Follow-up error: \(error.localizedDescription)\(DesignSystem.reset)")
                            await agentLoop.clearFollowUpQueue()
                            break
                        }
                    }
                } catch is CancellationError {
                    // abortGeneration() already printed "· Aborted" and cleaned up the UI.
                } catch {
                    await renderer.printScrollLine("\(DesignSystem.brightRed)✗ \(error.localizedDescription)\(DesignSystem.reset)")
                }
                await renderer.flushStreamLine()
                await renderer.setPendingCount(0)
                await renderer.renderFooter()
            }

        default:
            break
        }
    }

    if shouldQuit {
        let wasGenerating = await renderer.getIsGenerating()
        let runningTask = activeStreamTask
        runningTask?.cancel()
        if wasGenerating {
            await frontend.abortGeneration()
        }
        if let runningTask {
            await runningTask.value
        }
        // TokenIterator uses asyncEval pipelining. Ensure pending MLX work is
        // fully drained before process teardown to avoid shutdown races.
        MLX.Stream().synchronize()
    }
    pendingResizeTask?.cancel()
    sigwinchSource?.cancel()
    sigwinchSource = nil
    await renderer.flushStreamLine()
    await renderer.teardownScreen()
}

private func normalizedCommandInput(from input: String) -> String {
    var normalized = input.trimmingCharacters(in: .whitespacesAndNewlines)
    while normalized.first == ">" {
        normalized.removeFirst()
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return normalized
}

private func modeIndex(for thinkingLevel: AgentLoop.ThinkingLevel, appConfig: AppConfig) -> Int? {
    if let exact = appConfig.modes.firstIndex(where: { $0.id == thinkingLevel.rawValue || $0.label == thinkingLevel.rawValue }) {
        return exact
    }
    if thinkingLevel == .minimal {
        return appConfig.modes.firstIndex(where: { $0.id == "low" || $0.label == "low" })
    }
    return nil
}

private func statusModeLabel(workingMode: AgentLoop.WorkingMode, taskType: AgentLoop.TaskType) -> String {
    if workingMode == .plan { return "plan" }
    if taskType == .general { return "autopilot" }
    return ""
}

private func decisionForOption(_ index: Int?) -> ApprovalDecision {
    switch index {
    case 0: return .allowOnce
    case 1: return .allowAlwaysForCommand
    case 2: return .allowAllAutopilot
    case 3: return .deny(suggestion: nil)
    default: return .deny(suggestion: nil)
    }
}

@MainActor
private func runShellCommand(_ cmd: String, renderer: Renderer) async {
    // Render the shell invocation as a tool_call entry.
    let callEntry = SessionEntry(role: .toolCall, content: "bash \(cmd)")
    await renderer.printScrollLine(callEntry.render())

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", cmd]
    let pipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = pipe
    process.standardError = errPipe
    do {
        try process.run()
        let output = await Task.detached(priority: .userInitiated) {
            let outData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let out = String(data: outData, encoding: .utf8) ?? ""
            let err = String(data: errData, encoding: .utf8) ?? ""
            let status = process.terminationStatus
            return (out, err, status)
        }.value
        let (out, err, status) = output
        // Combine stdout and stderr; append exit-code hint on non-zero exit.
        var body = (out + err).trimmingCharacters(in: .newlines)
        if status != 0 { body += (body.isEmpty ? "" : "\n") + "exit \(status)" }
        if body.isEmpty { body = "(no output)" }
        let outputEntry = SessionEntry(role: .toolOutput, content: body)
        await renderer.printScrollLine(outputEntry.render())
    } catch {
        let errEntry = SessionEntry(role: .toolOutput, content: "✗ \(error.localizedDescription)")
        await renderer.printScrollLine(errEntry.render())
    }
}

private func helpLines() -> [String] {
    [
        "  /clear   clear the conversation",
        "  /help    this message",
        "  /memory  memory commands (save/log/search/list/undo/status/snippet)",
        "  /context show context usage",
        "  /skills  list discovered skills",
        "  /hooks   list active hooks",
        "  /model   open model chooser; /model <name|id|number> to switch",
        "  /transforms show context transforms; '/transforms clear' removes all",
        "  /save-history [path] save session transcript as markdown",
        "  /save-history-json [path] save session transcript as json",
        "  /load-history-json [path] load prior session transcript",
        "  /retry   re-run the last user prompt",
        "  /undo    undo the last conversation turn",
        "  /plan    toggle plan mode on/off",
        "  /autopilot toggle autopilot on/off",
        "  /agent   switch to agent mode",
        "  /steer [msg] queue/list steering messages",
        "  /followup [msg] queue/list follow-ups",
        "  /merge-approval run merge approval flow",
        "  /gittree run git tree flow",
        "  /quit    exit the TUI",
        "  ! <cmd>  run a shell command (e.g. ! ls -la)",
        "  !!       repeat the last shell command",
        "  Enter to submit · Ctrl+C to cancel · Ctrl+L to redraw",
    ]
}

@MainActor
private func handleModelCommand(
    input: String,
    appConfig: AppConfig,
    agentLoop: AgentLoop,
    renderer: Renderer
) async {
    guard let intent = TUIModelCommandParser.resolve(input: input, models: appConfig.models) else {
        return
    }

    switch intent {
    case .openMenu:
        let currentModel = await renderer.getCurrentModelLabel()
        let items = TUIModelCommandParser.menuItems(models: appConfig.models, currentModelLabel: currentModel)
        guard !items.isEmpty else {
            await renderer.printScrollLine("  No models configured.")
            return
        }
        await renderer.openCommandPalette(commands: items)
        await renderer.renderFooter()
    case .selectModel(let index):
        guard appConfig.models.indices.contains(index) else {
            await renderer.printScrollLine("  Invalid model index \(index + 1).")
            return
        }
        await switchToModel(model: appConfig.models[index], index: index, agentLoop: agentLoop, renderer: renderer)
    case .invalidModelName(let name):
        let labels = appConfig.models.map(\.label).joined(separator: ", ")
        await renderer.printScrollLine("  Unknown model '\(name)'. Available models: \(labels)")
    }
}

@MainActor
private func handleGitTreeCommand(
    input: String,
    agentLoop: AgentLoop,
    renderer: Renderer
) async {
    guard let intent = TUIGitTreeCommandParser.resolve(input: input) else {
        return
    }

    switch intent {
    case .openMenu:
        await renderer.openCommandPalette(commands: TUIGitTreeCommandParser.menuItems())
        await renderer.renderFooter()
    case .switchWorktree:
        await agentLoop.runGitTreeSwitchShortcutFlow()
    case .deleteBranch:
        await agentLoop.runGitTreeBranchDeleteShortcutFlow()
    case .invalidOption(let option):
        await renderer.printScrollLine(
            "  Unknown /gittree option '\(option)'. Try /gittree switch or /gittree delete-branch."
        )
    }
}

@MainActor
private func switchToModel(
    model: AppConfig.ModelConfig,
    index: Int,
    agentLoop: AgentLoop,
    renderer: Renderer
) async {
    let modelPath = localModelExists(model.id) ? model.id : "~/models/\(model.id)"
    await renderer.printScrollLine("  Switching to \(model.label)…")
    do {
        try await agentLoop.switchModel(to: modelPath)
        await renderer.setCurrentModelIndex(index)
        await renderer.printScrollLine("  Active model: \(model.label)")
        await renderer.renderFooter()
    } catch {
        await renderer.printScrollLine(
            "\(DesignSystem.brightRed)  Error: \(error.localizedDescription)\(DesignSystem.reset)"
        )
    }
}
