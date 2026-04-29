// Sources/CLI/SwiftCoderTUIFrontend.swift
// Adapter: AgentFrontend → SwiftCoderTUI Renderer.
//
// Translates AgentEvent values into Renderer / SessionEntry calls. Because
// AgentFrontend.emit is synchronous and Renderer is an actor, events are
// queued onto an AsyncStream which a long-lived consumer Task drains.

import Foundation
import SwiftCoderTUI

public final class SwiftCoderTUIFrontend: AgentFrontend, @unchecked Sendable {

    public let renderer: Renderer
    public let appConfig: AppConfig

    // Event pipeline
    private let continuation: AsyncStream<AgentEvent>.Continuation
    private let stream: AsyncStream<AgentEvent>
    private var consumerTask: Task<Void, Never>?

    // Approval bridging — only one outstanding approval at a time.
    private var pendingApproval: CheckedContinuation<ApprovalDecision, Never>?
    private let lock = NSLock()

    // Spinner ticker — one task at a time, rendering 100ms ticks while a
    // generation is in flight.
    private var spinnerTickTask: Task<Void, Never>?

    // Accumulated thinking text for the footer spinner label tail.
    // Reset at thinkingStarted, cleared at thinkingEnded.
    private var thinkingBuffer: String = ""

    // State machine: tracks whether the next assistantTextChunk is the very
    // first visible token (so we can transition label Processing→Generating).
    private var isFirstContentToken: Bool = true

    // Set when ESC is pressed; gates out late-arriving stream events from a
    // cancelled Task so they cannot corrupt the footer after abort.
    private var isAborted: Bool = false

