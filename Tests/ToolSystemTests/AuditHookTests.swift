import XCTest
@testable import NativeAgent

final class AuditHookTests: XCTestCase {
    func testAuditHookWritesPermissionAndPreToolEvents() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-agent-audit-hook-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logPath = tempDir.appendingPathComponent("audit.log.jsonl").path
        let logger = ToolAuditLogger(
            logFilePath: logPath,
            workspaceRoot: "/tmp/workspace",
            approvalMode: PermissionEngine.ApprovalMode.default.rawValue
        )
        let hook = AuditHook(logger: logger)

        await hook.handle(event: .permissionRequest(toolName: "write_file", isPlanMode: true))
        await hook.handle(event: .preToolUse(toolName: "write_file", argumentsPreview: "{\"path\":\"a.txt\"}"))

        let contents = try String(contentsOfFile: logPath, encoding: .utf8)
        XCTAssertTrue(contents.contains("\"event\":\"hook_event\""))
        XCTAssertTrue(contents.contains("\"hook_event\":\"permission_request\""))
        XCTAssertTrue(contents.contains("\"hook_event\":\"pre_tool_use\""))
        XCTAssertTrue(contents.contains("\"tool\":\"write_file\""))
    }

    func testAuditHookWritesPostAndCompressionEvents() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-agent-audit-hook-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logPath = tempDir.appendingPathComponent("audit.log.jsonl").path
        let logger = ToolAuditLogger(
            logFilePath: logPath,
            workspaceRoot: "/tmp/workspace",
            approvalMode: PermissionEngine.ApprovalMode.default.rawValue
        )
        let hook = AuditHook(logger: logger)

        await hook.handle(event: .postToolUse(toolName: "grep", isError: false, resultPreview: "ok"))
        await hook.handle(event: .compression(toolName: "web_fetch", beforeTokens: 1200, afterTokens: 120, usedFallback: false))

        let contents = try String(contentsOfFile: logPath, encoding: .utf8)
        XCTAssertTrue(contents.contains("\"hook_event\":\"post_tool_use\""))
        XCTAssertTrue(contents.contains("\"hook_event\":\"compression\""))
        XCTAssertTrue(contents.contains("\"tool\":\"web_fetch\""))
    }
}
