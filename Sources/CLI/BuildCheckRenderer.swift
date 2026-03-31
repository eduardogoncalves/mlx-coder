import Foundation

/// Renders build check results and errors to the console
public struct BuildCheckRenderer {
    private let maxErrorsToShow = 5
    
    public init() {}
    
    /// Print a build check result
    public func printBuildCheck(result: BuildCheckResult, to renderer: StreamRenderer) {
        if !result.hasErrors && result.totalWarningCount == 0 {
            printSuccess(result, to: renderer)
            return
        }
        
        if !result.hasErrors && result.totalWarningCount > 0 {
            printWarningsOnly(result, to: renderer)
            return
        }
        
        printErrors(result, to: renderer)
    }
    
    /// Print successful build check
    private func printSuccess(_ result: BuildCheckResult, to renderer: StreamRenderer) {
        let duration = String(format: "%.2f", result.duration)
        renderer.printStatus("✅ Build passed (\(result.tool), \(duration)s)")
    }
    
    /// Print warnings-only result
    private func printWarningsOnly(_ result: BuildCheckResult, to renderer: StreamRenderer) {
        let duration = String(format: "%.2f", result.duration)
        let msg = "⚠️  Build has \(result.totalWarningCount) warning(s), no errors (\(result.tool), \(duration)s)"
        renderer.printStatus(msg)
        
        // Show first few warnings
        for (index, warning) in result.warnings.prefix(maxErrorsToShow).enumerated() {
            printErrorLine(warning, index: index + 1, total: result.warnings.count, to: renderer)
        }
        
        if result.warnings.count > maxErrorsToShow {
            let omitted = result.warnings.count - maxErrorsToShow
            renderer.printStatus("  [\(omitted) more warning(s) omitted...]")
        }
    }
    
    /// Print errors result
    private func printErrors(_ result: BuildCheckResult, to renderer: StreamRenderer) {
        let duration = String(format: "%.2f", result.duration)
        let errorCount = result.errors.count
        let warningCount = result.totalWarningCount
        
        let warningStr = warningCount > 0 ? ", \(warningCount) warning(s)" : ""
        let msg = "❌ Build failed with \(errorCount) error(s)\(warningStr) (\(result.tool), \(duration)s)"
        
        renderer.printError(msg)
        
        // Show first few errors
        for (index, error) in result.errors.prefix(maxErrorsToShow).enumerated() {
            printErrorLine(error, index: index + 1, total: result.errors.count, to: renderer)
        }
        
        if result.errors.count > maxErrorsToShow {
            let omitted = result.errors.count - maxErrorsToShow
            renderer.printStatus("  [\(omitted) more error(s) omitted...]")
        }
    }
    
    /// Print a single error line
    private func printErrorLine(_ error: BuildError, index: Int, total: Int, to renderer: StreamRenderer) {
        let file = error.file
        let line = error.line
        let column = error.column.map { ":\($0)" } ?? ""
        let code = error.code.map { " [\($0)]" } ?? ""
        let severity = error.severity == .error ? "error" : "warning"
        
        let location = "\(file):\(line)\(column)"
        let emoji = error.severity == .error ? "❌" : "⚠️ "
        
        let output = "\(emoji) \(location): \(severity)\(code): \(error.message)"
        renderer.printStatus("  " + output)
    }
    
    /// Print Ralph loop progress update
    public func printRalphLoopProgress(attempt: Int, maxAttempts: Int, status: String, to renderer: StreamRenderer) {
        let attemptStr = "(\(attempt)/\(maxAttempts))"
        renderer.printStatus("🔧 Fixing errors \(attemptStr): \(status)")
    }
    
    /// Print Ralph loop result
    public func printRalphLoopResult(_ result: RalphLoopResult, to renderer: StreamRenderer) {
        let duration = String(format: "%.2f", result.duration)
        
        if result.succeeded {
            renderer.printStatus("✅ Build fixed successfully! (\(duration)s)")
            if result.fixLog.count > 1 {
                renderer.printStatus("  Steps taken:")
                for (index, step) in result.fixLog.dropFirst().enumerated() {
                    renderer.printStatus("    \(index + 1). \(step)")
                }
            }
        } else {
            renderer.printError("❌ Could not fix all errors after \(result.attemptCount) attempt(s). (\(duration)s)")
            
            if let finalErrors = result.finalErrors, !finalErrors.isEmpty {
                renderer.printStatus("Remaining errors:")
                for (index, error) in finalErrors.prefix(3).enumerated() {
                    printErrorLine(error, index: index + 1, total: finalErrors.count, to: renderer)
                }
                if finalErrors.count > 3 {
                    renderer.printStatus("  [\(finalErrors.count - 3) more error(s) omitted...]")
                }
            }
            
            if !result.fixLog.isEmpty {
                renderer.printStatus("\nFix attempts:")
                for (index, step) in result.fixLog.enumerated() {
                    renderer.printStatus("  \(index + 1). \(step)")
                }
            }
        }
    }
    
    /// Format errors as JSON for tool results
    public func formatErrorsAsJSON(_ result: BuildCheckResult) throws -> String {
        let errors = result.errors.map { error -> [String: Any] in
            var dict: [String: Any] = [
                "file": error.file,
                "line": error.line,
                "message": error.message,
                "severity": error.severity.rawValue
            ]
            if let code = error.code {
                dict["code"] = code
            }
            if let column = error.column {
                dict["column"] = column
            }
            return dict
        }
        
        let json: [String: Any] = [
            "hasErrors": result.hasErrors,
            "errorCount": result.errors.count,
            "warningCount": result.totalWarningCount,
            "tool": result.tool,
            "duration": result.duration,
            "usedLSP": result.usedLSP,
            "errors": errors
        ]
        
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
