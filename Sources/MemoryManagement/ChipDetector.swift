// Sources/MemoryManagement/ChipDetector.swift
// Detects Apple Silicon chip type and memory configuration

import Foundation

/// Detects the current Apple Silicon chip and its capabilities.
public struct ChipDetector: Sendable {

    /// The detected chip family.
    public enum ChipFamily: String, Sendable {
        case m1 = "M1"
        case m2 = "M2"
        case m3 = "M3"
        case m4 = "M4"
        case m5 = "M5"
        case unknown = "Unknown"
    }

    /// Information about the current chip.
    public struct ChipInfo: Sendable {
        public let family: ChipFamily
        public let totalMemoryBytes: UInt64
        public let gpuCoreCount: Int

        public var totalMemoryGB: Double {
            Double(totalMemoryBytes) / (1024 * 1024 * 1024)
        }
    }

    /// Detect the current chip and its capabilities.
    public static func detect() -> ChipInfo {
        let totalMemory = ProcessInfo.processInfo.physicalMemory
        let gpuCores = gpuCoreCount()
        let family = detectFamily()

        return ChipInfo(
            family: family,
            totalMemoryBytes: totalMemory,
            gpuCoreCount: gpuCores
        )
    }

    // MARK: - Private

    private static func detectFamily() -> ChipFamily {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var brand = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
        let brandString = String(decoding: brand.prefix(while: { $0 != 0 }).map(UInt8.init), as: UTF8.self)

        if brandString.contains("M5") { return .m5 }
        if brandString.contains("M4") { return .m4 }
        if brandString.contains("M3") { return .m3 }
        if brandString.contains("M2") { return .m2 }
        if brandString.contains("M1") { return .m1 }
        return .unknown
    }

    private static func gpuCoreCount() -> Int {
        var size = 0
        sysctlbyname("hw.perflevel0.logicalcpu", nil, &size, nil, 0)
        // Fallback: return a reasonable default
        guard size > 0 else { return 8 }
        var count: Int32 = 0
        var countSize = MemoryLayout<Int32>.size
        sysctlbyname("hw.perflevel0.logicalcpu", &count, &countSize, nil, 0)
        return Int(count)
    }
}
