// Sources/ModelEngine/ModelContainerExtensions.swift
// Extensions to MLXLMCommon.ModelContainer that require additional imports
// not available in the upstream library.

import MLXLMCommon
import MLXVLM

extension ModelContainer {
    /// Whether this model is a vision-language model (VLM).
    ///
    /// Returns `true` when the loaded model conforms to `VLMModel`, which covers
    /// all models loaded via `VLMModelFactory` (e.g. Gemma4, Qwen2VL, Llama3.2-Vision).
    /// Returns `false` for pure-text language models.
    ///
    /// Use this to decide whether the processor path is needed:
    /// ```swift
    /// let shouldUseProcessor = await container.isVLM
    /// ```
    public var isVLM: Bool {
        get async {
            await perform { context in
                context.model is any VLMModel
            }
        }
    }
}
