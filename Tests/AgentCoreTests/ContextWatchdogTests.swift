// Tests for the pure decision logic in Sources/AgentCore/ContextWatchdog.swift,
// which drives the mid-run context-compaction watchdog: a proactive
// percentage-of-window compaction trigger plus a "compaction didn't free enough
// headroom" no-progress pause/hysteresis guard (a port of little-coder's
// `context-watchdog`).
//
// This covers only the extracted, stateless arithmetic. The actual wiring —
// `AgentLoop.applyContextWatchdogIfNeeded()` in AgentLoop+ContextManagement.swift,
// which measures real token counts via the tokenizer, calls
// `ConversationHistory.compactByTurns`, invalidates the prompt cache, and mutates
// `AgentLoop.contextWatchdogPaused` — needs a loaded model and an actor instance,
// so it has no test coverage here (mirrors the existing precedent in
// ThinkingBudgetTests.swift for `AgentLoop.shouldStopThinking`).

import XCTest
@testable import MLXCoder

final class ContextWatchdogTests: XCTestCase {

    // MARK: - percent(for:)

    func testPercentComputesRatio() {
        let usage = ContextWatchdog.Usage(tokens: 4096, windowTokens: 8192)
        XCTAssertEqual(ContextWatchdog.percent(for: usage), 50)
    }

    func testPercentAtFullWindow() {
        let usage = ContextWatchdog.Usage(tokens: 8192, windowTokens: 8192)
        XCTAssertEqual(ContextWatchdog.percent(for: usage), 100)
    }

    func testPercentCanExceedOneHundred() {
        // Overflow past the window is a real (if rare) state — the caller should
        // still get a usable number rather than a clamp, so `shouldCompactNow`
        // reliably fires.
        let usage = ContextWatchdog.Usage(tokens: 9000, windowTokens: 8000)
        XCTAssertEqual(ContextWatchdog.percent(for: usage), 112.5)
    }

    func testPercentNilWhenWindowIsZero() {
        let usage = ContextWatchdog.Usage(tokens: 100, windowTokens: 0)
        XCTAssertNil(ContextWatchdog.percent(for: usage))
    }

    func testPercentNilWhenWindowIsNegative() {
        let usage = ContextWatchdog.Usage(tokens: 100, windowTokens: -1)
        XCTAssertNil(ContextWatchdog.percent(for: usage))
    }

    func testPercentNilWhenTokensNegative() {
        let usage = ContextWatchdog.Usage(tokens: -1, windowTokens: 8192)
        XCTAssertNil(ContextWatchdog.percent(for: usage))
    }

    func testPercentZeroTokensIsZeroPercent() {
        let usage = ContextWatchdog.Usage(tokens: 0, windowTokens: 8192)
        XCTAssertEqual(ContextWatchdog.percent(for: usage), 0)
    }

    // MARK: - shouldCompactNow — threshold boundary

    func testDoesNotTriggerBelowThreshold() {
        let usage = ContextWatchdog.Usage(tokens: 6000, windowTokens: 8192) // ≈73.2%
        XCTAssertFalse(ContextWatchdog.shouldCompactNow(usage: usage, thresholdPercent: 80, isPaused: false))
    }

    func testTriggersExactlyAtThreshold() {
        // 80% of 8192 == 6553.6; use an exact value to avoid float rounding ambiguity.
        let usage = ContextWatchdog.Usage(tokens: 80, windowTokens: 100) // exactly 80%
        XCTAssertTrue(ContextWatchdog.shouldCompactNow(usage: usage, thresholdPercent: 80, isPaused: false))
    }

    func testTriggersAboveThreshold() {
        let usage = ContextWatchdog.Usage(tokens: 90, windowTokens: 100)
        XCTAssertTrue(ContextWatchdog.shouldCompactNow(usage: usage, thresholdPercent: 80, isPaused: false))
    }

    func testJustBelowThresholdDoesNotTrigger() {
        let usage = ContextWatchdog.Usage(tokens: 79, windowTokens: 100)
        XCTAssertFalse(ContextWatchdog.shouldCompactNow(usage: usage, thresholdPercent: 80, isPaused: false))
    }

    // MARK: - shouldCompactNow — disabled / guarded cases

    func testDisabledWhenThresholdPercentIsZero() {
        let usage = ContextWatchdog.Usage(tokens: 100, windowTokens: 100)
        XCTAssertFalse(ContextWatchdog.shouldCompactNow(usage: usage, thresholdPercent: 0, isPaused: false))
    }

    func testDisabledWhenThresholdPercentIsNegative() {
        let usage = ContextWatchdog.Usage(tokens: 100, windowTokens: 100)
        XCTAssertFalse(ContextWatchdog.shouldCompactNow(usage: usage, thresholdPercent: -10, isPaused: false))
    }

    func testNeverTriggersWhilePaused() {
        // Even a wildly over-threshold usage must not trigger while paused —
        // this is the no-progress guard's whole point.
        let usage = ContextWatchdog.Usage(tokens: 100, windowTokens: 100)
        XCTAssertFalse(ContextWatchdog.shouldCompactNow(usage: usage, thresholdPercent: 80, isPaused: true))
    }

    func testNeverTriggersWithNilUsage() {
        XCTAssertFalse(ContextWatchdog.shouldCompactNow(usage: nil, thresholdPercent: 80, isPaused: false))
    }

    func testNeverTriggersWithZeroWindow() {
        let usage = ContextWatchdog.Usage(tokens: 100, windowTokens: 0)
        XCTAssertFalse(ContextWatchdog.shouldCompactNow(usage: usage, thresholdPercent: 80, isPaused: false))
    }

