// Sources/AgentCore/AgentLoop+ModelLifecycle.swift
// Model loading, reloading, switching, and low-level model utilities.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon

extension AgentLoop {

    /// Full model unload and reload to ensure fresh weights/cache.
    public func reloadModel() async throws {
        renderer.printStatus("Reloading model to ensure fresh state...")

        // Drop tool references first so old model-bound tools can be deallocated.
        await registry.clear()
        modelContainer = nil

        // Clear any unreferenced MLX buffers before loading replacement weights.
        MLX.Memory.clearCache()
        
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
        
        // Re-register tools that depend on modelContainer
        await registerToolsInternal()

        // Sweep again after rebinding to reclaim stale buffers from the old model.
        MLX.Memory.clearCache()
        
        renderer.printStatus("Model reloaded successfully")
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
            renderer.printStatus("Model is already active: \(trimmed)")
            return
        }

        renderer.printStatus("Unloading current model...")
        modelPath = trimmed
        pendingReload = false
        try await reloadModel()
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

        return LMInput(tokens: MLXArray(tokens))
    }
}
