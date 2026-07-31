// Tests/CodeGraphTests/CodeGraphExploreToolTests.swift
// Output shape + staleness banner for `code_graph_explore`.

import XCTest
@testable import MLXCoder

final class CodeGraphExploreToolTests: XCTestCase {

    private var workspace: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("test-workspaces", isDirectory: true)
            .appendingPathComponent("codegraph-explore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        workspace = root
        dbURL = root.appendingPathComponent("codegraph.db")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: workspace)
        try await super.tearDown()
    }

    private func write(_ content: String, to relativePath: String) throws {
        let url = workspace.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeIndexer() -> (CodeGraphIndexer, CodeGraphStore) {
        let permissions = PermissionEngine(workspaceRoot: workspace.path)
        let store = CodeGraphStore(dbPath: dbURL.path)
        let indexer = CodeGraphIndexer(store: store, permissions: permissions, config: CodeGraphConfig(enabled: true))
        return (indexer, store)
    }

    func testMissingSymbolsArgumentIsAnError() async throws {
        let (indexer, _) = makeIndexer()
        await indexer.bootstrap()
        let tool = CodeGraphExploreTool(indexer: indexer)

        let result = try await tool.execute(arguments: [:])
        XCTAssertTrue(result.isError)
    }

    func testDisabledIndexerReturnsAnError() async throws {
        let permissions = PermissionEngine(workspaceRoot: workspace.path)
        let store = CodeGraphStore(dbPath: dbURL.path)
        let indexer = CodeGraphIndexer(store: store, permissions: permissions, config: .disabled)
        let tool = CodeGraphExploreTool(indexer: indexer)

        let result = try await tool.execute(arguments: ["symbols": ["Foo"]])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.lowercased().contains("disabled"))
    }

    func testUnknownSymbolReportsNotFound() async throws {
        let (indexer, _) = makeIndexer()
        await indexer.bootstrap()
        let tool = CodeGraphExploreTool(indexer: indexer)

        let result = try await tool.execute(arguments: ["symbols": ["NoSuchSymbol"]])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("No symbol named 'NoSuchSymbol'"))
    }

    func testOutputShapeIncludesLocationHierarchyAndBlastRadius() async throws {
        let (indexer, _) = makeIndexer()
        await indexer.bootstrap()
        try write("class Base {}\n", to: "Base.swift")
        try write("class Foo: Base {\n    func bar() {}\n}\n", to: "Foo.swift")
        await indexer.indexAndWait(paths: ["Base.swift", "Foo.swift"])

        let tool = CodeGraphExploreTool(indexer: indexer)
        let result = try await tool.execute(arguments: ["symbols": ["Foo"], "depth": 1])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Foo.swift::Foo"))
        XCTAssertTrue(result.content.contains("Foo.swift:1-3"))
        XCTAssertTrue(result.content.contains("hierarchy: extends Base"))
    }

    func testStalenessBannerAppearsWhenFilesArePending() async throws {
        let permissions = PermissionEngine(workspaceRoot: workspace.path)
        let store = CodeGraphStore(dbPath: dbURL.path)
        let indexer = CodeGraphIndexer(store: store, permissions: permissions, config: CodeGraphConfig(enabled: true))
        await indexer.bootstrap()
        try write("class Foo {}\n", to: "Foo.swift")

        // Simulates the window between the async fire-and-forget `enqueue`
        // hook and the background drain loop catching up — deterministic
        // (see `debugMarkPending`'s doc comment) rather than racing the real
        // drain loop, whose `pending.popFirst()` happens before any `await`.
        await indexer.debugMarkPending(["Foo.swift"])

        let tool = CodeGraphExploreTool(indexer: indexer)
        let result = try await tool.execute(arguments: ["symbols": ["Foo"]])
        XCTAssertTrue(result.content.contains("Code graph is stale"))
    }
}
