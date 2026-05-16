// Tests/MemoryTests/Hybrid/RankFusionTests.swift
// RRF and weighted fusion behaviour.

import XCTest
@testable import MLXCoder

final class RankFusionTests: XCTestCase {

    func testRRFPrefersDocumentsRankedHighlyByMultipleSources() {
        // doc 1 is top-2 in both lists -> should win.
        // doc 5 is top in lexical only.
        // doc 6 is top in semantic only.
        let lexical = RankFusion.RankedList(documentIDs: [5, 1, 2, 3], weight: 1)
        let semantic = RankFusion.RankedList(documentIDs: [6, 1, 4, 7], weight: 1)
        let fused = RankFusion.reciprocalRankFusion([lexical, semantic])
        XCTAssertEqual(fused.first?.documentID, 1,
                       "doc present in both lists should win RRF")
    }

    func testWeightedFusionFavoursLexicalWhenWeightedSo() {
        let lexical = [Int64(10), Int64(20), Int64(30)]
        let semantic = [Int64(40), Int64(50), Int64(60)]
        let fused = RankFusion.fuseTop(
            lexical: lexical, semantic: semantic,
            weightLexical: 0.9, weightSemantic: 0.1, topN: 3)
        XCTAssertEqual(fused.first, 10, "lexical-weighted fusion should put 10 first")
    }

    func testFuseTopHandlesEmptyLists() {
        let fused = RankFusion.fuseTop(
            lexical: [], semantic: [], topN: 5)
        XCTAssertTrue(fused.isEmpty)
    }

    func testFuseTopHandlesOneEmptyList() {
        let fused = RankFusion.fuseTop(
            lexical: [Int64(1), Int64(2)], semantic: [], topN: 5)
        XCTAssertEqual(fused, [1, 2])
    }

    func testRRFIsDeterministicOnTiedScores() {
        // Two completely disjoint lists with same length → same RRF score
        // for every pair. Tiebreak should be ascending documentID.
        let a = RankFusion.RankedList(documentIDs: [1, 2], weight: 1)
        let b = RankFusion.RankedList(documentIDs: [3, 4], weight: 1)
        let fused = RankFusion.reciprocalRankFusion([a, b])
        // Top score belongs to rank-1 entries: 1 and 3 tied → 1 first.
        XCTAssertEqual(fused.map(\.documentID).prefix(2), [1, 3])
    }
}
