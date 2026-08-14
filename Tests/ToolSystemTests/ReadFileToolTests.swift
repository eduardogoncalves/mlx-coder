import XCTest
@testable import MLXCoder

final class ReadFileToolTests: XCTestCase {
    func testFullReadHasNoTruncationMarker() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try writeLines(count: 20, to: workspace.appendingPathComponent("small.txt"))

        let permissions = PermissionEngine(workspaceRoot: workspace.path)
        let tool = ReadFileTool(permissions: permissions, maxOutputLines: 500)

        let result = try await tool.execute(arguments: ["path": "small.txt"])

        XCTAssertFalse(result.isError)
        XCTAssertNil(result.truncationMarker)
        XCTAssertTrue(result.content.contains("line 20"))
    }

    func testCappedReadReportsLineRangeAndContinuation() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try writeLines(count: 25, to: workspace.appendingPathComponent("big.txt"))

        let permissions = PermissionEngine(workspaceRoot: workspace.path)
        let tool = ReadFileTool(permissions: permissions, maxOutputLines: 10)

        let result = try await tool.execute(arguments: ["path": "big.txt"])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("line 10"))
        XCTAssertFalse(result.content.contains("line 11"))
        let marker = try XCTUnwrap(result.truncationMarker)
        XCTAssertTrue(marker.contains("Read lines 1-10 of 25"))
        XCTAssertTrue(marker.contains("start_line: 11"))
    }

    func testContinuationReadResumesWhereTruncated() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try writeLines(count: 25, to: workspace.appendingPathComponent("big.txt"))

        let permissions = PermissionEngine(workspaceRoot: workspace.path)
        let tool = ReadFileTool(permissions: permissions, maxOutputLines: 10)

        let result = try await tool.execute(arguments: ["path": "big.txt", "start_line": 11])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.hasPrefix("line 11"))
        let marker = try XCTUnwrap(result.truncationMarker)
        XCTAssertTrue(marker.contains("Read lines 11-20 of 25"))
        XCTAssertTrue(marker.contains("start_line: 21"))

        let lastPage = try await tool.execute(arguments: ["path": "big.txt", "start_line": 21])
        XCTAssertFalse(lastPage.isError)
        XCTAssertNil(lastPage.truncationMarker)
        XCTAssertTrue(lastPage.content.contains("line 25"))
    }

    func testExplicitEndLineBeforeEOFStillReportsContinuation() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try writeLines(count: 25, to: workspace.appendingPathComponent("big.txt"))

        let permissions = PermissionEngine(workspaceRoot: workspace.path)
        let tool = ReadFileTool(permissions: permissions, maxOutputLines: 500)

        let result = try await tool.execute(arguments: ["path": "big.txt", "start_line": 5, "end_line": 8])

        XCTAssertFalse(result.isError)
        let marker = try XCTUnwrap(result.truncationMarker)
        XCTAssertTrue(marker.contains("Read lines 5-8 of 25"))
        XCTAssertTrue(marker.contains("start_line: 9"))
    }

    func testTruncatedSkillFileSuggestsReadSkillTool() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let skillDir = workspace.appendingPathComponent("skills/example", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try writeLines(count: 25, to: skillDir.appendingPathComponent("SKILL.md"))

        let permissions = PermissionEngine(workspaceRoot: workspace.path)
        let tool = ReadFileTool(permissions: permissions, maxOutputLines: 10)

        let result = try await tool.execute(arguments: ["path": "skills/example/SKILL.md"])

        XCTAssertFalse(result.isError)
        let marker = try XCTUnwrap(result.truncationMarker)
        XCTAssertTrue(marker.contains("read_skill"))
    }

    func testCRLFFileIsReturnedWithPlainNewlines() async throws {
        // CRLF files (routine in Windows-authored/.NET repos) must not leak a
        // trailing "\r" into the model's view of the file: a model reproduces
        // what it read as "\n"-only text in a later edit_file old_text, and if
        // read_file silently carried the "\r" through, every such edit would
        // fail to match — invisibly, since a bare "\r" renders as nothing (or
        // as a stray line-overwrite glitch) in most terminal output.
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let url = workspace.appendingPathComponent("crlf.txt")
        try "line1\r\nline2\r\nline3\r\n".write(to: url, atomically: true, encoding: .utf8)

        let permissions = PermissionEngine(workspaceRoot: workspace.path)
        let tool = ReadFileTool(permissions: permissions, maxOutputLines: 500)

        let result = try await tool.execute(arguments: ["path": "crlf.txt"])

        XCTAssertFalse(result.isError)
        XCTAssertFalse(result.content.contains("\r"), "no line should carry a trailing carriage return into the model-visible content")
        XCTAssertEqual(result.content, "line1\nline2\nline3")
    }

    private func writeLines(count: Int, to url: URL) throws {
        let content = (1...count).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeTempWorkspace() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mlx-coder-read-file-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
