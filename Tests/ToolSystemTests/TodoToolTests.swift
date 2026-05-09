import XCTest
@testable import MLXCoder

final class TodoToolTests: XCTestCase {
    func testSchemaUsesIntegerItemAndStringItemText() {
        let tool = TodoTool(workspaceRoot: "/tmp")
        let itemSchema = tool.parameters.properties?["item"]
        let itemTextSchema = tool.parameters.properties?["item_text"]

        XCTAssertEqual(itemSchema?.type, "integer")
        XCTAssertEqual(itemTextSchema?.type, "string")
    }

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

    func testAddAcceptsItemTextField() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let tool = TodoTool(workspaceRoot: workspace.path)
        let addResult = try await tool.execute(arguments: ["action": "add", "item_text": "first"])
        XCTAssertFalse(addResult.isError)

        let readResult = try await tool.execute(arguments: ["action": "read"])
        XCTAssertTrue(readResult.content.contains("first"))
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
