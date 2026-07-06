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
        // hasCache: false maps to the old cacheIsReusable: false behaviour.
        let decision = AgentLoop.computePromptCacheDecision(
            cachedTokens: [1, 2, 3],
            promptTokens: [1, 2, 3, 4],
            cacheOffset: 3,
            hasCache: false,
            cacheIsTrimmable: false
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
            hasCache: true,
            cacheIsTrimmable: true
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
            hasCache: true,
            cacheIsTrimmable: true
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
            hasCache: true,
            cacheIsTrimmable: true
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
            hasCache: true,
            cacheIsTrimmable: true
        )
        XCTAssertEqual(decision, PromptCacheDecision(common: 3, toTrim: 1, reuseCache: true))
    }

    func testDecisionDivergentFirstTokenFallsBackToFresh() {
        let decision = AgentLoop.computePromptCacheDecision(
            cachedTokens: [9, 2, 3],
            promptTokens: [1, 2, 3],
            cacheOffset: 3,
            hasCache: true,
            cacheIsTrimmable: true
        )
        XCTAssertEqual(decision, PromptCacheDecision(common: 0, toTrim: 0, reuseCache: false))
    }

    func testDecisionEmptyCacheFallsBackToFresh() {
        let decision = AgentLoop.computePromptCacheDecision(
            cachedTokens: [],
            promptTokens: [1, 2, 3],
            cacheOffset: 0,
            hasCache: true,
            cacheIsTrimmable: true
        )
        XCTAssertEqual(decision, PromptCacheDecision(common: 0, toTrim: 0, reuseCache: false))
    }

    func testDecisionCapWithSinglePromptToken() {
        // A one-token prompt can never reuse anything — capping to count-1 == 0.
        let decision = AgentLoop.computePromptCacheDecision(
            cachedTokens: [1],
            promptTokens: [1],
            cacheOffset: 1,
            hasCache: true,
            cacheIsTrimmable: true
        )
        XCTAssertEqual(decision, PromptCacheDecision(common: 0, toTrim: 0, reuseCache: false))
    }

    // MARK: - Non-trimmable cache (hybrid Mamba/attention, e.g. Qwen3.5)

    func testDecisionPureExtensionNonTrimmableReuses() {
        // Pure prefix extension (toTrim == 0) is valid for ANY cache type —
        // no trimming needed, just feed the suffix into the saved state.
        // This is the key lmstudio-parity fix: non-trimmable caches CAN be reused
        // when the new prompt is a strict extension of the cached tokens.
        let decision = AgentLoop.computePromptCacheDecision(
            cachedTokens: [1, 2, 3],
            promptTokens: [1, 2, 3, 4, 5],
            cacheOffset: 3,
            hasCache: true,
            cacheIsTrimmable: false
        )
        XCTAssertEqual(decision, PromptCacheDecision(common: 3, toTrim: 0, reuseCache: true))
    }

    func testDecisionDivergenceNonTrimmableDoesNotReuse() {
        // Diverged tail on a non-trimmable cache: cannot trim, so we must discard
        // the cache and re-prefill the full prompt. common and toTrim are still
        // returned so the caller can log why reuse was skipped.
        let decision = AgentLoop.computePromptCacheDecision(
            cachedTokens: [1, 2, 3, 9, 9],
            promptTokens: [1, 2, 3, 4, 5],
            cacheOffset: 5,
            hasCache: true,
            cacheIsTrimmable: false
        )
        XCTAssertEqual(decision, PromptCacheDecision(common: 3, toTrim: 2, reuseCache: false))
    }

    func testDecisionTrailingUnrecordedTokenNonTrimmableDoesNotReuse() {
        // Documents why the stop token MUST be recorded in cachedTokens.
        // If the physical cache advanced by an extra EOS token that was not appended
        // to cachedTokens (old behaviour before includeStopToken: true), then even
        // a pure extension will look like it needs a 1-token trim:
        //   cacheOffset=4 (3 recorded + 1 EOS in cache), common=3, toTrim=1
        // which is fatal for a non-trimmable cache.
        let decision = AgentLoop.computePromptCacheDecision(
            cachedTokens: [1, 2, 3],
            promptTokens: [1, 2, 3, 4, 5],
            cacheOffset: 4,        // cache physically holds one extra EOS not in cachedTokens
            hasCache: true,
            cacheIsTrimmable: false
        )
        // toTrim = max(4 - 3, 0) = 1 > 0 && !trimmable → reuseCache: false
        XCTAssertEqual(decision, PromptCacheDecision(common: 3, toTrim: 1, reuseCache: false))
    }

    func testDecisionTrailingUnrecordedTokenTrimmableReuses() {
        // Same scenario as above but on a TRIMMABLE cache: the 1-token offset
        // mismatch is handled by trimming, preserving the existing behaviour.
        let decision = AgentLoop.computePromptCacheDecision(
            cachedTokens: [1, 2, 3],
            promptTokens: [1, 2, 3, 4, 5],
            cacheOffset: 4,
            hasCache: true,
            cacheIsTrimmable: true
        )
        XCTAssertEqual(decision, PromptCacheDecision(common: 3, toTrim: 1, reuseCache: true))
    }

    // MARK: - computeCheckpointFallback

    func testCheckpointPurePrefixIsUsable() {
        // Checkpoint [1,2,3] is a pure prefix of prompt [1,2,3,4,5] with tokens left.
        let result = AgentLoop.computeCheckpointFallback(
            checkpointTokens: [1, 2, 3],
            promptTokens: [1, 2, 3, 4, 5]
        )
        XCTAssertEqual(result, AgentLoop.CheckpointFallbackDecision(prefillFrom: 3, useCheckpoint: true))
    }

    func testCheckpointDivergesInsideIsUnusable() {
        // Checkpoint [1,2,9] diverges from prompt [1,2,3,4,5] at position 2 —
        // not a pure prefix, so the checkpoint cannot be used.
        let result = AgentLoop.computeCheckpointFallback(
            checkpointTokens: [1, 2, 9],
            promptTokens: [1, 2, 3, 4, 5]
        )
        XCTAssertEqual(result, AgentLoop.CheckpointFallbackDecision(prefillFrom: 0, useCheckpoint: false))
    }

    func testCheckpointEmptyIsUnusable() {
        // No checkpoint recorded yet — must not attempt restore.
        let result = AgentLoop.computeCheckpointFallback(
            checkpointTokens: [],
            promptTokens: [1, 2, 3, 4, 5]
        )
        XCTAssertEqual(result, AgentLoop.CheckpointFallbackDecision(prefillFrom: 0, useCheckpoint: false))
    }

    func testCheckpointExactMatchNoTokensLeft() {
        // Checkpoint exactly equals the prompt — no token left to feed after restore.
        let result = AgentLoop.computeCheckpointFallback(
            checkpointTokens: [1, 2, 3],
            promptTokens: [1, 2, 3]
        )
        XCTAssertEqual(result, AgentLoop.CheckpointFallbackDecision(prefillFrom: 0, useCheckpoint: false))
    }

    func testCheckpointLongerThanPromptIsUnusable() {
        // Checkpoint [1,2,3,4,5] is longer than prompt [1,2,3] — LCP is at most 3
        // which is less than checkpointTokens.count (5), so not a pure prefix.
        let result = AgentLoop.computeCheckpointFallback(
            checkpointTokens: [1, 2, 3, 4, 5],
            promptTokens: [1, 2, 3]
        )
        XCTAssertEqual(result, AgentLoop.CheckpointFallbackDecision(prefillFrom: 0, useCheckpoint: false))
    }
}
