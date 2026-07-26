// Sources/AgentCore/AgentLoop+ContextManagement.swift
// Context transforms, steering queue, follow-up queue, and deterministic compaction.

import Foundation

extension AgentLoop {

    // MARK: - Steering & Follow-up

    /// Queues a steering message to be injected before the next generation turn within the
    /// current run. Steering messages let you redirect the agent mid-run — they are consumed
    /// between tool-execution rounds, before the model generates its next response.
    public func steer(_ message: String) {
        // The public steering API is user-facing (`/steer`, mid-run prompts), so these are
        // genuine human turns. Agent-internal redirects append to the queue directly with
        // `.automated` origin.
        steeringQueue.append(.init(message: message, origin: .human))
    }

    /// Returns the pending steering messages without consuming them.
    public func pendingSteeringMessages() -> [String] {
        steeringQueue.map(\.message)
    }

    /// Clears all pending steering messages.
    public func clearSteeringQueue() {
        steeringQueue.removeAll()
    }

    /// Queues a follow-up message for automatic processing after the current run completes.
    /// The CLI drains this queue and calls `processUserMessage` for each entry without
    /// requiring the user to type anything.
    public func queueFollowUp(_ message: String) {
        Self.enqueueFollowUp(message, onto: &followUpQueue)
    }

