import XCTest
@testable import MLXCoder

final class PatchToolTests: XCTestCase {
    func testAppliesValidHunk() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let file = workspace.appendingPathComponent("file.txt")
        try "a\nb\nc\n".write(to: file, atomically: true, encoding: .utf8)

        let permissions = PermissionEngine(workspaceRoot: workspace.path)
        let tool = PatchTool(permissions: permissions)

        let diff = """
@@ -2,1 +2,1 @@
-b
+B
"""

        let result = try await tool.execute(arguments: [
            "path": "file.txt",
            "diff": diff
        ])

        XCTAssertFalse(result.isError)
        let updated = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(updated, "a\nB\nc\n")
    }

    func testContextMismatchReturnsErrorAndDoesNotModifyFile() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let file = workspace.appendingPathComponent("file.txt")
        let original = "first\nsecond\nthird\n"
        try original.write(to: file, atomically: true, encoding: .utf8)

        let permissions = PermissionEngine(workspaceRoot: workspace.path)
        let tool = PatchTool(permissions: permissions)

        let mismatchedDiff = """
@@ -2,1 +2,1 @@
-NOT_SECOND
+new-second
"""

        let result = try await tool.execute(arguments: [
            "path": "file.txt",
            "diff": mismatchedDiff
        ])

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("context mismatch"))

        let after = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(after, original)
    }

    private func makeTempWorkspace() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mlx-coder-patch-tool-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
