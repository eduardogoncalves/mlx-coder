import Foundation

/// Configuration for a DFlash speculative-decoding draft model.
///
/// Mirrors `DFlashConfig` in z-lab/dflash (`dflash/model_mlx.py`). The draft is an
/// EAGLE-style drafter: it borrows the target model's `embed_tokens`/`lm_head` and
/// consumes the target's concatenated intermediate hidden states (captured at
/// `targetLayerIds`) as extra context.
struct DFlashConfig {
    let hiddenSize: Int
    let numHiddenLayers: Int
    let numAttentionHeads: Int
    let numKeyValueHeads: Int
    let headDim: Int
    let intermediateSize: Int
    let vocabSize: Int
    let rmsNormEps: Float
    let ropeTheta: Float
    let maxPositionEmbeddings: Int
    let blockSize: Int
    let targetLayerIds: [Int]
    let numTargetLayers: Int
    let maskTokenId: Int
    let layerTypes: [String]
    let slidingWindow: Int?
    let finalLogitSoftcapping: Float?

    /// `len(target_layer_ids) * hidden_size` — input dimension of the `fc` projection.
    var concatDim: Int { targetLayerIds.count * hiddenSize }

    var isLayerSliding: [Bool] { layerTypes.map { $0 == "sliding_attention" } }

    /// Parse from a draft `config.json` already decoded into a dictionary.
    init?(raw: [String: Any]) {
        guard
            let hiddenSize = raw["hidden_size"] as? Int,
            let numHiddenLayers = raw["num_hidden_layers"] as? Int,
            let numAttentionHeads = raw["num_attention_heads"] as? Int,
            let numKeyValueHeads = raw["num_key_value_heads"] as? Int,
            let headDim = raw["head_dim"] as? Int,
            let intermediateSize = raw["intermediate_size"] as? Int,
            let vocabSize = raw["vocab_size"] as? Int,
            let dflash = raw["dflash_config"] as? [String: Any],
            let targetLayerIds = dflash["target_layer_ids"] as? [Int],
            let numTargetLayers = raw["num_target_layers"] as? Int
        else { return nil }

        self.hiddenSize = hiddenSize
        self.numHiddenLayers = numHiddenLayers
        self.numAttentionHeads = numAttentionHeads
        self.numKeyValueHeads = numKeyValueHeads
        self.headDim = headDim
        self.intermediateSize = intermediateSize
        self.vocabSize = vocabSize
        self.targetLayerIds = targetLayerIds
        self.numTargetLayers = numTargetLayers
        self.maskTokenId = (dflash["mask_token_id"] as? Int) ?? 0
        self.rmsNormEps = DFlashConfig.float(raw["rms_norm_eps"]) ?? 1e-6

        // rope_theta may live at the top level (older configs) or under
        // `rope_parameters` (newer configs); the two checkpoints differ.
        let ropeParams = raw["rope_parameters"] as? [String: Any]
        self.ropeTheta =
            DFlashConfig.float(ropeParams?["rope_theta"])
            ?? DFlashConfig.float(raw["rope_theta"])
            ?? 1_000_000

        self.maxPositionEmbeddings = (raw["max_position_embeddings"] as? Int) ?? 32768
        // block_size is top-level in older configs, under dflash_config in newer ones.
        self.blockSize = (dflash["block_size"] as? Int) ?? (raw["block_size"] as? Int) ?? 8

        let defaultTypes = Array(repeating: "full_attention", count: numHiddenLayers)
        let layerTypes = (raw["layer_types"] as? [String]) ?? defaultTypes
        self.layerTypes = layerTypes.count == numHiddenLayers ? layerTypes : defaultTypes
        self.slidingWindow = raw["sliding_window"] as? Int
        self.finalLogitSoftcapping = DFlashConfig.float(raw["final_logit_softcapping"])
    }

    private static func float(_ value: Any?) -> Float? {
        if let d = value as? Double { return Float(d) }
        if let i = value as? Int { return Float(i) }
        if let f = value as? Float { return f }
        return nil
    }
}
