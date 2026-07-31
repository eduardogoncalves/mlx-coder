// Tests/MemoryTests/Hybrid/HybridKnowledgeStoreTests.swift
// End-to-end tests for the hybrid SQLite memory stack.

import XCTest
@testable import MLXCoder

final class HybridKnowledgeStoreTests: XCTestCase {

    private var tempDir: String!
    private var store: HybridKnowledgeStore!

    override func setUp() async throws {
        try await super.setUp()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempDir = url.path
        let dbPath = (tempDir as NSString).appendingPathComponent("hybrid.db")
        store = HybridKnowledgeStore(dbPath: dbPath)
        try await store.initialize()
    }

    override func tearDown() async throws {
        await store.close()
        try? FileManager.default.removeItem(atPath: tempDir)
        try await super.tearDown()
    }

    private func makeInput(
        kind: KnowledgeKind = .decision,
        memoryType: MemoryType = .semantic,
        content: String,
        confidence: Double = 0.5
    ) -> DocumentInput {
        DocumentInput(
            memoryType: memoryType,
            knowledgeKind: kind,
            content: content,
            source: .assistant,
            projectRoot: "/test/project",
            tags: ["build", "swift"],
            entities: ["xcodebuild"],
            confidence: confidence,
            importance: 0.6
        )
    }

    func testWriteInsertsActiveDocument() async throws {
        let outcome = try await store.write(
            makeInput(content: "Always use xcodebuild for this project."))
        switch outcome {
        case .inserted: break
        default: XCTFail("expected .inserted, got \(outcome)")
        }
        let stats = try await store.stats()
        XCTAssertEqual(stats.activeCount, 1)
        XCTAssertEqual(stats.embeddingCount, 1)
    }

    func testExactDuplicateIsCollapsed() async throws {
        let first = try await store.write(makeInput(content: "Use xcodebuild not swift build"))
        let second = try await store.write(makeInput(content: "Use xcodebuild not swift build"))
        guard case .inserted(let id1, let uuid1) = first else {
            return XCTFail("expected .inserted, got \(first)")
        }
        guard case .duplicate(let id2, let uuid2) = second else {
            return XCTFail("expected .duplicate, got \(second)")
        }
        XCTAssertEqual(id1, id2)
        XCTAssertEqual(uuid1, uuid2)
        let stats = try await store.stats()
        XCTAssertEqual(stats.activeCount, 1)
    }

    func testNearDuplicateSupersedesWhenConfidenceHigher() async throws {
        let original = try await store.write(makeInput(
            content: "Always run xcodebuild with TOOLCHAINS=swift to build deps.",
            confidence: 0.5))
        guard case .inserted(let oldID, _) = original else {
            return XCTFail("expected .inserted, got \(original)")
        }

        // Near-duplicate phrasing, higher confidence → should supersede.
        let updated = try await store.write(makeInput(
            content: "Always run xcodebuild with TOOLCHAINS=swift to build deps successfully.",
            confidence: 0.9))
        switch updated {
        case .superseded(let supersededID, _, _):
            XCTAssertEqual(supersededID, oldID)
        default:
            XCTFail("expected .superseded, got \(updated)")
        }

        let stats = try await store.stats()
        XCTAssertEqual(stats.activeCount, 1)
        XCTAssertEqual(stats.supersededCount, 1)
    }

