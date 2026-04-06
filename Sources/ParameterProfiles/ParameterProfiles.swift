// Sources/ParameterProfiles/ParameterProfiles.swift
// Per-chip generation parameter presets

import Foundation
import MLXLMCommon

/// Pre-configured generation profiles optimized for different Apple Silicon chips.
public struct ParameterProfile: Sendable {
    public let maxTokens: Int
    /// Bits for KV cache quantization. Supports integer (4, 8) and fractional
    /// values (2.5, 3.5) — fractional widths automatically select TurboQuant.
    public let kvBits: Float?
    public let kvGroupSize: Int
    /// Explicit quantization scheme override. Use `.turboQuant` to force TurboQuant
    /// even for integer bit widths.
    public let kvQuantizationScheme: KVQuantizationScheme
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

    public init(
        maxTokens: Int,
        kvBits: Float?,
        kvGroupSize: Int,
        kvQuantizationScheme: KVQuantizationScheme = .uniform,
        quantizedKVStart: Int,
        maxCacheBytes: Int,
        temperature: Float,
        topP: Float,
        topK: Int,
        minP: Float,
        presencePenalty: Float?,
        repetitionPenalty: Float?,
        longContextThreshold: Int
    ) {
        self.maxTokens = maxTokens
        self.kvBits = kvBits
        self.kvGroupSize = kvGroupSize
        self.kvQuantizationScheme = kvQuantizationScheme
        self.quantizedKVStart = quantizedKVStart
        self.maxCacheBytes = maxCacheBytes
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.minP = minP
        self.presencePenalty = presencePenalty
        self.repetitionPenalty = repetitionPenalty
        self.longContextThreshold = longContextThreshold
    }

    /// Profile for M1 8GB — most constrained. Uses TurboQuant at 2.5 bits for
    /// maximum memory savings while preserving attention quality.
    public static let m1_8gb = ParameterProfile(
        maxTokens: 2048,
        kvBits: 2.5,
        kvGroupSize: 64,
        kvQuantizationScheme: .turboQuant,
        quantizedKVStart: 0,
        maxCacheBytes: 512 * 1024 * 1024,  // 512 MB
        temperature: 0.6,
        topP: 1.0,
        topK: 0,
        minP: 0.0,
        presencePenalty: nil,
        repetitionPenalty: nil,
        longContextThreshold: 4096
    )

    /// Profile for M1/M2 16GB.
    public static let standard_16gb = ParameterProfile(
        maxTokens: 4096,
        kvBits: 4, // 4-bit by default
        kvGroupSize: 64,
        quantizedKVStart: 0,
        maxCacheBytes: 1024 * 1024 * 1024,  // 1 GB
        temperature: 0.6,
        topP: 1.0,
        topK: 0,
        minP: 0.0,
        presencePenalty: nil,
        repetitionPenalty: nil,
        longContextThreshold: 8192
    )

    /// Profile for M2+/M3+/M4+ with 16GB+.
    public static let performant = ParameterProfile(
        maxTokens: 8192,
        kvBits: 4, // 4-bit by default
        kvGroupSize: 64,
        quantizedKVStart: 0,
        maxCacheBytes: 2048 * 1024 * 1024,  // 2 GB
        temperature: 0.6,
        topP: 1.0,
        topK: 0,
        minP: 0.0,
        presencePenalty: nil,
        repetitionPenalty: nil,
        longContextThreshold: 16384
    )

    /// Select the best profile for the detected chip.
    public static func forChip(_ chip: ChipDetector.ChipInfo) -> ParameterProfile {
        let totalGB = chip.totalMemoryGB
        switch chip.family {
        case .m1 where totalGB <= 8:
            return .m1_8gb
        case .m1, .m2:
            return .standard_16gb
        case .m3, .m4, .m5, .unknown:
            return totalGB >= 16 ? .performant : .standard_16gb
        }
    }
}