    /// Dequeues and returns the next follow-up message, or `nil` if the queue is empty.
    public func dequeueFollowUp() -> String? {
        Self.dequeueFollowUp(from: &followUpQueue)
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

    static func enqueueFollowUp(_ message: String, onto queue: inout [String]) {
        queue.append(message)
    }

    static func dequeueFollowUp(from queue: inout [String]) -> String? {
        guard !queue.isEmpty else { return nil }
        return queue.removeFirst()
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

    // MARK: - Deterministic Context Compaction

    /// - Parameter overrideThreshold: When set, compacts against this token budget instead
    ///   of `currentGenerationConfig.longContextThreshold`. Used for emergency recovery when
    ///   a remote provider reports its actual context window size (e.g. after an
    ///   `exceed_context_size_error`) — that number is authoritative where the chip-based
    ///   default threshold isn't. Since remote-only sessions have no local tokenizer, the
    ///   `chars/4` fallback estimate can undercount real tokens, so the reserve is widened
    ///   proportionally to leave headroom for that error margin.
    func applyDeterministicContextCompactionIfNeeded(reason: String, overrideThreshold: Int? = nil) async {
        // Never compact mid-recovery. While a turn is in flight, transient artifacts
        // (malformed tool-call attempts, automated steering) are still in history so
        // the model can recover; they are purged when the turn completes. Skipping
        // here guarantees compaction only ever snapshots the durable, committed
        // conversation — malformed attempts never leak into a summary. The emergency
        // overflow path purges transient first (see processUserMessage), so it still
        // runs when genuinely needed.
        guard !history.messages.contains(where: { $0.transient }) else { return }

        let baseThreshold = overrideThreshold ?? currentGenerationConfig.longContextThreshold
        let reserve = overrideThreshold != nil ? max(contextReserveTokens, baseThreshold / 5) : contextReserveTokens
        let threshold = max(baseThreshold, reserve + 1)
        let target = max(256, threshold - reserve)

        let tokenCounter = await makeTokenCounter()
        _ = await performCompaction(reason: reason, target: target, tokenCounter: tokenCounter)
    }

    // MARK: - Context Watchdog (proactive percent-of-window trigger)

    /// Proactive, percentage-of-window compaction trigger — a port of little-coder's
    /// `context-watchdog` (see `ContextWatchdog` for the pure decision functions this
    /// wraps). This complements `applyDeterministicContextCompactionIfNeeded`'s
    /// existing per-iteration call, which only fires once the *fixed* `contextReserveTokens`
    /// margin has been eaten into — a margin that shrinks, percentage-wise, as
    /// `longContextThreshold` grows. This trigger is denominated directly in
    /// percent-of-window instead, so it stays proportionally consistent regardless of
    /// window size, and it carries its own no-progress pause/hysteresis state.
    ///
    /// **Deriving a percentage without a real context window.** mlx-coder has no path
    /// that reads a model's actual context window — the remote (OpenRouter) path only
    /// learns the true window *after* an overflow, parsed out of the error
    /// (`OpenRouterError.reportedContextWindow`); the local path has no such concept at
    /// all. `currentGenerationConfig.longContextThreshold` (default 8192) is the only
    /// number in this codebase that already plays the "window" role for every other
    /// long-context decision (KV quantization, the existing compaction target), so this
    /// watchdog reuses it as the effective window rather than inventing a second,
    /// competing constant.
    ///
    /// **Transient-guard interaction.** Like the per-iteration call, this skips
    /// entirely while transient recovery artifacts are in history — and, deliberately,
    /// does NOT purge them the way the emergency overflow-recovery path does. Purging
    /// here would risk folding a malformed tool-call attempt into a compaction summary
    /// just to hit a soft, non-emergency percentage target; that risk is only judged
    /// acceptable for the genuine emergency path (an imminent crash/oversized request).
    /// Worst case, this check is skipped for one iteration and re-evaluated on the very
    /// next one — failed-call streaks are bounded
    /// (`LoopDetectionService.repeatedFailedCallBreakLimit`), so that's a few
    /// iterations' delay at most, not an indefinite no-op.
    ///
    /// **Cost awareness.** A successful compaction fully invalidates the KV prompt
    /// cache (`PromptCacheStore.invalidate` has no partial mode) — mid-run, that can
    /// discard a cache that would otherwise have survived many more tool rounds. The
    /// percent trigger (80% by default) and the "compact down to threshold − 5%"
    /// target below are both deliberately conservative about *how often* that cost is
    /// paid: this fires meaningfully before the window is exhausted, but not on every
    /// small fluctuation near the line.
    func applyContextWatchdogIfNeeded() async {
        guard !history.messages.contains(where: { $0.transient }) else { return }

        let windowTokens = currentGenerationConfig.longContextThreshold
        let tokenCounter = await makeTokenCounter()
        let currentTokens = currentTokenCount(using: tokenCounter)
        let usage = ContextWatchdog.Usage(tokens: currentTokens, windowTokens: windowTokens)
        let prePercent = ContextWatchdog.percent(for: usage)

        // Hysteresis re-arm: once usage has genuinely dropped back under the
        // threshold, clear a previous no-progress pause so the watchdog can fire
        // again next time usage climbs back up.
        if contextWatchdogPaused,
           ContextWatchdog.shouldReArm(currentPercent: prePercent, thresholdPercent: contextWatchdogThresholdPercent) {
            contextWatchdogPaused = false
            frontend.emitStatus("[Context] Watchdog re-armed — usage dropped back below \(Int(contextWatchdogThresholdPercent))% of window.")
        }

        guard ContextWatchdog.shouldCompactNow(
            usage: usage,
            thresholdPercent: contextWatchdogThresholdPercent,
            isPaused: contextWatchdogPaused
        ) else { return }

        // Compact down to comfortably below the trigger threshold (not merely
        // "under the trigger point") so a successful pass reliably registers as
        // "helped" — see `ContextWatchdog.compactionHelped`.
        let targetPercent = max(0, contextWatchdogThresholdPercent - ContextWatchdog.defaultMinProgressPercent)
        let targetTokens = max(256, Int(Double(windowTokens) * targetPercent / 100))

        let compactionResult = await performCompaction(
            reason: "context_watchdog_percent",
            target: targetTokens,
            tokenCounter: tokenCounter
        )
        guard compactionResult != nil else {
            // Threshold was crossed but there was nothing left to compact (too few
            // turns to drop below `contextKeepRecentTurns`, or no system message —
            // see `compactByTurns`'s doc comment). Treat this the same as a failed
            // compaction: pause rather than re-attempt and re-decline on every
            // single iteration until the conversation naturally moves on.
            contextWatchdogPaused = true
            frontend.harnessIntervention(
                "pausing automatic compaction — at ≈\(Int(prePercent ?? 0))% of the context window with nothing left to compact. Consider running /compact manually, trimming large tool results, or starting a new session.",
                severity: .warning
            )
            return
        }

        let afterCounter = await makeTokenCounter()
        let afterTokens = currentTokenCount(using: afterCounter)
        guard let afterPercent = ContextWatchdog.percent(for: ContextWatchdog.Usage(tokens: afterTokens, windowTokens: windowTokens)) else { return }

        if !ContextWatchdog.compactionHelped(postPercent: afterPercent, thresholdPercent: contextWatchdogThresholdPercent) {
            contextWatchdogPaused = true
            frontend.harnessIntervention(
                "pausing automatic compaction — the last pass freed too little headroom (still ≈\(Int(afterPercent))% of window; threshold \(Int(contextWatchdogThresholdPercent))%) to avoid repeatedly summarizing an already-thin tail (see little-coder issue #68).",
                severity: .warning
            )
            // Steer the model away from re-reading files/tool output it already has
            // in context — that re-inflation is exactly what turns one compaction
            // into a doomed second one.
            steeringQueue.append(.init(
                message: "Context is near its window limit and automatic compaction is now paused because a recent pass did not free enough headroom. Do NOT re-read files or tool outputs you already have in this conversation — reuse what's already here. Only read something new if it is strictly necessary, and keep it as small as possible.",
                origin: .automated
            ))
        }
    }

    // MARK: - Compaction helpers (shared by both trigger paths above)

    /// Runs `compactByTurns` against `target` using `tokenCounter`, invalidates the
    /// prompt cache on success, and reports the before/after status line + the
    /// `.compression` hook. Shared by the reserve-based per-iteration compaction and
    /// the percent-based watchdog so the actual compaction mechanics — and their
    /// side effects — have exactly one code path.
    ///
    /// - Returns: `(before, after)` token counts on a successful compaction, or
    ///   `nil` if compaction did not run — either because `currentTokens <= target`
    ///   already, or `compactByTurns` structurally declined (see its doc comment:
    ///   no system message, or too few turns to drop below `keepRecentTurns`). The
    ///   caller cannot tell these two `nil` cases apart from the return value alone;
    ///   callers that need to (the watchdog's no-progress guard) re-check
    ///   `currentTokens > target` themselves immediately before calling in, so a
    ///   `nil` they see is unambiguously the structural-decline case.
    @discardableResult
    private func performCompaction(
        reason: String,
        target: Int,
        tokenCounter: ((String) -> Int)?
    ) async -> (before: Int, after: Int)? {
        let currentTokens = currentTokenCount(using: tokenCounter)
        guard currentTokens > target else { return nil }

        let before = currentTokens
        let compacted = history.compactByTurns(
            maxTokens: target,
            keepRecentTurns: contextKeepRecentTurns,
            tokenCounter: tokenCounter
        )
        guard compacted else { return nil }

        // Compaction rewrote the history prefix, so the persisted KV cache no longer
        // matches the prompt that produced it. Drop it — the next turn re-prefills.
        promptCache.invalidate(reason: "context compaction")

        // Re-snapshot after compaction for the "after" count.
        let afterCounter = await makeTokenCounter()
        let after = currentTokenCount(using: afterCounter)

        frontend.harnessIntervention("compacted conversation history (\(reason)) — before≈\(before), after≈\(after), target≈\(target) tokens.")
        await hooks.emit(.compression(toolName: "context_history", beforeTokens: before, afterTokens: after, usedFallback: false))

        return (before, after)
    }

    /// Builds a tokenizer-backed counter closure from a fresh snapshot of the
    /// current history, or `nil` if no model is loaded — callers fall back to
    /// `chars/4` via `currentTokenCount(using:)`. Snapshots message contents and
    /// computes counts inside `modelContainer.perform` (which is Sendable-safe),
    /// then exposes a lookup table as the closure to avoid capturing non-Sendable
    /// state across the isolation boundary.
    ///
    /// Not `private`: also used by `AgentLoop+ToolCondensation.swift` to build a
    /// `ToolResultCondensationPolicy.BudgetContext` for the budget-aware tool
    /// result trim, on the same "live tokens vs. `longContextThreshold`" basis
    /// this file already uses for the compaction watchdog — see
    /// `applyContextWatchdogIfNeeded` above.
    func makeTokenCounter() async -> ((String) -> Int)? {
        guard let modelContainer else { return nil }
        let contentSnapshot = history.messages.map(\.content)
        let counts = await modelContainer.perform { context in
            contentSnapshot.map { context.tokenizer.encode(text: $0).count }
        }
        let lookup = LoopDetectionService.makeTokenCountLookup(contents: contentSnapshot, counts: counts)
        return { text in lookup[text] ?? (text.count / 4) }
    }

    /// Total token count for the current history using `counter`, or the `chars/4`
    /// estimate (`ConversationHistory.estimatedTokenCount`) if no counter is
    /// available.
    func currentTokenCount(using counter: ((String) -> Int)?) -> Int {
        counter.map { c in history.messages.reduce(0) { $0 + c($1.content) } } ?? history.estimatedTokenCount
    }
}
