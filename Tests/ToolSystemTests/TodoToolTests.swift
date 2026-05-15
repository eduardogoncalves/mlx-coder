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

    func testItemDescriptionIsOneBased() {
        let tool = TodoTool(workspaceRoot: "/tmp")
        let desc = tool.parameters.properties?["item"]?.description ?? ""
        XCTAssertTrue(desc.contains("1-based"), "item description should say 1-based, got: \(desc)")
    }

    func testActionSchemaIncludesUncomplete() {
        let tool = TodoTool(workspaceRoot: "/tmp")
        let actions = tool.parameters.properties?["action"]?.enumValues ?? []
        XCTAssertTrue(actions.contains("uncomplete"))
    }

    func testCompleteRejectsZeroWithRangeHint() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let tool = TodoTool(workspaceRoot: workspace.path)
        _ = try await tool.execute(arguments: ["action": "add", "item_text": "first"])
        _ = try await tool.execute(arguments: ["action": "add", "item_text": "second"])
        _ = try await tool.execute(arguments: ["action": "add", "item_text": "third"])

        let result = try await tool.execute(arguments: ["action": "complete", "item": 0])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("1–3"), "Error should show valid range, got: \(result.content)")
    }

    func testCompleteAcceptsNumericItem() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let tool = TodoTool(workspaceRoot: workspace.path)
        _ = try await tool.execute(arguments: ["action": "add", "item_text": "first"])

        let result = try await tool.execute(arguments: ["action": "complete", "item": 1])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Completed:"))
    }

    func testUncompleteAcceptsNumericItem() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let tool = TodoTool(workspaceRoot: workspace.path)
        _ = try await tool.execute(arguments: ["action": "add", "item_text": "first"])
        _ = try await tool.execute(arguments: ["action": "complete", "item": 1])

        let result = try await tool.execute(arguments: ["action": "uncomplete", "item": 1])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Uncompleted:"))
    }

    func testCompleteRejectsStringItem() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let tool = TodoTool(workspaceRoot: workspace.path)
        _ = try await tool.execute(arguments: ["action": "add", "item_text": "first"])

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

    func testAddPersistsMarkdownUncheckedCheckboxFormat() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let tool = TodoTool(workspaceRoot: workspace.path)
        _ = try await tool.execute(arguments: ["action": "add", "item_text": "first"])

        let todoFile = workspace.appendingPathComponent(".mlx-coder-todo")
        let content = try String(contentsOf: todoFile, encoding: .utf8)
        XCTAssertEqual(content, "[ ] first")
    }

    func testAddRejectsLegacyStringItemField() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let tool = TodoTool(workspaceRoot: workspace.path)
        let result = try await tool.execute(arguments: ["action": "add", "item": "first"])

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("item_text"))
    }

    func testReadNormalizesLegacyUncheckedCheckboxFormat() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try "[] first".write(
            to: workspace.appendingPathComponent(".mlx-coder-todo"),
            atomically: true,
            encoding: .utf8
        )

        let tool = TodoTool(workspaceRoot: workspace.path)
        let result = try await tool.execute(arguments: ["action": "read"])

        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.content, "1. [ ] first")
    }

    func testCompleteNormalizesLegacyUncheckedCheckboxFormatBeforeCompleting() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let todoFile = workspace.appendingPathComponent(".mlx-coder-todo")
        try "[] first".write(to: todoFile, atomically: true, encoding: .utf8)

        let tool = TodoTool(workspaceRoot: workspace.path)
        let result = try await tool.execute(arguments: ["action": "complete", "item": 1])

        XCTAssertFalse(result.isError)
        XCTAssertEqual(try String(contentsOf: todoFile, encoding: .utf8), "[x] first")
    }

    func testCompleteHandlesUncheckedCheckboxWithoutSeparatorSpace() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let todoFile = workspace.appendingPathComponent(".mlx-coder-todo")
        try "[ ]first".write(to: todoFile, atomically: true, encoding: .utf8)

        let tool = TodoTool(workspaceRoot: workspace.path)
        let result = try await tool.execute(arguments: ["action": "complete", "item": 1])

        XCTAssertFalse(result.isError)
        XCTAssertEqual(try String(contentsOf: todoFile, encoding: .utf8), "[x] first")
    }

    func testUncompleteHandlesCheckedCheckboxWithoutSeparatorSpace() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let todoFile = workspace.appendingPathComponent(".mlx-coder-todo")
        try "[x]first".write(to: todoFile, atomically: true, encoding: .utf8)

        let tool = TodoTool(workspaceRoot: workspace.path)
        let result = try await tool.execute(arguments: ["action": "uncomplete", "item": 1])

        XCTAssertFalse(result.isError)
        XCTAssertEqual(try String(contentsOf: todoFile, encoding: .utf8), "[ ] first")
    }

    func testReadFallsBackToLegacyTodoFileName() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try "[ ] first".write(
            to: workspace.appendingPathComponent(".native-agent-todo.md"),
            atomically: true,
            encoding: .utf8
        )

        let tool = TodoTool(workspaceRoot: workspace.path)
        let result = try await tool.execute(arguments: ["action": "read"])

        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.content, "1. [ ] first")
    }

    func testReadNormalizesOrderedMarkdownTodoFormat() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try "1. [ ] first".write(
            to: workspace.appendingPathComponent(".mlx-coder-todo"),
            atomically: true,
            encoding: .utf8
        )

        let tool = TodoTool(workspaceRoot: workspace.path)
        let result = try await tool.execute(arguments: ["action": "read"])

        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.content, "1. [ ] first")
    }

    func testCompleteHandlesOrderedMarkdownTodoFormat() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let todoFile = workspace.appendingPathComponent(".mlx-coder-todo")
        try "1. [ ] first".write(to: todoFile, atomically: true, encoding: .utf8)

        let tool = TodoTool(workspaceRoot: workspace.path)
        let result = try await tool.execute(arguments: ["action": "complete", "item": 1])

        XCTAssertFalse(result.isError)
        XCTAssertEqual(try String(contentsOf: todoFile, encoding: .utf8), "[x] first")
    }

    func testCompleteWarnsWhenPersistFails() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try "[ ] first".write(
            to: workspace.appendingPathComponent(".native-agent-todo.md"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent(".mlx-coder-todo"),
            withIntermediateDirectories: false
        )

        let tool = TodoTool(workspaceRoot: workspace.path)
        let result = try await tool.execute(arguments: ["action": "complete", "item": 1])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("warning: failed to persist todo file changes"))
    }

    func testRemoveWarnsWhenPersistFails() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try "[ ] first".write(
            to: workspace.appendingPathComponent(".native-agent-todo.md"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent(".mlx-coder-todo"),
            withIntermediateDirectories: false
        )

        let tool = TodoTool(workspaceRoot: workspace.path)
        let result = try await tool.execute(arguments: ["action": "remove", "item": 1])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("warning: failed to persist todo file changes"))
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