    public init(renderer: Renderer, appConfig: AppConfig) {
        self.renderer = renderer
        self.appConfig = appConfig
        var cont: AsyncStream<AgentEvent>.Continuation!
        self.stream = AsyncStream<AgentEvent>(bufferingPolicy: .unbounded) { c in
            cont = c
        }
        self.continuation = cont
        self.consumerTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.stream {
                await self.render(event)
            }
        }
    }

    deinit {
        continuation.finish()
        consumerTask?.cancel()
    }

    // MARK: AgentFrontend

    public func emit(_ event: AgentEvent) {
        continuation.yield(event)
    }

    public func request(_ request: AgentRequest) async -> AgentResponse {
        switch request {
        case .approval(let req):
            let decision: ApprovalDecision = await withCheckedContinuation { cont in
                lock.lock()
                pendingApproval = cont
                lock.unlock()
                Task {
                    await renderer.requestApproval(
                        tool: req.toolName,
                        args: req.display
                    )
                }
            }
            await renderer.clearApproval()
            return .approval(decision)

        case .optionSelect(let req):
            await renderer.printScrollLine("? \(req.prompt)")
            for (i, opt) in req.options.enumerated() {
                await renderer.printScrollLine("  \(i + 1)) \(opt)")
            }
            return .optionSelect(nil)

        case .textInput(let req):
            await renderer.printScrollLine("? \(req.prompt)")
            return .textInput(nil)
        }
    }

    /// Called by the session loop when the user picks an approval option via
    /// keyboard. Resolves any outstanding approval continuation.
    public func resolveApproval(_ decision: ApprovalDecision) {
        lock.lock()
        let cont = pendingApproval
        pendingApproval = nil
        lock.unlock()
        cont?.resume(returning: decision)
    }

    public var hasPendingApproval: Bool {
        lock.lock(); defer { lock.unlock() }
        return pendingApproval != nil
    }

    // MARK: Event rendering

    private func render(_ event: AgentEvent) async {
        // Drop all events from a cancelled generation so late-arriving chunks,
        // stats, and .ended cleanup cannot corrupt the footer after ESC.
        // Only .generationActivity(.started) passes through to clear isAborted
        // and set up the UI for the next generation.
        if isAborted {
            switch event {
            case .generationActivity(let activity):
                switch activity {
                case .started: break          // let through — clears isAborted
                default:       return         // drop .ended, .phase
                }
            case .error, .modelLifecycle, .modeChanged:
                break                         // user-visible, let through
            default:
                return                        // drop everything else (stats, status, chunks…)
            }
        }

        switch event {
        case .assistantTextChunk(let text):
            // First visible assistant token: transition spinner label from
            // "Processing…" to "Generating…" so the user sees the model is
            // actively producing output (not just loading context).
            if isFirstContentToken {
                isFirstContentToken = false
                await renderer.setThinking("Generating…")
            }
            // Use appendStreamChunk (raw concat, no auto-space) because
            // LLM tokens already carry their own whitespace (e.g. " How").
            // appendStreamWord would add an extra space before each token.
            await renderer.appendStreamChunk(text)

        case .thinkingStarted:
            thinkingBuffer = ""
            isFirstContentToken = false  // thinking IS first content
            // Flush any partial assistant stream line before the think block.
            await renderer.flushStreamLine()
            await renderer.setThinking("Thinking…")

        case .thinkingChunk(let text):
            thinkingBuffer += text
            // Route through appendThinkChunk: complete lines go directly to
            // the scroll area; partial line shown in spinner label tail.
            await renderer.appendThinkChunk(text)
            let tail = thinkingBuffer
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            await renderer.setThinking(String(tail.suffix(50)))

        case .thinkingEnded:
            // Flush any remaining partial think line to scroll, reset state,
            // commit the · thinking… marker, restore "Generating…" label.
            await renderer.flushThinkLine()
            thinkingBuffer = ""
            let badge = await renderer.getCurrentModeBadgeColor()
            let marker = SessionEntry(role: .thinking(badgeColor: badge), content: "thinking…")
            await renderer.printScrollLine(marker.render())
            await renderer.setThinking("Generating…")

        case .toolCallStarted(let snap):
            // SessionEntry(.toolCall) splits content on the FIRST SPACE to get
            // (toolName, argsLine). Use a single-space separator with args
            // formatted inline so the split produces the correct pair.
            let args = snap.arguments
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key): \($0.value)" }
                .joined(separator: ", ")
            let content = args.isEmpty ? snap.name : "\(snap.name) \(args)"
            let entry = SessionEntry(role: .toolCall, content: content)
            await renderer.printScrollLine(entry.render())

        case .toolCallResult(let snap):
            let body = snap.content.isEmpty ? "(no output)" : snap.content
            let entry = SessionEntry(role: .toolOutput, content: body)
            await renderer.printScrollLine(entry.render())
            if snap.isError {
                await renderer.printScrollLine("\(DesignSystem.brightRed)tool error\(DesignSystem.reset)")
            }

        case .status(let s):
            // Flush any partial streaming line to scroll BEFORE the status
            // message so the response text always precedes its own stats line.
            await renderer.flushStreamLine()
            let prefix: String
            switch s.severity {
            case .warning: prefix = "\u{001B}[93m⚠ "
            case .success: prefix = "\u{001B}[92m✓ "
            case .info, .debug: prefix = "\(DesignSystem.dim)· "
            }
            await renderer.printScrollLine("\(prefix)\(s.text)\(DesignSystem.reset)")

        case .error(let msg):
            await renderer.printScrollLine("\(DesignSystem.brightRed)✗ \(msg)\(DesignSystem.reset)")

        case .stats(let stats):
            await renderer.flushStreamLine()
            let entry = SessionEntry(
                role: .stats,
                content: "",
                tokenCount: stats.generationTokens,
                tokensPerSecond: stats.tokensPerSecond,
                elapsed: 0
            )
            await renderer.printScrollLine(entry.render())

        case .modeChanged(let mode):
            await renderer.printScrollLine("\(DesignSystem.dim)mode: \(mode.workingMode)/\(mode.thinkingLevel)/\(mode.taskType)\(DesignSystem.reset)")

        case .modelLifecycle(let m):
            await renderer.printScrollLine("\(DesignSystem.dim)model: \(describe(m))\(DesignSystem.reset)")

        case .memoryEvent(let mem):
            await renderer.printScrollLine("\(DesignSystem.dim)memory: \(describe(mem))\(DesignSystem.reset)")

        case .buildCheck(let bc):
            await renderer.printScrollLine("\(DesignSystem.dim)build: \(describe(bc))\(DesignSystem.reset)")

        case .gitOrchestration(let g):
            await renderer.printScrollLine("\(DesignSystem.dim)git: \(describe(g))\(DesignSystem.reset)")

        case .contextCompaction(let before, let after, let target, let reason):
            await renderer.printScrollLine("\(DesignSystem.dim)context: \(before)→\(after) (target \(target), \(reason))\(DesignSystem.reset)")

        case .steeringInjected(let s):
            await renderer.printScrollLine("\(DesignSystem.dim)steering: \(s)\(DesignSystem.reset)")

        case .generationActivity(let activity):
            switch activity {
            case .started(let message):
                isAborted = false
                isFirstContentToken = true
                await renderer.setThinking(message)
                await renderer.setGenerating(true)
                await renderer.renderFooter()
                startSpinnerTicker()
            case .phase(let message):
                await renderer.setThinking(message)
            case .ended:
                stopSpinnerTicker()
                // Commit any partial response line from the footer stream zone
                // to the scroll area before hiding the spinner / input box.
                await renderer.flushStreamLine()
                await renderer.setGenerating(false)
                await renderer.setThinking("")
                await renderer.renderFooter()
            }
        }
    }

    private func startSpinnerTicker() {
        spinnerTickTask?.cancel()
        let r = renderer
        spinnerTickTask = Task {
            while !Task.isCancelled {
                await r.advanceSpinner()
                await r.renderSpinnerTick()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    /// Immediately tears down any in-flight generation UI (spinner, stream line)
    /// without going through the async event queue. Use this when the generation
    /// Task is cancelled externally (e.g. ESC) so the UI stays consistent.
    public func abortGeneration() async {
        isAborted = true
        stopSpinnerTicker()
        thinkingBuffer = ""
        isFirstContentToken = true
        // Single atomic renderer call: sets isStreamingAborted inside the actor
        // so any queued appendStreamChunk/appendThinkChunk calls become no-ops,
        // then clears all state, prints "· Aborted", and redraws.
        await renderer.abortGeneration()
    }

    private func stopSpinnerTicker() {
        spinnerTickTask?.cancel()
        spinnerTickTask = nil
    }

    private func describe(_ m: ModelLifecycleEvent) -> String {
        switch m {
        case .unloading(let s): return "unloading \(s)"
        case .loading(let s): return "loading \(s)"
        case .ready(let s): return "ready \(s)"
        case .reloaded(let s): return "reloaded \(s)"
        case .alreadyActive(let s): return "active \(s)"
        case .error(let s): return "error \(s)"
        }
    }

    private func describe(_ m: MemoryEvent) -> String {
        switch m {
        case .checkpointSaved(let s): return "checkpoint saved (\(s))"
        case .checkpointFailed(let s): return "checkpoint failed: \(s)"
        case .factSaved(let subj, let fact): return "fact [\(subj)]: \(fact)"
        case .factsListed(let n, _): return "\(n) fact(s)"
        case .searchResults(let q, _): return "search: \(q)"
        case .undone(let s): return s
        case .status(_): return "status"
        case .error(let s): return "error: \(s)"
        }
    }

    private func describe(_ b: BuildCheckEvent) -> String {
        switch b {
        case .skipped(let r): return "skipped (\(r))"
        case .started(let m): return m
        case .progress(let m): return m
        case .passed: return "passed"
        case .failed(let n, _): return "failed (\(n) error(s))"
        case .warning(let m): return m
        }
    }

    private func describe(_ g: GitOrchestrationEvent) -> String {
        switch g {
        case .info(let s), .warning(let s): return s
        case .worktreeCreated(let p, let b): return "worktree \(p) on \(b)"
        case .worktreeSwitched(let p, let b): return "switched to \(p) (\(b))"
        case .branchDeleted(let n, _): return "branch deleted \(n)"
        case .merged(let m, _): return "merged: \(m)"
        case .proposal(let t, let v): return "\(t): \(v)"
        case .skipped(let r): return "skipped (\(r))"
        }
    }
}
