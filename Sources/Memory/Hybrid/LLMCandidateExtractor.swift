// Sources/Memory/Hybrid/LLMCandidateExtractor.swift
// LLM-backed candidate extractor for the reflection loop.
//
// Drives a one-shot generation against the same ModelContainer the agent uses
// for inference, asks the model to emit a small JSON array of candidate
// memories, and converts each entry into a `ReflectionCandidate`.
//
// Falls back to `HeuristicCandidateExtractor` when:
//   * generation fails (cancellation, model error, empty output)
//   * the model output cannot be parsed as the expected JSON shape
//
// The prompt deliberately constrains the output schema and number of
// candidates so a small/fast model can answer reliably.

import Foundation
import MLX
import MLXLMCommon

public struct LLMCandidateExtractor: CandidateExtractor {

    /// Maximum number of memories the model may propose per reflection cycle.
    public static let defaultMaxCandidates = 5

    /// Cap on context characters fed to the extractor — keeps the prompt
    /// inside a small model's context window.
    public static let defaultMaxContextChars = 6_000

    public let container: ModelContainer
    public let baseConfig: GenerationEngine.Config
    public let maxCandidates: Int
    public let maxContextChars: Int
    public let fallback: CandidateExtractor

    public init(
        container: ModelContainer,
        baseConfig: GenerationEngine.Config,
        maxCandidates: Int = LLMCandidateExtractor.defaultMaxCandidates,
        maxContextChars: Int = LLMCandidateExtractor.defaultMaxContextChars,
        fallback: CandidateExtractor = HeuristicCandidateExtractor()
    ) {
        self.container = container
        self.baseConfig = baseConfig
        self.maxCandidates = max(1, maxCandidates)
        self.maxContextChars = max(512, maxContextChars)
        self.fallback = fallback
    }

    public func extract(from input: ReflectionInput) async -> [ReflectionCandidate] {
        let assistantBlob = Self.joinedRecent(input.recentAssistantText, limit: maxContextChars / 2)
        let userBlob = Self.joinedRecent(input.recentUserText, limit: maxContextChars / 2)

        // Without any conversation context the LLM has nothing to reflect on.
        guard !assistantBlob.isEmpty || !userBlob.isEmpty else {
            return await fallback.extract(from: input)
        }

        let prompt = Self.buildPrompt(
            triggerSummary: Self.summarize(input.trigger),
            userText: userBlob,
            assistantText: assistantBlob,
            maxCandidates: maxCandidates
        )

        let extractConfig = Self.deriveExtractionConfig(from: baseConfig)

        do {
            let raw = try await Self.runOneShot(
                container: container,
                prompt: prompt,
                config: extractConfig
            )
            let parsed = Self.parseCandidates(raw, maxCandidates: maxCandidates)
            if parsed.isEmpty {
                return await fallback.extract(from: input)
            }
            return parsed
        } catch {
            return await fallback.extract(from: input)
        }
    }

    // MARK: - Prompt construction

    static func summarize(_ trigger: ReflectionTrigger) -> String {
        switch trigger {
        case .turnCompleted(let idx):
            return "turn \(idx) completed"
        case .cadence(let every, let count):
            return "cadence (every \(every) turns; current count \(count))"
        case .failure(let reason):
            return "tool / step failure: \(reason)"
        case .userFeedback(let text):
            return "explicit user feedback: \(text)"
        case .sessionEnd:
            return "session ending — final consolidation"
        }
    }

    static func joinedRecent(_ messages: [String], limit: Int) -> String {
        guard !messages.isEmpty else { return "" }
        // Keep the *most recent* context until we hit the byte cap. Skip
        // (rather than break on) oversized items so a single huge message
        // doesn't drop everything older than itself.
        var pieces: [String] = []
        var used = 0
        for msg in messages.reversed() {
            let trimmed = msg.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let cost = trimmed.count + 2  // separator
            if used + cost > limit {
                continue
            }
            pieces.append(trimmed)
            used += cost
        }
        return pieces.reversed().joined(separator: "\n---\n")
    }

    static func buildPrompt(
        triggerSummary: String,
        userText: String,
        assistantText: String,
        maxCandidates: Int
    ) -> String {
        let kindList = KnowledgeKind.persistentKinds
            .map { $0.rawValue }
            .joined(separator: ", ")
        // Use a strict-output prompt: the assistant must return ONLY a JSON
        // array. We reinforce the schema and provide a worked example so even
        // small models converge on the right shape.
        return """
        You are mlx-coder's reflection helper. Read the recent conversation and \
        extract at most \(maxCandidates) durable memories the agent should \
        remember for future turns or sessions in this project.

        TRIGGER: \(triggerSummary)

        RECENT USER MESSAGES:
        \(userText.isEmpty ? "(none)" : userText)

        RECENT ASSISTANT MESSAGES:
        \(assistantText.isEmpty ? "(none)" : assistantText)

        Output rules — read carefully:
         * Reply with ONLY a JSON array, no prose, no Markdown fence, no comments.
         * Each element must be an object with keys:
             - "memory_type": one of "episodic", "semantic", "working"
             - "knowledge_kind": one of \(kindList)
             - "content": short factual sentence (≤ 280 chars) phrased as a \
                          standalone note the agent can re-read later.
             - "importance": float 0.0–1.0 (how central this is to future work)
             - "confidence": float 0.0–1.0 (how sure you are it is correct)
             - "tags": array of short string tags (may be empty)
         * Skip greetings, restatements of the user's request, and anything \
            already obvious from project structure. If nothing is worth \
            remembering, output: []
         * Prefer "semantic" + "decision"/"pattern" for stable rules; \
            "episodic" + "gotcha" for one-off failures; "working" only for \
            short-lived scratch state with a TTL of < 1 day.

        EXAMPLE valid output:
        [
          {"memory_type":"semantic","knowledge_kind":"decision","content":\
        "Use scripts/release.sh -b for builds; never swift build -c release.",\
        "importance":0.9,"confidence":0.95,"tags":["build","scripts"]}
        ]

        Now produce the JSON array:
        """
    }

