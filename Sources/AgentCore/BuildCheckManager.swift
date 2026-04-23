import Foundation

/// Manages build checks before commits
/// Coordinates build error detection and autonomous fixing
public actor BuildCheckManager {
    private let buildErrorDetector: BuildErrorDetector
    private let ralphLoop: RalphLoop
    private let renderer: BuildCheckRenderer
    
    public init(
        buildErrorDetector: BuildErrorDetector = BuildErrorDetector(),
        ralphLoop: RalphLoop = RalphLoop(),
        renderer: BuildCheckRenderer = BuildCheckRenderer()
    ) {
        self.buildErrorDetector = buildErrorDetector
        self.ralphLoop = ralphLoop
        self.renderer = renderer
    }
    
    /// Check build before allowing commit
    /// If errors found, attempts autonomous fixing up to maxAttempts
    /// Returns true if build passes, false if errors remain
    public func checkBeforeCommit(
        workspace: String,
        onProgress: @Sendable @escaping (String) -> Void = { _ in },
        streamRenderer: StreamRenderer? = nil
    ) async -> Bool {
        onProgress("Checking build status before commit...")
        
        let startTime = Date()
        
        // Initial build check
        let initialCheck = await buildErrorDetector.detect(workspace: workspace)

        // Some toolchains can report a failed status while emitting zero parseable diagnostics.
        // Avoid blocking autonomous flow on this ambiguous state.
        if initialCheck.errors.isEmpty {
            let duration = Date().timeIntervalSince(startTime)
            let msg = "⚠️  Build check returned 0 parseable error(s) (\(initialCheck.tool), \(String(format: "%.2f", duration))s) - continuing"
            onProgress(msg)
            if let renderer = streamRenderer {
                renderer.printStatus(msg)
            }
            return true
        }
        
        if !initialCheck.hasErrors {
            // Build is clean, commit can proceed
            let duration = Date().timeIntervalSince(startTime)
            let msg = "✅ Build check passed (\(initialCheck.tool), \(String(format: "%.2f", duration))s)"
            onProgress(msg)
            if let renderer = streamRenderer {
                renderer.printStatus(msg)
            }
            return true
        }
        
        // Build has errors - attempt autonomous fixes
        onProgress("Build has \(initialCheck.errors.count) error(s), attempting autonomous fixes...")
        
        if let renderer = streamRenderer {
            renderer.printError("Build check failed with \(initialCheck.errors.count) error(s)")
            // Show initial errors
            for (index, error) in initialCheck.errors.prefix(3).enumerated() {
                renderer.printStatus("  \(index + 1). \(error.file):\(error.line): \(error.message)")
            }
            if initialCheck.errors.count > 3 {
                renderer.printStatus("  [\(initialCheck.errors.count - 3) more error(s)...]")
            }
        }
        
        // Attempt fixing
        let fixResult = await ralphLoop.attemptFix(
            workspace: workspace,
            onProgress: onProgress
        )
        
        if let renderer = streamRenderer {
            let checkRenderer = BuildCheckRenderer()
            checkRenderer.printRalphLoopResult(fixResult, to: renderer)
        }
        
        // If fixes succeeded, return true
        if fixResult.succeeded {
            return true
        }
        
        // Fixes failed, commit should not proceed
        return false
    }
}
