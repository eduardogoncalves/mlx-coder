// Sources/ModelEngine/VisionWeightFilter.swift
// Drops vision-tower weights from a loaded model so a coding agent does not
// keep VRAM tied up by a vision encoder it never uses. The filter is a no-op
// on pure LLM checkpoints (no parameter keys match the vision prefixes).

import Foundation
import MLX
import MLXNN

public enum VisionWeightFilter {

    /// Parameter-key prefixes that identify weights belonging to a vision
    /// encoder in the VLM checkpoints supported by MLX-Swift-LM (Gemma3/4,
    /// Qwen2/2.5/3-VL, PaliGemma, Pixtral, Mistral3, SmolVLM, FastVLM, etc.).
    public static let visionPrefixes: [String] = [
        "vision_tower",
        "model.visual",
        "visual.",
        "vision_model",
    ]

    /// Returns `true` when `key` belongs to a vision encoder.
    public static func isVisionKey(_ key: String) -> Bool {
        for prefix in visionPrefixes where key.hasPrefix(prefix) {
            return true
        }
        return false
    }

    /// Walks `model`'s parameters and swaps every vision-prefixed parameter
    /// for a tiny scalar placeholder, then releases cached MLX buffers.
    ///
    /// `update(parameters:)` accepts a partial nested dictionary — keys that
    /// are omitted are left unchanged, so this only touches vision weights.
    /// Once the original `MLXArray` references are dropped,
    /// `MLX.Memory.clearCache()` returns the buffers to the allocator. Modules
    /// that owned those weights (the vision tower) become unusable, which is
    /// the intent — the CLI only invokes this path when the user has opted
    /// out of vision.
    ///
    /// - Returns: `true` if at least one vision-prefixed parameter was found
    ///   and replaced (i.e. the checkpoint actually included a vision encoder).
    @discardableResult
    public static func dropVisionWeights(in model: Module) -> Bool {
        let flat = model.parameters().flattened()
        var replacements: [(String, MLXArray)] = []

        let placeholder = MLXArray(0)
        for (key, _) in flat where isVisionKey(key) {
            replacements.append((key, placeholder))
        }

        guard !replacements.isEmpty else { return false }

        let partial = ModuleParameters.unflattened(replacements)
        // Use the non-throwing variant which passes `verify: .none`, allowing
        // a partial update without complaining about unused or missing keys.
        model.update(parameters: partial)

        // Force the placeholder swap to materialize, then release the buffers
        // that previously held the vision weights.
        eval(model)
        MLX.Memory.clearCache()

        return true
    }
}