    static func deriveExtractionConfig(from base: GenerationEngine.Config) -> GenerationEngine.Config {
        GenerationEngine.Config(
            maxTokens: 768,
            temperature: 0.2,
            topP: base.topP,
            topK: base.topK,
            minP: base.minP,
            repetitionPenalty: base.repetitionPenalty,
            repetitionContextSize: base.repetitionContextSize,
            presencePenalty: base.presencePenalty,
            presenceContextSize: base.presenceContextSize,
            frequencyPenalty: base.frequencyPenalty,
            frequencyContextSize: base.frequencyContextSize,
            kvBits: base.kvBits,
            kvGroupSize: base.kvGroupSize,
            quantizedKVStart: base.quantizedKVStart,
            longContextThreshold: base.longContextThreshold,
            numDraftTokens: base.numDraftTokens
        )
    }

    // MARK: - One-shot generation

    /// Run a single non-streaming LLM call and return decoded text.
    /// Mirrors `WebFetchTool.extractWithLLM` so we keep one inference idiom.
    static func runOneShot(
        container: ModelContainer,
        prompt: String,
        config: GenerationEngine.Config
    ) async throws -> String {
        try await container.perform { context in
            let chatML = """
            <|im_start|>system
            You are a precise JSON-emitting assistant.<|im_end|>
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
                    domain: "LLMCandidateExtractor",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Empty tokenization for extraction prompt."]
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

    // MARK: - JSON parsing

    /// Extract the first JSON array from raw model output and decode it into
    /// `ReflectionCandidate` values. Returns an empty array if anything fails.
    static func parseCandidates(_ raw: String, maxCandidates: Int) -> [ReflectionCandidate] {
        guard let json = extractFirstJSONArray(from: raw) else { return [] }
        guard let data = json.data(using: .utf8) else { return [] }
        guard let any = try? JSONSerialization.jsonObject(with: data) else { return [] }
        guard let arr = any as? [Any] else { return [] }

        var out: [ReflectionCandidate] = []
        for entry in arr.prefix(maxCandidates) {
            guard let dict = entry as? [String: Any] else { continue }
            guard
                let typeStr = (dict["memory_type"] as? String)?.lowercased(),
                let memType = MemoryType(rawValue: typeStr),
                let kindStr = (dict["knowledge_kind"] as? String)?.lowercased(),
                let kind = KnowledgeKind(rawValue: kindStr),
                let content = (dict["content"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !content.isEmpty
            else { continue }

            // Drop non-persistent kinds; reflection should not produce session_state.
            guard KnowledgeKind.persistentKinds.contains(kind) else { continue }

            let importance = clamp(numericValue(dict["importance"]) ?? 0.5)
            let confidence = clamp(numericValue(dict["confidence"]) ?? 0.5)
            let tags = (dict["tags"] as? [Any])?.compactMap { $0 as? String } ?? []

            out.append(
                ReflectionCandidate(
                    memoryType: memType,
                    knowledgeKind: kind,
                    content: content,
                    tags: tags,
                    confidence: confidence,
                    importance: importance
                )
            )
        }
        return out
    }

    static func numericValue(_ any: Any?) -> Double? {
        switch any {
        case let v as Double: return v
        case let v as Int: return Double(v)
        case let v as NSNumber: return v.doubleValue
        case let v as String: return Double(v)
        default: return nil
        }
    }

    static func clamp(_ x: Double) -> Double { Swift.min(1.0, Swift.max(0.0, x)) }

    /// Find the first balanced `[ ... ]` block in raw text (LLMs often wrap
    /// the array with prose or fenced code).
    static func extractFirstJSONArray(from text: String) -> String? {
        // Strip common Markdown fences first.
        let stripped = text
            .replacingOccurrences(of: "```json", with: "```")
            .replacingOccurrences(of: "```", with: "")
        guard let openIdx = stripped.firstIndex(of: "[") else { return nil }

        var depth = 0
        var inString = false
        var escape = false
        var idx = openIdx
        while idx < stripped.endIndex {
            let ch = stripped[idx]
            if escape {
                escape = false
            } else if ch == "\\" && inString {
                escape = true
            } else if ch == "\"" {
                inString.toggle()
            } else if !inString {
                if ch == "[" { depth += 1 }
                if ch == "]" {
                    depth -= 1
                    if depth == 0 {
                        return String(stripped[openIdx...idx])
                    }
                }
            }
            idx = stripped.index(after: idx)
        }
        return nil
    }
}
