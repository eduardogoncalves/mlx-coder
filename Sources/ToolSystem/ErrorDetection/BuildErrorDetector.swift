import Foundation

/// Orchestrates error detection using LSP first, then build tools
public actor BuildErrorDetector {
    private let projectDetector: ProjectTypeDetector
    private let lspDetector: LSPErrorDetector
    private let buildToolDetector: BuildToolErrorDetector
    private let options: BuildCheckOptions
    
    public init(
        projectDetector: ProjectTypeDetector = ProjectTypeDetector(),
        lspDetector: LSPErrorDetector = LSPErrorDetector(),
        buildToolDetector: BuildToolErrorDetector = BuildToolErrorDetector(),
        options: BuildCheckOptions = BuildCheckOptions()
    ) {
        self.projectDetector = projectDetector
        self.lspDetector = lspDetector
        self.buildToolDetector = buildToolDetector
        self.options = options
    }
    
    /// Detect build errors in the workspace
    /// Strategy: Try LSP first (if preferred), then fall back to build tool
    public func detect(
        workspace: String
    ) async -> BuildCheckResult {
        let startTime = Date()
        
        // Detect project type
        let detectionResult = await projectDetector.detect(workspace: workspace)
        
        guard let projectInfo = detectionResult.projectInfo else {
            let errorMsg = detectionResult.error ?? "Unknown project type"
            let duration = Date().timeIntervalSince(startTime)
            return .error(message: errorMsg, tool: "detector", duration: duration)
        }
        
        // LSP-first strategy
        if options.preferLSP {
            if let lspResult = await lspDetector.detect(workspace: workspace, projectInfo: projectInfo) {
                return lspResult
            }
            // Fall through to build tool if LSP unavailable
        }
        
        // Use build tool
        let result = await buildToolDetector.detect(workspace: workspace, projectInfo: projectInfo)
        
        // Truncate errors if needed
        if result.totalErrorCount > options.maxErrorsToReport {
            let truncated = Array(result.errors.prefix(options.maxErrorsToReport))
            return BuildCheckResult(
                hasErrors: result.hasErrors,
                errors: truncated,
                warnings: result.warnings,
                tool: result.tool,
                duration: result.duration,
                usedLSP: result.usedLSP,
                checkError: result.checkError
            )
        }
        
        return result
    }
}
