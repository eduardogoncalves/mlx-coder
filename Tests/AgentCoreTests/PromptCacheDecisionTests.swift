import XCTest
@testable import MLXCoder

/// Unit tests for the pure prompt-cache helpers that drive cross-turn KV reuse.
/// These cover the token-prefix diffing and the trim/reuse decision arithmetic
/// without needing a loaded model (real KV trimming can't be unit-tested here).
final class PromptCacheDecisionTests: XCTestCase {

    // MARK: - longestCommonPrefixLength

    func testLCPBothEmpty() {
        XCTAssertEqual(AgentLoop.longestCommonPrefixLength([], []), 0)
    }

    func testLCPIdentical() {
        XCTAssertEqual(AgentLoop.longestCommonPrefixLength([1, 2, 3], [1, 2, 3]), 3)
    }

    func testLCPPartial() {
        XCTAssertEqual(AgentLoop.longestCommonPrefixLength([1, 2, 3, 9], [1, 2, 3, 4, 5]), 3)
    }

    func testLCPOneEmpty() {
        XCTAssertEqual(AgentLoop.longestCommonPrefixLength([], [1, 2, 3]), 0)
        XCTAssertEqual(AgentLoop.longestCommonPrefixLength([1, 2, 3], []), 0)
    }

    func testLCPDivergentFirstToken() {
        XCTAssertEqual(AgentLoop.longestCommonPrefixLength([9, 1, 2], [1, 2, 3]), 0)
    }

    func testLCPPrefixShorterThanOther() {
        // The shared prefix is the entire shorter array.
        XCTAssertEqual(AgentLoop.longestCommonPrefixLength([1, 2], [1, 2, 3, 4]), 2)
    }

    // MARK: - computePromptCacheDecision

    func testDecisionNotReusableFallsBackToFresh() {
        let decision = AgentLoop.computePromptCacheDecision(
            cachedTokens: [1, 2, 3],
            promptTokens: [1, 2, 3, 4],
            cacheOffset: 3,
            cacheIsReusable: false
        )
        XCTAssertEqual(decision, PromptCacheDecision(common: 0, toTrim: 0, reuseCache: false))
    }

    func testDecisionExactPrefixReusesWithNoTrim() {
        // Cache holds [1,2,3]; new prompt extends it — reuse with zero trim and
        // feed only the suffix starting at index 3.
        let decision = AgentLoop.computePromptCacheDecision(
            cachedTokens: [1, 2, 3],
            promptTokens: [1, 2, 3, 4, 5],
            cacheOffset: 3,
            cacheIsReusable: true
        )
        XCTAssertEqual(decision, PromptCacheDecision(common: 3, toTrim: 0, reuseCache: true))
    }

    func testDecisionDivergedTailTrimsExtraTokens() {
        // Cache holds [1,2,3,9,9] but the new prompt only shares [1,2,3], so the
        // two extra cached tokens must be trimmed.
        let decision = AgentLoop.computePromptCacheDecision(
            cachedTokens: [1, 2, 3, 9, 9],
            promptTokens: [1, 2, 3, 4, 5],
            cacheOffset: 5,
            cacheIsReusable: true
        )
        XCTAssertEqual(decision, PromptCacheDecision(common: 3, toTrim: 2, reuseCache: true))
    }

    func testDecisionTrailingStopTokenTrimsFromLiveOffset() {
        // The previous turn ended on EOS, so the cache physically holds one more
        // token than `cachedTokens` records (cacheOffset 6 vs 5 recorded). The trim
        // must come off the live offset so the post-trim offset lands on `common`:
        // toTrim = 6 - 3 = 3 (the two divergent tokens plus the trailing EOS).
        let decision = AgentLoop.computePromptCacheDecision(
            cachedTokens: [1, 2, 3, 9, 9],
            promptTokens: [1, 2, 3, 4, 5],
            cacheOffset: 6,
            cacheIsReusable: true
        )
        XCTAssertEqual(decision, PromptCacheDecision(common: 3, toTrim: 3, reuseCache: true))
    }

    func testDecisionIdenticalPromptIsCappedToLeaveOneToken() {
        // When the prompt exactly equals the cached tokens, the common prefix is
        // capped at count-1 so at least one token is always fed to the iterator,
        // which forces trimming one token off the cache.
        let decision = AgentLoop.computePromptCacheDecision(
            cachedTokens: [1, 2, 3, 4],
            promptTokens: [1, 2, 3, 4],
            cacheOffset: 4,
            cacheIsReusable: true
        )
        XCTAssertEqual(decision, PromptCacheDecision(common: 3, toTrim: 1, reuseCache: true))
    }

    func testDecisionDivergentFirstTokenFallsBackToFresh() {
        let decision = AgentLoop.computePromptCacheDecision(
            cachedTokens: [9, 2, 3],
            promptTokens: [1, 2, 3],
            cacheOffset: 3,
            cacheIsReusable: true
        )
        XCTAssertEqual(decision, PromptCacheDecision(common: 0, toTrim: 0, reuseCache: false))
    }

    func testDecisionEmptyCacheFallsBackToFresh() {
        let decision = AgentLoop.computePromptCacheDecision(
            cachedTokens: [],
            promptTokens: [1, 2, 3],
            cacheOffset: 0,
            cacheIsReusable: true
        )
        XCTAssertEqual(decision, PromptCacheDecision(common: 0, toTrim: 0, reuseCache: false))
    }

    func testDecisionCapWithSinglePromptToken() {
        // A one-token prompt can never reuse anything — capping to count-1 == 0.
        let decision = AgentLoop.computePromptCacheDecision(
            cachedTokens: [1],
            promptTokens: [1],
            cacheOffset: 1,
            cacheIsReusable: true
        )
        XCTAssertEqual(decision, PromptCacheDecision(common: 0, toTrim: 0, reuseCache: false))
    }
}
