// Sources/ModelEngine/KVCacheManager.swift
// Manages KV cache lifecycle and memory reporting

import Foundation
import MLX

/// Manages KV cache settings and monitors cache memory usage.
public struct KVCacheManager: Sendable {

    public struct CacheConfig: Sendable {
        public let kvBits: Int?
        public let kvGroupSize: Int
        public let quantizedKVStart: Int
        public let maxCacheBytes: Int

        public init(
            kvBits: Int? = nil,
            kvGroupSize: Int = 64,
            quantizedKVStart: Int = 0,
            maxCacheBytes: Int = 512 * 1024 * 1024 // 512 MB default
        ) {
            self.kvBits = kvBits
            self.kvGroupSize = kvGroupSize
            self.quantizedKVStart = quantizedKVStart
            self.maxCacheBytes = maxCacheBytes
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
