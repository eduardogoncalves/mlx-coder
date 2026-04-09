// Sources/TurboQuant/TurboQuantKVCache.swift
// Adapted from osaurus-ai/mlx-swift-lm (TurboQuant — arXiv:2504.19874, Google DeepMind)
// Original copyright © 2025 Osaurus & JANG. All rights reserved.
//
// Adaptations vs. upstream:
//   - Removed innerState() override: BaseKVCache.innerState() is `public` (not `open`),
//     so it cannot be overridden in an external module.
//   - Added auto-compression: transitions fill→compressed automatically on the first
//     single-token update after `minTokensForAutoCompress` tokens, allowing this cache
//     to be injected into the upstream TokenIterator without modifying upstream code.

import Foundation
import MLX
import MLXLMCommon

/// Phase of the TurboQuant KV cache lifecycle.
///
/// ```
/// FILL ──────────────────► COMPRESSED
///   (prefill, float KV)      (encoded prefix + float window)
///   append via update()      new tokens → window via update()
///                            attention reads unified float buffer
/// ```
public enum TQPhase: Sendable {
    /// Accumulating float KV during prefill. Standard KVCacheSimple behavior.
    case fill
    /// Prefix is compressed. New decode tokens go to float window.
    case compressed
}

/// TurboQuant-backed KV cache for a single attention layer.
///
/// ## Lifecycle
///
/// 1. **Fill phase** (prefill): Behaves identically to `KVCacheSimple`.
///    Float keys/values accumulate via `update()`. Zero overhead.
///
/// 2. **Auto-compress** (first single-token update after minTokensForAutoCompress):
///    Compresses accumulated float KV into packed format. The prefix is decoded
///    once into a persistent float buffer. Original float cache is freed.
///
/// 3. **Generate phase** (token-by-token): New tokens are scatter-written
///    into pre-allocated window slots in the unified buffer. Models see normal
///    float MLXArrays — no special handling needed.
///
/// ## Why Models Don't Need Changes
///
/// Unlike `QuantizedKVCache`, TurboQuant decodes back to float16. The unified
/// buffer is float16. Normal `update()` + `scaledDotProductAttention()` work
/// unchanged.
///
/// ## Memory Savings
///
/// For b=3 bits at head_dim=128: ~4.9× compression over float16.
/// Enables multi-turn sessions at 4× longer context for the same VRAM.
public final class TurboQuantKVCache: KVCache, @unchecked Sendable {

    public private(set) var offset: Int = 0
    public var maxSize: Int? { nil }

    public private(set) var phase: TQPhase = .fill

    // Fill phase storage
    private var floatKeys: MLXArray?
    private var floatValues: MLXArray?

    // Compressed phase storage
    public private(set) var compressedKeys: EncodedKeys?
    public private(set) var compressedValues: EncodedValues?

    // Decoded prefix (persistent float buffer for attention reads)
    private var decodedKeyBuffer: MLXArray?
    private var decodedValueBuffer: MLXArray?

    // Unified buffer: [decoded_prefix | window_slots]
    private var unifiedKeys: MLXArray?
    private var unifiedValues: MLXArray?

    /// Number of tokens in the decoded prefix.
    private var prefixTokenCount: Int = 0

    /// Pre-allocated window step size.
    private let windowStep = 256

    /// Number of tokens written into the window region of the unified buffer.
    private var windowOffset = 0

    /// Encoder state (codebooks, rotation signs, QJL matrix).
    private var encoderState: TQEncoder.EncoderState?

    // Configuration
    public let keyBits: Int
    public let valueBits: Int
    public let sinkTokens: Int

    /// Minimum tokens before auto-compression triggers on first single-token update.
    /// Avoids compressing very short caches where overhead exceeds benefit.
    public let minTokensForAutoCompress: Int

    // MARK: - Init

