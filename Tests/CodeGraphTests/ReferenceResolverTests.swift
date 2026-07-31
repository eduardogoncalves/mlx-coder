// Tests/CodeGraphTests/ReferenceResolverTests.swift
// Phase-2 join tests: unresolved → resolved, and rename re-resolution.

import XCTest
@testable import MLXCoder

final class ReferenceResolverTests: XCTestCase {

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

    private func extract(_ source: String, path: String) -> ExtractionResult {
        LexicalSymbolExtractor().extract(path: path, source: source)
    }

    /// File A references `Widget` by name before `Widget` has been indexed
    /// anywhere — the edge should land dangling (`dst_id == nil`) but keep
    /// `dst_name`. Once file B (defining `Widget`) is indexed and
    /// `ReferenceResolver.resolveNewSymbols` runs on its inserted symbols,
    /// the dangling edge must resolve.
    func testDanglingReferenceResolvesOnceTargetIsIndexed() async throws {
        let a = extract("class Consumer {\n    func use() -> Widget { fatalError() }\n}\n", path: "A.swift")
        let outcomeA = try await store.upsertFile(path: "A.swift", contentHash: "a1", language: "swift", symbols: a.symbols, edges: a.edges)
        if case .indexed(let inserted) = outcomeA {
            _ = try await ReferenceResolver.resolveNewSymbols(inserted, in: store)
        }

        guard let use = try await store.symbol(key: "A.swift::Consumer.use()") else {
            return XCTFail("expected Consumer.use() symbol")
        }
        let beforeEdges = try await store.outgoingEdges(symbolID: use.id)
        let widgetRefBefore = beforeEdges.first { $0.dstName == "Widget" }
        XCTAssertNotNil(widgetRefBefore)
        XCTAssertNil(widgetRefBefore?.dstId, "target not indexed yet — edge must be dangling")

        let b = extract("class Widget {}\n", path: "B.swift")
        let outcomeB = try await store.upsertFile(path: "B.swift", contentHash: "b1", language: "swift", symbols: b.symbols, edges: b.edges)
        guard case .indexed(let insertedB) = outcomeB else { return XCTFail("expected B to index") }
        let resolvedCount = try await ReferenceResolver.resolveNewSymbols(insertedB, in: store)
        XCTAssertGreaterThan(resolvedCount, 0)

        let afterEdges = try await store.outgoingEdges(symbolID: use.id)
        let widgetRefAfter = afterEdges.first { $0.dstName == "Widget" }
        XCTAssertNotNil(widgetRefAfter?.dstId, "edge must resolve once Widget is indexed")

        guard let widgetSymbol = try await store.symbol(key: "B.swift::Widget") else {
            return XCTFail("expected Widget symbol")
        }
        XCTAssertEqual(widgetRefAfter?.dstId, widgetSymbol.id)
    }

    /// Renaming the file that defines the target (re-indexed under the same
    /// path with a different content hash) re-resolves in-edges without a
    /// full-graph rebuild: the old symbol row is cascade-deleted (edges drop
    /// to dangling), then the new symbol's insertion re-resolves them.
    func testRenameReResolvesReferencesWithoutFullRebuild() async throws {
        let a = extract("class Consumer {\n    func use() -> Widget { fatalError() }\n}\n", path: "A.swift")
        let outcomeA = try await store.upsertFile(path: "A.swift", contentHash: "a1", language: "swift", symbols: a.symbols, edges: a.edges)
        if case .indexed(let inserted) = outcomeA {
            _ = try await ReferenceResolver.resolveNewSymbols(inserted, in: store)
        }

        let bOriginal = extract("class Widget {}\n", path: "B.swift")
        let outcomeBOriginal = try await store.upsertFile(path: "B.swift", contentHash: "b1", language: "swift", symbols: bOriginal.symbols, edges: bOriginal.edges)
        if case .indexed(let insertedB) = outcomeBOriginal {
            _ = try await ReferenceResolver.resolveNewSymbols(insertedB, in: store)
        }

        guard let use = try await store.symbol(key: "A.swift::Consumer.use()") else {
            return XCTFail("expected Consumer.use() symbol")
        }
        let resolvedBefore = try await store.outgoingEdges(symbolID: use.id).first { $0.dstName == "Widget" }
        XCTAssertNotNil(resolvedBefore?.dstId)

        // "Rename": file B is edited to rename `Widget` → `WidgetV2`, then re-indexed
        // under a new content hash (cascade-deletes the old `Widget` symbol).
        let bRenamed = extract("class WidgetV2 {}\n", path: "B.swift")
        let outcomeBRenamed = try await store.upsertFile(path: "B.swift", contentHash: "b2", language: "swift", symbols: bRenamed.symbols, edges: bRenamed.edges)
        guard case .indexed = outcomeBRenamed else { return XCTFail("expected re-index on rename") }

        let danglingAfterRename = try await store.outgoingEdges(symbolID: use.id).first { $0.dstName == "Widget" }
        XCTAssertNil(danglingAfterRename?.dstId, "old target symbol is gone — edge falls back to dangling")

        // Now file A is edited to use the new name and re-indexed; its fresh
        // `references` edge to `WidgetV2` should resolve immediately via
        // upsertFile's own best-effort resolution (no separate rename-tracking
        // needed — this is the "re-resolve, don't chase renames" model, plan §10.3).
        let aRenamed = extract("class Consumer {\n    func use() -> WidgetV2 { fatalError() }\n}\n", path: "A.swift")
        let outcomeARenamed = try await store.upsertFile(path: "A.swift", contentHash: "a2", language: "swift", symbols: aRenamed.symbols, edges: aRenamed.edges)
        guard case .indexed(let insertedARenamed) = outcomeARenamed else { return XCTFail("expected re-index of A") }
        _ = try await ReferenceResolver.resolveNewSymbols(insertedARenamed, in: store)

        guard let useAfter = try await store.symbol(key: "A.swift::Consumer.use()") else {
            return XCTFail("expected Consumer.use() symbol after rename")
        }
        let resolvedAfter = try await store.outgoingEdges(symbolID: useAfter.id).first { $0.dstName == "WidgetV2" }
        XCTAssertNotNil(resolvedAfter?.dstId, "reference to the renamed symbol must resolve")
    }
}
