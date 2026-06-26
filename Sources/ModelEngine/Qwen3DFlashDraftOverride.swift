import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// Detects an EAGLE-style DFlash draft and builds a `DFlashRuntime` whose target
/// shares weights with the already-loaded main model.
///
/// Faithful port of z-lab/dflash (`dflash/model_mlx.py`): the draft borrows the
/// target's `embed_tokens`/`lm_head` and consumes the target's intermediate hidden
/// states, so it cannot be loaded through the standard token-level draft path.
enum Qwen3DFlashDraftOverride {

    static func isDFlashDraft(draftModelPath: String) -> Bool {
        let draftURL = resolvedModelDirectoryURL(for: draftModelPath)
        let configURL = draftURL.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
            let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return isDFlashConfig(raw)
    }

    static func buildRuntime(
        draftModelPath: String,
        mainModelPath: String,
        mainModelContainer: ModelContainer,
        renderer: StreamRenderer
    ) async throws -> DFlashRuntime {
        let draftURL = resolvedModelDirectoryURL(for: draftModelPath)
        let draftConfigData = try Data(contentsOf: draftURL.appendingPathComponent("config.json"))
        guard
            let draftRaw = try JSONSerialization.jsonObject(with: draftConfigData) as? [String: Any],
            let draftConfig = DFlashConfig(raw: draftRaw)
        else {
            throw error("Invalid DFlash draft config.json")
        }

        renderer.printStatus("Detected DFlash draft \(draftModelPath). Building EAGLE-style drafter...")

        // Main model config: target backbone + quantization + eos.
        let mainURL = resolvedModelDirectoryURL(for: mainModelPath)
        let mainConfigData = try Data(contentsOf: mainURL.appendingPathComponent("config.json"))
        guard let mainRaw = try JSONSerialization.jsonObject(with: mainConfigData) as? [String: Any]
        else {
            throw error("Invalid main model config.json")
        }
        guard let targetConfig = makeTargetConfig(mainRaw: mainRaw) else {
            throw error("Unsupported main model for DFlash (expected a qwen3_5 text backbone).")
        }
        let (groupSize, bits) = quantization(mainRaw: mainRaw)
        let eosTokenIds = eosIds(mainRaw: mainRaw)

        // Build + load the draft (its own BF16 weights).
        let draft = DFlashDraftModel(draftConfig)
        let draftWeights = try loadArrays(url: draftURL.appendingPathComponent("model.safetensors"))
        draft.update(parameters: ModuleParameters.unflattened(draftWeights))
        // Keep the wide `fc` projection in float32 to avoid bf16 matmul overflow (NaN)
        // over its large reduction dimension.
        draft.fc.update(parameters: ModuleParameters.unflattened(["weight": draft.fc.weight.asType(.float32)]))
        eval(draft)

        // Build the target backbone and share the main model's (quantized) weights.
        let target = DFlashTargetModel(targetConfig)
        try await mainModelContainer.perform { (context: ModelContext) in
            let prefix = "language_model."
            var targetParams = [String: MLXArray]()
            for (key, value) in context.model.parameters().flattened() where key.hasPrefix(prefix) {
                targetParams[String(key.dropFirst(prefix.count))] = value
            }
            guard !targetParams.isEmpty else {
                throw error("Main model has no language_model.* parameters to share.")
            }

            // Quantize the backbone where the source layer is quantized (scales present).
            quantize(model: target.wrapper, groupSize: groupSize, bits: bits) { path, _ in
                targetParams["\(path).scales"] != nil
            }
            target.wrapper.update(parameters: ModuleParameters.unflattened(targetParams))
            eval(target.wrapper)
        }

        renderer.printStatus("DFlash drafter ready (\(draftConfig.numHiddenLayers) layers, "
            + "targets \(draftConfig.targetLayerIds)).")

        return DFlashRuntime(
            draft: draft,
            target: target,
            targetLayerIds: draftConfig.targetLayerIds,
            maskTokenId: draftConfig.maskTokenId,
            blockSize: draftConfig.blockSize,
            eosTokenIds: eosTokenIds
        )
    }

    // MARK: - Config parsing

