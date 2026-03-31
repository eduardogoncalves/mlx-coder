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
        if totalGB <= 8 {
            return .m1_8gb
        } else if totalGB <= 16 {
            return Budget(
                totalBytes:   Int(totalGB * 0.7 * 1_073_741_824), // 70% of RAM
                modelBytes:   4_000_000_000,
                cacheBytes:   2_000_000_000,
                runtimeBytes: Int(totalGB * 0.7 * 1_073_741_824) - 6_000_000_000
            )
        } else {
            return Budget(
                totalBytes:   Int(totalGB * 0.6 * 1_073_741_824), // 60% of RAM
                modelBytes:   4_000_000_000,
                cacheBytes:   4_000_000_000,
                runtimeBytes: Int(totalGB * 0.6 * 1_073_741_824) - 8_000_000_000
            )
        }
    }
}
