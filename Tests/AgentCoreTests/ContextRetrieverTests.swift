// Tests/AgentCoreTests/ContextRetrieverTests.swift
// Deterministic tests for the lightweight RAG context-retrieval pipeline.
// The LLM stages are never invoked here (the client is unusable); we exercise
// the pure parsing/assembly helpers, the gate, the ignore/dedupe/cap logic, and
// the filesystem-backed materialize + offline fallback paths.

import XCTest
@testable import MLXCoder

final class ContextRetrieverTests: XCTestCase {

    // MARK: - Helpers

    /// A retriever whose LLMClient is unusable (local backend, no container), so
    /// the LLM stages degrade to their fallbacks — perfect for deterministic tests.
    private func makeRetriever(
        permissions: PermissionEngine,
        config: ContextRetrievalConfig = ContextRetrievalConfig(enabled: true),
        graphStore: CodeGraphStore? = nil
    ) -> ContextRetriever {
        let llm = LLMClient(
            backend: .local(modelPath: "/models/none"),
            container: nil,
            baseConfig: GenerationEngine.Config()
        )
        return ContextRetriever(llm: llm, permissions: permissions, config: config, graphStore: graphStore)
    }

    private func makeTempWorkspace() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctxretriever-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Resolve symlinks so paths line up with PermissionEngine's standardized root.
        return URL(filePath: dir.resolvingSymlinksInPath().path)
    }

    /// A freshly-initialized, empty `CodeGraphStore` backed by a temp file —
    /// caller is responsible for closing it and removing `dir`.
    private func makeGraphStore() async throws -> (store: CodeGraphStore, dir: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctxretriever-graph-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = CodeGraphStore(dbPath: dir.appendingPathComponent("codegraph.db").path)
        try await store.initialize()
        return (store, dir.path)
    }

    // MARK: - Gate (Stage 0)

    func testGate_passesForTopLevelCodingNonTrivial() {
        XCTAssertTrue(ContextRetriever.gatePasses(
            enabled: true, isTopLevel: true, isCoding: true,
            message: "Adjust the query handler to also return the origin farm", minChars: 24))
    }

    func testGate_blockedWhenDisabled() {
        XCTAssertFalse(ContextRetriever.gatePasses(
            enabled: false, isTopLevel: true, isCoding: true,
            message: "Adjust the query handler to also return the origin farm", minChars: 24))
    }

    func testGate_blockedForSubAgent() {
        XCTAssertFalse(ContextRetriever.gatePasses(
            enabled: true, isTopLevel: false, isCoding: true,
            message: "Adjust the query handler to also return the origin farm", minChars: 24))
    }

    func testGate_blockedForNonCoding() {
        XCTAssertFalse(ContextRetriever.gatePasses(
            enabled: true, isTopLevel: true, isCoding: false,
            message: "Adjust the query handler to also return the origin farm", minChars: 24))
    }

    func testGate_blockedForTrivialMessage() {
        XCTAssertFalse(ContextRetriever.gatePasses(
            enabled: true, isTopLevel: true, isCoding: true, message: "  hi ", minChars: 24))
    }

    // MARK: - Stage 1 parsing

    func testParseSubqueries_stripsNumberingBulletsQuotesAndFences() {
        let raw = """
        Here are the queries:
        1. ObterCargaRolosMobileQueryHandler
        2) GrupoVariedade
        - FazendaOrigem
        * "FazendaOrigemId"
        ```
        ```
        ObterCargaRolosMobileQueryHandler
        """
        let queries = ContextRetriever.parseSubqueries(raw, max: 5)
        XCTAssertEqual(queries, [
            "ObterCargaRolosMobileQueryHandler",
            "GrupoVariedade",
            "FazendaOrigem",
            "FazendaOrigemId",
        ], "numbering/bullets/quotes/fences/prose stripped and duplicates removed")
    }

    func testParseSubqueries_respectsMax() {
        let raw = "a\nb\nc\nd\ne\nf\ng"
        XCTAssertEqual(ContextRetriever.parseSubqueries(raw, max: 3).count, 3)
    }

    // MARK: - Stage 2 parsing

    func testParseSearchLines_parsesPathLineText() {
        let content = """
        Sources/Foo/Bar.swift:42:func handle() {
        Sources/Foo/Baz.swift:7:class Baz {
        [... 3 more results omitted ...]
        No code symbols matching 'x' found
        Sources/Foo/Bar.swift:99:let x = 1
        """
        let hits = ContextRetriever.parseSearchLines(content)
        XCTAssertEqual(hits.count, 3)
        XCTAssertEqual(hits[0].path, "Sources/Foo/Bar.swift")
        XCTAssertEqual(hits[0].line, 42)
        XCTAssertTrue(hits[0].text.contains("func handle"))
    }

    func testParseSearchLines_skipsUnparsable() {
        let content = "garbage line with no structure\njust text"
        XCTAssertTrue(ContextRetriever.parseSearchLines(content).isEmpty)
    }

    func testAggregateCandidates_dedupesRanksAndCaps() {
        let permissions = PermissionEngine(workspaceRoot: "/tmp/ws")
        let retriever = makeRetriever(permissions: permissions)
        let raw: [(path: String, line: Int, text: String)] = [
            ("A.swift", 1, "hit"),
            ("B.swift", 5, "hit"),
            ("A.swift", 9, "hit"),   // second hit for A → higher rank
            ("A.swift", 12, "hit"),  // third hit for A
            ("C.swift", 2, "hit"),
        ]
        let candidates = retriever.aggregateCandidates(from: raw, cap: 2)
        XCTAssertEqual(candidates.count, 2, "cap respected")
        XCTAssertEqual(candidates[0].path, "A.swift", "most-hit file ranks first")
        XCTAssertEqual(candidates[0].matchCount, 3)
        XCTAssertEqual(candidates[0].line, 1, "representative line is the first seen")
    }

    func testAggregateCandidates_dropsIgnoredPaths() {
        let permissions = PermissionEngine(
            workspaceRoot: "/tmp/ws",
            ignoredPathPatterns: ["*.generated.swift"]
        )
        let retriever = makeRetriever(permissions: permissions)
        let raw: [(path: String, line: Int, text: String)] = [
            ("Keep.swift", 1, "hit"),
            ("Model.generated.swift", 3, "hit"),
        ]
        let candidates = retriever.aggregateCandidates(from: raw, cap: 10)
        XCTAssertEqual(candidates.map(\.path), ["Keep.swift"])
    }

    // MARK: - Stage 2 graph-neighbor fusion (M4, plan §12.1)

    func testExtractSymbolTokens_dedupesAndDropsShortTokens() {
        let tokens = ContextRetriever.extractSymbolTokens(from: ["Foo.Foo a bb ccc"], cap: 10)
        XCTAssertEqual(tokens, ["Foo", "ccc"])
    }

    func testExtractSymbolTokens_respectsCap() {
        let tokens = ContextRetriever.extractSymbolTokens(
            from: ["AAA BBB CCC DDD EEE FFF GGG HHH"], cap: 3
        )
        XCTAssertEqual(tokens.count, 3)
    }

    func testGatherGraphNeighborHits_nilStoreIsNoOp() async {
        let permissions = PermissionEngine(workspaceRoot: "/tmp/ws")
        let retriever = makeRetriever(permissions: permissions)
        let hits = await retriever.gatherGraphNeighborHits(subqueries: ["Foo"])
        XCTAssertTrue(hits.isEmpty, "no graphStore configured ⇒ byte-identical to pre-M4 behavior")
    }

    func testGatherGraphNeighborHits_emptyGraphIsNoOp() async throws {
        let (store, dir) = try await makeGraphStore()
        defer { Task { await store.close(); try? FileManager.default.removeItem(atPath: dir) } }
        let permissions = PermissionEngine(workspaceRoot: "/tmp/ws")
        let retriever = makeRetriever(permissions: permissions, graphStore: store)
        let hits = await retriever.gatherGraphNeighborHits(subqueries: ["Foo"])
        XCTAssertTrue(hits.isEmpty, "empty graph ⇒ no fusion hits")
    }

    func testGatherGraphNeighborHits_findsSymbolAndStructuralNeighborFiles() async throws {
        let (store, dir) = try await makeGraphStore()
        defer { Task { await store.close(); try? FileManager.default.removeItem(atPath: dir) } }

        let baseExtraction = LexicalSymbolExtractor().extract(path: "Base.swift", source: "protocol Greeter {\n}\n")
        _ = try await store.upsertFile(
            path: "Base.swift", contentHash: "h1", language: "swift",
            symbols: baseExtraction.symbols, edges: baseExtraction.edges
        )
        let fooExtraction = LexicalSymbolExtractor().extract(path: "Foo.swift", source: "class Foo: Greeter {\n}\n")
        _ = try await store.upsertFile(
            path: "Foo.swift", contentHash: "h2", language: "swift",
            symbols: fooExtraction.symbols, edges: fooExtraction.edges
        )

        let permissions = PermissionEngine(workspaceRoot: "/tmp/ws")
        let retriever = makeRetriever(permissions: permissions, graphStore: store)
        let hits = await retriever.gatherGraphNeighborHits(subqueries: ["Foo"])
        let paths = Set(hits.map(\.path))
        XCTAssertTrue(paths.contains("Foo.swift"), "the matched symbol's own file is included")
        XCTAssertTrue(paths.contains("Base.swift"), "its structural (implements) neighbor's file is included")
    }

    func testGatherGraphNeighborHits_respectsIgnoredPaths() async throws {
        let (store, dir) = try await makeGraphStore()
        defer { Task { await store.close(); try? FileManager.default.removeItem(atPath: dir) } }
        let extraction = LexicalSymbolExtractor().extract(path: "Secret.generated.swift", source: "class Secret {\n}\n")
        _ = try await store.upsertFile(
            path: "Secret.generated.swift", contentHash: "h1", language: "swift",
            symbols: extraction.symbols, edges: extraction.edges
        )
        let permissions = PermissionEngine(workspaceRoot: "/tmp/ws", ignoredPathPatterns: ["*.generated.swift"])
        let retriever = makeRetriever(permissions: permissions, graphStore: store)
        let hits = await retriever.gatherGraphNeighborHits(subqueries: ["Secret"])
        XCTAssertTrue(hits.isEmpty, "ignored paths must never surface via graph fusion")
    }

    func testGatherCandidates_mergesGraphOnlyNeighborNotFoundLexically() async throws {
        let ws = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        try "protocol Greeter {}\n".write(to: ws.appendingPathComponent("Base.swift"), atomically: true, encoding: .utf8)
        try "class Foo: Greeter {}\n".write(to: ws.appendingPathComponent("Foo.swift"), atomically: true, encoding: .utf8)

        let (store, dir) = try await makeGraphStore()
        defer { Task { await store.close(); try? FileManager.default.removeItem(atPath: dir) } }
        let baseExtraction = LexicalSymbolExtractor().extract(path: "Base.swift", source: "protocol Greeter {}\n")
        _ = try await store.upsertFile(
            path: "Base.swift", contentHash: "h1", language: "swift",
            symbols: baseExtraction.symbols, edges: baseExtraction.edges
        )
        let fooExtraction = LexicalSymbolExtractor().extract(path: "Foo.swift", source: "class Foo: Greeter {}\n")
        _ = try await store.upsertFile(
            path: "Foo.swift", contentHash: "h2", language: "swift",
            symbols: fooExtraction.symbols, edges: fooExtraction.edges
        )

        let permissions = PermissionEngine(workspaceRoot: ws.path)
        let retriever = makeRetriever(permissions: permissions, graphStore: store)
        let candidates = await retriever.gatherCandidates(subqueries: ["Foo"])
        XCTAssertTrue(
            candidates.map(\.path).contains("Base.swift"),
            "Base.swift has no lexical hit for 'Foo' — it only surfaces via graph-neighbor fusion"
        )
    }

    func testGatherCandidates_respectsMaxCandidatesWithGraphHits() async throws {
        let ws = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let (store, dir) = try await makeGraphStore()
        defer { Task { await store.close(); try? FileManager.default.removeItem(atPath: dir) } }
        for i in 0..<5 {
            let name = "S\(i).swift"
            let source = "class Sym\(i) {}\n"
            try source.write(to: ws.appendingPathComponent(name), atomically: true, encoding: .utf8)
            let extraction = LexicalSymbolExtractor().extract(path: name, source: source)
            _ = try await store.upsertFile(path: name, contentHash: "h\(i)", language: "swift", symbols: extraction.symbols, edges: extraction.edges)
        }
        let permissions = PermissionEngine(workspaceRoot: ws.path)
        let retriever = makeRetriever(
            permissions: permissions,
            config: ContextRetrievalConfig(enabled: true, maxCandidates: 2),
            graphStore: store
        )
        let candidates = await retriever.gatherCandidates(subqueries: ["Sym0 Sym1 Sym2 Sym3 Sym4"])
        XCTAssertLessThanOrEqual(candidates.count, 2, "maxCandidates cap still respected with graph fusion merged in")
    }

    // MARK: - Stage 3 answer parsing

    func testParseYesNo() {
        XCTAssertTrue(ContextRetriever.parseYesNo("yes"))
        XCTAssertTrue(ContextRetriever.parseYesNo("  Yes, definitely"))
        XCTAssertTrue(ContextRetriever.parseYesNo("YES"))
        XCTAssertFalse(ContextRetriever.parseYesNo("no"))
        XCTAssertFalse(ContextRetriever.parseYesNo("No, not needed"))
        XCTAssertFalse(ContextRetriever.parseYesNo(""))
    }

    // MARK: - Stage 5 assembly

    func testAssembleContextBlock_wrapsFilesWithDirective() {
        let files = [
            ContextRetriever.MaterializedFile(path: "Sources/Foo/Bar.swift", snippet: "func handle() {}"),
        ]
        let block = ContextRetriever.assembleContextBlock(files: files)
        XCTAssertTrue(block.hasPrefix("<context>"))
        XCTAssertTrue(block.contains("<file path=\"Sources/Foo/Bar.swift\">"))
        XCTAssertTrue(block.contains("```swift"))
        XCTAssertTrue(block.contains("func handle() {}"))
        XCTAssertTrue(block.contains("</context>"))
        XCTAssertTrue(block.contains("Don't reference these context files"))
    }

    func testLanguageHint() {
        XCTAssertEqual(ContextRetriever.languageHint(forPath: "a/b.swift"), "swift")
        XCTAssertEqual(ContextRetriever.languageHint(forPath: "a/b.py"), "python")
        XCTAssertEqual(ContextRetriever.languageHint(forPath: "a/b.cs"), "csharp")
        XCTAssertEqual(ContextRetriever.languageHint(forPath: "a/b.unknown"), "")
    }

    // MARK: - Budget helpers

    func testEstimateTokensAndClamp() {
        XCTAssertEqual(ContextRetriever.estimateTokens(String(repeating: "x", count: 40)), 10)
        let long = String(repeating: "y", count: 10_000)
        let clamped = ContextRetriever.clampSnippet(long, tokenBudget: 100)
        XCTAssertLessThan(clamped.count, long.count)
        XCTAssertTrue(clamped.hasSuffix("[truncated]"))
    }

    // MARK: - Stage 4 materialize (filesystem-backed)

    func testMaterialize_readsRegionAroundLine() async throws {
        let ws = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let body = (1...200).map { "line \($0)" }.joined(separator: "\n")
        let file = ws.appendingPathComponent("Big.swift")
        try body.write(to: file, atomically: true, encoding: .utf8)

        let permissions = PermissionEngine(workspaceRoot: ws.path)
        let retriever = makeRetriever(
            permissions: permissions,
            config: ContextRetrievalConfig(enabled: true, snippetContextLines: 5)
        )
        let candidate = ContextRetriever.Candidate(path: "Big.swift", line: 100, matchText: "", matchCount: 1)
        let materialized = await retriever.materialize(files: [candidate])
        XCTAssertEqual(materialized.count, 1)
        XCTAssertTrue(materialized[0].snippet.contains("line 100"))
        XCTAssertTrue(materialized[0].snippet.contains("line 95"))
        XCTAssertFalse(materialized[0].snippet.contains("line 80"))
    }

    func testMaterialize_stopsAtTokenBudget() async throws {
        let ws = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let body = (1...100).map { "line \($0) padded with extra text to spend budget" }.joined(separator: "\n")
        for name in ["A.swift", "B.swift"] {
            try body.write(to: ws.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        let permissions = PermissionEngine(workspaceRoot: ws.path)
        // Budget large enough for one rendered file but not two.
        let retriever = makeRetriever(
            permissions: permissions,
            config: ContextRetrievalConfig(enabled: true, tokenBudget: 300, snippetContextLines: 20)
        )
        let files = [
            ContextRetriever.Candidate(path: "A.swift", line: 40, matchText: "", matchCount: 2),
            ContextRetriever.Candidate(path: "B.swift", line: 40, matchText: "", matchCount: 1),
        ]
        let materialized = await retriever.materialize(files: files)
        XCTAssertEqual(materialized.count, 1, "budget stops us after the first (most-relevant) file")
        XCTAssertEqual(materialized[0].path, "A.swift")
    }

    // MARK: - Fallback: LLM stages unavailable

    func testFilterByRelevance_offlineFallbackKeepsTopK() async {
        let permissions = PermissionEngine(workspaceRoot: "/tmp/ws")
        let retriever = makeRetriever(
            permissions: permissions,
            config: ContextRetrievalConfig(enabled: true, maxCandidates: 24)
        )
        let candidates = (0..<10).map {
            ContextRetriever.Candidate(path: "F\($0).swift", line: 1, matchText: "", matchCount: 10 - $0)
        }
        // Unusable LLM → keep bounded top-K lexical candidates, never rethrow.
        let survivors = await retriever.filterByRelevance(candidates: candidates, request: "do a thing")
        XCTAssertFalse(survivors.isEmpty)
        XCTAssertLessThanOrEqual(survivors.count, 5)
        XCTAssertEqual(survivors.first?.path, "F0.swift", "top-ranked lexical candidate kept")
    }

    func testRetrieve_returnsNilWhenNoCandidates() async throws {
        let ws = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let permissions = PermissionEngine(workspaceRoot: ws.path)
        let retriever = makeRetriever(permissions: permissions)
        // Empty workspace → lexical search finds nothing → nil (no injection).
        let block = await retriever.retrieve(userRequest: "Adjust NonexistentSymbolXYZ handler")
        XCTAssertNil(block)
    }
}
