import XCTest
@testable import MLXCoder

final class ReadSubagentLogToolTests: XCTestCase {
    private func makeArchive(in workspace: URL, runID: String, messages: [Message]) throws {
        let runDir = workspace
            .appendingPathComponent(".native-agent/subagent-logs/\(runID)", isDirectory: true)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(messages)
        try data.write(to: runDir.appendingPathComponent("history.json"))
    }

    func testRecoversFinalAssistantResponse() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let fullOutput = "System.Security.Cryptography.Xml 9.0.0 High GHSA-37gx-xxp4-5rgx"
        try makeArchive(in: workspace, runID: "run1", messages: [
            Message(role: .user, content: "run the scan"),
            Message(role: .tool, content: "raw stdout here", toolCallId: "bash"),
            Message(role: .assistant, content: fullOutput),
        ])

        let tool = ReadSubagentLogTool(permissions: PermissionEngine(workspaceRoot: workspace.path))
        let result = try await tool.execute(arguments: ["archive": ".native-agent/subagent-logs/run1"])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains(fullOutput))
        // Tool output is excluded by default.
        XCTAssertFalse(result.content.contains("raw stdout here"))
    }

    func testIncludesToolOutputWhenRequested() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try makeArchive(in: workspace, runID: "run2", messages: [
            Message(role: .tool, content: "the raw command output", toolCallId: "bash"),
            Message(role: .assistant, content: "summary"),
        ])

        let tool = ReadSubagentLogTool(permissions: PermissionEngine(workspaceRoot: workspace.path))
        let result = try await tool.execute(arguments: [
            "archive": ".native-agent/subagent-logs/run2",
            "include_tool_output": true,
        ])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("the raw command output"))
    }

    func testErrorsWhenArchiveMissing() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let tool = ReadSubagentLogTool(permissions: PermissionEngine(workspaceRoot: workspace.path))
        let result = try await tool.execute(arguments: ["archive": ".native-agent/subagent-logs/nope"])

        XCTAssertTrue(result.isError)
    }

    func testErrorsWhenArchiveMissingArgument() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let tool = ReadSubagentLogTool(permissions: PermissionEngine(workspaceRoot: workspace.path))
        let result = try await tool.execute(arguments: [:])

        XCTAssertTrue(result.isError)
    }

    private func makeTempWorkspace() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("read-subagent-log-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
