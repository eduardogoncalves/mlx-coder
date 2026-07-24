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
        // Force saveTodos to fail writes to the new file path while still
        // allowing loadTodos to read the legacy fallback content above.
        // Note: placing a *directory* at the `.mlx-coder-todo` path means every
        // subsequent saveTodos call in this test will also fail — that is
        // intentional: we want a persistently broken write path for the duration
        // of the test. The workspace is torn down by the `defer` above, so this
        // does not pollute other tests.
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
        // Force saveTodos to fail writes to the new file path while still
        // allowing loadTodos to read the legacy fallback content above.
        // Note: placing a *directory* at the `.mlx-coder-todo` path means every
        // subsequent saveTodos call in this test will also fail — that is
        // intentional: we want a persistently broken write path for the duration
        // of the test. The workspace is torn down by the `defer` above, so this
        // does not pollute other tests.
        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent(".mlx-coder-todo"),
            withIntermediateDirectories: false
        )

        let tool = TodoTool(workspaceRoot: workspace.path)
        let result = try await tool.execute(arguments: ["action": "remove", "item": 1])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("warning: failed to persist todo file changes"))
    }

    // MARK: - Session namespacing (R2: fresh orchestrator run doesn't inherit stale items)

    func testDifferentSessionNamespacesDoNotShareItems() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let toolA = TodoTool(workspaceRoot: workspace.path, sessionNamespace: "session-a")
        _ = try await toolA.execute(arguments: ["action": "add", "item_text": "session A item"])

        let toolB = TodoTool(workspaceRoot: workspace.path, sessionNamespace: "session-b")
        let readB = try await toolB.execute(arguments: ["action": "read"])

        XCTAssertFalse(readB.content.contains("session A item"), "session-b should not see session-a's items, got: \(readB.content)")
        XCTAssertEqual(readB.content, "(no todos)")
    }

    func testSameSessionNamespacePersistsAcrossInstances() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let toolA1 = TodoTool(workspaceRoot: workspace.path, sessionNamespace: "session-same")
        _ = try await toolA1.execute(arguments: ["action": "add", "item_text": "persisted item"])

        // A second TodoTool instance constructed with the SAME namespace (as
        // happens across turns within one AgentLoop run, since sessionId is
        // stable for the loop's lifetime) must still see the item.
        let toolA2 = TodoTool(workspaceRoot: workspace.path, sessionNamespace: "session-same")
        let read = try await toolA2.execute(arguments: ["action": "read"])

        XCTAssertTrue(read.content.contains("persisted item"), "same-namespace instance should see prior items, got: \(read.content)")
    }

    func testSessionNamespaceUsesDistinctFileFromDefaultTodoFile() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let defaultTool = TodoTool(workspaceRoot: workspace.path)
        _ = try await defaultTool.execute(arguments: ["action": "add", "item_text": "default item"])

        let namespacedTool = TodoTool(workspaceRoot: workspace.path, sessionNamespace: "some-session")
        let read = try await namespacedTool.execute(arguments: ["action": "read"])

        XCTAssertEqual(read.content, "(no todos)", "namespaced tool should not see the un-namespaced default file's items")

        let defaultFile = workspace.appendingPathComponent(".mlx-coder-todo")
        XCTAssertTrue(FileManager.default.fileExists(atPath: defaultFile.path), "default file should be untouched")
        let defaultContent = try String(contentsOf: defaultFile, encoding: .utf8)
        XCTAssertTrue(defaultContent.contains("default item"))
    }

    func testConstructingNamespacedToolCleansUpOtherStaleNamespacedFiles() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let staleFile1 = workspace.appendingPathComponent(".mlx-coder-todo-old-session-1")
        let staleFile2 = workspace.appendingPathComponent(".mlx-coder-todo-old-session-2")
        try "[ ] leftover from an old run".write(to: staleFile1, atomically: true, encoding: .utf8)
        try "[ ] another leftover".write(to: staleFile2, atomically: true, encoding: .utf8)

        // Constructing a TodoTool for a brand-new session namespace should
        // sweep away stale namespaced files from earlier runs.
        _ = TodoTool(workspaceRoot: workspace.path, sessionNamespace: "fresh-session")

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleFile1.path), "stale namespaced file should be cleaned up on startup")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleFile2.path), "stale namespaced file should be cleaned up on startup")
    }

    func testStaleNamespaceCleanupDoesNotTouchDefaultOrLegacyFiles() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let defaultFile = workspace.appendingPathComponent(".mlx-coder-todo")
        let legacyFile = workspace.appendingPathComponent(".native-agent-todo.md")
        try "[ ] default item".write(to: defaultFile, atomically: true, encoding: .utf8)
        try "[ ] legacy item".write(to: legacyFile, atomically: true, encoding: .utf8)

        _ = TodoTool(workspaceRoot: workspace.path, sessionNamespace: "fresh-session")

        XCTAssertTrue(FileManager.default.fileExists(atPath: defaultFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyFile.path))
    }

    // MARK: - Ephemeral (sub-agent) todos (R1: isolated scratch space, no leakage)

    func testEphemeralTodoStartsEmptyEvenWithExistingPersistentItems() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let persistentTool = TodoTool(workspaceRoot: workspace.path)
        _ = try await persistentTool.execute(arguments: ["action": "add", "item_text": "orchestrator item"])

        let ephemeralTool = TodoTool(workspaceRoot: workspace.path, ephemeral: true)
        let read = try await ephemeralTool.execute(arguments: ["action": "read"])

        XCTAssertEqual(read.content, "(no todos)", "ephemeral todo must start empty, got: \(read.content)")
    }

    func testEphemeralTodoDoesNotModifyThePersistentFile() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let persistentTool = TodoTool(workspaceRoot: workspace.path)
        _ = try await persistentTool.execute(arguments: ["action": "add", "item_text": "orchestrator item"])

        let ephemeralTool = TodoTool(workspaceRoot: workspace.path, ephemeral: true)
        _ = try await ephemeralTool.execute(arguments: ["action": "add", "item_text": "sub-agent scratch item"])
        _ = try await ephemeralTool.execute(arguments: ["action": "complete", "item": 1])

        let defaultFile = workspace.appendingPathComponent(".mlx-coder-todo")
        let content = try String(contentsOf: defaultFile, encoding: .utf8)
        XCTAssertEqual(content, "[ ] orchestrator item", "ephemeral writes must never reach the persistent file")

        // And no stray file was created anywhere in the workspace for the
        // ephemeral instance either.
        let entries = try FileManager.default.contentsOfDirectory(atPath: workspace.path)
        XCTAssertEqual(Set(entries), [".mlx-coder-todo"])
    }

    func testEphemeralTodoReadsAndWritesWithinItsOwnLifetime() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let ephemeralTool = TodoTool(workspaceRoot: workspace.path, ephemeral: true)
        _ = try await ephemeralTool.execute(arguments: ["action": "add", "item_text": "scratch item"])
        let read = try await ephemeralTool.execute(arguments: ["action": "read"])

        XCTAssertEqual(read.content, "1. [ ] scratch item")
    }

    func testTwoEphemeralTodoInstancesAreIsolatedFromEachOther() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let ephemeralA = TodoTool(workspaceRoot: workspace.path, ephemeral: true)
        _ = try await ephemeralA.execute(arguments: ["action": "add", "item_text": "sub-agent A item"])

        let ephemeralB = TodoTool(workspaceRoot: workspace.path, ephemeral: true)
        let readB = try await ephemeralB.execute(arguments: ["action": "read"])

        XCTAssertEqual(readB.content, "(no todos)", "sibling sub-agents must not share ephemeral todo state")
    }

    // MARK: - Back-compat (default constructor keeps today's exact behavior)

    func testDefaultConstructorStillReadsLegacyAndWritesDefaultFile() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try "[ ] legacy item".write(
            to: workspace.appendingPathComponent(".native-agent-todo.md"),
            atomically: true,
            encoding: .utf8
        )

        let tool = TodoTool(workspaceRoot: workspace.path)
        let read = try await tool.execute(arguments: ["action": "read"])
        XCTAssertEqual(read.content, "1. [ ] legacy item")

        _ = try await tool.execute(arguments: ["action": "add", "item_text": "new item"])

        let defaultFile = workspace.appendingPathComponent(".mlx-coder-todo")
        XCTAssertTrue(FileManager.default.fileExists(atPath: defaultFile.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".native-agent-todo.md").path),
            "legacy file should be migrated away after a successful persist, same as before"
        )
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
