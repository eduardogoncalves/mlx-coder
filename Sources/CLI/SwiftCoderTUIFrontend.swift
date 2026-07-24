// Sources/CLI/SwiftCoderTUIFrontend.swift
// Adapter: AgentFrontend → SwiftCoderTUI Renderer.
//
// Translates AgentEvent values into Renderer / SessionEntry calls. Because
// AgentFrontend.emit is synchronous and Renderer is an actor, events are
// queued onto an AsyncStream which a long-lived consumer Task drains.

import Foundation
import SwiftCoderTUI

public final class SwiftCoderTUIFrontend: AgentFrontend, @unchecked Sendable {
    // Keep memory bounded if rendering lags behind generation bursts.
    // 4096 provides a generous burst window for event-heavy responses while
    // still preventing unbounded growth from long-running sessions.
    private static let renderQueueCapacity = 4096

    private enum RenderCommand: Sendable {
        case event(AgentEvent)
        case spinnerTick
    }

    public let renderer: Renderer
    public let appConfig: AppConfig

    // Event pipeline
    private let continuation: AsyncStream<RenderCommand>.Continuation
    private let stream: AsyncStream<RenderCommand>
    private var consumerTask: Task<Void, Never>?

    // Approval bridging — only one outstanding approval at a time.
    private var pendingApproval: CheckedContinuation<ApprovalDecision, Never>?
    // Option-select bridging — only one outstanding picker at a time.
    private var pendingOptionSelect: CheckedContinuation<Int?, Never>?
    private let lock = NSLock()

    // Spinner ticker — one task at a time, rendering 100ms ticks while a
    // generation is in flight.
    private var spinnerTickTask: Task<Void, Never>?

    // Accumulated rendered thinking text for overlap/duplication filtering.
    // Reset at thinkingActivity(.started), cleared at thinkingActivity(.ended).
    private var thinkingBuffer: String = ""

    // State machine: tracks whether the next assistantTextChunk is the very
    // first visible token (so we can transition label Processing→Generating).
    private var isFirstContentToken: Bool = true

    // Set when ESC is pressed; gates out late-arriving stream events from a
    // cancelled Task so they cannot corrupt the footer after abort.
    private var isAborted: Bool = false
    private var tokenProcessingActive: Bool = false
    private var generationActive: Bool = false
    private var thinkingActive: Bool = false
    private var pendingGenerationEnd: Bool = false
    // True from `.toolCallStarted` to `.toolCallResult`. By the time a tool
    // actually runs, the model has already finished emitting text for this
    // round — tokenProcessingActive/generationActive/thinkingActive are all
    // false — so without this flag a slow tool call (e.g. a `bash` command
    // with a long timeout) left the spinner dead with no indication anything
    // was happening, indistinguishable from a hang.
    private var toolExecuting: Bool = false
    private var markdownTableNormalizer = StreamingMarkdownTableNormalizer()

    // Live token counters for the spinner label.
    private var liveTokens: Int = 0          // ↓ chunks streamed this turn
    private var promptTokenCount: Int = 0    // ↑ prompt tokens (from promptTokensKnown)
    private var spinnerBaseLabel: String = "Processing…"
    // Stats text captured from the backend; appended to the Turn complete line.
    private var pendingTurnStats: String? = nil
    // Set while a TaskTool-delegated sub-agent (internal agent) is generating,
    // so the spinner label can show which agent/model is currently active.
    // At most one is ever active at a time (sub-agents cannot nest further).
    private var activeSubAgent: (profile: String, modelPath: String)? = nil

    public init(renderer: Renderer, appConfig: AppConfig) {
        self.renderer = renderer
        self.appConfig = appConfig
        var cont: AsyncStream<RenderCommand>.Continuation!
        self.stream = AsyncStream<RenderCommand>(bufferingPolicy: .bufferingOldest(Self.renderQueueCapacity)) { c in
            cont = c
        }
        self.continuation = cont
        self.consumerTask = Task { [weak self] in
            guard let self else { return }
            for await command in self.stream {
                await self.render(command)
            }
        }
    }

    deinit {
        continuation.finish()
        consumerTask?.cancel()
    }

