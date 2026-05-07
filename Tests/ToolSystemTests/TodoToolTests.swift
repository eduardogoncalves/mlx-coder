import XCTest
@testable import MLXCoder

final class TodoToolTests: XCTestCase {
    func testCompleteAcceptsNumericItem() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let tool = TodoTool(workspaceRoot: workspace.path)
        _ = try await tool.execute(arguments: ["action": "add", "item": "first"])

        let result = try await tool.execute(arguments: ["action": "complete", "item": 1])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Completed:"))
    }

    func testCompleteRejectsStringItem() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let tool = TodoTool(workspaceRoot: workspace.path)
        _ = try await tool.execute(arguments: ["action": "add", "item": "first"])

        let result = try await tool.execute(arguments: ["action": "complete", "item": "1"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("numeric value"))
    }

    private func makeWorkspace() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("test-workspaces", isDirectory: true)
            .appendingPathComponent("mlx-coder-todo-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
