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
