// Tests/MemoryTests/Hybrid/RerankerTests.swift
// Lexical reranker scoring + time-budget guard.

import XCTest
@testable import MLXCoder

final class RerankerTests: XCTestCase {

    private func makeDoc(
        id: Int64,
        content: String,
        tags: [String] = [],
        entities: [String] = [],
        confidence: Double = 0.5,
        ageDays: Double = 0
    ) -> ScoredDocument {
        let updated = Date().addingTimeInterval(-ageDays * 86_400)
        let doc = MemoryDocument(
            id: id,
            uuid: UUID(),
            memoryType: .semantic,
            knowledgeKind: .decision,
            content: content,
            contentHash: "h\(id)",
            source: .assistant,
            projectRoot: "/test/project",
            branch: nil,
            surface: nil,
            confidence: confidence,
            importance: 0.5,
            status: .active,
            version: 1,
            supersedesID: nil,
            createdAt: updated,
            updatedAt: updated,
            expiresAt: nil,
            lastAccessAt: nil,
            accessCount: 0,
            tags: tags,
            entities: entities,
            sessionID: nil,
            taskID: nil,
            feedbackScore: nil
        )
        return ScoredDocument(document: doc, fusedScore: 0.5)
    }

    func testRerankerPrefersHigherTokenOverlap() async {
        let reranker = LexicalReranker()
        let candidates = [
            makeDoc(id: 1, content: "Always use xcodebuild for this project."),
            makeDoc(id: 2, content: "An unrelated note about file system permissions."),
        ]
        let reranked = await reranker.rerank(
            query: "use xcodebuild project", candidates: candidates, timeBudget: 1.0)
        XCTAssertEqual(reranked.first?.document.id, 1)
    }

    func testRerankerHonoursTimeBudget() async {
        // Zero budget → reranker scores at most one candidate (the budget
        // check fires after the first iteration). All inputs must still be
        // returned; later items keep nil rerankScore so the caller can fall
        // back to fused ranking for them.
        let reranker = LexicalReranker()
        let candidates = (1...20).map { makeDoc(id: Int64($0), content: "doc number \($0)") }
        let reranked = await reranker.rerank(
            query: "doc", candidates: candidates, timeBudget: 0.0)
        XCTAssertEqual(reranked.count, candidates.count,
                       "reranker must not drop candidates on budget exhaustion")
        let unscored = reranked.filter { $0.rerankScore == nil }
        XCTAssertGreaterThanOrEqual(unscored.count, candidates.count - 1,
            "with a 0s budget, at most one candidate should have been scored")
    }

    func testRerankerEmptyQueryShortCircuits() async {
        let reranker = LexicalReranker()
        let candidates = [makeDoc(id: 1, content: "anything")]
        let reranked = await reranker.rerank(query: "  ", candidates: candidates, timeBudget: 1.0)
        XCTAssertEqual(reranked, candidates)
    }
}

extension ScoredDocument: Equatable {
    public static func == (lhs: ScoredDocument, rhs: ScoredDocument) -> Bool {
        lhs.document.id == rhs.document.id
            && lhs.fusedScore == rhs.fusedScore
            && lhs.rerankScore == rhs.rerankScore
    }
}
