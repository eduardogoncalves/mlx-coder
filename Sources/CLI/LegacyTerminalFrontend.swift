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
    private var thinkingActive = false
    private var generationActive = false
    private var didRenderAssistantChunkInGeneration = false
    private var pendingSpinnerStopTask: Task<Void, Never>?
    private let spinnerStopDebounceNanoseconds: UInt64 = 120_000_000
    // Set while a TaskTool-delegated sub-agent (internal agent) is generating,
    // so the spinner message can show which agent/model is currently active.
    // At most one is ever active at a time (sub-agents cannot nest further).
    private var activeSubAgent: (profile: String, modelPath: String)? = nil

    public init(renderer: StreamRenderer, interactiveInput: InteractiveInput) {
        self.renderer = renderer
        self.interactiveInput = interactiveInput
    }

    // MARK: AgentFrontend

    public func emit(_ event: AgentEvent) {
        switch event {
        case .assistantTextChunk(let text):
            // Once visible content arrives, stop spinner immediately to avoid
            // redraw races that can overwrite streamed assistant output.
            if !didRenderAssistantChunkInGeneration {
                didRenderAssistantChunkInGeneration = true
                // Clear spinner row synchronously before printing the first
                // assistant token so no stale "Thinking..." line remains.
                clearCurrentTerminalLine()
            }
            stopSpinnerImmediately()
            renderer.printChunk(text)

        case .thinkingActivity(let lifecycle):
            if lifecycle == .started {
                thinkingActive = true
                // In non-verbose mode, thinking chunks are hidden. Keep a spinner
                // visible so the user knows generation is still progressing.
                if !renderer.verbose {
                    showSpinner(message: "Thinking...")
                }
                renderer.startThinking()
            } else {
                thinkingActive = false
                if !renderer.verbose {
                    if generationActive {
                        showSpinner(message: "Generating...")
                    } else {
                        stopSpinnerDebounced()
                    }
                }
                renderer.endThinking()
            }

        case .tokenProcessingActivity(let lifecycle):
            if lifecycle == .started {
                showSpinner(message: "Processing...")
            } else {
                // Debounce stop so rapid Processing -> Thinking/Generating
                // transitions don't flicker in short responses.
                stopSpinnerDebounced()
            }

        case .generationActivity(let lifecycle):
            if lifecycle == .started {
                generationActive = true
                didRenderAssistantChunkInGeneration = false
                if !thinkingActive {
                    showSpinner(message: "Generating...")
                }
            } else {
                generationActive = false
                didRenderAssistantChunkInGeneration = false
                if !thinkingActive {
                    stopSpinnerDebounced()
                }
            }

        case .thinkingChunk(let text):
            renderer.printThinkingChunk(text)

        case .toolCallStarted(let snapshot):
            // The spinner (Spinner.swift) is an independently-ticking
            // background Task writing raw ANSI directly to stdout every
            // 80ms. A tool call with no preceding visible assistant text
            // (very common — the model often goes straight to a tool call,
            // especially back-to-back calls in a sub-agent's own loop) never
            // hits the .assistantTextChunk case above, so the spinner was
            // never told to stop here — it kept ticking concurrently with
            // `printToolCall`'s own direct prints below, racing for stdout
            // and leaving the tool-call box printed mid-line wherever the
            // spinner's last write happened to leave the cursor. Same fix as
            // .assistantTextChunk: clear + stop before printing.
            clearCurrentTerminalLine()
            stopSpinnerImmediately()

            // Re-inflate string args into the [String: Any] shape StreamRenderer
            // expects. `printToolCall` renders the whole args string with a
            // single "│ " box prefix, so a multi-line value (e.g. `task`'s
            // `description`, an unbounded multi-paragraph spec) would print
            // raw past the box border for every line after the first — flatten
            // first, same as SwiftCoderTUIFrontend.
            let args: [String: Any] = snapshot.arguments.reduce(into: [:]) {
                $0[$1.key] = Self.previewSafeArgumentValue($1.value)
            }
            renderer.printToolCall(name: snapshot.name, arguments: args)

        case .toolCallResult(let snapshot):
            // Same race as .toolCallStarted above — the tool's own execution
            // can re-show a spinner (e.g. web_search/web_fetch's per-tool
            // spinner in AgentLoop+ToolExecution.swift) that's still ticking
            // when the result comes back.
            clearCurrentTerminalLine()
            stopSpinnerImmediately()

            let result = ToolResult(
                content: snapshot.content,
                truncationMarker: snapshot.truncationMarker,
                isError: snapshot.isError
            )
            renderer.printToolResult(result)

        case .status(let status):
            // Internal status noise (e.g. tool-call writer debug progress,
            // most notably "Generating tool call..." fired once per detected
            // tool call while a local model streams several in one turn —
            // exactly what sub-agent profiles like codebase_research do) must
            // not be printed: it races the active spinner's own raw-terminal
            // redraw (no shared cursor coordination between them) and
            // corrupts the layout with cascading indentation. SwiftCoderTUIFrontend
            // already drops these; mirror that here.
            if status.severity == .debug { return }
            // Same spinner/direct-print race as .toolCallStarted — status
            // lines (including "Turn complete."/"Sub-task complete.", the
            // most common one) can arrive while the spinner is still ticking.
            clearCurrentTerminalLine()
            stopSpinnerImmediately()
            if status.text.hasPrefix("Generated ") {
                // Keep token stats visually separated from streamed assistant text.
                print()
            }
            renderer.printStatus(status.text)

        case .error(let text):
            stopSpinnerImmediately()
            renderer.printError(text)

        case .stats(let stats):
            // Per-message generation stats — same shape as the turn-total line.
            print()
            renderer.printStatus(stats.formatted)
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
            case .factsListed(_, _, let lines), .searchResults(_, _, let lines), .status(_, let lines):
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
                if let count {
                    renderer.printError("Build check failed with \(count) error(s)")
                } else {
                    renderer.printError("Build check failed (error count unavailable)")
                }
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

        case .promptTokensKnown:
            break

        case .subAgentActivity(let activity):
            switch activity {
            case .started(let profile, let modelPath):
                activeSubAgent = (profile, modelPath)
            case .ended:
                activeSubAgent = nil
            }
            // Refresh the currently-visible spinner (if any) so the label
            // suffix updates immediately rather than on the next transition.
            if let s = spinner {
                let base = thinkingActive ? "Thinking..." : "Generating..."
                let suffix = activeSubAgent.map { " [\($0.profile) · \($0.modelPath)]" } ?? ""
                s.updateMessage(base + suffix)
            }
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
            if let idx = await interactiveInput.selectOption(prompt: req.prompt, options: req.options, escSelectsLastOption: req.escSelectsLastOption) {
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
            s.updateMessage(message)
            s.start()
            return
        }
        let s = Spinner(message: message)
        spinner = s
        s.start()
    }

    private func showSpinner(message: String) {
        pendingSpinnerStopTask?.cancel()
        pendingSpinnerStopTask = nil
        let suffix = activeSubAgent.map { " [\($0.profile) · \($0.modelPath)]" } ?? ""
        startOrUpdateSpinner(message: message + suffix)
    }

    private func stopSpinnerDebounced() {
        pendingSpinnerStopTask?.cancel()
        guard let s = spinner else { return }
        let delay = spinnerStopDebounceNanoseconds
        pendingSpinnerStopTask = Task {
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            s.stop(clearLine: true)
        }
    }

    private func stopSpinnerImmediately() {
        pendingSpinnerStopTask?.cancel()
        pendingSpinnerStopTask = nil
        if let s = spinner {
            s.stop(clearLine: true)
        }
    }

    private func clearCurrentTerminalLine() {
        print("\r\u{001B}[2K\r", terminator: "")
        fflush(stdout)
    }

    /// Collapses a tool-call argument value to a single, bounded-length line
    /// for the `printToolCall` preview — see the call site for why embedded
    /// newlines there break the box border.
    private static func previewSafeArgumentValue(_ value: String, maxCharacters: Int = 160) -> String {
        let flattened = value
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard flattened.count > maxCharacters else { return flattened }
        return String(flattened.prefix(maxCharacters)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
