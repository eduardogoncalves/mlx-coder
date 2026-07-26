// Tests for the pure thinking-token-budget decision in
// Sources/AgentCore/ThinkingBudget.swift, which enforces
// AgentLoop.ThinkingLevel.budgetTokens at runtime by deciding when the
// per-token streaming loop (AgentLoop+Generation.swift) should force a
// `<think>` block closed. The streaming loop itself has no test coverage
// (it needs a loaded model), so these tests only cover the extracted
// arithmetic — not the live token stream, StreamParser wiring, or the
// steering-queue/forceThinkingOffNextTurn plumbing in AgentLoop.swift.

import XCTest
@testable import MLXCoder

final class ThinkingBudgetTests: XCTestCase {

    // MARK: - thinkingBudgetTolerance

    func testToleranceFloorAppliesForSmallBudgets() {
        // 20% of 100 is 20, below the 24-token floor.
        XCTAssertEqual(AgentLoop.thinkingBudgetTolerance(budgetTokens: 100), 24)
    }

    func testToleranceFloorAppliesForZeroBudget() {
        XCTAssertEqual(AgentLoop.thinkingBudgetTolerance(budgetTokens: 0), 24)
    }

    func testTolerancePercentageAppliesForLargeBudgets() {
        // 20% of 2000 (ThinkingLevel.high) is 400, above the floor.
        XCTAssertEqual(AgentLoop.thinkingBudgetTolerance(budgetTokens: 2000), 400)
    }

    func testToleranceAtFloorBoundary() {
        // 120 / 5 == 24, exactly at the floor either way.
        XCTAssertEqual(AgentLoop.thinkingBudgetTolerance(budgetTokens: 120), 24)
    }

    // MARK: - shouldStopThinking — not thinking

    func testNeverStopsWhenNotThinking() {
        // Even a huge overshoot is irrelevant once the model closed the
        // block itself — nothing left to enforce.
        XCTAssertFalse(AgentLoop.shouldStopThinking(
            thinkingTokensSoFar: 1_000_000,
            budgetTokens: 100,
            isThinking: false
        ))
    }

    // MARK: - shouldStopThinking — within budget

    func testDoesNotStopBeforeBudget() {
        XCTAssertFalse(AgentLoop.shouldStopThinking(
            thinkingTokensSoFar: 50,
            budgetTokens: 100,
            isThinking: true
        ))
    }

    func testDoesNotStopExactlyAtBudget() {
        // At the budget line exactly — still within the tolerance window.
        XCTAssertFalse(AgentLoop.shouldStopThinking(
            thinkingTokensSoFar: 100,
            budgetTokens: 100,
            isThinking: true
        ))
    }

    func testDoesNotStopWithinTolerance() {
        // 100 + 24 == 124: still within tolerance (strictly greater is the
        // stop condition), so 124 itself must not stop.
        XCTAssertFalse(AgentLoop.shouldStopThinking(
            thinkingTokensSoFar: 124,
            budgetTokens: 100,
            isThinking: true
        ))
    }

    // MARK: - shouldStopThinking — breach

    func testStopsJustPastToleranceForMinimalBudget() {
        // minimal (100) + tolerance (24) == 124; 125 must breach.
        XCTAssertTrue(AgentLoop.shouldStopThinking(
            thinkingTokensSoFar: 125,
            budgetTokens: 100,
            isThinking: true
        ))
    }

    func testStopsJustPastToleranceForHighBudget() {
        // high (2000) + tolerance (400) == 2400; 2401 must breach.
        XCTAssertTrue(AgentLoop.shouldStopThinking(
            thinkingTokensSoFar: 2401,
            budgetTokens: 2000,
            isThinking: true
        ))
        XCTAssertFalse(AgentLoop.shouldStopThinking(
            thinkingTokensSoFar: 2400,
            budgetTokens: 2000,
            isThinking: true
        ))
    }

    func testZeroBudgetDoesNotStopOnFirstThinkingToken() {
        // The critical `.fast`/forced-suppression edge case: a 0 budget must
        // not be interpreted as "abort immediately on the first thinking
        // token" — it still gets the tolerance floor.
        XCTAssertFalse(AgentLoop.shouldStopThinking(
            thinkingTokensSoFar: 1,
            budgetTokens: 0,
            isThinking: true
        ))
        XCTAssertFalse(AgentLoop.shouldStopThinking(
            thinkingTokensSoFar: 24,
            budgetTokens: 0,
            isThinking: true
        ))
    }

    func testZeroBudgetEventuallyStopsPastTolerance() {
        XCTAssertTrue(AgentLoop.shouldStopThinking(
            thinkingTokensSoFar: 25,
            budgetTokens: 0,
            isThinking: true
        ))
    }

    // MARK: - Every ThinkingLevel's real budget is well-behaved

    func testAllThinkingLevelsProduceMonotonicNonNegativeLimits() {
        var previousLimit = -1
        for level: AgentLoop.ThinkingLevel in [.fast, .minimal, .low, .medium, .high] {
            let budget = level.budgetTokens
            let tolerance = AgentLoop.thinkingBudgetTolerance(budgetTokens: budget)
            XCTAssertGreaterThanOrEqual(tolerance, 24, "\(level) tolerance should never be below the floor")
            let limit = budget + tolerance
            XCTAssertGreaterThan(limit, previousLimit, "\(level)'s effective stop limit should exceed the previous level's")
            previousLimit = limit
            // Right at the limit must not stop; one token past it must.
            XCTAssertFalse(AgentLoop.shouldStopThinking(thinkingTokensSoFar: limit, budgetTokens: budget, isThinking: true))
            XCTAssertTrue(AgentLoop.shouldStopThinking(thinkingTokensSoFar: limit + 1, budgetTokens: budget, isThinking: true))
        }
    }
}
