// Tests/CodeGraphTests/CodeGraphStoreTests.swift
// Upsert / content-hash no-op / cascade delete / FTS tests for CodeGraphStore.

import XCTest
@testable import MLXCoder

final class CodeGraphStoreTests: XCTestCase {

    private var tempDir: String!
    private var store: CodeGraphStore!

    override func setUp() async throws {
        try await super.setUp()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempDir = url.path
        let dbPath = (tempDir as NSString).appendingPathComponent("codegraph.db")
        store = CodeGraphStore(dbPath: dbPath)
        try await store.initialize()
    }

    override func tearDown() async throws {
        await store.close()
        try? FileManager.default.removeItem(atPath: tempDir)
        try await super.tearDown()
    }

    private func extract(_ source: String, path: String = "Foo.swift") -> ExtractionResult {
        LexicalSymbolExtractor().extract(path: path, source: source)
    }

    // MARK: - Upsert / re-index

    func testUpsertInsertsSymbolsAndEdges() async throws {
        let source = """
        import Foundation

        class Foo: Base {
        }
        """
        let extraction = extract(source)
        let outcome = try await store.upsertFile(
            path: "Foo.swift", contentHash: "h1", language: "swift",
            symbols: extraction.symbols, edges: extraction.edges
        )
        guard case .indexed(let inserted) = outcome else { return XCTFail("expected .indexed") }
        XCTAssertEqual(inserted.count, extraction.symbols.count)

        let rows = try await store.symbolsIn(path: "Foo.swift")
        XCTAssertTrue(rows.contains { $0.name == "Foo" && $0.kind == "class" })

        let fooKey = "Foo.swift::Foo"
        let foo = try await store.symbol(key: fooKey)
        XCTAssertNotNil(foo, "symbol_key must be <path>::<qualifiedName>")

        let stats = try await store.stats()
        XCTAssertEqual(stats.fileCount, 1)
        XCTAssertGreaterThan(stats.symbolCount, 0)
        XCTAssertGreaterThan(stats.edgeCount, 0)
    }

    func testUnchangedContentHashIsANoOp() async throws {
        let extraction = extract("class Foo {}\n")
        let first = try await store.upsertFile(
            path: "Foo.swift", contentHash: "samehash", language: "swift",
            symbols: extraction.symbols, edges: extraction.edges
        )
        guard case .indexed = first else { return XCTFail("expected first upsert to index") }

        let second = try await store.upsertFile(
            path: "Foo.swift", contentHash: "samehash", language: "swift",
            symbols: extraction.symbols, edges: extraction.edges
        )
        XCTAssertEqual(second, .unchanged)
    }

    func testChangedContentHashReindexes() async throws {
        let v1 = extract("class Foo {}\n")
        _ = try await store.upsertFile(path: "Foo.swift", contentHash: "h1", language: "swift", symbols: v1.symbols, edges: v1.edges)

        let v2 = extract("class Foo {\n    func bar() {}\n}\n")
        let outcome = try await store.upsertFile(path: "Foo.swift", contentHash: "h2", language: "swift", symbols: v2.symbols, edges: v2.edges)
        guard case .indexed = outcome else { return XCTFail("expected re-index on hash change") }

        let rows = try await store.symbolsIn(path: "Foo.swift")
        XCTAssertTrue(rows.contains { $0.name == "bar" })
    }

    // MARK: - Cascade delete

    func testRemoveFileCascadesSymbolsAndEdges() async throws {
        let extraction = extract("class Foo: Base {\n    func bar() {}\n}\n")
        _ = try await store.upsertFile(path: "Foo.swift", contentHash: "h1", language: "swift", symbols: extraction.symbols, edges: extraction.edges)
        let before = try await store.symbolsIn(path: "Foo.swift")
        XCTAssertFalse(before.isEmpty)

        try await store.removeFile(path: "Foo.swift")

        let after = try await store.symbolsIn(path: "Foo.swift")
        XCTAssertTrue(after.isEmpty)
        let hash = try await store.fileContentHash(path: "Foo.swift")
        XCTAssertNil(hash)
        let stats = try await store.stats()
        XCTAssertEqual(stats.fileCount, 0)
        XCTAssertEqual(stats.symbolCount, 0)
        XCTAssertEqual(stats.edgeCount, 0, "cascade delete must also remove the file's out-edges")
    }

