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
    var cachedTokens: [Int] = []

    /// Optional sink for lifecycle log lines (cache cleared / initialized).
    /// `AgentLoop` wires this to the frontend so cache events surface in the
    /// terminal. `@Sendable` because the store is `@unchecked Sendable` and this
    /// may be invoked from the generation `perform` closure.
    var log: (@Sendable (String) -> Void)?

    /// Set once we've told the user this model's KV cache cannot be trimmed
    /// (hybrid state-space/attention models like Qwen3.5's Mamba layers, or
    /// sliding-window caches), so the "reuse unavailable" notice prints a single
    /// time rather than on every turn. Reset by `invalidate` (e.g. model reload)
    /// so a different model gets re-probed.
    var reuseUnavailableAnnounced = false

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
        // A cleared store may precede a model swap; re-probe reuse capability.
        reuseUnavailableAnnounced = false
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

    /// Pure prompt-cache reuse decision.
    ///
    /// - Parameters:
    ///   - cachedTokens: token ids the persisted cache is *recorded* to hold, used
    ///     only for the prefix-identity diff.
    ///   - promptTokens: token ids for this turn's full ChatML prompt.
    ///   - cacheOffset: the cache's **live** physical token count (`KVCache.offset`).
    ///     This is authoritative for how many tokens to trim and can legitimately
    ///     exceed `cachedTokens.count`: on an EOS-terminated turn the iterator feeds
    ///     the stop token through one extra cache step that is never recorded in
    ///     `cachedTokens`, so the physical cache ends up one token longer. Trimming
    ///     to `cacheOffset - common` lands the cache exactly at the shared prefix.
    ///   - cacheIsReusable: whether a live, trimmable cache exists.
    /// - Returns: whether to reuse-and-trim vs. prefill fresh, plus the shared
    ///   prefix length and the number of tail tokens to trim.
    static func computePromptCacheDecision(
        cachedTokens: [Int],
        promptTokens: [Int],
        cacheOffset: Int,
        cacheIsReusable: Bool
    ) -> PromptCacheDecision {
        // Longest common prefix between the previously-cached tokens and the new
        // prompt. Anything past this point diverged and must be re-prefilled.
        var common = longestCommonPrefixLength(cachedTokens, promptTokens)

        // Always leave at least one token to feed the iterator — the underlying
        // prefill/generation step rejects an empty input.
        common = min(common, max(promptTokens.count - 1, 0))

        // Reuse only when there is a live trimmable cache AND a non-empty shared
        // prefix; otherwise a fresh full prefill is both correct and simpler.
        guard cacheIsReusable, common > 0 else {
            return PromptCacheDecision(common: 0, toTrim: 0, reuseCache: false)
        }

        // Trim relative to the cache's live offset (not `cachedTokens.count`) so the
        // post-trim offset equals `common` even when the cache carries a trailing
        // stop token beyond the recorded tokens.
        let toTrim = max(cacheOffset - common, 0)
        return PromptCacheDecision(common: common, toTrim: toTrim, reuseCache: true)
    }
}
