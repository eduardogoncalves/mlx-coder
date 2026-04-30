// Sources/CLI/LegacyTerminalFrontend.swift
// Adapter: AgentFrontend ↔ existing StreamRenderer + InteractiveInput.
//
// Behaviour-preserving: every AgentEvent is translated to the equivalent
// `renderer.printX` call so output is byte-for-byte identical to the
// pre-decoupling implementation. Requests delegate to InteractiveInput.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

public final class LegacyTerminalFrontend: AgentFrontend, @unchecked Sendable {

    public let renderer: StreamRenderer
    public let interactiveInput: InteractiveInput
    /// Optional approval handler. Injected by the chat session so we can
    /// reuse `AgentLoop.askForToolApproval`'s native raw-mode UI for now;
    /// when the new TUI lands, that flow is replaced wholesale.
    public var approvalHandler: ((ApprovalRequest) async -> ApprovalDecision)?

    /// The legacy terminal spinner — owned by this adapter so AgentCore stays
    /// frontend-agnostic.
    private var spinner: Spinner?

    public init(renderer: StreamRenderer, interactiveInput: InteractiveInput) {
        self.renderer = renderer
        self.interactiveInput = interactiveInput
    }

    // MARK: AgentFrontend

    public func emit(_ event: AgentEvent) {
        switch event {
        case .assistantTextChunk(let text):
            renderer.printChunk(text)

        case .thinkingActivity(let lifecycle):
            if lifecycle == .started {
                renderer.startThinking()
            } else {
                renderer.endThinking()
            }

        case .tokenProcessingActivity(let lifecycle):
            if lifecycle == .started {
                startOrUpdateSpinner(message: "Processing...")
            } else {
                startOrUpdateSpinner(message: "Generating...")
            }

        case .generationActivity(let lifecycle):
            if lifecycle == .started {
                startOrUpdateSpinner(message: "Generating...")
            } else {
                stopSpinner()
            }

        case .thinkingChunk(let text):
            renderer.printThinkingChunk(text)

        case .toolCallStarted(let snapshot):
            // Re-inflate string args into the [String: Any] shape StreamRenderer expects.
            let args: [String: Any] = snapshot.arguments.reduce(into: [:]) { $0[$1.key] = $1.value }
            renderer.printToolCall(name: snapshot.name, arguments: args)

        case .toolCallResult(let snapshot):
            let result = ToolResult(
                content: snapshot.content,
                truncationMarker: snapshot.truncationMarker,
                isError: snapshot.isError
            )
            renderer.printToolResult(result)

        case .status(let status):
            // Severity is informational only for the legacy renderer —
            // it has a single printStatus formatting style.
            renderer.printStatus(status.text)

        case .error(let text):
            stopSpinner()
            renderer.printError(text)

        case .stats(let stats):
            let msg = String(
                format: "Generated %d tokens (%.1f tok/s), prompt: %d tokens (%.1f tok/s)",
                stats.generationTokens, stats.tokensPerSecond,
                stats.promptTokens, stats.promptTokensPerSecond
            )
            print()
            renderer.printStatus(msg)
            print()

        case .modeChanged(let snap):
            renderer.printStatus("Mode: \(snap.workingMode) | Thinking: \(snap.thinkingLevel) | Task: \(snap.taskType)")

        case .modelLifecycle(let event):
            switch event {
            case .unloading(let m):    renderer.printStatus("Unloading model: \(m)")
            case .loading(let m):      renderer.printStatus("Loading model: \(m)")
            case .ready(let m):        renderer.printStatus("Model ready: \(m)")
            case .reloaded(let m):     renderer.printStatus("Model reloaded: \(m)")
            case .alreadyActive(let m): renderer.printStatus("Model is already active: \(m)")
            case .error(let msg):      renderer.printError(msg)
            }

        case .memoryEvent(let event):
            switch event {
            case .checkpointSaved:
                renderer.printStatus("Checkpoint saved to memory")
            case .checkpointFailed(let reason):
                renderer.printError("Failed to save checkpoint: \(reason)")
            case .factSaved(let subject, _):
                renderer.printStatus("Memory: saved fact for subject '\(subject)'")
            case .factsListed(_, let lines), .searchResults(_, let lines), .status(let lines):
                for line in lines { renderer.printStatus(line) }
            case .undone(let msg):
                renderer.printStatus(msg)
            case .error(let msg):
                renderer.printError(msg)
            }

        case .buildCheck(let event):
            switch event {
            case .skipped(let reason):    renderer.printStatus("⏭️  Build check skipped: \(reason)")
            case .started(let m):         renderer.printStatus(m)
            case .progress(let m):        renderer.printStatus(m)
            case .passed:                 renderer.printStatus("✅ Build check passed - ready for commit!")
            case .failed(let count, let firsts):
                renderer.printError("Build check failed with \(count) error(s)")
                for line in firsts { renderer.printStatus(line) }
            case .warning(let m):         renderer.printStatus("⚠️  \(m)")
            }

        case .gitOrchestration(let event):
            switch event {
            case .info(let m):                              renderer.printStatus(m)
            case .warning(let m):                           renderer.printStatus("⚠️  \(m)")
            case .worktreeCreated(let path, let branch):    renderer.printStatus("🌿 Worktree created at: \(path) (branch: \(branch))")
            case .worktreeSwitched(let path, let branch):   renderer.printStatus("📁 Switched workspace to: \(path)\n🌿 Active branch: \(branch)")
            case .branchDeleted(let name, let force):       renderer.printStatus("\(force ? "🗑️ Force deleted" : "🗑️ Deleted") branch: \(name)")
            case .merged(let msg, let warnings):
                renderer.printStatus("✅ \(msg)")
                for w in warnings { renderer.printStatus("⚠️  Cleanup warning: \(w)") }
            case .proposal(let title, let value):           renderer.printStatus("📝 Proposed \(title.lowercased()): \(value)")
            case .skipped(let reason):                      renderer.printStatus("⏭️  \(reason)")
            }

        case .contextCompaction(let before, let after, let target, let reason):
            renderer.printStatus("[Context] Turn-aware compaction triggered (\(reason)): before≈\(before), after≈\(after), target≈\(target)")

        case .steeringInjected(let msg):
            renderer.printStatus("↩️  Steering: \(msg)")

        }
    }

    public func request(_ request: AgentRequest) async -> AgentResponse {
        switch request {
        case .approval(let req):
            // Delegate to caller-supplied handler (which today is
            // AgentLoop.askForToolApproval running its own raw-mode UI).
            if let handler = approvalHandler {
                let decision = await handler(req)
                return .approval(decision)
            }
            return .approval(.deny(suggestion: nil))

        case .optionSelect(let req):
            if let idx = await interactiveInput.selectOption(prompt: req.prompt, options: req.options) {
                return .optionSelect(idx)
            }
            return .optionSelect(nil)

        case .textInput(let req):
            let text = await interactiveInput.promptForText(
                prompt: req.prompt,
                placeholder: req.placeholder
            )
            return .textInput(text)
        }
    }

    private func startOrUpdateSpinner(message: String) {
        if let s = spinner {
            Task {
                await s.updateMessage(message)
                await s.start()
            }
            return
        }
        let s = Spinner(message: message)
        spinner = s
        Task { await s.start() }
    }

    private func stopSpinner() {
        if let s = spinner {
            spinner = nil
            Task { await s.stop(clearLine: true) }
        }
    }
}
