// Sources/Memory/Hybrid/MLXEmbeddingProvider.swift
// MLX-backed semantic embedding provider for the hybrid memory stack.

import Foundation
import Hub
import MLX
import MLXEmbedders
import MLXLMCommon
import Tokenizers

/// MLX-backed embedding provider that loads a sentence-encoder via MLXEmbedders
/// and produces normalized vectors using the model's pooling strategy.
///
/// The container is loaded lazily on first `embed(_:)` call so that mlx-coder
/// only pays the model-download/load cost when semantic embeddings are
/// actually used. Subsequent calls reuse the loaded container.
///
/// Default model is `BGE Micro v2` (~17MB on disk, dim=384) — small enough that
/// users with no embedding model installed pay a tiny one-time download and
/// then get true semantic recall instead of the trigram-hash fallback.
public actor MLXEmbeddingProvider: EmbeddingProvider {

    /// Curated default — favoured because:
    ///  - tiny on disk (~17MB), <100MB resident,
    ///  - 384-dim vectors fit cleanly in the existing BLOB encoding,
    ///  - well-known baseline for short-text retrieval.
    public static let defaultModelID = "TaylorAI/bge-micro-v2"

    /// Hard cap on tokenized input length — short memory chunks rarely exceed
    /// this and capping keeps per-call latency bounded.
    public static let defaultMaxTokens = 512

    public nonisolated let modelID: String
    public nonisolated let dimension: Int
    public nonisolated let maxTokens: Int

    /// Hugging Face / local model identifier passed to `EmbedderModelFactory`.
    private let configurationID: String

    /// Lazily-loaded container; nil until the first `embed` call succeeds.
    private var container: EmbedderModelContainer?
    /// In-flight load task so concurrent first-callers share a single load.
    private var loadingTask: Task<EmbedderModelContainer, Error>?

    public init(
        configurationID: String = MLXEmbeddingProvider.defaultModelID,
        dimension: Int = 384,
        maxTokens: Int = MLXEmbeddingProvider.defaultMaxTokens
    ) {
        precondition(dimension > 0, "dimension must be positive")
        precondition(maxTokens > 0, "maxTokens must be positive")
        self.configurationID = configurationID
        self.modelID = "mlx-\(configurationID)-d\(dimension)"
        self.dimension = dimension
        self.maxTokens = maxTokens
    }

    public func embed(_ text: String) async throws -> [Float] {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return [Float](repeating: 0, count: dimension)
        }

        let container = try await ensureContainer()

        let raw: [Float] = await container.perform { [maxTokens] context in
            // Tokenize with truncation. Pad to a single-row batch.
            var tokens = context.tokenizer.encode(text: normalized, addSpecialTokens: true)
            if tokens.isEmpty {
                tokens = context.tokenizer.encode(text: "x", addSpecialTokens: true)
            }
            if tokens.count > maxTokens {
                tokens = Array(tokens.prefix(maxTokens))
            }

            let inputIDs = MLXArray(tokens).reshaped([1, tokens.count])
            let mask = MLXArray.ones([1, tokens.count], type: Int32.self)
            // tokenTypeIds default to zeros for a single segment — many
            // BERT-style models accept nil here, but providing zeros keeps
            // models that require the input happy.
            let tokenTypes = MLXArray.zeros([1, tokens.count], type: Int32.self)

            let output = context.model(
                inputIDs,
                positionIds: nil,
                tokenTypeIds: tokenTypes,
                attentionMask: mask
            )
            let pooled = context.pooling(
                output, mask: mask, normalize: true, applyLayerNorm: false
            )
            pooled.eval()

            // pooled shape: [1, hidden_dim]
            let row = pooled[0]
            return row.asArray(Float.self)
        }

        return Self.fitToDimension(raw, target: dimension)
    }

    // MARK: - Container management

    private func ensureContainer() async throws -> EmbedderModelContainer {
        if let container { return container }
        if let loadingTask {
            return try await loadingTask.value
        }

        let id = configurationID
        let task = Task<EmbedderModelContainer, Error> {
            let downloader = MLXHubDownloader(
                downloadBase: URL(filePath: NSString(string: "~").expandingTildeInPath)
            )
            let configuration = ModelConfiguration(id: id)
            return try await EmbedderModelFactory.shared.loadContainer(
                from: downloader,
                using: MLXTokenizerLoader(),
                configuration: configuration
            )
        }
        loadingTask = task
        do {
            let loaded = try await task.value
            container = loaded
            loadingTask = nil
            return loaded
        } catch {
            loadingTask = nil
            throw error
        }
    }

    /// Trim or zero-pad the raw embedding to the configured dimension and
    /// re-normalize so cosine similarity stays meaningful. We never resize
    /// silently inside a vector that is already-normalized: re-normalize
    /// after any size change.
    static func fitToDimension(_ raw: [Float], target: Int) -> [Float] {
        if raw.count == target {
            return HashEmbeddingProvider.l2Normalize(raw)
        }
        if raw.count > target {
            let truncated = Array(raw.prefix(target))
            return HashEmbeddingProvider.l2Normalize(truncated)
        }
        var padded = raw
        padded.append(contentsOf: [Float](repeating: 0, count: target - raw.count))
        return HashEmbeddingProvider.l2Normalize(padded)
    }
}
