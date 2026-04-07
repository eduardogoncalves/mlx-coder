// Sources/VendoredVLM/VLMModelFactory+Gemma4.swift
// Registers Gemma4 model and processor types with the official MLXVLM factories.
// Called once at app startup via `Gemma4Registration.register()`.
//
// Vendored from adrgrondin/mlx-swift-lm@67b5729e3d47d8709e03417129a1ea9ed4f19ada

import Foundation
import MLXLMCommon
import MLXVLM
import Tokenizers

// MARK: - Registration helpers (mirrors the private `create` functions in VLMModelFactory.swift)

private func makeModelCreator<C: Codable>(
    _ configurationType: C.Type,
    _ modelInit: @escaping (C) -> any LanguageModel
) -> (Data) throws -> any LanguageModel {
    { data in
        let configuration = try JSONDecoder.json5().decode(C.self, from: data)
        return modelInit(configuration)
    }
}

private func makeProcessorCreator<C: Codable>(
    _ configurationType: C.Type,
    _ processorInit: @escaping (C, any Tokenizer) -> any UserInputProcessor
) -> (Data, any Tokenizer) throws -> any UserInputProcessor {
    { data, tokenizer in
        let configuration = try JSONDecoder.json5().decode(C.self, from: data)
        return processorInit(configuration, tokenizer)
    }
}

// MARK: - Gemma4Registration

/// Registers Gemma4 with the official MLXVLM type and model registries.
///
/// Call `await Gemma4Registration.shared.register()` once — before any model is loaded —
/// to enable loading `gemma4` models (e.g. `mlx-community/gemma-4-e4b-it-4bit`) via
/// `VLMModelFactory`.
public actor Gemma4Registration {

    public static let shared = Gemma4Registration()

    private var registered = false

    private init() {}

    /// Idempotent: safe to call multiple times; only the first call registers types.
    public func register() async {
        guard !registered else { return }
        registered = true

        await VLMTypeRegistry.shared.registerModelType(
            "gemma4",
            creator: makeModelCreator(Gemma4Configuration.self, Gemma4.init)
        )

        await VLMProcessorTypeRegistry.shared.registerProcessorType(
            "Gemma4Processor",
            creator: makeProcessorCreator(Gemma4ProcessorConfiguration.self, Gemma4Processor.init)
        )

        VLMRegistry.shared.register(configurations: [
            ModelConfiguration(
                id: "mlx-community/gemma-4-e2b-it-4bit",
                defaultPrompt: "Describe the image in English",
                extraEOSTokens: ["<end_of_turn>"]
            ),
            ModelConfiguration(
                id: "mlx-community/gemma-4-e4b-it-4bit",
                defaultPrompt: "Describe the image in English",
                extraEOSTokens: ["<end_of_turn>"]
            ),
            ModelConfiguration(
                id: "mlx-community/gemma-4-31b-it-4bit",
                defaultPrompt: "Describe the image in English",
                extraEOSTokens: ["<end_of_turn>"]
            ),
            ModelConfiguration(
                id: "mlx-community/gemma-4-26b-a4b-it-4bit",
                defaultPrompt: "Describe the image in English",
                extraEOSTokens: ["<end_of_turn>"]
            ),
        ])
    }
}
