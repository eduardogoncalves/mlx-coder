// Tests/MemoryTests/Hybrid/LLMHelpersTests.swift
// Pure-Swift unit tests for the parsing/prompt helpers used by
// LLMCandidateExtractor and LLMReranker. These tests never load a model;
// they only exercise the deterministic helpers that surround the LLM call.

import XCTest
@testable import MLXCoder

final class LLMHelpersTests: XCTestCase {

    // MARK: - Extractor: JSON parsing

    func testExtractor_parsesValidArray() {
        let raw = """
        [
          {"memory_type":"semantic","knowledge_kind":"decision",\
          "content":"Use scripts/release.sh -b for builds.",\
          "importance":0.9,"confidence":0.95,"tags":["build"]},
          {"memory_type":"episodic","knowledge_kind":"gotcha",\
          "content":"swift build -c release skips Metal pre-warm.",\
          "importance":0.6,"confidence":0.7,"tags":[]}
        ]
        """
        let candidates = LLMCandidateExtractor.parseCandidates(raw, maxCandidates: 5)
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].memoryType, .semantic)
        XCTAssertEqual(candidates[0].knowledgeKind, .decision)
        XCTAssertEqual(candidates[0].importance, 0.9, accuracy: 1e-6)
        XCTAssertEqual(candidates[0].tags, ["build"])
        XCTAssertEqual(candidates[1].memoryType, .episodic)
        XCTAssertEqual(candidates[1].knowledgeKind, .gotcha)
    }

    func testExtractor_stripsMarkdownFenceAndProse() {
        let raw = """
        Sure! Here you go:
        ```json
        [{"memory_type":"semantic","knowledge_kind":"pattern",\
        "content":"Compose system prompt via buildSystemPromptComposition.",\
        "importance":0.7,"confidence":0.8,"tags":["arch"]}]
        ```
        Hope that helps.
        """
        let candidates = LLMCandidateExtractor.parseCandidates(raw, maxCandidates: 5)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].knowledgeKind, .pattern)
    }

    func testExtractor_clampsImportanceAndConfidence() {
        let raw = """
        [{"memory_type":"semantic","knowledge_kind":"decision",\
        "content":"Always run tests before commit.","importance":2.5,\
        "confidence":-0.3,"tags":[]}]
        """
        let candidates = LLMCandidateExtractor.parseCandidates(raw, maxCandidates: 5)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].importance, 1.0, accuracy: 1e-6)
        XCTAssertEqual(candidates[0].confidence, 0.0, accuracy: 1e-6)
    }

    func testExtractor_dropsEntriesWithUnknownEnums() {
        let raw = """
        [
          {"memory_type":"semantic","knowledge_kind":"banana",\
          "content":"Bad kind","importance":0.5,"confidence":0.5,"tags":[]},
          {"memory_type":"galaxy","knowledge_kind":"decision",\
          "content":"Bad type","importance":0.5,"confidence":0.5,"tags":[]},
          {"memory_type":"semantic","knowledge_kind":"decision",\
          "content":"Good entry survives.","importance":0.5,"confidence":0.5,"tags":[]}
        ]
        """
        let candidates = LLMCandidateExtractor.parseCandidates(raw, maxCandidates: 5)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].content, "Good entry survives.")
    }

    func testExtractor_dropsNonPersistentKnowledgeKinds() {
        let raw = """
        [{"memory_type":"working","knowledge_kind":"session_state",\
        "content":"Transient state — should be dropped.",\
        "importance":0.5,"confidence":0.5,"tags":[]}]
        """
        let candidates = LLMCandidateExtractor.parseCandidates(raw, maxCandidates: 5)
        XCTAssertTrue(candidates.isEmpty)
    }

    func testExtractor_returnsEmptyForGarbageOutput() {
        XCTAssertTrue(LLMCandidateExtractor.parseCandidates("", maxCandidates: 5).isEmpty)
        XCTAssertTrue(LLMCandidateExtractor.parseCandidates("not json", maxCandidates: 5).isEmpty)
        XCTAssertTrue(
            LLMCandidateExtractor.parseCandidates("{\"id\":1}", maxCandidates: 5).isEmpty
        )
    }

    func testExtractor_respectsMaxCandidates() {
        let entries = (0..<10).map { idx in
            """
            {"memory_type":"semantic","knowledge_kind":"decision",\
            "content":"entry \(idx)","importance":0.5,"confidence":0.5,"tags":[]}
            """
        }
        let raw = "[" + entries.joined(separator: ",") + "]"
        let candidates = LLMCandidateExtractor.parseCandidates(raw, maxCandidates: 3)
        XCTAssertEqual(candidates.count, 3)
        XCTAssertEqual(candidates[0].content, "entry 0")
        XCTAssertEqual(candidates[2].content, "entry 2")
    }

    // MARK: - Extractor: prompt context truncation

    func testExtractor_joinedRecentRespectsLimit() {
        let messages = ["short", "medium length message",
                        String(repeating: "x", count: 1_000)]
        let joined = LLMCandidateExtractor.joinedRecent(messages, limit: 100)
        XCTAssertLessThanOrEqual(joined.count, 100 + 4)  // separator slack
        // Most recent messages take priority — short oldest may be dropped.
        XCTAssertFalse(joined.isEmpty)
    }

    func testExtractor_triggerSummaryCoversAllCases() {
        XCTAssertTrue(
            LLMCandidateExtractor.summarize(.turnCompleted(turnIndex: 3)).contains("3"))
        XCTAssertTrue(
            LLMCandidateExtractor.summarize(.cadence(everyNTurns: 6, currentCount: 12))
                .contains("6"))
        XCTAssertTrue(
            LLMCandidateExtractor.summarize(.failure(reason: "boom"))
                .contains("boom"))
        XCTAssertTrue(
            LLMCandidateExtractor.summarize(.userFeedback(text: "hi"))
                .contains("hi"))
        XCTAssertEqual(
            LLMCandidateExtractor.summarize(.sessionEnd),
            "session ending — final consolidation")
    }

    // MARK: - Reranker: JSON parsing

    func testReranker_parsesScoresAndNormalizes() {
        let raw = """
        [{"id":0,"score":9.5},{"id":1,"score":2.0},{"id":2,"score":0.0}]
        """
        guard let scores = LLMReranker.parseScores(raw, count: 3) else {
            return XCTFail("parseScores returned nil")
        }
        XCTAssertEqual(scores[0] ?? -1, 0.95, accuracy: 1e-6)
        XCTAssertEqual(scores[1] ?? -1, 0.20, accuracy: 1e-6)
        XCTAssertEqual(scores[2] ?? -1, 0.00, accuracy: 1e-6)
    }

    func testReranker_clampsOutOfRangeScores() {
        let raw = """
        [{"id":0,"score":99.0},{"id":1,"score":-3.0}]
        """
        guard let scores = LLMReranker.parseScores(raw, count: 2) else {
            return XCTFail("parseScores returned nil")
        }
        XCTAssertEqual(scores[0] ?? -1, 1.0, accuracy: 1e-6)
        XCTAssertEqual(scores[1] ?? -1, 0.0, accuracy: 1e-6)
    }

    func testReranker_dropsOutOfRangeIDs() {
        let raw = """
        [{"id":0,"score":5.0},{"id":99,"score":7.0},{"id":-1,"score":4.0}]
        """
        guard let scores = LLMReranker.parseScores(raw, count: 2) else {
            return XCTFail("parseScores returned nil")
        }
        XCTAssertEqual(scores.count, 1)
        XCTAssertNotNil(scores[0])
    }

    func testReranker_returnsNilForGarbage() {
        XCTAssertNil(LLMReranker.parseScores("not json", count: 5))
        XCTAssertNil(LLMReranker.parseScores("", count: 5))
    }

    // MARK: - Reranker: snippet helpers

    func testReranker_snippetCollapsesWhitespaceAndTruncates() {
        let text = "alpha   beta\n\n  gamma\tdelta epsilon zeta eta theta"
        let snippet = LLMReranker.snippet(from: text, max: 20)
        XCTAssertLessThanOrEqual(snippet.count, 21)  // ellipsis adds 1
        XCTAssertFalse(snippet.contains("\n"))
        XCTAssertFalse(snippet.contains("\t"))
        XCTAssertTrue(snippet.hasPrefix("alpha beta gamma"))
    }

    // MARK: - MLX embedder: dimension fitter

    func testEmbedder_fitToDimensionTruncates() {
        let raw: [Float] = [1, 0, 0, 0, 0, 0]
        let fitted = MLXEmbeddingProvider.fitToDimension(raw, target: 3)
        XCTAssertEqual(fitted.count, 3)
        XCTAssertEqual(fitted[0], 1.0, accuracy: 1e-6)
    }

    func testEmbedder_fitToDimensionPadsAndNormalizes() {
        let raw: [Float] = [3, 4]
        let fitted = MLXEmbeddingProvider.fitToDimension(raw, target: 4)
        XCTAssertEqual(fitted.count, 4)
        // Original norm was 5; padded vector renormalized to unit length.
        let norm = sqrt(fitted.reduce(0) { $0 + $1 * $1 })
        XCTAssertEqual(norm, 1.0, accuracy: 1e-5)
    }

    func testEmbedder_fitToDimensionPassthroughNormalizes() {
        let raw: [Float] = [2, 0, 0]
        let fitted = MLXEmbeddingProvider.fitToDimension(raw, target: 3)
        XCTAssertEqual(fitted, [1.0, 0.0, 0.0])
    }
}
