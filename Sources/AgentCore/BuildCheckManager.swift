import Foundation

/// Manages build checks before commits
/// Coordinates build error detection and autonomous fixing
public actor BuildCheckManager {
    private let buildErrorDetector: BuildErrorDetector
    private let ralphLoop: RalphLoop

    public init(
        buildErrorDetector: BuildErrorDetector = BuildErrorDetector(),
        ralphLoop: RalphLoop = RalphLoop()
    ) {
        self.buildErrorDetector = buildErrorDetector
        self.ralphLoop = ralphLoop
    }

    /// Check build before allowing commit.
    /// All progress is reported through `onProgress`; rendering is the caller's job.
    /// Returns true if build passes, false if errors remain.
    public func checkBeforeCommit(
        workspace: String,
        onProgress: @Sendable @escaping (String) -> Void = { _ in }
    ) async -> Bool {
        onProgress("Checking build status before commit...")

        let startTime = Date()
        let initialCheck = await buildErrorDetector.detect(workspace: workspace)

        if initialCheck.errors.isEmpty {
            let duration = Date().timeIntervalSince(startTime)
            onProgress("⚠️  Build check returned 0 parseable error(s) (\(initialCheck.tool), \(String(format: "%.2f", duration))s) - continuing")
            return true
        }

        if !initialCheck.hasErrors {
            let duration = Date().timeIntervalSince(startTime)
            onProgress("✅ Build check passed (\(initialCheck.tool), \(String(format: "%.2f", duration))s)")
            return true
        }

        onProgress("Build has \(initialCheck.errors.count) error(s), attempting autonomous fixes...")
        for (index, error) in initialCheck.errors.prefix(3).enumerated() {
            onProgress("  \(index + 1). \(error.file):\(error.line): \(error.message)")
        }
        if initialCheck.errors.count > 3 {
            onProgress("  [\(initialCheck.errors.count - 3) more error(s)...]")
        }

        let fixResult = await ralphLoop.attemptFix(
            workspace: workspace,
            onProgress: onProgress
        )

        if fixResult.succeeded {
            onProgress("✅ Build check passed after autonomous fixes")
            return true
        }
        onProgress("❌ Autonomous build fix did not succeed")
        return false
    }
}
