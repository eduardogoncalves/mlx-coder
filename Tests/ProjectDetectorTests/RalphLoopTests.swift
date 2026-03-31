import XCTest
@testable import NativeAgent

final class RalphLoopTests: XCTestCase {
    var ralphLoop: RalphLoop!
    
    override func setUp() async throws {
        ralphLoop = RalphLoop(options: RalphLoopOptions(maxAttempts: 2, verbose: true))
    }
    
    func testRalphLoopResultSuccess() {
        let result = RalphLoopResult(
            succeeded: true,
            attemptCount: 1,
            fixLog: ["Fixed syntax error", "Build passed"]
        )
        
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.attemptCount, 1)
        XCTAssertEqual(result.fixLog.count, 2)
        XCTAssertNil(result.finalErrors)
    }
    
    func testRalphLoopResultFailure() {
        let errors = [
            BuildError(file: "main.swift", line: 10, message: "Type error", severity: .error)
        ]
        let result = RalphLoopResult(
            succeeded: false,
            attemptCount: 2,
            finalErrors: errors,
            fixLog: ["Attempt 1: No fix found", "Attempt 2: Still broken"]
        )
        
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.attemptCount, 2)
        XCTAssertEqual(result.finalErrors?.count, 1)
        XCTAssertEqual(result.fixLog.count, 2)
    }
    
    func testRalphLoopOptions() {
        let opts = RalphLoopOptions(maxAttempts: 3, verbose: true)
        
        XCTAssertEqual(opts.maxAttempts, 3)
        XCTAssertTrue(opts.verbose)
    }
    
    func testRalphLoopOptionsDefaults() {
        let opts = RalphLoopOptions()
        
        XCTAssertEqual(opts.maxAttempts, 3)
        XCTAssertTrue(opts.verbose)
    }
    
    func testProgressCallbacks() async {
        var progressMessages: [String] = []
        let onProgress: @Sendable (String) -> Void = { msg in
            DispatchQueue.main.sync {
                progressMessages.append(msg)
            }
        }
        
        // Simulate progress callback
        onProgress("Step 1")
        onProgress("Step 2")
        
        XCTAssertEqual(progressMessages.count, 2)
        XCTAssertEqual(progressMessages[0], "Step 1")
        XCTAssertEqual(progressMessages[1], "Step 2")
    }
    
    func testToolCallInfo() {
        let toolCall = ToolCallInfo(toolName: "read_file")
        
        XCTAssertEqual(toolCall.toolName, "read_file")
    }
}
