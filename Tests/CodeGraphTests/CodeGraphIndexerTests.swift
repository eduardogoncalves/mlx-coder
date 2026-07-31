// Tests/CodeGraphTests/CodeGraphIndexerTests.swift
// Incremental indexing, ignore rules, size cap, and a mutating-tool → graph
// integration smoke test.

import XCTest
@testable import MLXCoder

final class CodeGraphIndexerTests: XCTestCase {

    private var workspace: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("test-workspaces", isDirectory: true)
            .appendingPathComponent("codegraph-indexer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        workspace = root
        dbURL = root.appendingPathComponent("codegraph.db")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: workspace)
        try await super.tearDown()
    }

    private func makeIndexer(
        maxFileBytes: Int = 1_000_000,
        ignoredPathPatterns: [String] = []
    ) -> (CodeGraphIndexer, CodeGraphStore) {
        let permissions = PermissionEngine(workspaceRoot: workspace.path, ignoredPathPatterns: ignoredPathPatterns)
        let store = CodeGraphStore(dbPath: dbURL.path)
        let config = CodeGraphConfig(enabled: true, maxFileBytes: maxFileBytes)
        let indexer = CodeGraphIndexer(store: store, permissions: permissions, config: config)
        return (indexer, store)
    }

    private func write(_ content: String, to relativePath: String) throws {
        let url = workspace.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Incremental indexing

    func testEnqueueIndexesAModifiedFile() async throws {
        let (indexer, store) = makeIndexer()
        await indexer.bootstrap()
        try write("class Foo {}\n", to: "Foo.swift")

        await indexer.indexAndWait(paths: ["Foo.swift"])

        let rows = try await store.symbolsIn(path: "Foo.swift")
        XCTAssertTrue(rows.contains { $0.name == "Foo" })
        let status = await indexer.status()
        XCTAssertEqual(status.pendingCount, 0)
        XCTAssertNil(status.lastError)
    }

    func testIncrementalReindexPicksUpNewSymbol() async throws {
        let (indexer, store) = makeIndexer()
        await indexer.bootstrap()
        try write("class Foo {}\n", to: "Foo.swift")
        await indexer.indexAndWait(paths: ["Foo.swift"])
        let before = try await store.symbolsIn(path: "Foo.swift")
        XCTAssertFalse(before.contains { $0.name == "bar" })

        try write("class Foo {\n    func bar() {}\n}\n", to: "Foo.swift")
        await indexer.indexAndWait(paths: ["Foo.swift"])

        let after = try await store.symbolsIn(path: "Foo.swift")
        XCTAssertTrue(after.contains { $0.name == "bar" })
    }

    func testDeletedFileIsRemovedFromGraph() async throws {
        let (indexer, store) = makeIndexer()
        await indexer.bootstrap()
        try write("class Foo {}\n", to: "Foo.swift")
        await indexer.indexAndWait(paths: ["Foo.swift"])
        let before = try await store.symbolsIn(path: "Foo.swift")
        XCTAssertFalse(before.isEmpty)

        try FileManager.default.removeItem(at: workspace.appendingPathComponent("Foo.swift"))
        await indexer.indexAndWait(paths: ["Foo.swift"])

        let after = try await store.symbolsIn(path: "Foo.swift")
        XCTAssertTrue(after.isEmpty)
    }

    // MARK: - Disabled config is a true no-op

    func testDisabledConfigNeverTouchesTheStore() async throws {
        let permissions = PermissionEngine(workspaceRoot: workspace.path)
        let store = CodeGraphStore(dbPath: dbURL.path)
        let indexer = CodeGraphIndexer(store: store, permissions: permissions, config: .disabled)
        try write("class Foo {}\n", to: "Foo.swift")

        await indexer.bootstrap() // no-op: config.enabled == false
        await indexer.indexAndWait(paths: ["Foo.swift"]) // no-op: not initialized

        // The DB file shouldn't even have been opened/created.
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbURL.path))
        let status = await indexer.status()
        XCTAssertFalse(status.enabled)
    }

    // MARK: - Ignore rules

    func testIgnoredPathIsNeverIndexed() async throws {
        let (indexer, store) = makeIndexer(ignoredPathPatterns: ["Generated/*"])
        await indexer.bootstrap()
        try write("class Skip {}\n", to: "Generated/Skip.swift")

        await indexer.indexAndWait(paths: ["Generated/Skip.swift"])

        let rows = try await store.symbolsIn(path: "Generated/Skip.swift")
        XCTAssertTrue(rows.isEmpty)
        let stats = try await store.stats()
        XCTAssertEqual(stats.fileCount, 0)
    }

    func testNonSwiftPathIsSilentlyIgnoredNotStale() async throws {
        let (indexer, _) = makeIndexer()
        await indexer.bootstrap()
        try write("{}", to: "config.json")

        await indexer.indexAndWait(paths: ["config.json"])

        let status = await indexer.status()
        XCTAssertEqual(status.pendingCount, 0, "unsupported languages must not accumulate as pending/stale")
    }

    // MARK: - Size cap

    func testOversizedFileIsSkipped() async throws {
        // `CodeGraphConfig` clamps `maxFileBytes` to a minimum of 1024 (a
        // pathologically small cap isn't a real-world config), so the fixture
        // content must exceed *that*, not the requested value.
        let (indexer, store) = makeIndexer(maxFileBytes: 100)
        await indexer.bootstrap()
        let huge = "class Big {\n" + String(repeating: "    // padding line to exceed the byte cap\n", count: 60) + "}\n"
        XCTAssertGreaterThan(huge.utf8.count, 1024)
        try write(huge, to: "Big.swift")

        await indexer.indexAndWait(paths: ["Big.swift"])

        let rows = try await store.symbolsIn(path: "Big.swift")
        XCTAssertTrue(rows.isEmpty)
        let status = await indexer.status()
        XCTAssertNil(status.lastError, "an oversized file is a silent skip, not an indexing failure")
    }

    // MARK: - Workspace scan discovery

    func testDiscoverSourceFilesPrunesBuildDirectoriesAndRespectsIgnorePatterns() throws {
        try write("class A {}\n", to: "Sources/A.swift")
        try write("class B {}\n", to: ".build/checkouts/B.swift")
        try write("class C {}\n", to: "Vendor/C.swift")
        let permissions = PermissionEngine(workspaceRoot: workspace.path, ignoredPathPatterns: ["Vendor/*"])

        let discovered = CodeGraphIndexer.discoverSourceFiles(root: workspace.path, permissions: permissions, maxFileBytes: 1_000_000)

        XCTAssertTrue(discovered.contains("Sources/A.swift"))
        XCTAssertFalse(discovered.contains(where: { $0.contains(".build") }))
        XCTAssertFalse(discovered.contains(where: { $0.contains("Vendor") }))
    }

    // MARK: - Integration: mutating-tool event → graph updated

    func testMutatingToolEventUpdatesGraph() async throws {
        let permissions = PermissionEngine(workspaceRoot: workspace.path)
        let store = CodeGraphStore(dbPath: dbURL.path)
        let indexer = CodeGraphIndexer(store: store, permissions: permissions, config: CodeGraphConfig(enabled: true))
        await indexer.bootstrap()

        // Simulate the real seam: a mutating tool (WriteFileTool) executes,
        // and the caller (AgentLoop's end-of-turn hook) enqueues its path.
        let tool = WriteFileTool(permissions: permissions)
        let result = try await tool.execute(arguments: ["path": "Widget.swift", "content": "class Widget {}\n"])
        XCTAssertFalse(result.isError)

        await indexer.indexAndWait(paths: ["Widget.swift"])

        let rows = try await store.symbolsIn(path: "Widget.swift")
        XCTAssertTrue(rows.contains { $0.name == "Widget" })
    }
}