    private static func isDFlashConfig(_ raw: [String: Any]) -> Bool {
        if let architectures = raw["architectures"] as? [String],
            architectures.contains(where: { $0.contains("DFlashDraftModel") })
        {
            return true
        }
        if let autoMap = raw["auto_map"] as? [String: Any],
            let autoModel = autoMap["AutoModel"] as? String, autoModel.contains("DFlashDraftModel")
        {
            return true
        }
        return raw["dflash_config"] != nil
    }

    private static func makeTargetConfig(mainRaw: [String: Any]) -> DFlashTargetConfig? {
        guard let text = mainRaw["text_config"] as? [String: Any] else { return nil }
        guard
            let hiddenSize = text["hidden_size"] as? Int,
            let numHiddenLayers = text["num_hidden_layers"] as? Int,
            let intermediateSize = text["intermediate_size"] as? Int,
            let attentionHeads = text["num_attention_heads"] as? Int,
            let kvHeads = text["num_key_value_heads"] as? Int,
            let vocabSize = text["vocab_size"] as? Int
        else { return nil }

        let headDim = (text["head_dim"] as? Int) ?? (hiddenSize / attentionHeads)
        let rope = text["rope_parameters"] as? [String: Any]
        let ropeTheta =
            float(rope?["rope_theta"]) ?? float(text["rope_theta"]) ?? 1_000_000
        let partialRotary =
            float(rope?["partial_rotary_factor"]) ?? float(text["partial_rotary_factor"]) ?? 0.25
        let mrope = (rope?["mrope_section"] as? [Int]) ?? [11, 11, 10]

        return DFlashTargetConfig(
            hiddenSize: hiddenSize,
            numHiddenLayers: numHiddenLayers,
            intermediateSize: intermediateSize,
            attentionHeads: attentionHeads,
            kvHeads: kvHeads,
            headDim: headDim,
            rmsNormEps: float(text["rms_norm_eps"]) ?? 1e-6,
            vocabSize: vocabSize,
            ropeTheta: ropeTheta,
            partialRotaryFactor: partialRotary,
            mropeSection: mrope,
            fullAttentionInterval: (text["full_attention_interval"] as? Int) ?? 4,
            attentionBias: (text["attention_bias"] as? Bool) ?? false,
            tieWordEmbeddings: (text["tie_word_embeddings"] as? Bool) ?? false,
            linearNumValueHeads: (text["linear_num_value_heads"] as? Int) ?? 48,
            linearNumKeyHeads: (text["linear_num_key_heads"] as? Int) ?? 16,
            linearKeyHeadDim: (text["linear_key_head_dim"] as? Int) ?? 128,
            linearValueHeadDim: (text["linear_value_head_dim"] as? Int) ?? 128,
            linearConvKernelDim: (text["linear_conv_kernel_dim"] as? Int) ?? 4
        )
    }

    private static func quantization(mainRaw: [String: Any]) -> (groupSize: Int, bits: Int) {
        let q = (mainRaw["quantization"] as? [String: Any])
            ?? (mainRaw["quantization_config"] as? [String: Any])
        let groupSize = (q?["group_size"] as? Int) ?? 64
        let bits = (q?["bits"] as? Int) ?? 4
        return (groupSize, bits)
    }

    private static func eosIds(mainRaw: [String: Any]) -> Set<Int> {
        if let ids = mainRaw["eos_token_id"] as? [Int] { return Set(ids) }
        if let id = mainRaw["eos_token_id"] as? Int { return [id] }
        if let text = mainRaw["text_config"] as? [String: Any] {
            if let ids = text["eos_token_id"] as? [Int] { return Set(ids) }
            if let id = text["eos_token_id"] as? Int { return [id] }
        }
        return []
    }

    private static func float(_ value: Any?) -> Float? {
        if let d = value as? Double { return Float(d) }
        if let i = value as? Int { return Float(i) }
        if let f = value as? Float { return f }
        return nil
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "Qwen3DFlashDraftOverride", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func resolvedModelDirectoryURL(for path: String) -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded) {
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        let parts = path.split(separator: "/")
        if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
            let local = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent(String(parts[0]), isDirectory: true)
                .appendingPathComponent(String(parts[1]), isDirectory: true)
            if FileManager.default.fileExists(atPath: local.path) {
                return local
            }
        }
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }
}
