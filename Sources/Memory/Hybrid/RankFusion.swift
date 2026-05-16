// Sources/Memory/Hybrid/RankFusion.swift
// Reciprocal Rank Fusion (RRF) and weighted score fusion utilities.

import Foundation

/// Fuses multiple ranked retrieval results into a single ordering.
///
/// We use **Reciprocal Rank Fusion** (Cormack et al. 2009) because it:
///  - is parameter-light (only `k`),
///  - is robust to score-scale differences between FTS5 BM25 and cosine,
///  - degrades gracefully when one retriever returns nothing.
///
/// Optionally, callers can supply per-source weights to bias the final
/// ranking toward lexical or semantic recall depending on the query class.
public enum RankFusion {

    /// One ranked list of document IDs. Lower index = better rank.
    public struct RankedList: Sendable {
        public let documentIDs: [Int64]
        public let weight: Double

        public init(documentIDs: [Int64], weight: Double = 1.0) {
            self.documentIDs = documentIDs
            self.weight = weight
        }
    }

    /// Reciprocal Rank Fusion across multiple ranked lists.
    ///
    /// score(doc) = Σ_list  list.weight / (k + rank_in_list(doc))
    ///
    /// Returns IDs sorted by descending RRF score, with the score itself.
    /// `k` defaults to 60 (the canonical Cormack value); lower values
    /// emphasise top-ranked items more aggressively.
    public static func reciprocalRankFusion(
        _ lists: [RankedList],
        k: Double = 60
    ) -> [(documentID: Int64, score: Double)] {
        var scores: [Int64: Double] = [:]
        for list in lists {
            for (rank, id) in list.documentIDs.enumerated() {
                let contribution = list.weight / (k + Double(rank + 1))
                scores[id, default: 0] += contribution
            }
        }
        return scores
            .map { (documentID: $0.key, score: $0.value) }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.documentID < rhs.documentID  // deterministic tiebreak
            }
    }

    /// Convenience wrapper that takes per-source ranked ID lists and returns
    /// only the top-N IDs after fusion.
    public static func fuseTop(
        lexical: [Int64],
        semantic: [Int64],
        weightLexical: Double = 0.45,
        weightSemantic: Double = 0.55,
        k: Double = 60,
        topN: Int
    ) -> [Int64] {
        let fused = reciprocalRankFusion([
            RankedList(documentIDs: lexical, weight: weightLexical),
            RankedList(documentIDs: semantic, weight: weightSemantic),
        ], k: k)
        return Array(fused.prefix(topN).map(\.documentID))
    }
}
