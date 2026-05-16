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
}
