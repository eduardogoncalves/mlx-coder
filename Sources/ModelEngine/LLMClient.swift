// Sources/ModelEngine/LLMClient.swift
// Unified one-shot LLM helper — the single "ask the model one question, get one
// string back" primitive that previously only existed as private, copy-pasted
// idioms inside LLMCandidateExtractor / LLMReranker / WebFetchTool.
//
// It dispatches on `InferenceBackend`:
//   * `.local`  → the mlx-lm `container.perform { generateTokens }` idiom,
//                 wrapping the prompt in a minimal ChatML template. The derived
//                 GenerationEngine.Config forces `kvBits: nil` (a quantized KV
//                 cache + a direct `cache.update()` is a `fatalError`) and no
//                 TurboQuant, and uses a small `maxTokens` / low temperature.
//   * `.remote` → accumulate `RemoteAPIClient.stream(...).text` events (with an
//                 empty `tools` list) until `.done`.
//
// This is deliberately best-effort and self-contained: callers use it for cheap
// auxiliary calls (subquery expansion, yes/no relevance) and fall back gracefully
// when it throws / returns empty. It never mutates conversation state.

import Foundation
import MLX
import MLXLMCommon

public struct LLMClient: Sendable {

    /// Interpreted backend (local MLX vs. a configured remote provider).
    public let backend: InferenceBackend
    /// The loaded model container for the local path. Must be non-nil when
    /// `backend` is `.local`; ignored for `.remote`.
    public let container: ModelContainer?
    /// Base generation config to derive the one-shot config from (sampling
    /// knobs, KV group size, etc.). Overridden per call for `maxTokens` /
    /// `temperature` and always stripped of KV quantization.
    public let baseConfig: GenerationEngine.Config
    /// Optional conversation id forwarded as `session_id` on remote requests so
    /// auxiliary calls are grouped with the main run for tracing.
    public let sessionId: String?

    public init(
        backend: InferenceBackend,
        container: ModelContainer?,
        baseConfig: GenerationEngine.Config,
        sessionId: String? = nil
    ) {
        self.backend = backend
        self.container = container
        self.baseConfig = baseConfig
        self.sessionId = sessionId
    }

    /// Whether this client is able to run a call at all (local needs a container).
    public var isUsable: Bool {
        switch backend {
        case .local:  return container != nil
        case .remote: return true
        }
    }

    // MARK: - Public API

    /// Run a single prompt and return the decoded assistant text.
    ///
    /// Throws on model/transport error, cancellation, or (local) empty
    /// tokenization. Callers that must never break the turn should wrap this in
    /// their own `try?` / time-budget race.
    public func complete(
        prompt: String,
        maxTokens: Int,
        temperature: Double = 0.0
    ) async throws -> String {
        switch backend {
        case .local:
            guard let container else {
                throw NSError(
                    domain: "LLMClient",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Local backend requested but no ModelContainer is loaded."]
                )
            }
            let config = Self.deriveConfig(from: baseConfig, maxTokens: maxTokens, temperature: temperature)
            return try await Self.runLocalOneShot(container: container, prompt: prompt, config: config)

        case .remote(let providerID, let modelID):
            return try await runRemoteOneShot(
                providerID: providerID,
                modelID: modelID,
                prompt: prompt,
                maxTokens: maxTokens,
                temperature: temperature
            )
        }
    }

    // MARK: - Config derivation

    /// Clone `base` with a small token cap / overridden temperature, and force
    /// off both KV quantization paths (`kvBits`, TurboQuant) — a quantized KV
    /// cache combined with a direct `cache.update()` traps in mlx-lm.
    static func deriveConfig(
        from base: GenerationEngine.Config,
        maxTokens: Int,
        temperature: Double
    ) -> GenerationEngine.Config {
        GenerationEngine.Config(
            maxTokens: max(1, maxTokens),
            temperature: Float(temperature),
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
            turboQuantBits: nil, // TurboQuant is incompatible with these one-shot caches
            numDraftTokens: base.numDraftTokens
        )
    }

    // MARK: - Local one-shot

    /// Mirrors `LLMCandidateExtractor.runOneShot` / `WebFetchTool.extractWithLLM`
    /// so the whole codebase keeps a single local-inference idiom.
    static func runLocalOneShot(
        container: ModelContainer,
        prompt: String,
        config: GenerationEngine.Config
    ) async throws -> String {
        try await container.perform { context in
            let chatML = """
            <|im_start|>system
            You are a precise, concise assistant.<|im_end|>
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
                    domain: "LLMClient",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Empty tokenization for one-shot prompt."]
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

    // MARK: - Remote one-shot

    /// Accumulate `.text` events from a tool-less streaming completion until the
    /// stream ends. Mirrors the wiring in `AgentLoop+RemoteGeneration.swift`.
    private func runRemoteOneShot(
        providerID: String,
        modelID: String,
        prompt: String,
        maxTokens: Int,
        temperature: Double
    ) async throws -> String {
        guard let provider = RemoteProviderRegistry.provider(id: providerID) else {
            throw NSError(
                domain: "LLMClient",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Unknown remote provider '\(providerID)'."]
            )
        }
        let apiKey = RemoteProviderRegistry.apiKey(for: providerID)
        let base = provider.baseURLValue ?? URL(string: "https://openrouter.ai/api/v1")!
        let client = RemoteAPIClient(apiKey: apiKey ?? "", baseURL: base, providerName: provider.name)

        let messages = [RemoteAPIMessage(role: .user, content: prompt)]
        let stream = client.stream(
            model: modelID,
            messages: messages,
            tools: [],
            temperature: temperature,
            maxTokens: max(1, maxTokens),
            sessionId: sessionId
        )

        var responseText = ""
        for try await event in stream {
            if Task.isCancelled { throw CancellationError() }
            switch event {
            case .text(let chunk):
                responseText += chunk
            case .done:
                // Keep consuming until the stream terminates ([DONE]); a mid-run
                // per-choice finish_reason arrives as its own `.done`.
                break
            case .toolCallDelta, .usage, .slotAssigned:
                break
            }
        }
        return responseText
    }
}