    func testNeverTriggersWithNegativeWindow() {
        let usage = ContextWatchdog.Usage(tokens: 100, windowTokens: -50)
        XCTAssertFalse(ContextWatchdog.shouldCompactNow(usage: usage, thresholdPercent: 80, isPaused: false))
    }

    // MARK: - compactionHelped

    func testCompactionHelpedWhenComfortablyBelowThreshold() {
        // threshold 80, minProgress 5 -> must land at or below 75.
        XCTAssertTrue(ContextWatchdog.compactionHelped(postPercent: 70, thresholdPercent: 80))
    }

    func testCompactionHelpedExactlyAtMinProgressBoundary() {
        XCTAssertTrue(ContextWatchdog.compactionHelped(postPercent: 75, thresholdPercent: 80))
    }

    func testCompactionDidNotHelpJustAboveBoundary() {
        XCTAssertFalse(ContextWatchdog.compactionHelped(postPercent: 75.1, thresholdPercent: 80))
    }

    func testCompactionDidNotHelpWhenBarelyMoved() {
        // Compaction ran but only shaved off a couple points — the doomed
        // "near-empty second compaction" scenario from little-coder issue #68.
        XCTAssertFalse(ContextWatchdog.compactionHelped(postPercent: 79, thresholdPercent: 80))
    }

    func testCompactionHelpedWithCustomMinProgress() {
        XCTAssertTrue(ContextWatchdog.compactionHelped(postPercent: 70, thresholdPercent: 80, minProgressPercent: 10))
        XCTAssertFalse(ContextWatchdog.compactionHelped(postPercent: 71, thresholdPercent: 80, minProgressPercent: 10))
    }

    func testCompactionHelpedUsesDefaultMinProgressConstant() {
        XCTAssertEqual(ContextWatchdog.defaultMinProgressPercent, 5)
        XCTAssertTrue(ContextWatchdog.compactionHelped(postPercent: 75, thresholdPercent: 80))
    }

    // MARK: - shouldReArm (hysteresis)

    func testReArmsWhenBelowThreshold() {
        XCTAssertTrue(ContextWatchdog.shouldReArm(currentPercent: 70, thresholdPercent: 80))
    }

    func testDoesNotReArmExactlyAtThreshold() {
        // Strictly below is required — sitting exactly at the threshold would
        // immediately re-trigger and re-fail the same way.
        XCTAssertFalse(ContextWatchdog.shouldReArm(currentPercent: 80, thresholdPercent: 80))
    }

    func testDoesNotReArmAboveThreshold() {
        XCTAssertFalse(ContextWatchdog.shouldReArm(currentPercent: 85, thresholdPercent: 80))
    }

    func testDoesNotReArmWithNilPercent() {
        XCTAssertFalse(ContextWatchdog.shouldReArm(currentPercent: nil, thresholdPercent: 80))
    }

    // MARK: - Full pause → hysteresis → re-arm lifecycle (integration of the pure functions)

    func testPauseThenReArmLifecycle() {
        let threshold = 80.0

        // 1. Usage crosses the threshold: should compact.
        let highUsage = ContextWatchdog.Usage(tokens: 85, windowTokens: 100)
        XCTAssertTrue(ContextWatchdog.shouldCompactNow(usage: highUsage, thresholdPercent: threshold, isPaused: false))

        // 2. Compaction ran but barely moved the needle -> did not help -> pause.
        let postPercent = 79.0
        XCTAssertFalse(ContextWatchdog.compactionHelped(postPercent: postPercent, thresholdPercent: threshold))
        var paused = true

        // 3. While still near/at the threshold, no re-arm and no further triggering.
        XCTAssertFalse(ContextWatchdog.shouldReArm(currentPercent: postPercent, thresholdPercent: threshold))
        XCTAssertFalse(ContextWatchdog.shouldCompactNow(
            usage: ContextWatchdog.Usage(tokens: 79, windowTokens: 100),
            thresholdPercent: threshold,
            isPaused: paused
        ))

        // 4. Usage eventually drops (e.g. the user sends a short follow-up that
        // gets summarized away next turn, or the conversation naturally trims) ->
        // re-arm clears the pause.
        let droppedPercent = 60.0
        XCTAssertTrue(ContextWatchdog.shouldReArm(currentPercent: droppedPercent, thresholdPercent: threshold))
        paused = false

        // 5. Watchdog is live again and stays quiet below threshold.
        XCTAssertFalse(ContextWatchdog.shouldCompactNow(
            usage: ContextWatchdog.Usage(tokens: 60, windowTokens: 100),
            thresholdPercent: threshold,
            isPaused: paused
        ))

        // 6. If usage climbs back over threshold, it can fire again.
        XCTAssertTrue(ContextWatchdog.shouldCompactNow(
            usage: ContextWatchdog.Usage(tokens: 90, windowTokens: 100),
            thresholdPercent: threshold,
            isPaused: paused
        ))
    }

    // MARK: - Default constants sanity

    func testDefaultThresholdPercentMatchesReference() {
        // Mirrors little-coder's `DEFAULT_PERCENT`.
        XCTAssertEqual(ContextWatchdog.defaultThresholdPercent, 80)
    }

    func testDefaultMinProgressPercentMatchesReference() {
        // Mirrors little-coder's `MIN_PROGRESS_PCT`.
        XCTAssertEqual(ContextWatchdog.defaultMinProgressPercent, 5)
    }
}