    /// Deleting a file that other files' edges point at should drop `dst_id`
    /// to NULL (cascade `SET NULL`) while preserving `dst_name` for later
    /// re-resolution — never silently deleting the referencing edge.
    func testRemovingReferencedFileLeavesDanglingButPreservedEdge() async throws {
        let target = extract("class Target {}\n", path: "Target.swift")
        _ = try await store.upsertFile(path: "Target.swift", contentHash: "t1", language: "swift", symbols: target.symbols, edges: target.edges)
        guard let targetSymbol = try await store.symbol(key: "Target.swift::Target") else {
            return XCTFail("expected Target symbol")
        }

        let referrer = extract("class Referrer: Target {}\n", path: "Referrer.swift")
        _ = try await store.upsertFile(path: "Referrer.swift", contentHash: "r1", language: "swift", symbols: referrer.symbols, edges: referrer.edges)

        let beforeIncoming = try await store.incomingEdges(symbolID: targetSymbol.id, name: "Target")
        XCTAssertTrue(beforeIncoming.contains { $0.dstId == targetSymbol.id })

        try await store.removeFile(path: "Target.swift")

        let afterIncoming = try await store.incomingEdges(symbolID: targetSymbol.id, name: "Target")
        // dst_id is now unresolvable (target symbol gone) but dst_name survives.
        XCTAssertTrue(afterIncoming.contains { $0.dstId == nil && $0.dstName == "Target" })
    }

    // MARK: - FTS

    func testSearchSymbolsFindsByName() async throws {
        let extraction = extract("class RepositoryManager {}\n", path: "Repo.swift")
        _ = try await store.upsertFile(path: "Repo.swift", contentHash: "h1", language: "swift", symbols: extraction.symbols, edges: extraction.edges)

        let hits = try await store.searchSymbols(query: "Repository", limit: 5)
        XCTAssertTrue(hits.contains { $0.name == "RepositoryManager" })
    }

    func testFTSStaysInSyncAfterDeleteViaTrigger() async throws {
        let extraction = extract("class Ephemeral {}\n", path: "Eph.swift")
        _ = try await store.upsertFile(path: "Eph.swift", contentHash: "h1", language: "swift", symbols: extraction.symbols, edges: extraction.edges)
        let before = try await store.searchSymbols(query: "Ephemeral", limit: 5)
        XCTAssertFalse(before.isEmpty)

        try await store.removeFile(path: "Eph.swift")
        let after = try await store.searchSymbols(query: "Ephemeral", limit: 5)
        XCTAssertTrue(after.isEmpty, "FTS row must be removed by the AFTER DELETE trigger")
    }

    // MARK: - user_version drop + rebuild

    func testReopeningWithSameSchemaVersionPreservesData() async throws {
        let extraction = extract("class Persisted {}\n", path: "P.swift")
        _ = try await store.upsertFile(path: "P.swift", contentHash: "h1", language: "swift", symbols: extraction.symbols, edges: extraction.edges)
        await store.close()

        let dbPath = (tempDir as NSString).appendingPathComponent("codegraph.db")
        let reopened = CodeGraphStore(dbPath: dbPath)
        try await reopened.initialize()
        let rows = try await reopened.symbolsIn(path: "P.swift")
        XCTAssertFalse(rows.isEmpty, "data must survive a reopen at the same schema version")
        await reopened.close()
    }

    func testDropAndRecreateWipesData() async throws {
        let extraction = extract("class Temp {}\n", path: "T.swift")
        _ = try await store.upsertFile(path: "T.swift", contentHash: "h1", language: "swift", symbols: extraction.symbols, edges: extraction.edges)
        let before = try await store.symbolsIn(path: "T.swift")
        XCTAssertFalse(before.isEmpty)

        try await store.dropAndRecreate()
        let after = try await store.symbolsIn(path: "T.swift")
        XCTAssertTrue(after.isEmpty)
        let stats = try await store.stats()
        XCTAssertEqual(stats.fileCount, 0)
    }
}
