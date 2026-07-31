// Tests/CodeGraphTests/SemanticEdgeEnricherTests.swift
// Call-hierarchy JSON parsing (plan §13.5) + indexer wiring for M5b
// enrichment, and the "server absent ⇒ syntactic fallback, no throw"
// contract. Deliberately does NOT spawn a real language server — the pure
// parser is tested against canned JSON, and the "server absent" case uses a
// bogus `LSPServerSpec` (nonexistent executable) so `LSPBridge.start` fails
// fast and offline, exactly like a missing sourcekit-lsp/tsserver install
// would in the wild.

import XCTest
@testable import MLXCoder

// MARK: - Pure parser tests (no I/O)

final class LSPCallHierarchyParserTests: XCTestCase {

    func testParsesPrepareCallHierarchyItems() {
        let json = """
        [
          {
            "name": "bar",
            "kind": 6,
            "uri": "file:///Foo.swift",
            "range": { "start": { "line": 3, "character": 9 }, "end": { "line": 3, "character": 12 } },
            "selectionRange": { "start": { "line": 3, "character": 9 }, "end": { "line": 3, "character": 12 } }
          }
        ]
        """
        let items = LSPCallHierarchyParser.parseItems(fromJSONText: json)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.name, "bar")
        XCTAssertEqual(items.first?.uri, "file:///Foo.swift")
        XCTAssertEqual(items.first?.startLine, 3)
        XCTAssertEqual(items.first?.startCharacter, 9)
    }

    func testParsesOutgoingCalls() {
        let json = """
        [
          { "to": { "name": "baz", "kind": 6, "uri": "file:///Foo.swift",
                     "range": {"start":{"line":10,"character":4},"end":{"line":10,"character":7}},
                     "selectionRange": {"start":{"line":10,"character":4},"end":{"line":10,"character":7}} },
            "fromRanges": [] }
        ]
        """
        let calls = LSPCallHierarchyParser.parseOutgoingCalls(fromJSONText: json)
        XCTAssertEqual(calls, [LSPResolvedCall(calleeName: "baz", calleeURI: "file:///Foo.swift")])
    }

    func testParsesIncomingCalls() {
        let json = """
        [
          { "from": { "name": "caller", "kind": 6, "uri": "file:///Foo.swift",
                       "range": {"start":{"line":1,"character":0},"end":{"line":1,"character":6}},
                       "selectionRange": {"start":{"line":1,"character":0},"end":{"line":1,"character":6}} },
            "fromRanges": [] }
        ]
        """
        let calls = LSPCallHierarchyParser.parseIncomingCalls(fromJSONText: json)
        XCTAssertEqual(calls, [LSPResolvedCall(calleeName: "caller", calleeURI: "file:///Foo.swift")])
    }

    func testNullResponseParsesToEmpty() {
        XCTAssertEqual(LSPCallHierarchyParser.parseItems(fromJSONText: "null"), [])
        XCTAssertEqual(LSPCallHierarchyParser.parseOutgoingCalls(fromJSONText: "null"), [])
    }

    func testMalformedJSONNeverThrowsJustReturnsEmpty() {
        XCTAssertEqual(LSPCallHierarchyParser.parseItems(fromJSONText: "{not json"), [])
        XCTAssertEqual(LSPCallHierarchyParser.parseOutgoingCalls(fromJSONText: "not even close"), [])
    }
}

// MARK: - Mock enricher (indexer wiring)

private actor MockSemanticEdgeEnricher: SemanticEdgeEnricher {
    private var edgesByPath: [String: [RawEdge]]
    private(set) var callCount = 0

    init(edgesByPath: [String: [RawEdge]]) {
        self.edgesByPath = edgesByPath
    }

    func enrichCalls(path: String, symbols: [RawSymbol]) async -> [RawEdge] {
        callCount += 1
        return edgesByPath[path] ?? []
    }
}

final class SemanticEdgeEnricherIndexerWiringTests: XCTestCase {

