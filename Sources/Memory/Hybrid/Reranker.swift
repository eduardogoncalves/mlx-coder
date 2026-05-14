// Sources/Memory/Hybrid/Reranker.swift
// Final reranking layer for the hybrid memory retrieval pipeline.

import Foundation

/// Lightweight reranker contract — runs after lexical+semantic fusion to
/// reorder the top-K candidates for final relevance.
public protocol Reranker: Sendable {
    /// Score each candidate against the query. Return the same documents
    /// with `rerankScore` populated (higher = more relevant).
    ///
    /// Implementations are expected to honour `timeBudget` and return early
    /// (with whatever scores they have) if the budget is exhausted — the
    /// caller will fall back to fused ranking for unscored items.
    func rerank(
        query: String,
        candidates: [ScoredDocument],
        timeBudget: TimeInterval
    ) async -> [ScoredDocument]
}

/// Default reranker — no model required, runs in O(n·m) where n=candidates
/// and m=query terms. Intended as a sane local default until a cross-encoder
/// or LLM-backed reranker is wired in.
///
/// Score = α·token_overlap + β·entity_overlap + γ·freshness + δ·confidence
///         - ε·length_penalty
///
/// The weights are deliberately simple; tune via the `Weights` struct.
public struct LexicalReranker: Reranker {
    public struct Weights: Sendable {
        public var tokenOverlap: Double
        public var entityOverlap: Double
        public var freshness: Double
        public var confidence: Double
        public var lengthPenalty: Double

        public init(
            tokenOverlap: Double = 0.55,
            entityOverlap: Double = 0.20,
            freshness: Double = 0.15,
            confidence: Double = 0.15,
            lengthPenalty: Double = 0.05
        ) {
            self.tokenOverlap = tokenOverlap
            self.entityOverlap = entityOverlap
            self.freshness = freshness
            self.confidence = confidence
            self.lengthPenalty = lengthPenalty
        }

        public static let `default` = Weights()
    }

    public let weights: Weights
    private let now: @Sendable () -> Date

    public init(
        weights: Weights = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.weights = weights
        self.now = now
    }

    public func rerank(
        query: String,
        candidates: [ScoredDocument],
        timeBudget: TimeInterval
    ) async -> [ScoredDocument] {
        let start = Date()
        let queryTokens = LexicalReranker.tokens(in: query)
        guard !queryTokens.isEmpty else { return candidates }

        let now = self.now()
        var output: [ScoredDocument] = []
        output.reserveCapacity(candidates.count)
        for var candidate in candidates {
            // Time-budget guard: stop early; remaining items keep fusedScore.
            if Date().timeIntervalSince(start) > timeBudget {
                output.append(candidate)
                continue
            }

            let docTokens = LexicalReranker.tokens(in: candidate.document.content)
            let tokenOverlap = LexicalReranker.jaccard(queryTokens, docTokens)

            let docEntities = Set(candidate.document.entities.map { $0.lowercased() })
            let entityOverlap: Double
            if docEntities.isEmpty {
                entityOverlap = 0
            } else {
                let queryEntityHits = queryTokens.intersection(docEntities).count
                entityOverlap = Double(queryEntityHits) / Double(docEntities.count)
            }

            let ageDays = max(0,
                now.timeIntervalSince(candidate.document.updatedAt) / 86_400.0)
            let freshness = 1.0 / (1.0 + ageDays / 30.0)

            let confidence = candidate.document.confidence
            let lengthPenalty = min(1.0, Double(candidate.document.content.count) / 2_000.0)

            let score =
                weights.tokenOverlap   * tokenOverlap   +
                weights.entityOverlap  * entityOverlap  +
                weights.freshness      * freshness      +
                weights.confidence     * confidence     -
                weights.lengthPenalty  * lengthPenalty

            candidate.rerankScore = score
            output.append(candidate)
        }

        return output.sorted { $0.finalScore > $1.finalScore }
    }

    // MARK: - Tokenization

    static func tokens(in text: String) -> Set<String> {
        var tokens = Set<String>()
        var current = ""
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.append(Character(scalar))
            } else {
                if current.count >= 2 { tokens.insert(current) }
                current = ""
            }
        }
        if current.count >= 2 { tokens.insert(current) }
        return tokens
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b).count
        guard union > 0 else { return 0 }
        return Double(a.intersection(b).count) / Double(union)
    }
}
