import XCTest
@testable import MLXCoder

final class ErrorDetectionModelsTests: XCTestCase {
    func testBuildErrorCreation() {
        let error = BuildError(
            file: "src/main.swift",
            line: 42,
            column: 10,
            message: "Type mismatch",
            code: "E0001",
            severity: .error
        )
        
        XCTAssertEqual(error.file, "src/main.swift")
        XCTAssertEqual(error.line, 42)
        XCTAssertEqual(error.column, 10)
        XCTAssertEqual(error.message, "Type mismatch")
        XCTAssertEqual(error.code, "E0001")
        XCTAssertEqual(error.severity, .error)
    }
    
    func testBuildCheckResultSuccess() {
        let result = BuildCheckResult.success(tool: "dotnet", duration: 2.5)
        
        XCTAssertFalse(result.hasErrors)
        XCTAssertEqual(result.errors.count, 0)
        XCTAssertEqual(result.warnings.count, 0)
        XCTAssertEqual(result.tool, "dotnet")
        XCTAssertEqual(result.duration, 2.5)
        XCTAssertNil(result.checkError)
    }
    
    func testBuildCheckResultError() {
        let result = BuildCheckResult.error(
            message: "Build failed",
            tool: "npm",
            duration: 5.0
        )
        
        XCTAssertTrue(result.hasErrors)
        XCTAssertEqual(result.checkError, "Build failed")
        XCTAssertEqual(result.totalErrorCount, 0)
    }
    
    func testBuildCheckResultWithErrors() {
        let errors = [
            BuildError(file: "a.ts", line: 1, message: "error1", severity: .error),
            BuildError(file: "b.ts", line: 2, message: "error2", severity: .error)
        ]
        let warnings = [
            BuildError(file: "c.ts", line: 3, message: "warn1", severity: .warning)
        ]
        
        let result = BuildCheckResult(
            hasErrors: true,
            errors: errors,
            warnings: warnings,
            tool: "typescript",
            duration: 1.2
        )
        
        XCTAssertTrue(result.hasErrors)
        XCTAssertEqual(result.totalErrorCount, 2)
        XCTAssertEqual(result.totalWarningCount, 1)
        XCTAssertEqual(result.locationFormatted, "❌ 2 errors, 1 warning")
    }
    
    func testErrorSeverityValues() {
        XCTAssertEqual(ErrorSeverity.error.rawValue, "error")
        XCTAssertEqual(ErrorSeverity.warning.rawValue, "warning")
        XCTAssertEqual(ErrorSeverity.info.rawValue, "info")
        XCTAssertEqual(ErrorSeverity.note.rawValue, "note")
    }
    
    func testBuildCheckOptions() {
        let options = BuildCheckOptions(
            preferLSP: true,
            timeout: 60.0,
            maxErrorsToReport: 50
        )
        
        XCTAssertTrue(options.preferLSP)
        XCTAssertEqual(options.timeout, 60.0)
        XCTAssertEqual(options.maxErrorsToReport, 50)
    }
    
    func testBuildCheckOptionsDefaults() {
        let options = BuildCheckOptions()
        
        XCTAssertTrue(options.preferLSP)
        XCTAssertEqual(options.timeout, 60.0)
        XCTAssertEqual(options.maxErrorsToReport, 100)
    }
    
    func testLocationFormatted() {
        // No errors or warnings
        let result1 = BuildCheckResult.success(tool: "test", duration: 0)
        XCTAssertEqual(result1.locationFormatted, "✅ No build errors or warnings")
        
        // Warnings only
        let warnings = [BuildError(file: "a.ts", line: 1, message: "warn", severity: .warning)]
        let result2 = BuildCheckResult(
            hasErrors: false,
            errors: [],
            warnings: warnings,
            tool: "test",
            duration: 0
        )
        XCTAssertEqual(result2.locationFormatted, "⚠️  1 warning, no errors")
        
        // Multiple errors
        let errors = Array(repeating: BuildError(file: "a.ts", line: 1, message: "err", severity: .error), count: 3)
        let result3 = BuildCheckResult(
            hasErrors: true,
            errors: errors,
            warnings: [],
            tool: "test",
            duration: 0
        )
        XCTAssertEqual(result3.locationFormatted, "❌ 3 errors")
    }
}
