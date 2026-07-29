// Tests/ToolSystemTests/BackgroundProcessRegistryTests.swift

import XCTest
import Foundation
import Darwin
@testable import MLXCoder

final class BackgroundProcessRegistryTests: XCTestCase {

    func testParseBackgroundPIDExtractsPID() {
        let launch = "[background] Started process with PID 48123\n"
        XCTAssertEqual(BashTool.parseBackgroundPID(from: launch), 48123)
    }

    func testParseBackgroundPIDReturnsNilWhenAbsent() {
        XCTAssertNil(BashTool.parseBackgroundPID(from: "zsh: command not found: uvicorn"))
        XCTAssertNil(BashTool.parseBackgroundPID(from: ""))
    }

    func testRegisterIgnoresInvalidPIDs() {
        let registry = BackgroundProcessRegistry()
        registry.register(0)
        registry.register(1)
        registry.register(-5)
        XCTAssertTrue(registry.trackedPIDs().isEmpty)
    }

    func testTerminateAllKillsTrackedProcessAndClearsList() async throws {
        // A real, long-lived child stands in for a sub-agent's background server.
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sleep")
        process.arguments = ["120"]
        try process.run()
        let pid = process.processIdentifier
        XCTAssertGreaterThan(pid, 1)

        let registry = BackgroundProcessRegistry()
        registry.register(pid)
        XCTAssertEqual(registry.trackedPIDs(), [pid])

        let killed = await registry.terminateAll(graceSeconds: 0.1)
        XCTAssertEqual(killed, [pid])
        // List is cleared, so a second sweep is a no-op.
        XCTAssertTrue(registry.trackedPIDs().isEmpty)
        let secondSweep = await registry.terminateAll()
        XCTAssertTrue(secondSweep.isEmpty)

        // The process is torn down. Foundation reaps the SIGKILLed child; poll
        // briefly for `isRunning` to settle so the assertion isn't racy.
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(process.isRunning)
    }
}
