import Foundation

/// Severity level of a build error or warning
public enum ErrorSeverity: String, Sendable {
    case error = "error"
    case warning = "warning"
    case info = "info"
    case note = "note"
}

/// A single build error or warning
public struct BuildError: Sendable {
    /// File path relative to workspace
    public let file: String
    
    /// Line number (1-based)
    public let line: Int
    
    /// Column number (1-based), if known
    public let column: Int?
    
    /// Error message
    public let message: String
    
    /// Error code (e.g., "CS0103", "E0001")
    public let code: String?
    
    /// Severity level
    public let severity: ErrorSeverity
    
    public init(
        file: String,
        line: Int,
        column: Int? = nil,
        message: String,
        code: String? = nil,
        severity: ErrorSeverity = .error
    ) {
        self.file = file
        self.line = line
        self.column = column
        self.message = message
        self.code = code
        self.severity = severity
    }
}

/// Result of a build check
public struct BuildCheckResult: Sendable {
    /// Whether the build has errors (warnings-only builds still pass)
    public let hasErrors: Bool
    
    /// All errors found
    public let errors: [BuildError]
    
    /// All warnings found
    public let warnings: [BuildError]
    
    /// Tool used for detection (e.g., "dotnet build", "npm", "csharp-ls")
    public let tool: String
    
    /// Elapsed time for the check in seconds
    public let duration: Double
    
    /// Whether the check used LSP (vs build tool)
    public let usedLSP: Bool
    
    /// Optional error message if check failed
    public let checkError: String?
    
    public var totalErrorCount: Int {
        errors.count
    }
    
    public var totalWarningCount: Int {
        warnings.count
    }
    
    public var locationFormatted: String {
        guard !errors.isEmpty else {
            if warnings.isEmpty {
                return "✅ No build errors or warnings"
            }
            let warningStr = "\(warnings.count) warning\(warnings.count == 1 ? "" : "s")"
            return "⚠️  \(warningStr), no errors"
        }
        
        let errorStr = "\(errors.count) error\(errors.count == 1 ? "" : "s")"
        let warningStr = warnings.isEmpty ? "" : ", \(warnings.count) warning\(warnings.count == 1 ? "" : "s")"
        return "❌ \(errorStr)\(warningStr)"
    }
    
    public init(
        hasErrors: Bool,
        errors: [BuildError],
        warnings: [BuildError],
        tool: String,
        duration: Double,
        usedLSP: Bool = false,
        checkError: String? = nil
    ) {
        self.hasErrors = hasErrors
        self.errors = errors
        self.warnings = warnings
        self.tool = tool
        self.duration = duration
        self.usedLSP = usedLSP
        self.checkError = checkError
    }
    
    public static func success(tool: String, duration: Double) -> BuildCheckResult {
        BuildCheckResult(
            hasErrors: false,
            errors: [],
            warnings: [],
            tool: tool,
            duration: duration
        )
    }
    
    public static func error(message: String, tool: String, duration: Double) -> BuildCheckResult {
        BuildCheckResult(
            hasErrors: true,
            errors: [],
            warnings: [],
            tool: tool,
            duration: duration,
            checkError: message
        )
    }
}

/// Options for build check configuration
public struct BuildCheckOptions: Sendable {
    /// Try LSP first, then fall back to build tool
    public let preferLSP: Bool
    
    /// Timeout for build check in seconds
    public let timeout: TimeInterval
    
    /// Maximum number of errors to report
    public let maxErrorsToReport: Int
    
    public init(
        preferLSP: Bool = true,
        timeout: TimeInterval = 60.0,
        maxErrorsToReport: Int = 100
    ) {
        self.preferLSP = preferLSP
        self.timeout = timeout
        self.maxErrorsToReport = maxErrorsToReport
    }
}
