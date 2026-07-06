// Sources/AgentCore/PromptCacheStore.swift
// Cross-turn persistent KV (prompt) cache storage and pure decision logic.

import Foundation
import MLXLMCommon

/// Holds the live KV cache from the previous turn together with the exact token
/// sequence that cache physically contains, so the next turn can reuse the
/// shared prefix instead of re-prefilling the whole prompt (mlx_lm.server-style).
///
/// `[KVCache]` is **not** `Sendable`, and `ModelContainer.perform` isolates the
/// model. To persist the cache across turns while keeping every MLX manipulation
/// confined to the `perform` closure, we box the cache in an `@unchecked Sendable`
/// reference type. This is safe here because `AgentLoop` is an actor and turns
/// are serial — only one `perform` closure ever touches the store at a time.
final class PromptCacheStore: @unchecked Sendable {
    /// The live KV cache carried over from the previous turn, or `nil` when there
    /// is nothing reusable (first turn, unsupported path, or after invalidation).
    var cache: [KVCache]?

    /// The exact token ids the `cache` physically contains — this is
    /// `promptTokens + generatedTokenIds` from the turn that produced it. The
    /// next turn diffs its own prompt tokens against this to find the reusable
    /// prefix, so it MUST mirror what the cache actually holds.
    ///
    /// With `includeStopToken: true` on the generation call, the EOS token is now
    /// emitted and appended to `generatedTokenIds`, so `cachedTokens` includes it
    /// and the physical cache offset equals `cachedTokens.count` for normal turns.
    var cachedTokens: [Int] = []

    /// mlx-engine-style checkpoint: a snapshot of the KV cache taken right after
    /// bulk-prefilling the stable portion of the prompt (all tokens except the last
    /// `checkpointTailTokens`). On the next turn, if the live cache diverges (which
    /// happens on non-trimmable hybrid Mamba models when thinking-block tokens are
    /// retroactively stripped from the re-rendered prompt), the checkpoint is
    /// restored instead — it is still a pure prefix of the new prompt, so no
    /// trimming is required. This bypasses the Mamba non-trimmable constraint.
    ///
    /// `copy()` on each `KVCache` materialises the tensor state, so later mutation
    /// of the live cache cannot affect the snapshot.
    var checkpointCache: [KVCache]?

    /// The token ids the `checkpointCache` physically contains — i.e.,
    /// `promptTokens.prefix(promptTokens.count - checkpointTailTokens)` from the
    /// turn that produced it. Used to verify that the checkpoint is still a pure
    /// prefix of the new turn's prompt before restoring it.
    var checkpointTokens: [Int] = []

    /// Number of prompt-tail tokens excluded from the checkpoint snapshot.
    ///
    /// The volatile portion of a prompt (generation-header tokens like `<think>\n`,
    /// which are retroactively stripped when a thinking-block response is re-rendered
    /// on the next turn) lives at the very end. Snapshotting `promptLen - tailMargin`
    /// tokens keeps the checkpoint safely upstream of that region, so it remains a
    /// pure prefix of the next turn's prompt even after the tail diverges.
    ///
    /// mlx-engine uses 11; 16 gives extra margin — the observed divergence in real
    /// traces was 2 tokens before the prompt end, well within this window.
    static let checkpointTailTokens = 16

    /// Optional sink for lifecycle log lines (cache cleared / initialized).
    /// `AgentLoop` wires this to the frontend so cache events surface in the
    /// terminal. `@Sendable` because the store is `@unchecked Sendable` and this
    /// may be invoked from the generation `perform` closure.
    var log: (@Sendable (String) -> Void)?

    /// Drop the persisted cache so a stale or partially-written cache is never
    /// reused. Called whenever the prompt prefix could have changed out from
    /// under the cache (system-prompt replacement, compaction, model reload) or
    /// when generation fails/cancels mid-stream.
    ///
    /// - Parameter reason: short human-readable cause, surfaced in the log line.
    func invalidate(reason: String = "") {
        let hadCache = cache != nil
        cache = nil
        cachedTokens = []
        checkpointCache = nil
        checkpointTokens = []
        // Only announce a real drop: `invalidate()` is also called defensively on
        // every non-cacheable turn (VLM / speculative / TurboQuant), where there
        // is nothing to clear and a log line would just be noise.
        if hadCache {
            let suffix = reason.isEmpty ? "" : " (\(reason))"
            log?("[PromptCache] cleared\(suffix)")
        }
    }
}

/// The decision for how to (re)use the persistent cache on a given turn.
///
/// Factored out as a pure value so the prefix/trim arithmetic can be unit-tested
/// without a loaded model.
struct PromptCacheDecision: Equatable {
    /// Longest common prefix length between the cached tokens and this turn's
    /// prompt tokens, capped so at least one token is always fed to the iterator.
    let common: Int

    /// Number of tokens to trim off the tail of the existing cache to bring it
    /// back to the shared prefix. Zero when the cache is already an exact prefix.
    let toTrim: Int

    /// When `true`, trim the existing cache to `common` and feed only the suffix
    /// `promptTokens[common...]`. When `false`, ignore the existing cache and
    /// prefill the entire prompt into a fresh cache.
    let reuseCache: Bool
}

extension AgentLoop {

    /// Length of the longest shared prefix between two token sequences.
    static func longestCommonPrefixLength(_ a: [Int], _ b: [Int]) -> Int {
        let bound = min(a.count, b.count)
        var i = 0
        while i < bound && a[i] == b[i] {
            i += 1
        }
        return i
    }