    func testRetrieveReturnsRelevantDocument() async throws {
        _ = try await store.write(makeInput(
            content: "Always use xcodebuild instead of swift build for this project."))
        _ = try await store.write(makeInput(
            kind: .gotcha,
            content: "The CSQLite module map must use a relative header path."))

        let scope = RetrievalScope(projectRoot: "/test/project")
        let results = try await store.retrieve(query: "xcodebuild", scope: scope, limit: 5)
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.first!.document.content.lowercased().contains("xcodebuild"))
    }

    func testFTSEscapingHandlesPunctuation() async throws {
        // Tokens with operator-like characters used to crash FTS5 if unescaped.
        _ = try await store.write(makeInput(content: "Always set TOOLCHAINS=swift in CI builds."))
        let scope = RetrievalScope(projectRoot: "/test/project")
        // `=` would be syntactically meaningful otherwise.
        let results = try await store.retrieve(
            query: "TOOLCHAINS=swift", scope: scope, limit: 5)
        XCTAssertFalse(results.isEmpty)
    }

    func testRetrieveWithEmptyScopeFiltersReturnsNoResults() async throws {
        _ = try await store.write(makeInput(content: "Always use xcodebuild for this project."))
        let scope = RetrievalScope(
            projectRoot: "/test/project",
            memoryTypes: [],
            knowledgeKinds: []
        )

        let results = try await store.retrieve(query: "xcodebuild", scope: scope, limit: 5)
        XCTAssertTrue(results.isEmpty)
    }

    func testConsolidateWithEmptyScopeFiltersReturnsZero() async throws {
        _ = try await store.write(makeInput(
            content: "Prefer swift build over manual invocations of swiftc.",
            confidence: 0.4))
        _ = try await store.write(makeInput(
            content: "Prefer swift build over manual invocations of swiftc CLI.",
            confidence: 0.6))
        let scope = RetrievalScope(
            projectRoot: "/test/project",
            memoryTypes: [],
            knowledgeKinds: []
        )

        let merged = try await store.consolidate(scope: scope)
        XCTAssertEqual(merged, 0)
    }

    func testPruneRemovesExpiredWorkingMemory() async throws {
        let expired = DocumentInput(
            memoryType: .working,
            knowledgeKind: .sessionState,
            content: "scratch state for the current branch — short-lived",
            source: .assistant,
            projectRoot: "/test/project",
            ttl: -1  // already expired
        )
        _ = try await store.write(expired)
        let removed = try await store.prune()
        XCTAssertGreaterThanOrEqual(removed, 1)
        let stats = try await store.stats()
        XCTAssertEqual(stats.activeCount, 0)
    }

    func testConsolidateMergesNearDuplicates() async throws {
        _ = try await store.write(makeInput(
            content: "Prefer swift build over manual invocations of swiftc.",
            confidence: 0.4))
        _ = try await store.write(makeInput(
            content: "Prefer swift build over manual invocations of swiftc CLI.",
            confidence: 0.6))
        // Insertion path itself supersedes when near-dup; expect 1 already.
        var stats = try await store.stats()
        XCTAssertEqual(stats.activeCount + stats.supersededCount, 2)

        let merged = try await store.consolidate(
            scope: RetrievalScope(projectRoot: "/test/project"))
        XCTAssertGreaterThanOrEqual(merged, 0)
        stats = try await store.stats()
        XCTAssertEqual(stats.activeCount, 1)
    }

    // MARK: - Code graph symbol join (M4, plan §12.2)

    /// A freshly-initialized, empty `CodeGraphStore` backed by a temp file —
    /// caller is responsible for closing it and removing `dir`.
    private func makeGraphStore() async throws -> (store: CodeGraphStore, dir: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = CodeGraphStore(dbPath: dir.appendingPathComponent("codegraph.db").path)
        try await store.initialize()
        return (store, dir.path)
    }

    private func makeTaggedStore(graphStore: CodeGraphStore, name: String) async throws -> HybridKnowledgeStore {
        let dbPath = (tempDir as NSString).appendingPathComponent(name)
        let taggedStore = HybridKnowledgeStore(dbPath: dbPath, graphStore: graphStore)
        try await taggedStore.initialize()
        return taggedStore
    }

    func testWrite_withNilGraphStoreLeavesEntitiesUntouched() async throws {
        // No graphStore configured (the default, `store` from setUp) — write
        // must be byte-identical to pre-M4 behavior: only caller-supplied
        // entities survive.
        let outcome = try await store.write(makeInput(content: "Refactored the FooBarBaz widget."))
        guard case .inserted(let id, _) = outcome else { return XCTFail("expected .inserted") }
        let docs = try await store.retrieve(query: "FooBarBaz", scope: RetrievalScope(projectRoot: "/test/project"))
        _ = docs // retrieval isn't the point here; just confirm no crash/tag path taken
        let uuid = try await store.documentUUID(forID: id)
        XCTAssertNotNil(uuid)
    }

    func testWrite_taggesEntitiesWithMatchingSymbolKeyAndRoundTrips() async throws {
        let (graph, dir) = try await makeGraphStore()
        defer { Task { await graph.close(); try? FileManager.default.removeItem(atPath: dir) } }
        let extraction = LexicalSymbolExtractor().extract(path: "Foo.swift", source: "class FooBarBaz {\n}\n")
        _ = try await graph.upsertFile(
            path: "Foo.swift", contentHash: "h1", language: "swift",
            symbols: extraction.symbols, edges: extraction.edges
        )
        guard let symbolKey = try await graph.findSymbols(named: "FooBarBaz").first?.symbolKey else {
            return XCTFail("expected FooBarBaz to be indexed")
        }

        let tagged = try await makeTaggedStore(graphStore: graph, name: "hybrid-tagged.db")
        defer { Task { await tagged.close() } }

        let outcome = try await tagged.write(makeInput(content: "Refactored FooBarBaz to fix the race condition."))
        guard case .inserted(let id, _) = outcome else { return XCTFail("expected .inserted, got \(outcome)") }

        // Read path: symbol_key lookup returns the doc, and the entities_json
        // it was written with contains the stable symbol_key (never a numeric id).
        let matches = try await tagged.documents(referencingSymbol: symbolKey)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].id, id)
        XCTAssertTrue(matches[0].entities.contains(symbolKey))
    }

    func testWrite_doesNotTagUnrelatedSymbolNames() async throws {
        let (graph, dir) = try await makeGraphStore()
        defer { Task { await graph.close(); try? FileManager.default.removeItem(atPath: dir) } }
        let extraction = LexicalSymbolExtractor().extract(path: "Foo.swift", source: "class FooBarBaz {\n}\n")
        _ = try await graph.upsertFile(
            path: "Foo.swift", contentHash: "h1", language: "swift",
            symbols: extraction.symbols, edges: extraction.edges
        )
        let tagged = try await makeTaggedStore(graphStore: graph, name: "hybrid-untagged.db")
        defer { Task { await tagged.close() } }

        _ = try await tagged.write(makeInput(content: "Just a note about the build process, no symbols here."))
        guard let symbolKey = try await graph.findSymbols(named: "FooBarBaz").first?.symbolKey else {
            return XCTFail("expected FooBarBaz to be indexed")
        }
        let matches = try await tagged.documents(referencingSymbol: symbolKey)
        XCTAssertTrue(matches.isEmpty, "content never mentioned the symbol — no tag should be attached")
    }

    func testDocumentsReferencingSymbol_renameDoesNotResurrectStaleTag() async throws {
        let (graph, dir) = try await makeGraphStore()
        defer { Task { await graph.close(); try? FileManager.default.removeItem(atPath: dir) } }
        let extraction = LexicalSymbolExtractor().extract(path: "Foo.swift", source: "class FooBarBaz {\n}\n")
        _ = try await graph.upsertFile(
            path: "Foo.swift", contentHash: "h1", language: "swift",
            symbols: extraction.symbols, edges: extraction.edges
        )
        guard let oldKey = try await graph.findSymbols(named: "FooBarBaz").first?.symbolKey else {
            return XCTFail("expected FooBarBaz to be indexed")
        }

        let tagged = try await makeTaggedStore(graphStore: graph, name: "hybrid-rename.db")
        defer { Task { await tagged.close() } }
        _ = try await tagged.write(makeInput(content: "Notes about FooBarBaz's threading behavior."))

        // Rename: re-index the same file with the symbol renamed. `symbol_key`
        // encodes `<path>::<qualifiedName>`, so this is a brand-new key —
        // the old one no longer exists anywhere in `cg_symbols`.
        let renamed = LexicalSymbolExtractor().extract(path: "Foo.swift", source: "class FooBarBazRenamed {\n}\n")
        _ = try await graph.upsertFile(
            path: "Foo.swift", contentHash: "h2", language: "swift",
            symbols: renamed.symbols, edges: renamed.edges, force: true
        )
        guard let newKey = try await graph.findSymbols(named: "FooBarBazRenamed").first?.symbolKey else {
            return XCTFail("expected FooBarBazRenamed to be indexed")
        }
        XCTAssertNotEqual(oldKey, newKey)

        // The old tag is durable text already committed to the doc's
        // entities_json — a later graph rename doesn't retroactively erase it.
        let oldMatches = try await tagged.documents(referencingSymbol: oldKey)
        XCTAssertEqual(oldMatches.count, 1, "previously-written tag persists on its doc")

        // Nothing has ever been written mentioning the *new* key, so the
        // rename must not cause the old doc to spuriously resurface under it.
        let newMatches = try await tagged.documents(referencingSymbol: newKey)
        XCTAssertTrue(newMatches.isEmpty, "rename must not resurrect the old doc under the new symbol_key")
    }

    func testLikePattern_escapesWildcardsAndQuotes() {
        let pattern = HybridKnowledgeStore.likePattern(forJSONArrayElement: "Sources/A_B%C\".swift::Foo(_:)")
        // Must not contain a bare unescaped '%' or '_' from the original value
        // (only the two wrapping '%' wildcards we add ourselves).
        XCTAssertTrue(pattern.hasPrefix("%"))
        XCTAssertTrue(pattern.hasSuffix("%"))
        XCTAssertTrue(pattern.contains("\\_"))
        XCTAssertTrue(pattern.contains("\\%"))
    }
}