    private var workspace: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("test-workspaces", isDirectory: true)
            .appendingPathComponent("codegraph-enrich-\(UUID().uuidString)", isDirectory: true)
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

    func testSynchronousEnrichmentReplacesSyntacticCallsEdges() async throws {
        let permissions = PermissionEngine(workspaceRoot: workspace.path)
        let store = CodeGraphStore(dbPath: dbURL.path)

        try write(
            """
            class Foo {
                func bar() {
                    self.wrongGuess()
                }
            }
            """,
            to: "Foo.swift"
        )

        // Base extraction with enrichment OFF, so the automatic
        // fire-and-forget enrichment Task (see `enqueueEnrichment`) can't
        // race this test's "before" snapshot of the syntactic edges — a
        // second indexer below drives enrichment explicitly instead.
        let baseIndexer = CodeGraphIndexer(store: store, permissions: permissions, config: CodeGraphConfig(enabled: true, treeSitter: true))
        await baseIndexer.bootstrap()
        await baseIndexer.indexAndWait(paths: ["Foo.swift"])

        let symbols = try await store.symbolsIn(path: "Foo.swift")
        guard let bar = symbols.first(where: { $0.name == "bar" }) else { return XCTFail("expected bar symbol") }
        let beforeOutgoing = try await store.outgoingEdges(symbolID: bar.id)
        XCTAssertTrue(beforeOutgoing.contains { $0.kind == "calls" && $0.dstName == "wrongGuess" })

        // Enrichment supersedes it with the "resolved" edge.
        let mock = MockSemanticEdgeEnricher(edgesByPath: [
            "Foo.swift": [RawEdge(srcQualifiedName: "Foo.bar()", dstName: "resolvedCallee", kind: .calls)]
        ])
        let enrichConfig = CodeGraphConfig(enabled: true, treeSitter: true, callEnrichment: true)
        let enrichIndexer = CodeGraphIndexer(store: store, permissions: permissions, config: enrichConfig, enricher: mock)
        await enrichIndexer.bootstrap()
        await enrichIndexer.indexAndEnrichSynchronously(paths: ["Foo.swift"])

        let afterOutgoing = try await store.outgoingEdges(symbolID: bar.id)
        XCTAssertFalse(afterOutgoing.contains { $0.kind == "calls" && $0.dstName == "wrongGuess" }, "syntactic calls edge should have been replaced")
        XCTAssertTrue(afterOutgoing.contains { $0.kind == "calls" && $0.dstName == "resolvedCallee" }, "expected the enriched calls edge")
    }

    func testDetachedEnrichmentEventuallyAppliesViaNormalIndexAndWait() async throws {
        let permissions = PermissionEngine(workspaceRoot: workspace.path)
        let store = CodeGraphStore(dbPath: dbURL.path)
        let config = CodeGraphConfig(enabled: true, treeSitter: true, callEnrichment: true)

        try write("class Foo { func bar() { self.baz() } }", to: "Foo.swift")

        let mock = MockSemanticEdgeEnricher(edgesByPath: [
            "Foo.swift": [RawEdge(srcQualifiedName: "Foo.bar()", dstName: "resolvedCallee", kind: .calls)]
        ])
        let indexer = CodeGraphIndexer(store: store, permissions: permissions, config: config, enricher: mock)
        await indexer.bootstrap()

        // indexAndWait only awaits the synchronous base-extraction path; the
        // enrichment Task it fires is detached (off the critical path, plan
        // §4/§13.1) — poll the indexer's own completion counter instead of a
        // raw sleep to await it deterministically.
        await indexer.indexAndWait(paths: ["Foo.swift"])
        var completed = 0
        for _ in 0..<200 {
            completed = await indexer.enrichmentCompletedCount()
            if completed >= 1 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(completed, 1)

        let symbols = try await store.symbolsIn(path: "Foo.swift")
        guard let bar = symbols.first(where: { $0.name == "bar" }) else { return XCTFail("expected bar symbol") }
        let outgoing = try await store.outgoingEdges(symbolID: bar.id)
        XCTAssertTrue(outgoing.contains { $0.kind == "calls" && $0.dstName == "resolvedCallee" })
    }

    func testEnrichmentDisabledNeverInvokesEnricher() async throws {
        let permissions = PermissionEngine(workspaceRoot: workspace.path)
        let store = CodeGraphStore(dbPath: dbURL.path)
        // callEnrichment defaults to false.
        let config = CodeGraphConfig(enabled: true, treeSitter: true)
        try write("class Foo { func bar() {} }", to: "Foo.swift")

        let mock = MockSemanticEdgeEnricher(edgesByPath: [:])
        let indexer = CodeGraphIndexer(store: store, permissions: permissions, config: config, enricher: mock)
        await indexer.bootstrap()
        await indexer.indexAndWait(paths: ["Foo.swift"])

        // Give any (incorrectly) fired background task a moment, then assert
        // it never ran.
        try await Task.sleep(nanoseconds: 30_000_000)
        let calls = await mock.callCount
        XCTAssertEqual(calls, 0, "enricher must never be invoked when callEnrichment is off")
    }
}

// MARK: - Server-absent ⇒ graceful degrade, never throws

final class LSPCallHierarchyEnricherServerAbsentTests: XCTestCase {

