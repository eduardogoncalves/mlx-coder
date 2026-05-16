// Tests/MemoryTests/Hybrid/ReflectorTests.swift
// Self-improvement loop: trigger gating, candidate write-through, supersede.

import XCTest
@testable import MLXCoder

final class ReflectorTests: XCTestCase {

    private var tempDir: String!
    private var store: HybridKnowledgeStore!

    override func setUp() async throws {
        try await super.setUp()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempDir = url.path
        let dbPath = (tempDir as NSString).appendingPathComponent("reflector.db")
        store = HybridKnowledgeStore(dbPath: dbPath)
        try await store.initialize()
    }

    override func tearDown() async throws {
        await store.close()
        try? FileManager.default.removeItem(atPath: tempDir)
        try await super.tearDown()
    }

    func testCadenceGatesTurnCompleted() async {
        let reflector = Reflector(store: store)
        let outcomes = await reflector.reflect(ReflectionInput(
            trigger: .turnCompleted(turnIndex: 1),
            projectRoot: "/test/project",
            recentAssistantText: ["We decided to always use xcodebuild for this project."]
        ))
        XCTAssertTrue(outcomes.isEmpty, "turnCompleted should not fire by itself")
    }

    func testCadenceFiresOnMultiple() async {
        let reflector = Reflector(
            store: store,
            cadence: ReflectionCadence(nudgeInterval: 3, minContentChars: 10))
        // Line starts with "always " so the heuristic extractor will pick it up.
        let outcomes = await reflector.reflect(ReflectionInput(
            trigger: .cadence(everyNTurns: 3, currentCount: 6),
            projectRoot: "/test/project",
            recentAssistantText: ["Always use xcodebuild when building Apple platform targets."]
        ))
        XCTAssertFalse(outcomes.isEmpty)
    }

    func testHeuristicExtractorIgnoresMidSentenceMarkers() async {
        // "use " and "prefer " appear mid-sentence here; they must not produce candidates.
        let extractor = HeuristicCandidateExtractor()
        let candidates = await extractor.extract(from: ReflectionInput(
            trigger: .cadence(everyNTurns: 1, currentCount: 1),
            projectRoot: "/test/project",
            recentAssistantText: [
                "I'll use the existing helper rather than writing a new one.",
                "This happens because the API prefers asynchronous calls in this context."
            ]
        ))
        XCTAssertTrue(candidates.isEmpty, "mid-sentence markers should not produce candidates")
    }

    func testHeuristicExtractorPicksLineStartMarkers() async {
        // Lines that *start* with an action marker should be captured.
        let extractor = HeuristicCandidateExtractor()
        let candidates = await extractor.extract(from: ReflectionInput(
            trigger: .cadence(everyNTurns: 1, currentCount: 1),
            projectRoot: "/test/project",
            recentAssistantText: [
                "Always run swift build before swift test to catch type errors early."
            ]
        ))
        XCTAssertFalse(candidates.isEmpty)
        XCTAssertEqual(candidates.first?.knowledgeKind, .pattern)
    }

    func testUserFeedbackAlwaysFiresAndPersists() async throws {
        let reflector = Reflector(store: store)
        let outcomes = await reflector.reflect(ReflectionInput(
            trigger: .userFeedback(text: "Stop running tests with --release."),
            projectRoot: "/test/project"
        ))
        XCTAssertFalse(outcomes.isEmpty)
        let stats = try await store.stats()
        XCTAssertGreaterThanOrEqual(stats.activeCount, 1)
    }

    func testFailureTriggerCreatesGotcha() async throws {
        let reflector = Reflector(store: store)
        let outcomes = await reflector.reflect(ReflectionInput(
            trigger: .failure(reason: "swift test exited 1: missing libcblas"),
            projectRoot: "/test/project"
        ))
        XCTAssertFalse(outcomes.isEmpty)
        let scope = RetrievalScope(projectRoot: "/test/project")
        let results = try await store.retrieve(query: "libcblas", scope: scope)
        XCTAssertFalse(results.isEmpty)
        XCTAssertEqual(results.first?.document.knowledgeKind, .gotcha)
    }

    func testExplicitCandidatesWriteThrough() async throws {
        let reflector = Reflector(store: store)
        let candidate = ReflectionCandidate(
            memoryType: .semantic,
            knowledgeKind: .pattern,
            content: "Test files live next to source files as Foo.test.swift.",
            tags: ["tests", "convention"],
            confidence: 0.8,
            importance: 0.7
        )
        let outcomes = await reflector.reflect(ReflectionInput(
            trigger: .sessionEnd,
            projectRoot: "/test/project",
            explicitCandidates: [candidate]
        ))
        XCTAssertEqual(outcomes.count, 1)
        if case .inserted = outcomes.first!.action {
            // ok
        } else {
            XCTFail("expected inserted, got \(outcomes.first!.action)")
        }
    }

    func testSupersededOutcomePreservesOldIDProvenance() async throws {
        let seed = DocumentInput(
            memoryType: .semantic,
            knowledgeKind: .decision,
            content: "Always run swift build before swift test.",
            source: .assistant,
            projectRoot: "/test/project",
            confidence: 0.5,
            importance: 0.5
        )
        _ = try await store.write(seed)

        let reflector = Reflector(store: store)
        let candidate = ReflectionCandidate(
            memoryType: .semantic,
            knowledgeKind: .decision,
            content: "Always run swift build before swift test.",
            confidence: 0.9,
            importance: 0.7
        )
        let outcomes = await reflector.reflect(ReflectionInput(
            trigger: .sessionEnd,
            projectRoot: "/test/project",
            explicitCandidates: [candidate]
        ))

        XCTAssertEqual(outcomes.count, 1)
        guard case .superseded(let oldID, let oldUUID, let newUUID) = outcomes[0].action else {
            return XCTFail("expected superseded, got \(outcomes[0].action)")
        }
        XCTAssertGreaterThan(oldID, 0)
        XCTAssertNotNil(oldUUID)
        XCTAssertNotEqual(oldUUID, newUUID)
    }

    func testSupersededOutcomeKeepsSuccessWhenOldUUIDUnavailable() async throws {
        let seed = DocumentInput(
            memoryType: .semantic,
            knowledgeKind: .decision,
            content: "Always run swift build before swift test.",
            source: .assistant,
            projectRoot: "/test/project",
            confidence: 0.5,
            importance: 0.5
        )
        _ = try await store.write(seed)

        let reflector = Reflector(
            store: store,
            resolveDocumentUUID: { _ in nil }
        )
        let candidate = ReflectionCandidate(
            memoryType: .semantic,
            knowledgeKind: .decision,
            content: "Always run swift build before swift test.",
            confidence: 0.9,
            importance: 0.7
        )
        let outcomes = await reflector.reflect(ReflectionInput(
            trigger: .sessionEnd,
            projectRoot: "/test/project",
            explicitCandidates: [candidate]
        ))

        XCTAssertEqual(outcomes.count, 1)
        guard case .superseded(let oldID, let oldUUID, _) = outcomes[0].action else {
            return XCTFail("expected superseded, got \(outcomes[0].action)")
        }
        XCTAssertGreaterThan(oldID, 0)
        XCTAssertNil(oldUUID)
    }
}