    /// Create a TurboQuantKVCache in fill phase.
    ///
    /// The cache auto-compresses on the first single-token update (generation phase)
    /// after `minTokensForAutoCompress` tokens have been accumulated.
    ///
    /// - Parameters:
    ///   - keyBits: Total bits per key element (e.g., 3 = 2-bit codebook + 1-bit QJL)
    ///   - valueBits: Total bits per value element (e.g., 3 = 3-bit codebook)
    ///   - sinkTokens: Leading tokens preserved at full precision (default 4)
    ///   - minTokensForAutoCompress: Minimum context before triggering compression (default 32)
    public init(
        keyBits: Int = 3,
        valueBits: Int = 3,
        sinkTokens: Int = 4,
        minTokensForAutoCompress: Int = 32
    ) {
        self.keyBits = keyBits
        self.valueBits = valueBits
        self.sinkTokens = sinkTokens
        self.minTokensForAutoCompress = minTokensForAutoCompress
    }

    // MARK: - Create from KVCacheSimple

    /// Convert a KVCacheSimple to TurboQuantKVCache by compressing its contents.
    ///
    /// This is an alternative entry point (vs. creating an empty fill-phase cache)
    /// when you want to compress an existing cache immediately.
    public static func fromSimpleCache(
        _ source: KVCacheSimple,
        keyBits: Int,
        valueBits: Int,
        sinkTokens: Int = 4
    ) -> TurboQuantKVCache {
        let tqCache = TurboQuantKVCache(
            keyBits: keyBits, valueBits: valueBits, sinkTokens: sinkTokens)

        let state = source.state
        guard state.count == 2 else { return tqCache }

        let keys = state[0]
        let values = state[1]

        guard keys.ndim == 4, values.ndim == 4, source.offset > 0 else {
            return tqCache
        }

        tqCache.compressFloatKV(keys: keys, values: values, sourceOffset: source.offset)
        return tqCache
    }

    // MARK: - Compression

    private func compressFloatKV(keys: MLXArray, values: MLXArray, sourceOffset: Int) {
        let dim = keys.dim(keys.ndim - 1)

        let state = TQEncoder.EncoderState(
            dim: dim, keyBits: keyBits, valueBits: valueBits)
        self.encoderState = state

        let encodedKeys = TQEncoder.encodeKeys(keys, state: state, sinkTokens: sinkTokens)
        let encodedValues = TQEncoder.encodeValues(values, state: state, sinkTokens: sinkTokens)

        // Materialize encoded tensors eagerly to prevent the lazy evaluation graph
        // from growing excessively large across many layers.
        MLX.eval(
            encodedKeys.indicesPacked, encodedKeys.qjlPacked,
            encodedKeys.residualNorms, encodedKeys.vectorNorms)
        MLX.eval(encodedValues.indicesPacked, encodedValues.vectorNorms)

        let dKeys = TQEncoder.decodeKeys(encodedKeys, state: state)
        let dValues = TQEncoder.decodeValues(encodedValues, state: state)

        self.compressedKeys = encodedKeys
        self.compressedValues = encodedValues
        self.decodedKeyBuffer = dKeys
        self.decodedValueBuffer = dValues
        self.prefixTokenCount = dKeys.dim(2)

        let B = dKeys.dim(0), H = dKeys.dim(1)
        let kD = dKeys.dim(3), vD = dValues.dim(3)
        let windowK = MLXArray.zeros([B, H, windowStep, kD], dtype: dKeys.dtype)
        let windowV = MLXArray.zeros([B, H, windowStep, vD], dtype: dValues.dtype)
        self.unifiedKeys = concatenated([dKeys, windowK], axis: 2)
        self.unifiedValues = concatenated([dValues, windowV], axis: 2)
        self.windowOffset = 0

        self.phase = .compressed
        self.offset = sourceOffset

        self.floatKeys = nil
        self.floatValues = nil
    }

    // MARK: - KVCache Protocol

    public func update(keys: MLXArray, values: MLXArray) -> (MLXArray, MLXArray) {
        switch phase {
        case .fill:
            return appendFloat(keys: keys, values: values)
        case .compressed:
            return appendDecodeTokens(keys: keys, values: values)
        }
    }

