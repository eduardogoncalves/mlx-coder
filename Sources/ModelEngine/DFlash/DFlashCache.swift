import Foundation
import MLX

/// Minimal KV cache for the DFlash draft model.
///
/// The draft attention manages context and proposal keys itself (see
/// `DFlashAttention`), so this cache only needs to store the *context* keys/values
/// and support the trim + sliding-window behaviour the draft loop relies on. We use
/// our own type (rather than the package `KVCache`) because the draft's
/// `_trim_recent_cache` semantics need direct access to the stored tensors and a
/// monotonic absolute `offset`.
///
/// Keys/values are stored as `[B, H, S, D]` with RoPE already applied (the draft
/// applies RoPE before inserting). `offset` tracks the absolute position of the next
/// token to be inserted. For sliding layers we retain only the most recent
/// `maxSize` tokens; `offset` keeps growing regardless so RoPE positions stay
/// absolute.
final class DFlashCache {
    private(set) var keys: MLXArray?
    private(set) var values: MLXArray?
    /// Absolute position of the next token (monotonic, like mlx-lm RotatingKVCache).
    var offset: Int = 0
    /// Maximum retained tokens for sliding layers; `nil` for full attention.
    let maxSize: Int?

    init(maxSize: Int? = nil) {
        self.maxSize = maxSize
    }

    /// Materialized tensors, for `eval` to bound graph growth between blocks.
    var evalArrays: [MLXArray] {
        [keys, values].compactMap { $0 }
    }

    /// Append context keys/values and return all retained keys/values.
    func update(keys newKeys: MLXArray, values newValues: MLXArray) -> (MLXArray, MLXArray) {
        let added = newKeys.dim(2)
        if let existing = keys, let existingValues = values {
            keys = concatenated([existing, newKeys], axis: 2)
            values = concatenated([existingValues, newValues], axis: 2)
        } else {
            keys = newKeys
            values = newValues
        }
        offset += added

        if let maxSize, let k = keys, k.dim(2) > maxSize {
            keys = k[.ellipsis, (k.dim(2) - maxSize)..., 0...]
            values = values![.ellipsis, (values!.dim(2) - maxSize)..., 0...]
        }
        return (keys!, values!)
    }

    /// Drop the `n` most-recently-inserted tokens (mirrors `_trim_recent_cache`).
    func trim(_ n: Int) {
        guard n > 0 else { return }
        let trimmed = min(offset, n)
        offset -= trimmed
        guard let k = keys else { return }
        let stored = k.dim(2)
        let keep = max(0, stored - trimmed)
        if keep == 0 {
            keys = nil
            values = nil
        } else {
            keys = k[.ellipsis, ..<keep, 0...]
            values = values![.ellipsis, ..<keep, 0...]
        }
    }
}
