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

@MainActor
public func runSwiftCoderTUISession(
    agentLoop: AgentLoop,
    frontend: SwiftCoderTUIFrontend
) async {
    let processTerminal = ProcessTerminal()
    processTerminal.setupRawMode(title: frontend.appConfig.appName)
    defer { processTerminal.restoreMode() }

    let renderer = frontend.renderer

    let staticItems = frontend.appConfig.commands.map {
        AutocompleteItem(value: String($0.name.dropFirst()), label: $0.name, description: $0.description)
    }
    let provider = CombinedAutocompleteProvider(staticCommands: staticItems)
    await renderer.setAutocompleteProvider(provider)

    await renderer.setupScreen()
    await renderer.showWelcome()
    await renderer.renderFooter()

    let inputHistory = InputHistory()
    var activeStreamTask: Task<Void, Never>? = nil
    var lastShellCommand: String = ""
    var shouldQuit = false

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
            if let prev = inputHistory.previous() {
                await renderer.setInputBuffer(prev)
                await renderer.renderFooter()
            }

        case .arrowDown:
            if let next = inputHistory.next() {
                await renderer.setInputBuffer(next)
            } else {
                await renderer.setInputBuffer("")
            }
            await renderer.renderFooter()

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
            await renderer.setupScreen()
            await renderer.renderFooter()

        case .tab:
            if await renderer.isAutocompleteActive() {
                await renderer.acceptAutocomplete()
            } else {
                await renderer.openCommandPalette()
            }
            await renderer.renderFooter()

        case .enter:
            // Accept any pending ghost/autocomplete suggestion before submitting,
            // so "/q" + Enter expands to "/quit" and executes it.
            if await renderer.isAutocompleteActive() {
                await renderer.acceptAutocomplete()
            }
            let prompt = (await renderer.submitInput()) ?? ""
            let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                await renderer.renderFooter()
                continue
            }
            inputHistory.add(trimmed)
            inputHistory.resetCursor()

            if trimmed == "/quit" || trimmed == "exit" || trimmed == "quit" {
                shouldQuit = true
                break mainLoop
            }
            if trimmed == "/clear" {
                await renderer.clearConversation()
                await agentLoop.clearHistoryWithCheckpoint()
                continue
            }
            if trimmed == "/help" || trimmed == "?" {
                for line in helpLines() {
                    await renderer.printScrollLine(line)
                }
                continue
            }
            if trimmed.hasPrefix("/model") {
                let arg = String(trimmed.dropFirst("/model".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                await handleModelCommand(arg: arg, agentLoop: agentLoop, renderer: renderer)
                continue
            }

            // ! <cmd> — run a shell command; !! — repeat last shell command
            // Use hasPrefix("!!") so "!! " and "!! <extra>" also hit the repeat path.
            let shellCmd: String?
            if trimmed.hasPrefix("!!") {
                shellCmd = lastShellCommand.isEmpty ? nil : lastShellCommand
            } else if trimmed.hasPrefix("!") && trimmed.count > 1 {
                shellCmd = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            } else {
                shellCmd = nil
            }
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
    await renderer.flushStreamLine()
    await renderer.teardownScreen()
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
        "  /model   list local models; /model <n> or /model user/name to switch",
        "  /quit    exit the TUI",
        "  ! <cmd>  run a shell command (e.g. ! ls -la)",
        "  !!       repeat the last shell command",
        "  Enter to submit · Ctrl+C to cancel · Ctrl+L to redraw",
    ]
}

@MainActor
private func handleModelCommand(arg: String, agentLoop: AgentLoop, renderer: Renderer) async {
    let localModels = listHomeModelsAsRepoIDs()

    if arg.isEmpty {
        let currentPath = await agentLoop.modelPath
        if localModels.isEmpty {
            await renderer.printScrollLine("  No local models found under ~/models.")
            await renderer.printScrollLine("  Download a model via HuggingFace Hub or mlx_lm.convert.")
        } else {
            await renderer.printScrollLine("  Local models (~/models):")
            for (i, model) in localModels.enumerated() {
                let fullPath = "~/models/\(model)"
                let marker = fullPath == currentPath ? "  ← active" : ""
                await renderer.printScrollLine("  \(i + 1). \(model)\(marker)")
            }
            await renderer.printScrollLine("  Use /model <number> or /model user/name to switch.")
        }
        return
    }

    // Try numeric index into the local list.
    if let index = Int(arg), (1...localModels.count).contains(index) {
        let modelID = localModels[index - 1]
        let modelPath = "~/models/\(modelID)"
        await renderer.printScrollLine("  Switching to \(modelID)…")
        do {
            try await agentLoop.switchModel(to: modelPath)
            await renderer.printScrollLine("  Active model: \(modelID)")
        } catch {
            await renderer.printScrollLine(
                "\(DesignSystem.brightRed)  Error: \(error.localizedDescription)\(DesignSystem.reset)"
            )
        }
        return
    }

    // Try user/model identifier.
    guard let modelID = parseUserModelIdentifier(arg) else {
        await renderer.printScrollLine(
            "  Invalid model identifier '\(arg)'. Use a number or 'user/model' format."
        )
        return
    }

    let modelPath = "~/models/\(modelID)"
    guard localModelExists(modelPath) else {
        await renderer.printScrollLine(
            "  Model not found at \(modelPath). Use /model to list installed models."
        )
        return
    }

    await renderer.printScrollLine("  Switching to \(modelID)…")
    do {
        try await agentLoop.switchModel(to: modelPath)
        await renderer.printScrollLine("  Active model: \(modelID)")
    } catch {
        await renderer.printScrollLine(
            "\(DesignSystem.brightRed)  Error: \(error.localizedDescription)\(DesignSystem.reset)"
        )
    }
}
