// Sources/ModelEngine/KVCacheManager.swift
// Manages KV cache lifecycle and memory reporting

import Foundation
import MLX
import MLXLMCommon

/// Manages KV cache settings and monitors cache memory usage.
public struct KVCacheManager: Sendable {

    public struct CacheConfig: Sendable {
        /// Number of bits for KV cache quantization. Supports integer (e.g. 4, 8) and
        /// fractional values (e.g. 2.5, 3.5) — fractional widths automatically select
        /// TurboQuant. nil means no quantization.
        public let kvBits: Float?
        public let kvGroupSize: Int
        public let kvQuantizationScheme: KVQuantizationScheme
        public let quantizedKVStart: Int
        public let maxCacheBytes: Int

        public init(
            kvBits: Float? = nil,
            kvGroupSize: Int = 64,
            kvQuantizationScheme: KVQuantizationScheme = .uniform,
            quantizedKVStart: Int = 0,
            maxCacheBytes: Int = 512 * 1024 * 1024 // 512 MB default
        ) {
            self.kvBits = kvBits
            self.kvGroupSize = kvGroupSize
            self.kvQuantizationScheme = kvQuantizationScheme
            self.quantizedKVStart = quantizedKVStart
            self.maxCacheBytes = maxCacheBytes
        }

        /// Whether this config uses TurboQuant as the KV cache backend.
        public var usesTurboQuant: Bool {
            turboquantEnabled(bits: kvBits, scheme: kvQuantizationScheme)
        }
    }

    /// Get current active memory usage (includes cache).
    public static func currentMemoryUsage() -> Int {
        let snapshot = MLX.Memory.snapshot()
        return snapshot.activeMemory
    }

    /// Check if active memory exceeds the configured cache limit.
    public static func isCacheOverBudget(config: CacheConfig) -> Bool {
        currentMemoryUsage() > config.maxCacheBytes
    }
}
