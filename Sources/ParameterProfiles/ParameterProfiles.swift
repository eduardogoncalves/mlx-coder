// Sources/ParameterProfiles/ParameterProfiles.swift
// Per-chip generation parameter presets

import Foundation

/// Pre-configured generation profiles optimized for different Apple Silicon chips.
public struct ParameterProfile: Sendable {
    public let maxTokens: Int
    public let kvBits: Int?
    public let kvGroupSize: Int
    /// The transformer layer index at which KV-cache quantization begins.
    /// 0 means all layers are quantized (maximum memory savings).
    public let quantizedKVStart: Int
    public let maxCacheBytes: Int
    public let temperature: Float
    public let topP: Float
    public let topK: Int
    public let minP: Float
    public let presencePenalty: Float?
    public let repetitionPenalty: Float?
    public let longContextThreshold: Int
    /// TurboQuant KV cache bit-width, or nil to rely on the long-context auto-enable.
    /// Standard mlx-lm kvBits quantization is stripped before generation (QuantizedKVCache.update()
    /// crashes some model types), so TurboQuant is the only per-turn KV compression path.
    public let turboQuantBits: Int?

    /// Profile for M1 8GB — most constrained. TurboQuant on by default: fp16 KV cache
    /// for even moderate contexts would exhaust available unified memory.
    public static let m1_8gb = ParameterProfile(
        maxTokens: 2048,
        kvBits: 4,
        kvGroupSize: 64,
        quantizedKVStart: 0,
        maxCacheBytes: 512 * 1024 * 1024,  // 512 MB
        temperature: 0.6,
        topP: 1.0,
        topK: 0,
        minP: 0.0,
        presencePenalty: nil,
        repetitionPenalty: nil,
        longContextThreshold: 4096,
        turboQuantBits: 3
    )

    /// Profile for M1/M2 16GB.
    public static let standard_16gb = ParameterProfile(
        maxTokens: 4096,
        kvBits: 4,
        kvGroupSize: 64,
        quantizedKVStart: 0,
        maxCacheBytes: 1024 * 1024 * 1024,  // 1 GB
        temperature: 0.6,
        topP: 1.0,
        topK: 0,
        minP: 0.0,
        presencePenalty: nil,
        repetitionPenalty: nil,
        longContextThreshold: 8192,
        turboQuantBits: nil
    )

    /// Profile for M2+/M3+/M4+ with 16–23GB.
    public static let performant = ParameterProfile(
        maxTokens: 8192,
        kvBits: 4,
        kvGroupSize: 64,
        quantizedKVStart: 0,
        maxCacheBytes: 2048 * 1024 * 1024,  // 2 GB
        temperature: 0.6,
        topP: 1.0,
        topK: 0,
        minP: 0.0,
        presencePenalty: nil,
        repetitionPenalty: nil,
        longContextThreshold: 16384,
        turboQuantBits: nil
    )

    /// Profile for M5 and any chip with 24GB+ unified memory.
    /// Higher token budget and a larger long-context threshold (fp16 KV stays affordable
    /// at 32k tokens on these chips before TurboQuant auto-activates).
    public static let high_memory = ParameterProfile(
        maxTokens: 16384,
        kvBits: 4,
        kvGroupSize: 64,
        quantizedKVStart: 0,
        maxCacheBytes: 6 * 1024 * 1024 * 1024,  // 6 GB
        temperature: 0.6,
        topP: 1.0,
        topK: 0,
        minP: 0.0,
        presencePenalty: nil,
        repetitionPenalty: nil,
        longContextThreshold: 32768,
        turboQuantBits: nil
    )

    /// Select the best profile for the detected chip.
    public static func forChip(_ chip: ChipDetector.ChipInfo) -> ParameterProfile {
        let totalGB = chip.totalMemoryGB
        switch chip.family {
        case .m1 where totalGB <= 8:
            return .m1_8gb
        case .m1, .m2:
            return .standard_16gb
        case .m5:
            // M5 always routes to high-memory regardless of exact GB — base M5 starts at 24GB.
            return .high_memory
        case .m3, .m4, .unknown:
            if totalGB >= 24 { return .high_memory }
            return totalGB >= 16 ? .performant : .standard_16gb
        }
    }
}
