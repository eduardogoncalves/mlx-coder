// Sources/Memory/Hybrid/LLMReranker.swift
// LLM-backed reranker for the hybrid memory retrieval pipeline.
//
// Wraps the agent's ModelContainer to score candidate documents against the
// query in a single LLM call. Honours `timeBudget` (the existing contract on
// `Reranker`) by both racing the call against a cancellation deadline and
// falling back to the fused score when the model takes too long or returns
// malformed output.
//
// The wire format is intentionally tiny so a small model can answer reliably:
// the prompt asks for a JSON array of {id,score} entries scored 0–10 against
// the query.

import Foundation
import MLX
import MLXLMCommon

public struct LLMReranker: Reranker {

    /// Cap on candidates handed to the LLM. Beyond this, the tail keeps its
    /// fused score and we only rerank the head.
    public static let defaultMaxCandidates = 8

    /// Cap on per-candidate snippet length fed to the prompt.
    public static let defaultSnippetChars = 280

    public let container: ModelContainer
    public let baseConfig: GenerationEngine.Config
    public let maxCandidates: Int
    public let snippetChars: Int
    public let fallback: Reranker

    public init(
        container: ModelContainer,
        baseConfig: GenerationEngine.Config,
        maxCandidates: Int = LLMReranker.defaultMaxCandidates,
        snippetChars: Int = LLMReranker.defaultSnippetChars,
        fallback: Reranker = LexicalReranker()
    ) {
        self.container = container
        self.baseConfig = baseConfig
        self.maxCandidates = max(1, maxCandidates)
        self.snippetChars = max(64, snippetChars)
        self.fallback = fallback
    }

    public func rerank(
        query: String,
        candidates: [ScoredDocument],
        timeBudget: TimeInterval
    ) async -> [ScoredDocument] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, !candidates.isEmpty else { return candidates }

        // Split: the head goes to the LLM, the tail keeps its fused score.
        let head = Array(candidates.prefix(maxCandidates))
        let tail = Array(candidates.dropFirst(maxCandidates))

        let prompt = Self.buildPrompt(
            query: trimmedQuery,
            head: head,
            snippetChars: snippetChars
        )
        let cfg = Self.deriveRerankConfig(from: baseConfig)

        // Race the LLM call against the time budget so a slow model never
        // blocks retrieval. On timeout / failure fall back to the lexical
        // reranker (whose own budget guard fires for the tail).
        let raced = await raceWithBudget(timeBudget: timeBudget) {
            try await Self.runOneShot(container: container, prompt: prompt, config: cfg)
        }

        guard let raw = raced,
              let scoreMap = Self.parseScores(raw, count: head.count),
              !scoreMap.isEmpty
        else {
            return await fallback.rerank(query: query, candidates: candidates, timeBudget: timeBudget)
        }

        var rescoredHead: [ScoredDocument] = []
        rescoredHead.reserveCapacity(head.count)
        for (idx, var candidate) in head.enumerated() {
            if let score = scoreMap[idx] {
                candidate.rerankScore = score
            }
            rescoredHead.append(candidate)
        }

