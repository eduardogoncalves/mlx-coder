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

    func testIncludesHiddenEntriesByDefault() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let hiddenFile = workspace.appendingPathComponent(".gitignore")
        let hiddenDir = workspace.appendingPathComponent(".git", isDirectory: true)
        try "*\n".write(to: hiddenFile, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: hiddenDir, withIntermediateDirectories: true)

        let permissions = PermissionEngine(workspaceRoot: workspace.path)
        let tool = ListDirTool(permissions: permissions)
        let result = try await tool.execute(arguments: ["path": "."])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains(".gitignore"))
        XCTAssertTrue(result.content.contains(".git/"))
    }

    func testCanExcludeHiddenEntries() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let hiddenFile = workspace.appendingPathComponent(".env")
        try "TOKEN=1\n".write(to: hiddenFile, atomically: true, encoding: .utf8)

        let permissions = PermissionEngine(workspaceRoot: workspace.path)
        let tool = ListDirTool(permissions: permissions)
        let result = try await tool.execute(arguments: ["path": ".", "include_hidden": false])

        XCTAssertFalse(result.isError)
        XCTAssertFalse(result.content.contains(".env"))
    }

    func testHidesHarnessInternalArtifactsByDefault() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try "hello".write(to: workspace.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "[ ] x".write(to: workspace.appendingPathComponent(".mlx-coder-todo"), atomically: true, encoding: .utf8)
        try "[ ] y".write(to: workspace.appendingPathComponent(".mlx-coder-todo-abc123"), atomically: true, encoding: .utf8)
        try "TOKEN=1".write(to: workspace.appendingPathComponent(".mlx-coder.env"), atomically: true, encoding: .utf8)
        try "[ ] z".write(to: workspace.appendingPathComponent(".native-agent-todo.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent(".native-agent"), withIntermediateDirectories: true)

        let permissions = PermissionEngine(workspaceRoot: workspace.path)
        let tool = ListDirTool(permissions: permissions)
        let result = try await tool.execute(arguments: ["path": "."])

        // Check the emoji-prefixed *entry* forms are absent — the skip-summary
        // line at the bottom legitimately echoes the hidden names, so a raw
        // substring check would false-positive on that.
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("README.md"))
        XCTAssertFalse(result.content.contains("📄 .mlx-coder-todo"))
        XCTAssertFalse(result.content.contains("📄 .mlx-coder.env"))
        XCTAssertFalse(result.content.contains("📄 .native-agent-todo.md"))
        XCTAssertFalse(result.content.contains("📁 .native-agent"))
        XCTAssertTrue(result.content.contains("Skipped build-output / mlx-coder-internal entries"))
    }

    func testIncludeBuildDirsRevealsHarnessArtifacts() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try "TOKEN=1".write(to: workspace.appendingPathComponent(".mlx-coder.env"), atomically: true, encoding: .utf8)

        let permissions = PermissionEngine(workspaceRoot: workspace.path)
        let tool = ListDirTool(permissions: permissions)
        let result = try await tool.execute(arguments: ["path": ".", "include_build_dirs": true])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains(".mlx-coder.env"))
    }

    func testListingHarnessDirectlyIsSkipped() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let logs = workspace.appendingPathComponent(".native-agent/subagent-logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try "{}".write(to: logs.appendingPathComponent("history.json"), atomically: true, encoding: .utf8)

        let permissions = PermissionEngine(workspaceRoot: workspace.path)
        let tool = ListDirTool(permissions: permissions)

        let skipped = try await tool.execute(arguments: ["path": ".native-agent", "recursive": true])
        XCTAssertFalse(skipped.isError)
        XCTAssertFalse(skipped.content.contains("history.json"))
        XCTAssertTrue(skipped.content.contains("internal workspace state"))

        // Escape hatch still works.
        let revealed = try await tool.execute(arguments: ["path": ".native-agent", "recursive": true, "include_build_dirs": true])
        XCTAssertTrue(revealed.content.contains("history.json"))
    }

    private func makeTempWorkspace() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mlx-coder-list-dir-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
