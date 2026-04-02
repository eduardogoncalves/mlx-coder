import XCTest
@testable import MLXCoder

final class ListDirToolTests: XCTestCase {
    func testMaxDepthZeroListsTopLevelEntries() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let topFile = workspace.appendingPathComponent("README.md")
        let nestedDir = workspace.appendingPathComponent("Sources")
        let nestedFile = nestedDir.appendingPathComponent("main.swift")

        try "hello".write(to: topFile, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        try "print(1)".write(to: nestedFile, atomically: true, encoding: .utf8)

        let permissions = PermissionEngine(workspaceRoot: workspace.path)
        let tool = ListDirTool(permissions: permissions)

        let result = try await tool.execute(arguments: ["path": ".", "max_depth": 0])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("README.md"))
        XCTAssertTrue(result.content.contains("Sources/"))
        XCTAssertFalse(result.content.contains("Sources/main.swift"))
    }

    func testRecursiveWithDepthZeroDoesNotDescendIntoChildren() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let nestedDir = workspace.appendingPathComponent("Sources")
        let nestedFile = nestedDir.appendingPathComponent("main.swift")

        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        try "print(1)".write(to: nestedFile, atomically: true, encoding: .utf8)

        let permissions = PermissionEngine(workspaceRoot: workspace.path)
        let tool = ListDirTool(permissions: permissions)

        let result = try await tool.execute(arguments: ["path": ".", "recursive": true, "max_depth": 0])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Sources/"))
        XCTAssertFalse(result.content.contains("Sources/main.swift"))
    }

    private func makeTempWorkspace() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mlx-coder-list-dir-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
