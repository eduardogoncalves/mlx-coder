// Tests/MemoryTests/Hybrid/MemoryChunkerTests.swift
// Pure-string chunker tests + smoke tests for HybridKnowledgeStore.writeChunked
// and the feedback-score path.

import XCTest
@testable import MLXCoder

final class MemoryChunkerTests: XCTestCase {

    func testEmptyAndShortInputsReturnSingleOrEmpty() {
        XCTAssertEqual(MemoryChunker.chunk(""), [])
        XCTAssertEqual(MemoryChunker.chunk("   \n  \n"), [])

        let short = "This is short."
        XCTAssertEqual(MemoryChunker.chunk(short), [short])
    }

    func testParagraphBoundariesArePreferred() {
        // Three paragraphs, each well under maxChars; together they exceed it.
        let p1 = String(repeating: "alpha ", count: 80)   // ~480 chars
        let p2 = String(repeating: "beta ",  count: 80)   // ~400 chars
        let p3 = String(repeating: "gamma ", count: 80)   // ~480 chars
        let text = "\(p1)\n\n\(p2)\n\n\(p3)"
        let chunks = MemoryChunker.chunk(text, maxChars: 600, overlap: 20)
        XCTAssertGreaterThan(chunks.count, 1)
        // Every chunk should be smaller than maxChars+overlap window.
        for c in chunks { XCTAssertLessThanOrEqual(c.count, 700) }
        // Joined chunks should still mention all three paragraph markers.
        let joined = chunks.joined(separator: " ")
        XCTAssertTrue(joined.contains("alpha"))
        XCTAssertTrue(joined.contains("beta"))
        XCTAssertTrue(joined.contains("gamma"))
    }

    func testHardCapWhenNoBoundary() {
        // Single 5000-char blob with no whitespace at all → forced hard cuts.
        let blob = String(repeating: "x", count: 5_000)
        let chunks = MemoryChunker.chunk(blob, maxChars: 1_000, overlap: 50)
        XCTAssertGreaterThanOrEqual(chunks.count, 5)
        for c in chunks { XCTAssertLessThanOrEqual(c.count, 1_000) }
    }

    func testChunkTagRoundTrip() {
        let g = UUID()
        let tag = MemoryChunker.chunkTag(groupID: g, index: 2, total: 5)
        let parsed = MemoryChunker.parseChunkTag(in: ["unrelated", tag, "x"])
        XCTAssertEqual(parsed?.group, g)
        XCTAssertEqual(parsed?.index, 2)
        XCTAssertEqual(parsed?.total, 5)
        XCTAssertNil(MemoryChunker.parseChunkTag(in: ["chunk:not-a-uuid:1/2"]))
        XCTAssertNil(MemoryChunker.parseChunkTag(in: ["nope"]))
    }
}

final class HybridStoreChunkedAndFeedbackTests: XCTestCase {

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

    private func makeInput(content: String) -> DocumentInput {
        DocumentInput(
            memoryType: .semantic,
            knowledgeKind: .decision,
            content: content,
            source: .assistant,
            projectRoot: "/test/project",
            tags: ["seed"],
            confidence: 0.5,
            importance: 0.5
        )
    }

    // MARK: - writeChunked

    func testWriteChunkedShortContentReturnsSingleOutcome() async throws {
        let outcomes = try await store.writeChunked(
            makeInput(content: "tiny note"),
            maxChars: 200
        )
        XCTAssertEqual(outcomes.count, 1)
    }

    func testWriteChunkedSplitsLongContentAndTagsSiblings() async throws {
        // Use varied content per paragraph so chunk-level dedup does not
        // collapse siblings (the store treats identical-content chunks as
        // exact duplicates and returns `.duplicate` instead of `.inserted`).
        let p1 = String(repeating: "alpha ", count: 200) // ~1200 chars
        let p2 = String(repeating: "beta ",  count: 200)
        let p3 = String(repeating: "gamma ", count: 200)
        let text = "\(p1)\n\n\(p2)\n\n\(p3)"
        let outcomes = try await store.writeChunked(
            makeInput(content: text),
            maxChars: 800,
            overlap: 40
        )
        XCTAssertGreaterThan(outcomes.count, 1)
        // Every outcome should be a fresh insert (varied content → no dedup).
        for outcome in outcomes {
            if case .duplicate = outcome {
                XCTFail("unexpected duplicate among chunked siblings: \(outcome)")
            }
        }
        let stats = try await store.stats()
        XCTAssertEqual(stats.activeCount, outcomes.count)
        XCTAssertEqual(stats.embeddingCount, outcomes.count)
    }

    // MARK: - feedback

    func testRecordFeedbackAccumulatesAndClamps() async throws {
        let outcome = try await store.write(makeInput(content: "Use xcodebuild always."))
        guard case let .inserted(id, uuid) = outcome else {
            XCTFail("expected .inserted"); return
        }

        // First upvote: score should be exactly 0.5.
        let s1 = try await store.recordFeedback(documentID: id, delta: .upvote)
        XCTAssertEqual(s1 ?? -99, 0.5, accuracy: 0.0001)

        // Second upvote: would push to 1.0 (clamped).
        let s2 = try await store.recordFeedback(documentID: id, delta: .upvote)
        XCTAssertEqual(s2 ?? -99, 1.0, accuracy: 0.0001)

        // Third upvote: stays clamped at 1.0.
        let s3 = try await store.recordFeedback(documentID: id, delta: .upvote)
        XCTAssertEqual(s3 ?? -99, 1.0, accuracy: 0.0001)

        // Strong downvote: clamps at -1.0 (1.0 + (-1.0) = 0.0; one more strong
        // downvote pushes to -1.0).
        _ = try await store.recordFeedback(documentUUID: uuid, delta: .strongDownvote)
        let s5 = try await store.recordFeedback(documentUUID: uuid, delta: .strongDownvote)
        XCTAssertEqual(s5 ?? 99, -1.0, accuracy: 0.0001)
    }

    func testRecordFeedbackOnMissingDocumentReturnsNil() async throws {
        let result = try await store.recordFeedback(documentID: 999_999, delta: .upvote)
        XCTAssertNil(result)
    }
}
