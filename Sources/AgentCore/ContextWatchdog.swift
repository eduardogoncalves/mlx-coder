// Sources/AgentCore/ContextWatchdog.swift
// Pure decision logic for the mid-run context-compaction watchdog: a proactive,
// percentage-of-window trigger layered on top of `AgentLoop`'s existing
// deterministic compaction, plus a "compaction didn't free enough headroom"
// no-progress guard.
//
// This is a port of little-coder's `context-watchdog` (see that project's
// `shouldCompactNow` / `compactionHelped`). The reference fires compaction once
// token usage crosses `DEFAULT_PERCENT` (80%) of the model's real context window,
// and — critically — measures the FIRST post-compaction usage: if it isn't at
// least `MIN_PROGRESS_PCT` (5 percentage points) below the trigger threshold, it
// pauses automatic compaction rather than firing a second, likely-doomed
// compaction immediately after. Their issue #68: after a mid-run compaction the
// model re-read files, re-inflated context, the watchdog fired again, and the
// second compaction had only a tiny post-compaction tail left to summarize —
// failing and wedging the session. The pause clears automatically once usage
// drops back below the threshold (hysteresis) — see `shouldReArm`.
//
// mlx-coder has no path that reads a model's real context window (see the doc
// comment on `AgentLoop.applyContextWatchdogIfNeeded` for how the caller derives a
// stand-in); this file only receives whatever `(tokens, windowTokens)` pair the
// caller computed and makes the trigger/helped/re-arm decisions on it. It is
// otherwise a direct, stateless port — no actor isolation, no I/O, fully
// unit-testable without a loaded model (mirrors the `LoopDetectionService` /
// `ThinkingBudget` pattern already used elsewhere in this file's neighborhood).
enum ContextWatchdog {

    /// Mirrors little-coder's `DEFAULT_PERCENT` — the percent-of-window usage at
    /// which the watchdog proactively triggers compaction.
    static let defaultThresholdPercent: Double = 80

    /// Mirrors little-coder's `MIN_PROGRESS_PCT` — how far below the trigger
    /// threshold a post-compaction usage must land to count as "helped".
    static let defaultMinProgressPercent: Double = 5

    /// A token-usage snapshot: current token count against the effective window.
    struct Usage: Sendable, Equatable {
        let tokens: Int
        let windowTokens: Int
    }

    /// Percent of window currently used, or `nil` if there is no usable window
    /// (`windowTokens <= 0`) or a nonsensical negative token count — mirrors the
    /// reference's `usage.percent === null` case.
    static func percent(for usage: Usage) -> Double? {
        guard usage.windowTokens > 0, usage.tokens >= 0 else { return nil }
        return (Double(usage.tokens) / Double(usage.windowTokens)) * 100
    }

    /// Whether the watchdog should trigger a compaction attempt right now.
    /// Direct port of little-coder's `shouldCompactNow`.
    static func shouldCompactNow(
        usage: Usage?,
        thresholdPercent: Double,
        isPaused: Bool
    ) -> Bool {
        guard thresholdPercent > 0 else { return false }
        guard !isPaused else { return false }
        guard let usage else { return false }
        guard usage.windowTokens > 0 else { return false }
        guard let pct = percent(for: usage) else { return false }
        return pct >= thresholdPercent
    }

    /// Whether a just-completed compaction freed enough headroom to be worth
    /// doing — i.e. it's safe to let the watchdog fire again later without
    /// immediately re-triggering a doomed second pass. Direct port of
    /// little-coder's `compactionHelped`: the comparison is against the
    /// *threshold*, not the pre-compaction usage — "helped" means "landed
    /// comfortably below the trigger point", not merely "went down at all".
    static func compactionHelped(
        postPercent: Double,
        thresholdPercent: Double,
        minProgressPercent: Double = ContextWatchdog.defaultMinProgressPercent
    ) -> Bool {
        postPercent <= thresholdPercent - minProgressPercent
    }

    /// Whether a previous no-progress pause should clear now. Usage must have
    /// dropped strictly below `thresholdPercent - minProgressPercent` — the same
    /// band `compactionHelped` uses to judge a compaction — not merely below the
    /// raw trigger threshold. Re-arming at the raw threshold would clear the pause
    /// the instant usage ticks a fraction under it (exactly the "didn't really
    /// help" state that caused the pause in the first place), immediately exposing
    /// the watchdog to firing another likely-doomed compaction on the same thin
    /// tail. The margin keeps a re-armed watchdog from immediately re-triggering.
    static func shouldReArm(
        currentPercent: Double?,
        thresholdPercent: Double,
        minProgressPercent: Double = ContextWatchdog.defaultMinProgressPercent
    ) -> Bool {
        guard let currentPercent else { return false }
        return currentPercent < thresholdPercent - minProgressPercent
    }
}
