// Sources/AgentCore/AgentLoop+ModelLifecycle.swift
// Model loading, reloading, switching, and low-level model utilities.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon

extension AgentLoop {

    /// Full model unload and reload to ensure fresh weights/cache.
    public func reloadModel() async throws {
        frontend.emit(.modelLifecycle(.loading("Reloading model to ensure fresh state...")))

        // Drop tool references first so old model-bound tools can be deallocated.
        await registry.clear()
        modelContainer = nil

        // The KV cache belongs to a specific loaded model; a reload swaps weights
        // (and possibly KV-cache config), so any persisted cache must be discarded.
        promptCache.invalidate(reason: "model reload")

        // Clear any unreferenced MLX buffers before loading replacement weights.
        MLX.Memory.clearCache()

        // Online backends have no local container to load — inference is done over
        // HTTP by the per-backend client. Skip the MLX load path and just refresh
        // the dialect + registry so tools the backend still needs are bound.
        if backend.isOnline {
            self.loadedModelPath = modelPath
            await registerToolsInternal()
            let note = await remoteLoadStatusNote()
            frontend.emit(.modelLifecycle(.reloaded("Online provider ready: \(modelPath)\(note)")))
            return
        }

        // Load fresh container
        let newContainer = try await ModelLoader.load(
            from: modelPath,
            memoryLimit: memoryLimit,
            cacheLimit: cacheLimit
        )

        self.modelContainer = newContainer

        // Update loaded tracking parameters
        self.loadedModelPath = modelPath
        self.loadedMemoryLimit = memoryLimit
        self.loadedCacheLimit = cacheLimit
        self.loadedKVBits = currentGenerationConfig.kvBits
        self.loadedKVGroupSize = currentGenerationConfig.kvGroupSize
        self.loadedQuantizedKVStart = currentGenerationConfig.quantizedKVStart
        self.loadedTurboQuantBits = currentGenerationConfig.turboQuantBits
        
        // Re-register tools that depend on modelContainer
        await registerToolsInternal()

        // Sweep again after rebinding to reclaim stale buffers from the old model.
        MLX.Memory.clearCache()
        
        frontend.emit(.modelLifecycle(.reloaded("Model reloaded successfully")))
    }

    /// Switch to a different model path and immediately reload model and dependent tools.
    public func switchModel(to newModelPath: String) async throws {
        let trimmed = newModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "AgentLoop",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Model path cannot be empty."]
            )
        }

        if trimmed == modelPath {
            frontend.emit(.modelLifecycle(.alreadyActive(trimmed)))
            return
        }

        frontend.emit(.modelLifecycle(.unloading("Unloading current model...")))
        modelPath = trimmed
        toolCallDialect = ToolCallDialect.detect(modelPath: trimmed)
        pendingReload = false
        try await reloadModel()
    }

    /// Stage a model switch to be applied on the next user message turn.
    /// This updates `modelPath` and marks `pendingReload` without reloading immediately.
    public func stageModelSwitch(to newModelPath: String) async throws {
        let trimmed = newModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "AgentLoop",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Model path cannot be empty."]
            )
        }

        if trimmed == modelPath {
            frontend.emit(.modelLifecycle(.alreadyActive(trimmed)))
            return
        }

        modelPath = trimmed
        toolCallDialect = ToolCallDialect.detect(modelPath: trimmed)
        pendingReload = true
    }

    /// Best-effort suffix describing whether the active remote model is actually
    /// loaded on the server (router-mode llama.cpp, llama-swap, etc. can report
    /// "unloaded"/"sleeping"/"loading" and autoload lazily on first request).
    /// Returns "" when the backend is local, the provider isn't configured, or
    /// the server doesn't expose a status field (OpenRouter, LM Studio, vLLM,
    /// single-model mlx-lm.server) — those cases need no messaging.
    func remoteLoadStatusNote() async -> String {
        guard case .remote(let providerID, let modelID) = backend,
              let provider = RemoteProviderRegistry.provider(id: providerID),
              let base = provider.baseURLValue
        else {
            return ""
        }
        let apiKey = RemoteProviderRegistry.apiKey(for: providerID)
        let client = OpenRouterClient(apiKey: apiKey ?? "", baseURL: base, providerName: provider.name)
        guard let status = await client.remoteModelLoadStatus(modelID: modelID), status != "loaded" else {
            return ""
        }
        return " (server reports \(status) — first request may take longer while it loads)"
    }

    func requireLoadedModelContainer() throws -> ModelContainer {
        guard let modelContainer else {
            throw NSError(
                domain: "AgentLoop",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Model is currently unloading or not loaded."]
            )
        }
        return modelContainer
    }

    func modelHasProcessorConfig(_ path: String) -> Bool {
        let expandedPath = NSString(string: path).expandingTildeInPath
        let fm = FileManager.default
        guard fm.fileExists(atPath: expandedPath) else {
            // Hub IDs are downloaded/resolved by MLX internals; keep existing behavior.
            return true
        }

        let modelURL = URL(filePath: expandedPath)
        let processorConfig = modelURL.appendingPathComponent("processor_config.json").path
        let preprocessorConfig = modelURL.appendingPathComponent("preprocessor_config.json").path
        return fm.fileExists(atPath: processorConfig) || fm.fileExists(atPath: preprocessorConfig)
    }

    static func encodeNonEmptyTokens(
        primaryText: String,
        fallbackTexts: [String],
        using encode: (String) -> [Int]
    ) throws -> [Int] {
        let primaryTokens = encode(primaryText)
        if !primaryTokens.isEmpty {
            return primaryTokens
        }

        for fallback in fallbackTexts {
            let candidate = encode(fallback)
            if !candidate.isEmpty {
                return candidate
            }
        }

        throw NSError(
            domain: "AgentLoop",
            code: 4,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Tokenizer produced an empty token sequence for all fallback prompts."
            ]
        )
    }

    static func makeSafeTextLMInput(tokens: [Int]) throws -> LMInput {
        guard !tokens.isEmpty else {
            throw NSError(
                domain: "AgentLoop",
                code: 6,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Refusing to construct LMInput from an empty token sequence."
                ]
            )
        }

        let tokenArray = MLXArray(tokens).expandedDimensions(axis: 0)
        let mask = ones(like: tokenArray).asType(.int8)
        return LMInput(text: .init(tokens: tokenArray, mask: mask), image: nil)
    }

    static func makeSafeTokenLMInput(tokens: [Int]) throws -> LMInput {
        guard !tokens.isEmpty else {
            throw NSError(
                domain: "AgentLoop",
                code: 7,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Refusing to construct token LMInput from an empty token sequence."
                ]
            )
        }

        // Keep the token-only initializer for pure-text LLM checkpoints, which
        // historically expect a 1D token vector.
        return LMInput(tokens: MLXArray(tokens))
    }

    static func makeSafeBatchedTokenLMInput(tokens: [Int]) throws -> LMInput {
        guard !tokens.isEmpty else {
            throw NSError(
                domain: "AgentLoop",
                code: 8,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Refusing to construct batched token LMInput from an empty token sequence."
                ]
            )
        }

        let tokenArray = MLXArray(tokens).expandedDimensions(axis: 0)
        let mask = ones(like: tokenArray).asType(.int8)
        return LMInput(tokens: tokenArray, mask: mask)
    }
}
