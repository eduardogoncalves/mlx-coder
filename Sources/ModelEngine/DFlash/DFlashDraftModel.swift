import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// EAGLE-style DFlash draft model.
///
/// Port of `DFlashDraftModel` from z-lab/dflash (`dflash/model_mlx.py`). The model
/// borrows `embed_tokens`/`lm_head` from the target and consumes the target's
/// concatenated hidden states (`target_hidden`) projected through `fc`.
final class DFlashDraftModel: Module {

    // MARK: Submodules

    final class MLP: Module, UnaryLayer {
        @ModuleInfo(key: "gate_proj") var gate: Linear
        @ModuleInfo(key: "up_proj") var up: Linear
        @ModuleInfo(key: "down_proj") var down: Linear

        init(_ dim: Int, _ hidden: Int) {
            _gate.wrappedValue = Linear(dim, hidden, bias: false)
            _up.wrappedValue = Linear(dim, hidden, bias: false)
            _down.wrappedValue = Linear(hidden, dim, bias: false)
            super.init()
        }

        func callAsFunction(_ x: MLXArray) -> MLXArray {
            down(silu(gate(x)) * up(x))
        }
    }

    final class Attention: Module {
        let nHeads: Int
        let nKVHeads: Int
        let headDim: Int
        let scale: Float
        let isSliding: Bool
        let slidingWindow: Int?

        @ModuleInfo(key: "q_proj") var qProj: Linear
        @ModuleInfo(key: "k_proj") var kProj: Linear
        @ModuleInfo(key: "v_proj") var vProj: Linear
        @ModuleInfo(key: "o_proj") var oProj: Linear
        @ModuleInfo(key: "q_norm") var qNorm: RMSNorm
        @ModuleInfo(key: "k_norm") var kNorm: RMSNorm

