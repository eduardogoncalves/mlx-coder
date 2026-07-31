import XCTest
@testable import MLXCoder

final class TaskOutputToolTests: XCTestCase {
    private func makeArchive(in workspace: URL, runID: String, messages: [Message]) throws {
        let runDir = workspace
            .appendingPathComponent(".native-agent/subagent-logs/\(runID)", isDirectory: true)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(messages)
        try data.write(to: runDir.appendingPathComponent("history.json"))
    }

    private func makeTempWorkspace() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("task-output-tool-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testIncludeToolOutputReturnsToolResultContent() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let fullOutput = "System.Security.Cryptography.Xml 9.0.0 High GHSA-37gx-xxp4-5rgx"
        try makeArchive(in: workspace, runID: "run1", messages: [
            Message(role: .user, content: "run the scan"),
            Message(role: .tool, content: fullOutput, toolCallId: "bash"),
            Message(role: .assistant, content: "Found one vulnerability."),
        ])

        let tool = TaskOutputTool(permissions: PermissionEngine(workspaceRoot: workspace.path))
        let result = try await tool.execute(arguments: ["archive": ".native-agent/subagent-logs/run1"])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains(fullOutput))
        // Default include is tool_output, so the final assistant summary should not appear.
        XCTAssertFalse(result.content.contains("Found one vulnerability."))
    }

    func testReadsSpoolPathPassedAsArchiveDirectly() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        // A large-output spool file, exactly as a digest's `tool_output:` line
        // hands it to the orchestrator. Passing it as `archive` must read it
        // back verbatim — not mangle it into `<spool>.txt/history.json`.
        let spooled = "line one\nline two\nvulnerable package X 1.0 High"
        let handle = try XCTUnwrap(ToolOutputSpool.shared.spool(content: spooled, toolName: "task-terminal"))
        defer { try? FileManager.default.removeItem(atPath: handle.path) }

        let tool = TaskOutputTool(permissions: PermissionEngine(workspaceRoot: workspace.path))
        let result = try await tool.execute(arguments: ["archive": handle.path])

        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.content, spooled)
    }

    func testMissingSpoolFileReturnsActionableError() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        // A path inside the spool root that no longer exists (pruned).
        let missing = ToolOutputSpool.shared.root
            .appendingPathComponent("1785338929254-task-terminal-DEADBEEF.txt").path

        let tool = TaskOutputTool(permissions: PermissionEngine(workspaceRoot: workspace.path))
        let result = try await tool.execute(arguments: ["archive": missing])

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("No spooled output"))
        XCTAssertFalse(result.content.contains("history.json"))
    }

    func testIncludeFinalReturnsLastAssistantMessage() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try makeArchive(in: workspace, runID: "run2", messages: [
            Message(role: .tool, content: "raw tool output", toolCallId: "bash"),
            Message(role: .assistant, content: "first draft"),
            Message(role: .tool, content: "more raw output", toolCallId: "bash"),
            Message(role: .assistant, content: "final summary text"),
        ])

        let tool = TaskOutputTool(permissions: PermissionEngine(workspaceRoot: workspace.path))
        let result = try await tool.execute(arguments: [
            "archive": ".native-agent/subagent-logs/run2",
            "include": "final",
        ])

        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.content, "final summary text")
    }

    func testIncludeAllReturnsFullTranscript() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try makeArchive(in: workspace, runID: "run3", messages: [
            Message(role: .user, content: "Sub-agent Task: do the thing"),
            Message(role: .tool, content: "raw tool output", toolCallId: "bash"),
            Message(role: .assistant, content: "final summary text"),
        ])

        let tool = TaskOutputTool(permissions: PermissionEngine(workspaceRoot: workspace.path))
        let result = try await tool.execute(arguments: [
            "archive": ".native-agent/subagent-logs/run3",
            "include": "all",
        ])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Sub-agent Task: do the thing"))
        XCTAssertTrue(result.content.contains("raw tool output"))
        XCTAssertTrue(result.content.contains("final summary text"))
    }

    func testBareRunIDResolvesSameAsRelativePath() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try makeArchive(in: workspace, runID: "run4", messages: [
            Message(role: .tool, content: "bare-id tool output", toolCallId: "bash"),
        ])

        let tool = TaskOutputTool(permissions: PermissionEngine(workspaceRoot: workspace.path))

        let viaPath = try await tool.execute(arguments: ["archive": ".native-agent/subagent-logs/run4"])
        let viaBareID = try await tool.execute(arguments: ["archive": "run4"])

        XCTAssertFalse(viaPath.isError)
        XCTAssertFalse(viaBareID.isError)
        XCTAssertEqual(viaPath.content, viaBareID.content)
        XCTAssertTrue(viaBareID.content.contains("bare-id tool output"))
    }

    func testReadToolOutputRedirectsSubagentArchivePathToTaskOutput() async throws {
        // A subagent-logs archive path passed to read_tool_output (not a spool
        // file) should be rejected WITH a corrective pointer to task_output +
        // the run id — not the generic "use read_file" hint.
        let tool = ReadToolOutputTool()
        let result = try await tool.execute(arguments: [
            "path": "/ws/.native-agent/subagent-logs/20260731-145155-executor-f94e77a8/tool_output",
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("task_output"))
        XCTAssertTrue(result.content.contains("20260731-145155-executor-f94e77a8"))
        XCTAssertFalse(result.content.contains("Use read_file"))
    }

    func testConflatedToolOutputSuffixStillResolvesArchive() async throws {
        // A model commonly appends the digest's `tool_output:` label onto the
        // `archive:` run dir. task_output should strip it back to the run dir
        // rather than form a nonsense ".../tool_output/history.json".
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try makeArchive(in: workspace, runID: "run7", messages: [
            Message(role: .tool, content: "conflated-path tool output", toolCallId: "bash"),
        ])

        let tool = TaskOutputTool(permissions: PermissionEngine(workspaceRoot: workspace.path))

        let viaConflated = try await tool.execute(arguments: ["archive": ".native-agent/subagent-logs/run7/tool_output"])
        let viaBareID = try await tool.execute(arguments: ["archive": "run7"])

        XCTAssertFalse(viaConflated.isError)
        XCTAssertEqual(viaConflated.content, viaBareID.content)
        XCTAssertTrue(viaConflated.content.contains("conflated-path tool output"))
    }

    func testMissingArchiveReturnsError() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let tool = TaskOutputTool(permissions: PermissionEngine(workspaceRoot: workspace.path))
        let result = try await tool.execute(arguments: ["archive": ".native-agent/subagent-logs/nope"])

        XCTAssertTrue(result.isError)
    }

    func testMissingArchiveArgumentReturnsError() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let tool = TaskOutputTool(permissions: PermissionEngine(workspaceRoot: workspace.path))
        let result = try await tool.execute(arguments: [:])

        XCTAssertTrue(result.isError)
    }

    func testMaxCharsTruncatesAndMarksTruncation() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let longOutput = String(repeating: "x", count: 500)
        try makeArchive(in: workspace, runID: "run5", messages: [
            Message(role: .tool, content: longOutput, toolCallId: "bash"),
        ])

        let tool = TaskOutputTool(permissions: PermissionEngine(workspaceRoot: workspace.path))
        let result = try await tool.execute(arguments: [
            "archive": ".native-agent/subagent-logs/run5",
            "max_chars": 50,
        ])

        XCTAssertFalse(result.isError)
        XCTAssertNotNil(result.truncationMarker, "truncation must be surfaced via the structured marker")
        XCTAssertTrue(result.truncationMarker?.contains("max_chars") ?? false)
        XCTAssertLessThanOrEqual(result.content.count, 50)
        XCTAssertFalse(result.content.contains(longOutput), "full untruncated output must not survive the cap")
    }

    func testPathEscapeAttemptIsRejected() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let tool = TaskOutputTool(permissions: PermissionEngine(workspaceRoot: workspace.path))
        let result = try await tool.execute(arguments: ["archive": "../../etc"])

        XCTAssertTrue(result.isError)
    }
}