    private func appendFloat(keys: MLXArray, values: MLXArray) -> (MLXArray, MLXArray) {
        if var existingKeys = floatKeys, var existingValues = floatValues {
            if offset < existingKeys.dim(2) {
                existingKeys = existingKeys[.ellipsis, ..<offset, 0...]
                existingValues = existingValues[.ellipsis, ..<offset, 0...]
            }
            floatKeys = concatenated([existingKeys, keys], axis: 2)
            floatValues = concatenated([existingValues, values], axis: 2)
        } else {
            floatKeys = keys
            floatValues = values
        }
        offset += keys.dim(2)

        // Auto-compress: on the first single-token update after enough context,
        // transition from fill to compressed phase. This allows TurboQuantKVCache
        // to be used transparently inside upstream TokenIterator without external hooks.
        if keys.dim(2) == 1, offset >= minTokensForAutoCompress {
            let fk = floatKeys!, fv = floatValues!
            compressFloatKV(keys: fk, values: fv, sourceOffset: offset)
            let totalTokens = prefixTokenCount + windowOffset
            return (
                unifiedKeys![.ellipsis, ..<totalTokens, 0...],
                unifiedValues![.ellipsis, ..<totalTokens, 0...]
            )
        }

        return (floatKeys!, floatValues!)
    }

    private func appendDecodeTokens(keys: MLXArray, values: MLXArray) -> (MLXArray, MLXArray) {
        let newTokens = keys.dim(2)
        offset += newTokens

        let writePos = prefixTokenCount + windowOffset

        let needsRealloc: Bool
        if let existing = unifiedKeys {
            needsRealloc = (writePos + newTokens) > existing.dim(2)
        } else {
            needsRealloc = true
        }

        if needsRealloc {
            let B = keys.dim(0), H = keys.dim(1)
            let kD = keys.dim(3), vD = values.dim(3)
            let nSteps = max(1, (windowStep + newTokens - 1) / windowStep)
            let newK = MLXArray.zeros([B, H, nSteps * windowStep, kD], dtype: keys.dtype)
            let newV = MLXArray.zeros([B, H, nSteps * windowStep, vD], dtype: values.dtype)

            if let existingKeys = unifiedKeys, let existingValues = unifiedValues, writePos > 0 {
                unifiedKeys = concatenated(
                    [existingKeys[.ellipsis, ..<writePos, 0...], newK], axis: 2)
                unifiedValues = concatenated(
                    [existingValues[.ellipsis, ..<writePos, 0...], newV], axis: 2)
            } else {
                unifiedKeys = newK
                unifiedValues = newV
            }
        }

        unifiedKeys?[.ellipsis, writePos..<(writePos + newTokens), 0...] = keys
        unifiedValues?[.ellipsis, writePos..<(writePos + newTokens), 0...] = values
        windowOffset += newTokens

        let totalTokens = prefixTokenCount + windowOffset
        return (
            unifiedKeys![.ellipsis, ..<totalTokens, 0...],
            unifiedValues![.ellipsis, ..<totalTokens, 0...]
        )
    }

    // MARK: - State

    public var state: [MLXArray] {
        get {
            switch phase {
            case .fill:
                guard let keys = floatKeys, let values = floatValues else { return [] }
                if offset < keys.dim(2) {
                    return [
                        keys[.ellipsis, ..<offset, 0...],
                        values[.ellipsis, ..<offset, 0...],
                    ]
                }
                return [keys, values]
            case .compressed:
                let totalTokens = prefixTokenCount + windowOffset
                guard let uk = unifiedKeys, let uv = unifiedValues, totalTokens > 0 else {
                    return []
                }
                return [
                    uk[.ellipsis, ..<totalTokens, 0...],
                    uv[.ellipsis, ..<totalTokens, 0...],
                ]
            }
        }
        set {
            if newValue.count >= 2 {
                resetToEmpty()
                floatKeys = newValue[0]
                floatValues = newValue[1]
                offset = newValue[0].dim(2)
                phase = .fill
            } else {
                resetToEmpty()
            }
        }
    }

    public var metaState: [String] {
        get { [""] }
        set { }
    }

    // MARK: - Trim

    public var isTrimmable: Bool { true }