        init(_ config: DFlashConfig, layerIdx: Int) {
            self.nHeads = config.numAttentionHeads
            self.nKVHeads = config.numKeyValueHeads
            self.headDim = config.headDim
            self.scale = pow(Float(config.headDim), -0.5)
            self.isSliding = config.layerTypes[layerIdx] == "sliding_attention"
            self.slidingWindow = isSliding ? config.slidingWindow : nil

            _qProj.wrappedValue = Linear(config.hiddenSize, nHeads * headDim, bias: false)
            _kProj.wrappedValue = Linear(config.hiddenSize, nKVHeads * headDim, bias: false)
            _vProj.wrappedValue = Linear(config.hiddenSize, nKVHeads * headDim, bias: false)
            _oProj.wrappedValue = Linear(nHeads * headDim, config.hiddenSize, bias: false)
            _qNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: config.rmsNormEps)
            _kNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: config.rmsNormEps)
            super.init()
        }

        func callAsFunction(_ x: MLXArray, ctx: MLXArray, rope: RoPE, cache: DFlashCache) -> MLXArray {
            let B = x.dim(0)
            let L = x.dim(1)
            var xCtx = ctx
            var S = xCtx.dim(1)

            if isSliding, let window = slidingWindow {
                let keepCtx = window - 1
                if S > keepCtx {
                    let skip = S - keepCtx
                    xCtx = xCtx[0..., skip..., 0...]
                    S = xCtx.dim(1)
                    cache.offset += skip
                }
            }

            var queries = qProj(x)
            var ctxKeys = kProj(xCtx)
            var ctxValues = vProj(xCtx)
            var propKeys = kProj(x)
            var propValues = vProj(x)

            queries = qNorm(queries.reshaped(B, L, nHeads, -1)).transposed(0, 2, 1, 3)
            ctxKeys = kNorm(ctxKeys.reshaped(B, S, nKVHeads, -1)).transposed(0, 2, 1, 3)
            ctxValues = ctxValues.reshaped(B, S, nKVHeads, -1).transposed(0, 2, 1, 3)
            propKeys = kNorm(propKeys.reshaped(B, L, nKVHeads, -1)).transposed(0, 2, 1, 3)
            propValues = propValues.reshaped(B, L, nKVHeads, -1).transposed(0, 2, 1, 3)

            queries = rope(queries, offset: cache.offset + S)
            ctxKeys = rope(ctxKeys, offset: cache.offset)
            propKeys = rope(propKeys, offset: cache.offset + S)

            let (storedKeys, storedValues) = cache.update(keys: ctxKeys, values: ctxValues)
            let ctxLen = storedKeys.dim(2)
            let keys = concatenated([storedKeys, propKeys], axis: 2)
            let values = concatenated([storedValues, propValues], axis: 2)

            let mask: MLXFast.ScaledDotProductAttentionMaskMode
            if isSliding, let window = slidingWindow {
                mask =
                    ctxLen + L <= window
                    ? .causal
                    : .array(createCausalMask(n: L, offset: ctxLen, windowSize: window))
            } else {
                mask = .none
            }

            let output = MLXFast.scaledDotProductAttention(
                queries: queries, keys: keys, values: values, scale: scale, mask: mask
            )
            .transposed(0, 2, 1, 3)
            .reshaped(B, L, -1)

            return oProj(output)
        }
    }

    final class DecoderLayer: Module {
        @ModuleInfo(key: "self_attn") var selfAttn: Attention
        let mlp: MLP
        @ModuleInfo(key: "input_layernorm") var inputLayerNorm: RMSNorm
        @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayerNorm: RMSNorm

        init(_ config: DFlashConfig, layerIdx: Int) {
            _selfAttn.wrappedValue = Attention(config, layerIdx: layerIdx)
            self.mlp = MLP(config.hiddenSize, config.intermediateSize)
            _inputLayerNorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
            _postAttentionLayerNorm.wrappedValue = RMSNorm(
                dimensions: config.hiddenSize, eps: config.rmsNormEps)
            super.init()
        }

        func callAsFunction(_ x: MLXArray, ctx: MLXArray, rope: RoPE, cache: DFlashCache) -> MLXArray {
            let h = x + selfAttn(inputLayerNorm(x), ctx: ctx, rope: rope, cache: cache)
            return h + mlp(postAttentionLayerNorm(h))
        }
    }

    // MARK: Trained parameters

    let fc: Linear
    @ModuleInfo(key: "hidden_norm") var hiddenNorm: RMSNorm
    fileprivate let layers: [DecoderLayer]
    let norm: RMSNorm

    // MARK: Borrowed from the target (not part of the saved checkpoint)

    /// `embed_tokens(inputs)` — set via `bind`.
    var borrowedEmbed: ((MLXArray) -> MLXArray)?
    /// `lm_head(x)` — set via `bind`.
    var borrowedLMHead: ((MLXArray) -> MLXArray)?
    var embedScale: Float = 1.0

    let config: DFlashConfig
    private let rope: RoPE

    init(_ config: DFlashConfig) {
        self.config = config
        self.fc = Linear(config.concatDim, config.hiddenSize, bias: false)
        _hiddenNorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self.layers = (0..<config.numHiddenLayers).map { DecoderLayer(config, layerIdx: $0) }
        self.norm = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self.rope = RoPE(
            dimensions: config.headDim, traditional: false, base: config.ropeTheta, scale: 1.0)
        super.init()
    }

    /// Create one KV cache per draft layer.
    func makeCache() -> [DFlashCache] {
        config.isLayerSliding.map { sliding in
            if sliding, let window = config.slidingWindow {
                return DFlashCache(maxSize: window - 1)
            }
            return DFlashCache(maxSize: nil)
        }
    }

    /// - Parameters:
    ///   - inputs: token ids `[B, L]` (the proposal block, position 0 is the real token).
    ///   - targetHidden: concatenated target hidden states `[B, L, concatDim]`.
    ///   - cache: per-layer draft caches.
    ///   - logitsStart: drop the first `logitsStart` positions before the LM head.
    func callAsFunction(
        _ inputs: MLXArray, targetHidden: MLXArray, cache: [DFlashCache], logitsStart: Int = 0
    ) -> MLXArray {
        guard let borrowedEmbed, let borrowedLMHead else {
            fatalError("DFlashDraftModel used before bind()")
        }
        var h = borrowedEmbed(inputs)
        if embedScale != 1.0 {
            h = h * embedScale
        }
        // The `fc` projection reduces over `len(target_layer_ids) * hidden_size`
        // (e.g. 32768) dims. Hidden-state magnitudes are large enough that a bf16
        // matmul over that many terms overflows fp16 accumulation to NaN, so run it
        // in float32 (mlx-lm accumulates the matmul in fp32).
        let fcOut = fc(targetHidden.asType(.float32)).asType(h.dtype)
        let hCtx = hiddenNorm(fcOut)
        for (layer, c) in zip(layers, cache) {
            h = layer(h, ctx: hCtx, rope: rope, cache: c)
        }
        if logitsStart > 0 {
            h = h[0..., logitsStart..., 0...]
        }
        var logits = borrowedLMHead(norm(h))
        if let cap = config.finalLogitSoftcapping {
            logits = tanh(logits / cap) * cap
        }
        return logits
    }
}
