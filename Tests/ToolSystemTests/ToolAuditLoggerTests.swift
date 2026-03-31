import XCTest
@testable import MLXCoder

final class ToolAuditLoggerTests: XCTestCase {
    func testWritesApprovalAndExecutionEvents() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-agent-audit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logPath = tempDir.appendingPathComponent("audit.log.jsonl").path
        let logger = ToolAuditLogger(
            logFilePath: logPath,
            workspaceRoot: "/tmp/workspace",
            approvalMode: PermissionEngine.ApprovalMode.default.rawValue
        )

        await logger.logApprovalDecision(
            toolName: "write_file",
            mode: "agent",
            isPlanModePrompt: false,
            approved: true,
            suggestion: nil
        )

        await logger.logExecutionResult(
            toolName: "write_file",
            arguments: ["path": "a.txt"],
            approved: true,
            isError: false,
            resultPreview: "ok"
        )

        let contents = try String(contentsOfFile: logPath, encoding: .utf8)
        let lines = contents.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(contents.contains("\"event\":\"approval_decision\""))
        XCTAssertTrue(contents.contains("\"event\":\"tool_execution\""))
        XCTAssertTrue(contents.contains("\"tool\":\"write_file\""))
    }

    func testWritesHookEvents() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-agent-audit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logPath = tempDir.appendingPathComponent("audit.log.jsonl").path
        let logger = ToolAuditLogger(
            logFilePath: logPath,
            workspaceRoot: "/tmp/workspace",
            approvalMode: PermissionEngine.ApprovalMode.default.rawValue
        )

        await logger.logHookEvent(
            hookName: "audit",
            eventName: "pre_tool_use",
            toolName: "read_file",
            details: "{}"
        )

        let contents = try String(contentsOfFile: logPath, encoding: .utf8)
        XCTAssertTrue(contents.contains("\"event\":\"hook_event\""))
        XCTAssertTrue(contents.contains("\"hook\":\"audit\""))
        XCTAssertTrue(contents.contains("\"hook_event\":\"pre_tool_use\""))
        XCTAssertTrue(contents.contains("\"tool\":\"read_file\""))
    }
}