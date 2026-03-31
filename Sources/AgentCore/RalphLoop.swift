import Foundation

/// Results from a Ralph loop fixing attempt
public struct RalphLoopResult: Sendable {
    /// Whether fixing was successful (build passed)
    public let succeeded: Bool
    
    /// Number of fix attempts made
    public let attemptCount: Int
    
    /// Final errors if not successful
    public let finalErrors: [BuildError]?
    
    /// Log of actions taken during fixing
    public let fixLog: [String]
    
    /// Duration of entire fixing process
    public let duration: Double
    
    public init(
        succeeded: Bool,
        attemptCount: Int,
        finalErrors: [BuildError]? = nil,
        fixLog: [String] = [],
        duration: Double = 0
    ) {
        self.succeeded = succeeded
        self.attemptCount = attemptCount
        self.finalErrors = finalErrors
        self.fixLog = fixLog
        self.duration = duration
    }
}

/// Options for Ralph loop behavior
public struct RalphLoopOptions: Sendable {
    /// Maximum number of fix attempts
    public let maxAttempts: Int
    
    /// Whether to show progress updates
    public let verbose: Bool
    
    public init(maxAttempts: Int = 3, verbose: Bool = true) {
        self.maxAttempts = maxAttempts
        self.verbose = verbose
    }
}

/// Autonomous error fixing loop (Ralph loop)
/// Analyzes build errors, investigates via search/LSP, generates and applies fixes
public actor RalphLoop {
    private let buildErrorDetector: BuildErrorDetector
    private let options: RalphLoopOptions
    
    // Callback for progress reporting (called on main actor)
    public typealias ProgressCallback = @Sendable (String) -> Void
    
    public init(
        buildErrorDetector: BuildErrorDetector = BuildErrorDetector(),
        options: RalphLoopOptions = RalphLoopOptions()
    ) {
        self.buildErrorDetector = buildErrorDetector
        self.options = options
    }
    
    /// Attempt to autonomously fix build errors
    /// Coordinates with agent loop via callbacks for tool execution (search, read, edit)
    public func attemptFix(
        workspace: String,
        onProgress: ProgressCallback? = nil
    ) async -> RalphLoopResult {
        let startTime = Date()
        var fixLog: [String] = []
        var attemptCount = 0
        
        for attempt in 1...options.maxAttempts {
            attemptCount = attempt
            
            let msg = "Checking build status (attempt \(attempt)/\(options.maxAttempts))..."
            onProgress?(msg)
            fixLog.append(msg)
            
            // Check current build status
            let checkResult = await buildErrorDetector.detect(workspace: workspace)
            
            if !checkResult.hasErrors {
                let successMsg = "✅ Build fixed successfully!"
                onProgress?(successMsg)
                fixLog.append(successMsg)
                
                let duration = Date().timeIntervalSince(startTime)
                return RalphLoopResult(
                    succeeded: true,
                    attemptCount: attemptCount,
                    fixLog: fixLog,
                    duration: duration
                )
            }
            
            // Analyze errors and attempt fixes
            let errorAnalysis = analyzeErrors(checkResult.errors, workspace: workspace)
            
            let analyzeMsg = "Found \(checkResult.errors.count) error(s) to fix: \(errorAnalysis.summary)"
            onProgress?(analyzeMsg)
            fixLog.append(analyzeMsg)
            
            // For each error, attempt deep investigation and fix
            for (index, error) in checkResult.errors.enumerated() {
                let errorMsg = "Analyzing error \(index + 1)/\(checkResult.errors.count): \(error.message)"
                onProgress?(errorMsg)
                fixLog.append(errorMsg)
                
                // Deep investigation: search for related code patterns
                let investigateMsg = "Investigating: searching codebase for context..."
                onProgress?(investigateMsg)
                fixLog.append(investigateMsg)
                
                // In a real implementation, this would:
                // 1. Call onToolNeeded("code_search", query: error description)
                // 2. Call onToolNeeded("read_file", path: error.file, line: error.line)
                // 3. Use LSP hover/references to understand context
                // 4. Generate fix using agent's LLM
                // 5. Call onToolNeeded("write_file" or "edit_file") to apply fix
                
                // For now, log the intention
                let fixMsg = "Would attempt to fix: \(error.file):\(error.line) - \(error.message)"
                onProgress?(fixMsg)
                fixLog.append(fixMsg)
                
                // Note: Actual fix execution would happen here
                // This would require integration with the agent loop
                // to call search/read/edit tools
            }
            
            // If last attempt, return with remaining errors
            if attempt == options.maxAttempts {
                let finalMsg = "⚠️  Max attempts (\(options.maxAttempts)) reached, \(checkResult.errors.count) error(s) remain"
                onProgress?(finalMsg)
                fixLog.append(finalMsg)
                
                let duration = Date().timeIntervalSince(startTime)
                return RalphLoopResult(
                    succeeded: false,
                    attemptCount: attemptCount,
                    finalErrors: checkResult.errors,
                    fixLog: fixLog,
                    duration: duration
                )
            }
        }
        
        // Should not reach here
        let duration = Date().timeIntervalSince(startTime)
        return RalphLoopResult(
            succeeded: false,
            attemptCount: attemptCount,
            fixLog: fixLog,
            duration: duration
        )
    }
    
    // MARK: - Error Analysis
    
    private func analyzeErrors(_ errors: [BuildError], workspace: String) -> ErrorAnalysis {
        var summary = ""
        var categories: [String: Int] = [:]
        
        // Group errors by type/code
        for error in errors {
            let key = error.code ?? "unknown"
            categories[key, default: 0] += 1
        }
        
        // Build summary
        if categories.count == 1, let (code, count) = categories.first {
            summary = "\(count) instance(s) of \(code)"
        } else {
            let parts = categories.map { "\($0.value)x \($0.key)" }
            summary = parts.joined(separator: ", ")
        }
        
        return ErrorAnalysis(summary: summary, categories: categories)
    }
    
    private struct ErrorAnalysis {
        let summary: String
        let categories: [String: Int]
    }
}

/// Information about a tool call the Ralph loop needs to make
public struct ToolCallInfo: Sendable {
    public let toolName: String
    
    public init(toolName: String) {
        self.toolName = toolName
    }
}