        // Combine with the (un-reranked) tail and re-sort by finalScore.
        let merged = (rescoredHead + tail).sorted { $0.finalScore > $1.finalScore }
        return merged
    }

    // MARK: - Prompt construction

    static func buildPrompt(query: String, head: [ScoredDocument], snippetChars: Int) -> String {
        var lines: [String] = []
        lines.reserveCapacity(head.count)
        for (idx, cand) in head.enumerated() {
            let snippet = Self.snippet(from: cand.document.content, max: snippetChars)
            lines.append("[\(idx)] (\(cand.document.knowledgeKind.rawValue)) \(snippet)")
        }
        let listing = lines.joined(separator: "\n")

        return """
        You are scoring memory candidates for relevance to a query.

        QUERY:
        \(query)

        CANDIDATES (id in brackets):
        \(listing)

        Output rules — read carefully:
         * Reply with ONLY a JSON array, no prose, no Markdown fence.
         * One element per candidate, with keys "id" (integer) and "score" \
            (number from 0.0 to 10.0; higher = more relevant).
         * If a candidate is unrelated to the query, score it close to 0.
         * Do not invent ids; use only the ids shown above.

        EXAMPLE valid output:
        [{"id":0,"score":9.2},{"id":1,"score":2.0},{"id":2,"score":0.5}]

        Now score the candidates:
        """
    }

    static func snippet(from text: String, max: Int) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if collapsed.count <= max { return collapsed }
        let cut = collapsed.index(collapsed.startIndex, offsetBy: max)
        return String(collapsed[..<cut]) + "…"
    }

    static func deriveRerankConfig(from base: GenerationEngine.Config) -> GenerationEngine.Config {
        GenerationEngine.Config(
            maxTokens: 256,
            temperature: 0.0,
            topP: base.topP,
            topK: base.topK,
            minP: base.minP,
            repetitionPenalty: nil,
            repetitionContextSize: base.repetitionContextSize,
            presencePenalty: nil,
            presenceContextSize: base.presenceContextSize,
            frequencyPenalty: nil,
            frequencyContextSize: base.frequencyContextSize,
            kvBits: nil, // maybeQuantizeKVCache + direct cache.update() = fatalError
            kvGroupSize: base.kvGroupSize,
            quantizedKVStart: base.quantizedKVStart,
            longContextThreshold: base.longContextThreshold,
            numDraftTokens: base.numDraftTokens
        )
    }

    // MARK: - One-shot generation

    static func runOneShot(
        container: ModelContainer,
        prompt: String,
        config: GenerationEngine.Config
    ) async throws -> String {
        try await container.perform { context in
            let chatML = """
            <|im_start|>system
            You are a precise JSON-emitting scorer.<|im_end|>
            <|im_start|>user
            \(prompt)<|im_end|>
            <|im_start|>assistant

            """
            var tokens = context.tokenizer.encode(text: chatML)
            if tokens.isEmpty {
                tokens = context.tokenizer.encode(text: "x")
            }
            if tokens.isEmpty {
                throw NSError(
                    domain: "LLMReranker",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Empty tokenization for rerank prompt."]
                )
            }
            let inputTokens = MLXArray(tokens)
            let input = LMInput(tokens: inputTokens)

            var responseText = ""
            let stream = try MLXLMCommon.generateTokens(
                input: input,
                parameters: config.generateParameters,
                context: context
            )
            for await item in stream {
                if Task.isCancelled { throw CancellationError() }
                switch item {
                case .token(let id):
                    responseText += context.tokenizer.decode(tokenIds: [id])
                case .info:
                    break
                }
            }
            return responseText
        }
    }

    // MARK: - Time budget race

    /// Run `op` with a soft deadline. Returns nil on failure or if the budget
    /// elapses before the operation completes. The op is cancelled in either
    /// case so the model task does not leak.
    private func raceWithBudget(
        timeBudget: TimeInterval,
        _ op: @escaping @Sendable () async throws -> String
    ) async -> String? {
        guard timeBudget > 0 else {
            return try? await op()
        }
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                do { return try await op() } catch { return nil }
            }
            group.addTask {
                let nanos = UInt64(max(0, timeBudget) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: - JSON parsing

    /// Parse `[{"id":N,"score":S}, ...]` and return id→score map.
    /// Scores are normalized from the [0,10] LLM range into [0,1] so they are
    /// comparable with `LexicalReranker` outputs and `fusedScore` for the
    /// final ordering.
    static func parseScores(_ raw: String, count: Int) -> [Int: Double]? {
        guard let json = LLMCandidateExtractor.extractFirstJSONArray(from: raw) else { return nil }
        guard let data = json.data(using: .utf8) else { return nil }
        guard let any = try? JSONSerialization.jsonObject(with: data) else { return nil }
        guard let arr = any as? [Any] else { return nil }

        var out: [Int: Double] = [:]
        for entry in arr {
            guard let dict = entry as? [String: Any] else { continue }
            guard
                let idValue = LLMCandidateExtractor.numericValue(dict["id"]),
                let scoreValue = LLMCandidateExtractor.numericValue(dict["score"])
            else { continue }
            let id = Int(idValue)
            guard id >= 0, id < count else { continue }
            let normalized = Swift.max(0.0, Swift.min(1.0, scoreValue / 10.0))
            out[id] = normalized
        }
        return out
    }
}
