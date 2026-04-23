import XCTest
@testable import MLXCoder

final class EditFileToolTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempWorkspace() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mlx-coder-edit-file-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ content: String, named name: String, in workspace: URL) throws -> URL {
        let url = workspace.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Success path: replacement applied and diff returned

    func testSuccessfulEditReturnsDiff() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try write("line1\nfoo\nline3\n", named: "file.txt", in: workspace)

        let tool = EditFileTool(permissions: PermissionEngine(workspaceRoot: workspace.path))
        let result = try await tool.execute(arguments: [
            "path": "file.txt",
            "old_text": "foo",
            "new_text": "bar"
        ])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Applied edit to file.txt"))
        XCTAssertTrue(result.content.contains("-foo"), "diff should show removed line")
        XCTAssertTrue(result.content.contains("+bar"), "diff should show added line")

        let written = try String(contentsOf: workspace.appendingPathComponent("file.txt"), encoding: .utf8)
        XCTAssertEqual(written, "line1\nbar\nline3\n")
    }

    func testSuccessfulEditDiffContainsHunkHeader() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try write("alpha\nbeta\ngamma\n", named: "f.txt", in: workspace)

        let tool = EditFileTool(permissions: PermissionEngine(workspaceRoot: workspace.path))
        let result = try await tool.execute(arguments: [
            "path": "f.txt",
            "old_text": "beta",
            "new_text": "BETA"
        ])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("@@"), "diff should contain a hunk header")
        XCTAssertTrue(result.content.contains("--- a/f.txt"))
        XCTAssertTrue(result.content.contains("+++ b/f.txt"))
    }

    // MARK: - Error: old_text not found

    func testOldTextNotFoundReturnsError() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try write("hello world\n", named: "file.txt", in: workspace)

        let tool = EditFileTool(permissions: PermissionEngine(workspaceRoot: workspace.path))
        let result = try await tool.execute(arguments: [
            "path": "file.txt",
            "old_text": "does not exist",
            "new_text": "replacement"
        ])

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.lowercased().contains("not found"))
    }

    // MARK: - Error: old_text appears more than once

    func testDuplicateOldTextReturnsError() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try write("foo\nfoo\n", named: "file.txt", in: workspace)

        let tool = EditFileTool(permissions: PermissionEngine(workspaceRoot: workspace.path))
        let result = try await tool.execute(arguments: [
            "path": "file.txt",
            "old_text": "foo",
            "new_text": "bar"
        ])

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("2"), "error should mention occurrence count")
        XCTAssertTrue(result.content.contains("unique"),
                      "error should say old_text must be unique")
    }

    // MARK: - generateUnifiedDiff unit tests

    func testDiffHelperSingleLineChange() {
        let tool = EditFileTool(permissions: PermissionEngine(workspaceRoot: NSTemporaryDirectory()))
        let orig    = "a\nb\nc\n"
        let updated = "a\nB\nc\n"
        let diff = tool.generateUnifiedDiff(original: orig, updated: updated, path: "x.txt")

        XCTAssertTrue(diff.contains("-b"))
        XCTAssertTrue(diff.contains("+B"))
        XCTAssertTrue(diff.contains("@@"))
    }

    func testDiffHelperNoChanges() {
        let tool = EditFileTool(permissions: PermissionEngine(workspaceRoot: NSTemporaryDirectory()))
        let content = "same\n"
        let diff = tool.generateUnifiedDiff(original: content, updated: content, path: "x.txt")
        XCTAssertEqual(diff, "(no changes)")
    }

    func testDiffHelperContextLines() {
        let tool = EditFileTool(permissions: PermissionEngine(workspaceRoot: NSTemporaryDirectory()))
        let orig    = "1\n2\n3\n4\nOLD\n6\n7\n8\n9\n"
        let updated = "1\n2\n3\n4\nNEW\n6\n7\n8\n9\n"
        let diff = tool.generateUnifiedDiff(original: orig, updated: updated, path: "x.txt")

        // Should include 3 lines of context before and after the change
        XCTAssertTrue(diff.contains(" 2"), "context line 2")
        XCTAssertTrue(diff.contains(" 3"), "context line 3")
        XCTAssertTrue(diff.contains(" 4"), "context line 4 (leading context)")
        XCTAssertTrue(diff.contains(" 6"), "context line 6 (trailing context)")
        XCTAssertTrue(diff.contains(" 7"), "context line 7")
        XCTAssertTrue(diff.contains(" 8"), "context line 8")
        XCTAssertTrue(diff.contains("-OLD"))
        XCTAssertTrue(diff.contains("+NEW"))
    }
}