    // MARK: AgentFrontend

    public func emit(_ event: AgentEvent) {
        continuation.yield(.event(event))
    }

    public func request(_ request: AgentRequest) async -> AgentResponse {
        switch request {
        case .approval(let req):
            let decision: ApprovalDecision = await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { cont in
                    guard registerPendingApproval(cont) else {
                        cont.resume(returning: .deny(suggestion: nil))
                        return
                    }
                    Task {
                        await renderer.requestApproval(
                            tool: req.toolName,
                            args: req.display,
                            isPlanMode: req.isPlanModeBlock
                        )
                    }
                }
            }, onCancel: { [weak self] in
                self?.cancelPendingApproval()
            })
            await renderer.clearApproval()
            return .approval(decision)

        case .optionSelect(let req):
            let index: Int? = await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { cont in
                    guard registerPendingOptionSelect(cont) else {
                        cont.resume(returning: nil)
                        return
                    }
                    Task {
                        await renderer.requestOptionSelect(
                            prompt: req.prompt,
                            options: req.options,
                            escSelectsLastOption: req.escSelectsLastOption
                        )
                    }
                }
            }, onCancel: { [weak self] in
                self?.cancelPendingOptionSelect()
            })
            await renderer.clearOptionSelect()
            return .optionSelect(index)

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

    /// Called by the session loop when the user picks an option.
    public func resolveOptionSelect(_ index: Int?) {
        lock.lock()
        let cont = pendingOptionSelect
        pendingOptionSelect = nil
        lock.unlock()
        cont?.resume(returning: index)
    }

    public var hasPendingOptionSelect: Bool {
        lock.lock(); defer { lock.unlock() }
        return pendingOptionSelect != nil
    }

    private func registerPendingApproval(_ cont: CheckedContinuation<ApprovalDecision, Never>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard pendingApproval == nil, !Task.isCancelled else { return false }
        pendingApproval = cont
        return true
    }

    private func registerPendingOptionSelect(_ cont: CheckedContinuation<Int?, Never>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard pendingOptionSelect == nil, !Task.isCancelled else { return false }
        pendingOptionSelect = cont
        return true
    }

    private func cancelPendingApproval() {
        lock.lock()
        let cont = pendingApproval
        pendingApproval = nil
        lock.unlock()
        cont?.resume(returning: .deny(suggestion: nil))
        Task { await renderer.clearApproval() }
    }

    private func cancelPendingOptionSelect() {
        lock.lock()
        let cont = pendingOptionSelect
        pendingOptionSelect = nil
        lock.unlock()
        cont?.resume(returning: nil)
        Task { await renderer.clearOptionSelect() }
    }

    // MARK: Event rendering

    private func render(_ command: RenderCommand) async {
        switch command {
        case .spinnerTick:
            await renderSpinnerTick()
        case .event(let event):
            await render(event)
        }
    }

    private static func kilo(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }

    /// Collapses a tool-call argument value to a single, bounded-length line
    /// for the `toolCallStarted` preview — see the call site for why embedded
    /// newlines there corrupt the whole layout below it.
    private static func previewSafeArgumentValue(_ value: String, maxCharacters: Int = 160) -> String {
        let flattened = value
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard flattened.count > maxCharacters else { return flattened }
        return String(flattened.prefix(maxCharacters)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private func spinnerLabel() -> String {
        let up   = promptTokenCount > 0 ? " ↑ \(Self.kilo(promptTokenCount))" : ""
        let down = liveTokens > 0      ? " ↓ \(liveTokens)" : ""
        let sep  = !up.isEmpty && !down.isEmpty ? " ·" : ""
        let agent = activeSubAgent.map { " [\($0.profile) · \($0.modelPath)]" } ?? ""
        return "\(spinnerBaseLabel)\(up)\(sep)\(down)\(agent)"
    }

    private func render(_ event: AgentEvent) async {
        // Drop all events from a cancelled generation so late-arriving chunks,
        // stats, and lifecycle events cannot corrupt the footer after ESC.
        // Only a new token-processing start opens the next stream lifecycle.
        if isAborted {
            switch event {
            case .tokenProcessingActivity(let lifecycle) where lifecycle == .started:
                break
            case .error, .modelLifecycle, .modeChanged:
                break
            default:
                return
            }
        }

        switch event {
        case .assistantTextChunk(let text):
            guard generationActive else { return }
            isFirstContentToken = false
            liveTokens += 1
            await renderer.setThinking(spinnerLabel())
            // Keep backend output UI-agnostic: this is raw markdown. The TUI
            // renderer applies incremental ANSI formatting as chunks arrive.
            // Use appendStreamChunk (raw concat, no auto-space) because
            // LLM tokens already carry their own whitespace (e.g. " How").
            // appendStreamWord would add an extra space before each token.
            let normalized = markdownTableNormalizer.consume(text)
            if !normalized.isEmpty {
                await renderer.appendStreamChunk(normalized)
            }

        case .thinkingActivity(let lifecycle):
            switch lifecycle {
            case .started:
                thinkingActive = true
                thinkingBuffer = ""
                spinnerBaseLabel = "Thinking…"
                // Flush any partial assistant stream line before the think block.
                await renderer.flushStreamLine()
                await renderer.setThinking(spinnerLabel())
            case .ended:
                guard thinkingActive else { break }
                thinkingActive = false
                spinnerBaseLabel = "Generating…"
                await renderer.flushThinkLine()
                thinkingBuffer = ""
                await renderer.setThinking(spinnerLabel())
                if pendingGenerationEnd {
                    pendingGenerationEnd = false
                    await finalizeGenerationUI()
                }
            }

        case .thinkingChunk(let text):
            guard thinkingActive else { return }
            let normalized = normalizedThinkingDelta(incoming: text, alreadyRendered: thinkingBuffer)
            guard !normalized.isEmpty else { return }
            thinkingBuffer += normalized
            liveTokens += 1
            await renderer.setThinking(spinnerLabel())
            // Route through appendThinkChunk: complete lines go directly to
            // the scroll area; partial line is managed by the renderer.
            await renderer.appendThinkChunk(normalized)

        case .toolCallStarted(let snap):
            // SessionEntry(.toolCall) splits content on the FIRST SPACE to get
            // (toolName, argsLine), then renders that single argsLine with one
            // "│ " box-continuation prefix — it does NOT re-prefix embedded
            // newlines. A multi-line argument value (e.g. `task`'s
            // `description`, which can be an unbounded, multi-paragraph spec)
            // would otherwise print raw past the box's left border for every
            // line after the first, breaking the box visually and throwing
            // off the renderer's line/cursor accounting for everything drawn
            // afterward. Flatten and cap each value before building the preview.
            let args = snap.arguments
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key): \(Self.previewSafeArgumentValue($0.value))" }
                .joined(separator: ", ")
            let content = args.isEmpty ? snap.name : "\(snap.name) \(args)"
            let entry = SessionEntry(role: .toolCall, content: content)
            await renderer.printScrollLine(entry.render())

            toolExecuting = true
            spinnerBaseLabel = "Running \(snap.name)…"
            await renderer.setThinking(spinnerLabel())
            await renderer.renderFooter()
            startSpinnerTicker()

        case .toolCallResult(let snap):
            let body = snap.content.isEmpty ? "(no output)" : snap.content
            let entry = SessionEntry(role: .toolOutput, content: body)
            await renderer.printScrollLine(entry.render())
            if snap.isError {
                await renderer.printScrollLine("\(DesignSystem.brightRed)tool error\(DesignSystem.reset)")
            }

            toolExecuting = false
            stopSpinnerTicker()
            await renderer.setThinking("")
            await renderer.renderFooter()

        case .status(let s):
            // Internal status noise (e.g. tool-call writer debug progress)
            // should not be printed into the user-visible chat transcript.
            if s.severity == .debug { return }
            // During streamed tool-call writes, surface the tmp-file path in the
            // animated footer label (REPL parity) instead of only printing it.
            if s.severity == .info,
               s.text.hasPrefix(StreamingToolCallWriter.tmpFileStatusPrefix),
               (tokenProcessingActive || generationActive || thinkingActive || pendingGenerationEnd) {
                await renderer.setThinking(s.text)
                await renderer.renderFooter()
                return
            }
            // Intercept per-turn generation stats (starts with "↑"). Store for
            // the Turn complete line and suppress the separate dim stats line.
            // For remote providers, stats arrive before generationActivity.ended,
            // so we also need to trigger finalizeGenerationUI here.
            if s.severity == .info && s.text.hasPrefix("↑") {
                pendingTurnStats = s.text
                if tokenProcessingActive || generationActive || thinkingActive || pendingGenerationEnd {
                    await finalizeGenerationUI()
                }
                return
            }
            // Append pending stats to the Turn complete / Sub-task complete
            // success line. Sub-agents emit their own "↑ ..." stats line
            // (line 332 above) followed by "Sub-task complete." instead of
            // "Turn complete." — both must be matched here, or a sub-agent's
            // pendingTurnStats would never get consumed and could leak onto
            // the orchestrator's next actual "Turn complete." line.
            if s.severity == .success && (s.text.hasPrefix("Turn complete.") || s.text.hasPrefix("Sub-task complete.")) {
                if tokenProcessingActive || generationActive || thinkingActive || pendingGenerationEnd {
                    await finalizeGenerationUI()
                }
                await renderer.flushStreamLine()
                let statsStr = pendingTurnStats.map { " \(DesignSystem.dim)· \($0)" } ?? ""
                pendingTurnStats = nil
                await renderer.printScrollLine("\u{001B}[92m✓ \(s.text)\(DesignSystem.reset)\(statsStr)\(DesignSystem.reset)")
                return
            }
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
            if tokenProcessingActive || generationActive {
                await finalizeGenerationUI()
            }

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
            if let modeIndex = modeIndex(for: mode) {
                await renderer.setCurrentModeIndex(modeIndex)
            }
            let statusModeLabel = statusModeLabel(for: mode)
            await renderer.setAutopilot(statusModeLabel == "autopilot")
            await renderer.setStatusModeLabel(statusModeLabel)
            await renderer.renderFooter()

        case .modelLifecycle(let m):
            await renderer.printScrollLine("\(DesignSystem.dim)model: \(describe(m))\(DesignSystem.reset)")

        case .memoryEvent(let mem):
            switch mem {
            case .checkpointSaved(let summary):
                await renderer.printScrollLine("\(DesignSystem.dim)memory: checkpoint saved (\(summary))\(DesignSystem.reset)")
            case .checkpointFailed(let reason):
                await renderer.printScrollLine("\(DesignSystem.brightRed)memory: checkpoint failed: \(reason)\(DesignSystem.reset)")
            case .factSaved(let subject, let fact):
                await renderer.printScrollLine("\(DesignSystem.dim)memory: fact [\(subject)]: \(fact)\(DesignSystem.reset)")
            case .factsListed(let action, _, let lines):
                let actionEntry = SessionEntry(role: .toolCall, content: "memory \(action)")
                await renderer.printScrollLine(actionEntry.render())
                let resultBody = lines.joined(separator: "\n")
                let resultEntry = SessionEntry(role: .toolOutput, content: resultBody)
                await renderer.printScrollLine(resultEntry.render())
            case .searchResults(let action, _, let lines):
                let actionEntry = SessionEntry(role: .toolCall, content: "memory \(action)")
                await renderer.printScrollLine(actionEntry.render())
                let resultBody = lines.joined(separator: "\n")
                let resultEntry = SessionEntry(role: .toolOutput, content: resultBody)
                await renderer.printScrollLine(resultEntry.render())
            case .status(let action, let lines):
                let actionEntry = SessionEntry(role: .toolCall, content: "memory \(action)")
                await renderer.printScrollLine(actionEntry.render())
                let resultBody = lines.joined(separator: "\n")
                let resultEntry = SessionEntry(role: .toolOutput, content: resultBody)
                await renderer.printScrollLine(resultEntry.render())
            case .undone(let message):
                await renderer.printScrollLine("\(DesignSystem.dim)memory: \(message)\(DesignSystem.reset)")
            case .error(let message):
                await renderer.printScrollLine("\(DesignSystem.brightRed)memory: error: \(message)\(DesignSystem.reset)")
            }

        case .buildCheck(let bc):
            await renderer.printScrollLine("\(DesignSystem.dim)build: \(describe(bc))\(DesignSystem.reset)")

        case .gitOrchestration(let g):
            await renderer.printScrollLine("\(DesignSystem.dim)git: \(describe(g))\(DesignSystem.reset)")

        case .contextCompaction(let before, let after, let target, let reason):
            await renderer.printScrollLine("\(DesignSystem.dim)context: \(before)→\(after) (target \(target), \(reason))\(DesignSystem.reset)")

        case .steeringInjected(let s):
            await renderer.printScrollLine("\(DesignSystem.dim)steering: \(s)\(DesignSystem.reset)")

        case .promptTokensKnown(let count):
            promptTokenCount = count
            await renderer.setThinking(spinnerLabel())

        case .tokenProcessingActivity(let lifecycle):
            switch lifecycle {
            case .started:
                isAborted = false
                tokenProcessingActive = true
                generationActive = false
                thinkingActive = false
                pendingGenerationEnd = false
                thinkingBuffer = ""
                isFirstContentToken = true
                markdownTableNormalizer.reset()
                liveTokens = 0
                promptTokenCount = 0
                spinnerBaseLabel = "Processing…"
                pendingTurnStats = nil
                await renderer.setThinking(spinnerLabel())
                await renderer.setGenerating(true)
                await renderer.renderFooter()
                startSpinnerTicker()
            case .ended:
                tokenProcessingActive = false
                // Keep the processing label through prompt decode / generation
                // handoff. Downstream events (think or assistant text) select the
                // specific active label.
                await renderer.renderFooter()
            }

        case .generationActivity(let lifecycle):
            switch lifecycle {
            case .started:
                generationActive = true
                tokenProcessingActive = false
                isFirstContentToken = true
                markdownTableNormalizer.reset()
                // Switch to "Generating…" immediately so the ↑ count (if known)
                // is visible from the first spinner tick — not deferred until the
                // first text token arrives.
                spinnerBaseLabel = "Generating…"
                await renderer.setThinking(spinnerLabel())
                await renderer.renderFooter()
            case .ended:
                let wasActive = tokenProcessingActive || generationActive || thinkingActive || pendingGenerationEnd
                generationActive = false
                guard wasActive else { break }
                if thinkingActive {
                    pendingGenerationEnd = true
                } else {
                    await finalizeGenerationUI()
                }
            }

        case .subAgentActivity(let activity):
            switch activity {
            case .started(let profile, let modelPath):
                activeSubAgent = (profile, modelPath)
            case .ended:
                activeSubAgent = nil
            }
            if tokenProcessingActive || generationActive || thinkingActive || toolExecuting {
                await renderer.setThinking(spinnerLabel())
                await renderer.renderFooter()
            }
        }
    }

    private func startSpinnerTicker() {
        spinnerTickTask?.cancel()
        let cont = continuation
        spinnerTickTask = Task {
            while !Task.isCancelled {
                cont.yield(.spinnerTick)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    /// Immediately tears down any in-flight generation UI (spinner, stream line)
    /// without going through the async event queue. Use this when the generation
    /// Task is cancelled externally (e.g. ESC) so the UI stays consistent.
    public func abortGeneration() async {
        isAborted = true
        tokenProcessingActive = false
        generationActive = false
        thinkingActive = false
        pendingGenerationEnd = false
        toolExecuting = false
        stopSpinnerTicker()
        thinkingBuffer = ""
        isFirstContentToken = true
        markdownTableNormalizer.reset()
        // Single atomic renderer call: sets isStreamingAborted inside the actor
        // so any queued appendStreamChunk/appendThinkChunk calls become no-ops,
        // then clears all state, prints "· Aborted", and redraws.
        await renderer.abortGeneration()
    }

    private func stopSpinnerTicker() {
        spinnerTickTask?.cancel()
        spinnerTickTask = nil
    }

    private func renderSpinnerTick() async {
        guard tokenProcessingActive || generationActive || toolExecuting else { return }
        await renderer.advanceSpinner()
        await renderer.renderSpinnerTick()
    }

    private func finalizeGenerationUI() async {
        tokenProcessingActive = false
        generationActive = false
        thinkingActive = false
        pendingGenerationEnd = false
        stopSpinnerTicker()
        let trailing = markdownTableNormalizer.finish()
        if !trailing.isEmpty {
            await renderer.appendStreamChunk(trailing)
        }
        // Commit any partial response line from the footer stream zone
        // to the scroll area before hiding the spinner / input box.
        await renderer.flushStreamLine()
        await renderer.setGenerating(false)
        await renderer.setThinking("")
        await renderer.renderFooter()
    }

    /// Normalizes streamed think chunks into append-only deltas.
    ///
    /// Some model/tokenizer paths can occasionally replay an already-rendered
    /// snapshot (or an overlapping suffix/prefix) instead of a strict delta.
    /// This keeps rendering monotonic and prevents duplicated think lines.
    private func normalizedThinkingDelta(incoming: String, alreadyRendered: String) -> String {
        guard !incoming.isEmpty else { return "" }
        guard !alreadyRendered.isEmpty else { return incoming }

        // Snapshot replay case: incoming already includes the full rendered text.
        if incoming.hasPrefix(alreadyRendered) {
            return String(incoming.dropFirst(alreadyRendered.count))
        }

        // Tail replay case: incoming fully matches already-rendered tail.
        if alreadyRendered.hasSuffix(incoming) {
            return ""
        }

        // Large replay case: incoming chunk appears verbatim somewhere in what
        // we've already rendered. Keep small chunks exempt to avoid suppressing
        // legitimate repeated short tokens.
        if incoming.count >= 24 && alreadyRendered.contains(incoming) {
            return ""
        }

        // Overlap case: rendered suffix overlaps incoming prefix.
        let maxOverlap = min(alreadyRendered.count, incoming.count)
        if maxOverlap > 0 {
            for overlap in stride(from: maxOverlap, through: 1, by: -1) {
                let renderedSuffix = String(alreadyRendered.suffix(overlap))
                let incomingPrefix = String(incoming.prefix(overlap))
                if renderedSuffix == incomingPrefix {
                    return String(incoming.dropFirst(overlap))
                }
            }
        }

        // No detectable overlap — treat as a fresh delta.
        return incoming
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
        case .factsListed(_, let n, _): return "\(n) fact(s)"
        case .searchResults(_, let q, _): return "search: \(q)"
        case .undone(let s): return s
        case .status(_, _): return "status"
        case .error(let s): return "error: \(s)"
        }
    }

    private func describe(_ b: BuildCheckEvent) -> String {
        switch b {
        case .skipped(let r): return "skipped (\(r))"
        case .started(let m): return m
        case .progress(let m): return m
        case .passed: return "passed"
        case .failed(let n, _):
            if let n {
                return "failed (\(n) error(s))"
            }
            return "failed (error count unavailable)"
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

    private func statusModeLabel(for mode: ModeSnapshot) -> String {
        if mode.workingMode == "plan" { return "plan" }
        if mode.taskType == "general" { return "autopilot" }
        return ""
    }

    private func modeDisplayLabel(for mode: ModeSnapshot) -> String {
        if mode.workingMode == "plan" { return "plan" }
        if mode.taskType == "general" { return "autopilot" }
        return "coding"
    }

    private func modeIndex(for mode: ModeSnapshot) -> Int? {
        let modePrefix: String
        if mode.workingMode == "plan" {
            modePrefix = "plan"
        } else if mode.taskType == "general" {
            modePrefix = "autopilot"
        } else {
            modePrefix = "coding"
        }
        let effort = mode.thinkingLevel == "fast" ? "off" : mode.thinkingLevel
        let id = "\(modePrefix)-\(effort)"
        if let exact = appConfig.modes.firstIndex(where: { $0.id == id }) {
            return exact
        }
        return appConfig.modes.firstIndex(where: { $0.id == "\(modePrefix)-low" })
    }
}