    /// Pure prompt-cache reuse decision — mirrors mlx-engine (lmstudio) semantics.
    ///
    /// A cache whose tokens are a **pure prefix** of the new prompt (toTrim == 0)
    /// can always be reused regardless of cache type — feeding the suffix simply
    /// continues from the exact saved state, and no trimming is needed.  Trimming
    /// is only required when the new prompt diverges before the end of the cache;
    /// only then must a non-trimmable cache be discarded (full re-prefill into a
    /// fresh cache, but caching remains enabled for the next turn).
    ///
    /// - Parameters:
    ///   - cachedTokens: token ids the persisted cache is *recorded* to hold, used
    ///     only for the prefix-identity diff.
    ///   - promptTokens: token ids for this turn's full ChatML prompt.
    ///   - cacheOffset: the cache's **live** physical token count.
    ///     For hybrid models (e.g. Qwen3.5) this should be the **max** offset
    ///     across all cache layers — MambaCache layers never update their `offset`
    ///     property (always 0), so only KVCacheSimple (attention) layers reflect
    ///     the true physical depth. Trimming to `cacheOffset - common` lands the
    ///     cache exactly at the shared prefix.
    ///     With `includeStopToken: true` on the generation call, the EOS token is
    ///     appended to `cachedTokens`, so `cacheOffset` should normally equal
    ///     `cachedTokens.count`; the math is a safety net either way.
    ///   - hasCache: whether a live cache exists from a prior turn.
    ///   - cacheIsTrimmable: whether every layer in the cache supports trimming
    ///     (i.e. `canTrimPromptCache` returns true). Hybrid models with MambaCache
    ///     layers return false here, but can still reuse when toTrim == 0.
    /// - Returns: whether to reuse-and-trim vs. prefill fresh, plus the shared
    ///   prefix length and the number of tail tokens to trim.
    static func computePromptCacheDecision(
        cachedTokens: [Int],
        promptTokens: [Int],
        cacheOffset: Int,
        hasCache: Bool,
        cacheIsTrimmable: Bool
    ) -> PromptCacheDecision {
        // Longest common prefix between the previously-cached tokens and the new
        // prompt. Anything past this point diverged and must be re-prefilled.
        var common = longestCommonPrefixLength(cachedTokens, promptTokens)

        // Always leave at least one token to feed the iterator — the underlying
        // prefill/generation step rejects an empty input.
        common = min(common, max(promptTokens.count - 1, 0))

        // Reuse only when there is a live cache AND a non-empty shared prefix;
        // otherwise a fresh full prefill is both correct and simpler.
        guard hasCache, common > 0 else {
            return PromptCacheDecision(common: 0, toTrim: 0, reuseCache: false)
        }

        // Trim relative to the cache's live offset (not `cachedTokens.count`) so
        // the post-trim offset equals `common` even when the cache carries a
        // trailing stop token beyond the recorded tokens.
        let toTrim = max(cacheOffset - common, 0)

        if toTrim == 0 {
            // Pure prefix extension — valid for any cache type (attention, Mamba,
            // rotating): feeding the suffix just continues from the saved state.
            return PromptCacheDecision(common: common, toTrim: 0, reuseCache: true)
        } else if cacheIsTrimmable {
            // Diverged tail, but every layer can be trimmed back.
            return PromptCacheDecision(common: common, toTrim: toTrim, reuseCache: true)
        } else {
            // Diverged tail on a non-trimmable cache (e.g. hybrid Mamba/attention).
            // Return the computed values so the caller can log why reuse was skipped,
            // but reuseCache is false — the caller must re-prefill into a fresh cache.
            return PromptCacheDecision(common: common, toTrim: toTrim, reuseCache: false)
        }
    }

    /// Decision returned by `computeCheckpointFallback`.
    struct CheckpointFallbackDecision: Equatable {
        /// Number of tokens already prefilled in the checkpoint cache — i.e. the
        /// index into the new prompt from which the caller must still prefill.
        let prefillFrom: Int
        /// `true` when the checkpoint is a valid pure prefix of the new prompt and
        /// at least one prompt token remains to be fed after restoring it.
        let useCheckpoint: Bool
    }

    /// Pure decision helper for the mlx-engine checkpoint fallback path.
    ///
    /// On non-trimmable hybrid models (e.g. Qwen3.5 with Mamba layers), the live
    /// cache cannot be trimmed when the new prompt diverges in the tail. Instead of
    /// re-prefilling the entire prompt, we try to restore a checkpoint snapshot that
    /// was taken before the volatile tail tokens. If the checkpoint is still a pure
    /// prefix of the new prompt, restoring it requires zero trimming and we only need
    /// to prefill the delta.
    ///
    /// - Parameters:
    ///   - checkpointTokens: token ids recorded in the checkpoint (the stable prefix).
    ///   - promptTokens: token ids for the new turn's full prompt.
    /// - Returns: whether the checkpoint is usable and the index to resume from.
    static func computeCheckpointFallback(
        checkpointTokens: [Int],
        promptTokens: [Int]
    ) -> CheckpointFallbackDecision {
        guard !checkpointTokens.isEmpty else {
            return CheckpointFallbackDecision(prefillFrom: 0, useCheckpoint: false)
        }
        let lcp = longestCommonPrefixLength(checkpointTokens, promptTokens)
        // The checkpoint must be a pure prefix of the new prompt (every checkpoint
        // token matches), and at least one prompt token must remain to be fed.
        let isPurePrefix = lcp == checkpointTokens.count
        let hasTokensLeft = checkpointTokens.count <= promptTokens.count - 1
        guard isPurePrefix && hasTokensLeft else {
            return CheckpointFallbackDecision(prefillFrom: 0, useCheckpoint: false)
        }
        return CheckpointFallbackDecision(
            prefillFrom: checkpointTokens.count,
            useCheckpoint: true
        )
    }
}