    private var workspace: URL!

    override func setUp() async throws {
        try await super.setUp()
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("test-workspaces", isDirectory: true)
            .appendingPathComponent("codegraph-enrich-absent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        workspace = root
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: workspace)
        try await super.tearDown()
    }

    func testMissingServerBinaryDegradesToEmptyEdgesWithoutThrowing() async throws {
        // A registry entry pointing at a language server binary that does
        // not exist — mirrors a real "sourcekit-lsp/tsserver not installed"
        // environment, fully offline.
        let bogusSpec = LSPServerSpec(
            languageId: "swift",
            executableName: "definitely-not-a-real-language-server-binary-xyz",
            installHint: "n/a"
        )
        let table: [String: LanguageServerRegistryEntry] = [
            "swift": LanguageServerRegistryEntry(language: "swift", treeSitterLanguageID: .swift, lspServer: bogusSpec),
        ]
        let registry = LanguageServerRegistry(entriesByExtension: table)
        let permissions = PermissionEngine(workspaceRoot: workspace.path)
        let enricher = LSPCallHierarchyEnricher(registry: registry, permissions: permissions)

        let fileURL = workspace.appendingPathComponent("Foo.swift")
        try "class Foo { func bar() { self.baz() } }".write(to: fileURL, atomically: true, encoding: .utf8)

        let symbol = RawSymbol(
            qualifiedName: "Foo.bar()", name: "bar", kind: .method, parent: "Foo",
            startLine: 1, endLine: 1, signature: "func bar()"
        )

        // Must not throw (the protocol method itself isn't `throws`), and
        // must degrade to an empty result rather than hang or crash.
        let edges = await enricher.enrichCalls(path: "Foo.swift", symbols: [symbol])
        XCTAssertTrue(edges.isEmpty)

        // A second call for the same (now known-bad) language must
        // short-circuit rather than re-attempt a doomed launch.
        let edgesAgain = await enricher.enrichCalls(path: "Foo.swift", symbols: [symbol])
        XCTAssertTrue(edgesAgain.isEmpty)
    }

    func testUnknownLanguageOrNoLSPEntryDegradesToEmptyEdges() async throws {
        let registry = LanguageServerRegistry(entriesByExtension: [:]) // nothing registered
        let permissions = PermissionEngine(workspaceRoot: workspace.path)
        let enricher = LSPCallHierarchyEnricher(registry: registry, permissions: permissions)

        let symbol = RawSymbol(qualifiedName: "Foo.bar()", name: "bar", kind: .method, parent: "Foo", startLine: 1, endLine: 1)
        let edges = await enricher.enrichCalls(path: "Foo.cs", symbols: [symbol])
        XCTAssertTrue(edges.isEmpty)
    }
}
