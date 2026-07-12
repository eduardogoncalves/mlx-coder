// Sources/MemoryManagement/MemoryGuard.swift
// Enforces memory budget for model + cache + runtime

import Foundation
import MLX

/// Enforces the 6.8 GB total memory budget.
/// Budget breakdown: ~4 GB model weights, ~1.5 GB KV cache, ~1.3 GB runtime.
public struct MemoryGuard: Sendable {

    /// Memory budget configuration.
    public struct Budget: Sendable {
        public let totalBytes: Int
        public let modelBytes: Int
        public let cacheBytes: Int
        public let runtimeBytes: Int

        /// Default budget for M1 8GB.
        public static let m1_8gb = Budget(
            totalBytes:   6_800_000_000,  // 6.8 GB
            modelBytes:   4_000_000_000,  // ~4 GB for 9B-4bit
            cacheBytes:   1_500_000_000,  // ~1.5 GB KV cache
            runtimeBytes: 1_300_000_000   // ~1.3 GB runtime
        )

        public init(totalBytes: Int, modelBytes: Int, cacheBytes: Int, runtimeBytes: Int) {
            self.totalBytes = totalBytes
            self.modelBytes = modelBytes
            self.cacheBytes = cacheBytes
            self.runtimeBytes = runtimeBytes
        }
    }

    /// Configure MLX memory limits based on budget.
    public static func configure(budget: Budget) {
        MLX.Memory.memoryLimit = budget.totalBytes
        MLX.Memory.cacheLimit = budget.cacheBytes
    }

    /// Get a snapshot of current memory usage.
    public static func snapshot() -> MLX.Memory.Snapshot {
        MLX.Memory.snapshot()
    }

    /// Check if we're over budget.
    public static func isOverBudget(budget: Budget) -> Bool {
        let snap = snapshot()
        return snap.peakMemory > budget.totalBytes
    }

    /// Create budget from detected chip info.
    public static func budgetFor(chip: ChipDetector.ChipInfo) -> Budget {
        let totalGB = chip.totalMemoryGB
        let gb = 1_073_741_824.0
        if totalGB <= 8 {
            return .m1_8gb
        } else if totalGB <= 16 {
            // M1/M2 16GB, M3/M4 16GB — 70% of RAM.
            let total = Int(totalGB * 0.70 * gb)
            return Budget(
                totalBytes:   total,
                modelBytes:   4_000_000_000,
                cacheBytes:   2_000_000_000,
                runtimeBytes: max(0, total - 6_000_000_000)
            )
        } else if totalGB <= 32 {
            // M5 24GB, M4 Pro/Max 24-32GB — 75% of RAM.
            // More aggressive: these chips have high-bandwidth unified memory and macOS
            // typically uses only ~4-5 GB of background footprint.
            let total = Int(totalGB * 0.75 * gb)
            return Budget(
                totalBytes:   total,
                modelBytes:   6_000_000_000,
                cacheBytes:   6_000_000_000,  // larger MLX buffer cache for longer contexts
                runtimeBytes: max(0, total - 12_000_000_000)
            )
        } else {
            // 36GB+ (M4 Max 36GB, M5 Pro/Max, etc.) — 80% of RAM.
            let total = Int(totalGB * 0.80 * gb)
            return Budget(
                totalBytes:   total,
                modelBytes:   10_000_000_000,
                cacheBytes:   8_000_000_000,
                runtimeBytes: max(0, total - 18_000_000_000)
            )
        }
    }
}