    @discardableResult
    public func trim(_ n: Int) -> Int {
        let trimmed = min(offset, n)
        guard trimmed > 0 else { return 0 }

        let targetOffset = offset - trimmed
        guard targetOffset > 0 else {
            resetToEmpty()
            return trimmed
        }

        switch phase {
        case .fill:
            offset = targetOffset
            return trimmed

        case .compressed:
            let totalUsedTokens = prefixTokenCount + windowOffset

            if targetOffset >= prefixTokenCount && targetOffset <= totalUsedTokens {
                // Fast path: trim within window only — O(1)
                windowOffset = targetOffset - prefixTokenCount
                offset = targetOffset
                return trimmed
            }

            // Slow path: trim reaches into compressed prefix — decode, truncate, re-compress.
            let totalTokens = prefixTokenCount + windowOffset
            guard let uk = unifiedKeys, let uv = unifiedValues, totalTokens > 0 else {
                resetToEmpty()
                return trimmed
            }

            let fullKeys = uk[.ellipsis, ..<totalTokens, 0...]
            let fullValues = uv[.ellipsis, ..<totalTokens, 0...]
            let trimmedKeys = fullKeys[.ellipsis, ..<targetOffset, 0...]
            let trimmedValues = fullValues[.ellipsis, ..<targetOffset, 0...]

            resetToEmpty()
            compressFloatKV(
                keys: trimmedKeys, values: trimmedValues, sourceOffset: targetOffset)
            return trimmed
        }
    }

    // MARK: - Copy

    public func copy() -> any KVCache {
        let new = TurboQuantKVCache(
            keyBits: keyBits, valueBits: valueBits, sinkTokens: sinkTokens,
            minTokensForAutoCompress: minTokensForAutoCompress)
        new.phase = phase
        new.offset = offset
        new.prefixTokenCount = prefixTokenCount
        new.windowOffset = windowOffset
        new.encoderState = encoderState

        new.compressedKeys = compressedKeys
        new.compressedValues = compressedValues

        new.floatKeys = floatKeys.map { $0[.ellipsis] }
        new.floatValues = floatValues.map { $0[.ellipsis] }
        new.decodedKeyBuffer = decodedKeyBuffer.map { $0[.ellipsis] }
        new.decodedValueBuffer = decodedValueBuffer.map { $0[.ellipsis] }
        new.unifiedKeys = unifiedKeys.map { $0[.ellipsis] }
        new.unifiedValues = unifiedValues.map { $0[.ellipsis] }

        return new
    }

    // MARK: - Helpers

    private func resetToEmpty() {
        phase = .fill
        floatKeys = nil
        floatValues = nil
        compressedKeys = nil
        compressedValues = nil
        decodedKeyBuffer = nil
        decodedValueBuffer = nil
        unifiedKeys = nil
        unifiedValues = nil
        windowOffset = 0
        prefixTokenCount = 0
        offset = 0
        encoderState = nil
    }

    public func innerState() -> [MLXArray] {
        switch phase {
        case .fill:
            var arrays: [MLXArray] = []
            if let floatKeys { arrays.append(floatKeys) }
            if let floatValues { arrays.append(floatValues) }
            return arrays
        case .compressed:
            var arrays: [MLXArray] = []
            if let unifiedKeys { arrays.append(unifiedKeys) }
            if let unifiedValues { arrays.append(unifiedValues) }
            return arrays
        }
    }

    public func makeMask(
        n: Int,
        windowSize: Int?,
        returnArray: Bool
    ) -> MLXFast.ScaledDotProductAttentionMaskMode {
        if n == 1 {
            return .none
        }

        if returnArray || (windowSize != nil && n > windowSize!) {
            return .array(createCausalMask(n: n, offset: offset, windowSize: windowSize))
        }

        return .causal
    }
}

// MARK: - Cache Creation Helper

/// Replace KVCacheSimple layers with TurboQuantKVCache layers in a model's default cache.
///
/// Sliding-window (RotatingKVCache) and other non-standard cache types are preserved as-is.
/// TurboQuantKVCache starts in fill phase and auto-compresses after prefill.
///
/// - Parameters:
///   - model: The language model (used to create the baseline cache structure).
///   - parameters: Generation parameters (passed to model.newCache).
///   - keyBits: Key compression bits (default 3).
///   - valueBits: Value compression bits (default 3).
/// - Returns: Cache array with KVCacheSimple layers replaced by TurboQuantKVCache.
public func makeTurboQuantCaches(
    model: any LanguageModel,
    parameters: GenerateParameters,
    keyBits: Int = 3,
    valueBits: Int = 3
) -> [any KVCache] {
    let baseCaches = model.newCache(parameters: parameters)
    return baseCaches.map { cache in
        cache is KVCacheSimple
            ? TurboQuantKVCache(keyBits: keyBits, valueBits: valueBits)
            : cache
    }
}
