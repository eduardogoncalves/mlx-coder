import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// Per-GatedDeltaNet-layer state captured during a verify forward, used to roll the
/// linear-attention cache back to the accepted prefix (mirrors `_GDNStateCapture`).
final class DFlashGDNRecord {
    let q: MLXArray
    let k: MLXArray
    let v: MLXArray
    let a: MLXArray
    let b: MLXArray
    let aLog: MLXArray
    let dtBias: MLXArray
    let initState: MLXArray?
    let mask: MLXArray?
    let convInput: MLXArray
    let convKernelSize: Int
    let cache: MambaCache

    init(
        q: MLXArray, k: MLXArray, v: MLXArray, a: MLXArray, b: MLXArray, aLog: MLXArray,
        dtBias: MLXArray, initState: MLXArray?, mask: MLXArray?, convInput: MLXArray,
        convKernelSize: Int, cache: MambaCache
    ) {
        self.q = q
        self.k = k
        self.v = v
        self.a = a
        self.b = b
        self.aLog = aLog
        self.dtBias = dtBias
        self.initState = initState
        self.mask = mask
        self.convInput = convInput
        self.convKernelSize = convKernelSize
        self.cache = cache
    }
}

/// Sink that GatedDeltaNet layers append to when capture is enabled.
final class DFlashGDNCapture {
    var records: [DFlashGDNRecord] = []
    func clear() { records.removeAll(keepingCapacity: true) }
}

/// Text-only port of the qwen3_5 backbone (`MLXVLM/Models/Qwen35.swift`,
/// `Qwen35Language`) that additionally:
///   - returns the per-layer hidden states at `targetLayerIds`, and
///   - captures GatedDeltaNet state for speculative-decode rollback.
///
/// Weights are *shared* with an already-loaded `Qwen35` VLM (see
/// `Qwen3DFlashDraftOverride`), so this adds no extra memory.
final class DFlashTargetModel: @unchecked Sendable {

    // MARK: Rotary (mrope)

    final class RotaryEmbedding {
        private let invFreq: MLXArray
        private let mropeSection: [Int]

        init(dim: Int, base: Float, mropeSection: [Int]) {
            let safeDim = max(1, dim)
            var freq = MLXArray(stride(from: 0, to: safeDim, by: 2)).asType(.float32)
            freq = freq / Float(safeDim)
            self.invFreq = 1.0 / pow(MLXArray(base), freq)
            self.mropeSection = mropeSection.count >= 3 ? mropeSection : [11, 11, 10]
        }

        private func applyInterleavedMRope(_ freqs: MLXArray) -> MLXArray {
            let freqsT = freqs[0, 0..., 0..., 0...]
            let dims = freqsT.dim(-1)
            var slices: [MLXArray] = []
            slices.reserveCapacity(dims)
            for idx in 0..<dims {
                var slice = freqsT[0..., 0..., idx]
                for (dim, offset) in [(1, 1), (2, 2)] {
                    let length = min(mropeSection[dim] * 3, dims)
                    if idx >= offset && idx < length && ((idx - offset) % 3 == 0) {
                        slice = freqs[dim, 0..., 0..., idx]
                        break
                    }
                }
                slices.append(slice)
            }
            return stacked(slices, axis: -1)
        }

        func callAsFunction(x: MLXArray, positionIds: MLXArray) -> (MLXArray, MLXArray) {
            var positionIds = positionIds
            if positionIds.ndim == 2 {
                positionIds = broadcast(
                    positionIds[.newAxis, 0..., 0...],
                    to: [3, positionIds.dim(0), positionIds.dim(1)])
            }
            let pos = positionIds.asType(.float32)
            var inv = invFreq.asType(.float32)
            inv = inv[.newAxis, .newAxis, .newAxis, 0...]
            var freqs = pos[0..., 0..., 0..., .newAxis] * inv
            freqs = applyInterleavedMRope(freqs)
            let emb = concatenated([freqs, freqs], axis: -1)
            return (cos(emb).asType(x.dtype), sin(emb).asType(x.dtype))
        }
    }

    private static func rotateHalf(_ x: MLXArray) -> MLXArray {
        let index = x.dim(-1) / 2
        let x1 = x[.ellipsis, 0..<index]
        let x2 = x[.ellipsis, index...]
        return concatenated([-x2, x1], axis: -1)
    }

    static func applyMultimodalRotaryPosEmb(
        q: MLXArray, k: MLXArray, cos: MLXArray, sin: MLXArray
    ) -> (MLXArray, MLXArray) {
        let cos = expandedDimensions(cos, axis: 1)
        let sin = expandedDimensions(sin, axis: 1)
        let rotaryDim = cos.dim(-1)
        let qDim = q.dim(-1)
        let kDim = k.dim(-1)
        let qRot = q[.ellipsis, ..<rotaryDim]
        let kRot = k[.ellipsis, ..<rotaryDim]
        let qEmbedded = (qRot * cos) + (rotateHalf(qRot) * sin)
        let kEmbedded = (kRot * cos) + (rotateHalf(kRot) * sin)
        let qOut = rotaryDim < qDim ? concatenated([qEmbedded, q[.ellipsis, rotaryDim...]], axis: -1) : qEmbedded
        let kOut = rotaryDim < kDim ? concatenated([kEmbedded, k[.ellipsis, rotaryDim...]], axis: -1) : kEmbedded
        return (qOut, kOut)
    }

    // MARK: Modules

    final class RMSNormGated: Module {
        @ParameterInfo(key: "weight") var weight: MLXArray
        let eps: Float
        init(dimensions: Int, eps: Float = 1e-6) {
            self.eps = eps
            _weight.wrappedValue = MLXArray.ones([dimensions])
            super.init()
        }
        func callAsFunction(_ hiddenStates: MLXArray, gate: MLXArray? = nil) -> MLXArray {
            var x = MLXFast.rmsNorm(hiddenStates, weight: weight, eps: eps)
            if let gate { x = x * silu(gate) }
            return x
        }
    }

    final class Attention: Module {
        let numKeyValueHeads: Int
        let numAttentionHeads: Int
        let headDim: Int
        let scale: Float

        @ModuleInfo(key: "q_proj") var qProj: Linear
        @ModuleInfo(key: "k_proj") var kProj: Linear
        @ModuleInfo(key: "v_proj") var vProj: Linear
        @ModuleInfo(key: "o_proj") var oProj: Linear
        @ModuleInfo(key: "q_norm") var qNorm: RMSNorm
        @ModuleInfo(key: "k_norm") var kNorm: RMSNorm

        let rotaryEmbedding: RotaryEmbedding

        init(_ args: DFlashTargetConfig) {
            self.numKeyValueHeads = args.kvHeads
            self.numAttentionHeads = args.attentionHeads
            self.headDim = args.headDim
            self.scale = pow(Float(headDim), -0.5)

            _qProj.wrappedValue = Linear(args.hiddenSize, numAttentionHeads * headDim * 2, bias: args.attentionBias)
            _kProj.wrappedValue = Linear(args.hiddenSize, numKeyValueHeads * headDim, bias: args.attentionBias)
            _vProj.wrappedValue = Linear(args.hiddenSize, numKeyValueHeads * headDim, bias: args.attentionBias)
            _oProj.wrappedValue = Linear(numAttentionHeads * headDim, args.hiddenSize, bias: args.attentionBias)
            _qNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: args.rmsNormEps)
            _kNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: args.rmsNormEps)

            let rotaryDim = Int(Float(headDim) * args.partialRotaryFactor)
            self.rotaryEmbedding = RotaryEmbedding(
                dim: rotaryDim, base: args.ropeTheta, mropeSection: args.mropeSection)
            super.init()
        }

        func callAsFunction(_ x: MLXArray, mask: MLXArray?, cache: KVCache?) -> MLXArray {
            let B = x.dim(0)
            let L = x.dim(1)

            let qProjOutput = qProj(x)
            let qSplit = qProjOutput.reshaped(B, L, numAttentionHeads, -1).split(parts: 2, axis: -1)
            var queries = qSplit[0]
            let gate = qSplit[1].reshaped(B, L, -1)

            var keys = kProj(x)
            var values = vProj(x)

            queries = qNorm(queries).transposed(0, 2, 1, 3)
            keys = kNorm(keys.reshaped(B, L, numKeyValueHeads, -1)).transposed(0, 2, 1, 3)
            values = values.reshaped(B, L, numKeyValueHeads, -1).transposed(0, 2, 1, 3)

            var kvSeqLen = keys.dim(-2)
            let offset = cache?.offset ?? 0
            kvSeqLen += offset + 1
            var base = MLXArray(stride(from: offset, to: offset + L, by: 1)).asType(.int32)
            base = tiled(base[.newAxis, 0...], repetitions: [B, 1])
            var positionIds = base[.newAxis, 0..., 0...]
            positionIds = tiled(positionIds, repetitions: [3, 1, 1])

            let (cosValues, sinValues) = rotaryEmbedding(x: values, positionIds: positionIds)
            (queries, keys) = applyMultimodalRotaryPosEmb(q: queries, k: keys, cos: cosValues, sin: sinValues)

            let attentionMask: MLXFast.ScaledDotProductAttentionMaskMode
            if let mask {
                attentionMask = .array(mask[.ellipsis, 0..<kvSeqLen])
            } else {
                attentionMask = .none
            }

            let output = attentionWithCacheUpdate(
                queries: queries, keys: keys, values: values, cache: cache, scale: scale,
                mask: attentionMask
            )
            .transposed(0, 2, 1, 3)
            .reshaped(B, L, -1)

            return oProj(output * sigmoid(gate))
        }
    }

    final class MLP: Module, UnaryLayer {
        @ModuleInfo(key: "gate_proj") var gateProj: Linear
        @ModuleInfo(key: "down_proj") var downProj: Linear
        @ModuleInfo(key: "up_proj") var upProj: Linear
        init(dimensions: Int, hiddenDimensions: Int) {
            _gateProj.wrappedValue = Linear(dimensions, hiddenDimensions, bias: false)
            _downProj.wrappedValue = Linear(hiddenDimensions, dimensions, bias: false)
            _upProj.wrappedValue = Linear(dimensions, hiddenDimensions, bias: false)
            super.init()
        }
        func callAsFunction(_ x: MLXArray) -> MLXArray {
            downProj(silu(gateProj(x)) * upProj(x))
        }
    }

    final class GatedDeltaNet: Module {
        let numVHeads: Int
        let numKHeads: Int
        let headKDim: Int
        let headVDim: Int
        let keyDim: Int
        let valueDim: Int
        let convKernelSize: Int
        let convDim: Int

        @ModuleInfo(key: "conv1d") var conv1d: Conv1d
        @ModuleInfo(key: "in_proj_qkv") var inProjQKV: Linear
        @ModuleInfo(key: "in_proj_z") var inProjZ: Linear
        @ModuleInfo(key: "in_proj_b") var inProjB: Linear
        @ModuleInfo(key: "in_proj_a") var inProjA: Linear
        @ParameterInfo(key: "dt_bias") var dtBias: MLXArray
        @ParameterInfo(key: "A_log") var aLog: MLXArray
        @ModuleInfo(key: "norm") var norm: RMSNormGated
        @ModuleInfo(key: "out_proj") var outProj: Linear

        /// Set by the model when a verify forward needs rollback data.
        var capture: DFlashGDNCapture?

        init(_ args: DFlashTargetConfig) {
            self.numVHeads = args.linearNumValueHeads
            self.numKHeads = args.linearNumKeyHeads
            self.headKDim = args.linearKeyHeadDim
            self.headVDim = args.linearValueHeadDim
            self.keyDim = headKDim * numKHeads
            self.valueDim = headVDim * numVHeads
            self.convKernelSize = args.linearConvKernelDim
            self.convDim = keyDim * 2 + valueDim

            _conv1d.wrappedValue = Conv1d(
                inputChannels: convDim, outputChannels: convDim, kernelSize: convKernelSize,
                stride: 1, padding: 0, dilation: 1, groups: convDim, bias: false)
            _inProjQKV.wrappedValue = Linear(args.hiddenSize, keyDim * 2 + valueDim, bias: false)
            _inProjZ.wrappedValue = Linear(args.hiddenSize, valueDim, bias: false)
            _inProjB.wrappedValue = Linear(args.hiddenSize, numVHeads, bias: false)
            _inProjA.wrappedValue = Linear(args.hiddenSize, numVHeads, bias: false)
            _dtBias.wrappedValue = MLXArray.ones([numVHeads])
            _aLog.wrappedValue = MLXArray.ones([numVHeads])
            _norm.wrappedValue = RMSNormGated(dimensions: headVDim, eps: args.rmsNormEps)
            _outProj.wrappedValue = Linear(valueDim, args.hiddenSize, bias: false)
            super.init()
        }

        func callAsFunction(_ inputs: MLXArray, mask: MLXArray? = nil, cache: MambaCache? = nil) -> MLXArray {
            let B = inputs.dim(0)
            let S = inputs.dim(1)

            var mixedQKV = inProjQKV(inputs)
            let z = inProjZ(inputs).reshaped(B, S, numVHeads, headVDim)
            let b = inProjB(inputs)
            let a = inProjA(inputs)

            let convState: MLXArray
            if let cacheState = cache?[0] {
                convState = cacheState
            } else {
                convState = MLXArray.zeros([B, max(0, convKernelSize - 1), convDim], dtype: inputs.dtype)
            }

            if let mask {
                mixedQKV = MLX.where(mask[.ellipsis, .newAxis], mixedQKV, 0)
            }

            let convInput = concatenated([convState, mixedQKV], axis: 1)
            if let cache, convKernelSize > 1 {
                cache[0] = convInput[0..., (-(convKernelSize - 1))...]
            }

            let convOut = silu(conv1d(convInput))
            let split = MLX.split(convOut, indices: [keyDim, 2 * keyDim], axis: -1)
            let q = split[0].reshaped(B, S, numKHeads, headKDim)
            let k = split[1].reshaped(B, S, numKHeads, headKDim)
            let v = split[2].reshaped(B, S, numVHeads, headVDim)

            let initState = cache?[1]
            var state = initState
            let dtype = q.dtype
            let invScale = pow(Float(headKDim), -0.5)
            let qNormed = MLXArray(pow(invScale, 2)).asType(dtype) * MLXFast.rmsNorm(q, weight: MLXArray.mlxNone, eps: 1e-6)
            let kNormed = MLXArray(invScale).asType(dtype) * MLXFast.rmsNorm(k, weight: MLXArray.mlxNone, eps: 1e-6)

            var out: MLXArray
            (out, state) = dflashGatedDeltaUpdate(
                q: qNormed, k: kNormed, v: v, a: a, b: b, aLog: aLog, dtBias: dtBias,
                state: state, mask: mask)

            if let cache {
                cache[1] = state
                if let capture {
                    capture.records.append(
                        DFlashGDNRecord(
                            q: qNormed, k: kNormed, v: v, a: a, b: b, aLog: aLog, dtBias: dtBias,
                            initState: initState, mask: mask, convInput: convInput,
                            convKernelSize: convKernelSize, cache: cache))
                }
            }

            out = norm(out, gate: z)
            return outProj(out.reshaped(B, S, -1))
        }
    }

    final class DecoderLayer: Module {
        let isLinear: Bool
        @ModuleInfo(key: "self_attn") var selfAttn: Attention?
        @ModuleInfo(key: "linear_attn") var linearAttn: GatedDeltaNet?
        @ModuleInfo(key: "input_layernorm") var inputLayerNorm: RMSNorm
        @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayerNorm: RMSNorm
        @ModuleInfo(key: "mlp") var mlp: MLP

        init(_ args: DFlashTargetConfig, layerIdx: Int) {
            self.isLinear = (layerIdx + 1) % args.fullAttentionInterval != 0
            if isLinear {
                _linearAttn.wrappedValue = GatedDeltaNet(args)
            } else {
                _selfAttn.wrappedValue = Attention(args)
            }
            _mlp.wrappedValue = MLP(dimensions: args.hiddenSize, hiddenDimensions: args.intermediateSize)
            _inputLayerNorm.wrappedValue = RMSNorm(dimensions: args.hiddenSize, eps: args.rmsNormEps)
            _postAttentionLayerNorm.wrappedValue = RMSNorm(dimensions: args.hiddenSize, eps: args.rmsNormEps)
            super.init()
        }

        func callAsFunction(_ x: MLXArray, attentionMask: MLXArray?, ssmMask: MLXArray?, cache: KVCache?) -> MLXArray {
            let r: MLXArray
            if isLinear {
                r = linearAttn!(inputLayerNorm(x), mask: ssmMask, cache: cache as? MambaCache)
            } else {
                r = selfAttn!(inputLayerNorm(x), mask: attentionMask, cache: cache)
            }
            let h = x + r
            return h + mlp(postAttentionLayerNorm(h))
        }
    }

    final class Model: Module {
        @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
        @ModuleInfo(key: "layers") var layers: [DecoderLayer]
        @ModuleInfo(key: "norm") var norm: RMSNorm
        let faIdx: Int
        let ssmIdx: Int

        init(_ args: DFlashTargetConfig) {
            _embedTokens.wrappedValue = Embedding(embeddingCount: args.vocabSize, dimensions: args.hiddenSize)
            _layers.wrappedValue = (0..<args.numHiddenLayers).map { DecoderLayer(args, layerIdx: $0) }
            _norm.wrappedValue = RMSNorm(dimensions: args.hiddenSize, eps: args.rmsNormEps)
            self.ssmIdx = 0
            self.faIdx = args.fullAttentionInterval - 1
            super.init()
        }
    }

    /// The weight-bearing module tree. Its parameter paths (`model.*`, `lm_head.*`)
    /// match the target VLM's `language_model.*` subtree after stripping the prefix,
    /// so the whole tree can be quantized and weight-shared as a unit.
    final class Wrapper: Module {
        @ModuleInfo(key: "model") var model: Model
        @ModuleInfo(key: "lm_head") var lmHead: Linear?

        init(_ config: DFlashTargetConfig) {
            _model.wrappedValue = Model(config)
            if !config.tieWordEmbeddings {
                _lmHead.wrappedValue = Linear(config.hiddenSize, config.vocabSize, bias: false)
            }
            super.init()
        }
    }

    // MARK: Top-level

    let wrapper: Wrapper
    let config: DFlashTargetConfig

    var model: Model { wrapper.model }

    /// `isLinear[i]` — whether layer i uses GatedDeltaNet (non-trimmable cache).
    var isLinear: [Bool] { model.layers.map { $0.isLinear } }

    init(_ config: DFlashTargetConfig) {
        self.config = config
        self.wrapper = Wrapper(config)
    }

    func makeCache() -> [KVCache] {
        model.layers.map { $0.isLinear ? MambaCache() : KVCacheSimple() }
    }

    func embed(_ inputs: MLXArray) -> MLXArray { model.embedTokens(inputs) }

    func applyLMHead(_ x: MLXArray) -> MLXArray {
        if let lm = wrapper.lmHead { return lm(x) }
        return model.embedTokens.asLinear(x)
    }

    /// Forward pass returning `(logits, capturedHidden)` where `capturedHidden` is the
    /// concatenation of the residual stream after each `targetLayerIds` layer, shape
    /// `[B, L, len(ids) * hiddenSize]`.
    ///
    /// - Parameter captureGDN: when true, GatedDeltaNet layers record rollback state.
    func forward(
        _ inputs: MLXArray, cache: [KVCache], targetLayerIds: [Int], captureGDN: DFlashGDNCapture?
    ) -> (logits: MLXArray, hidden: MLXArray) {
        for (i, layer) in model.layers.enumerated() where layer.isLinear {
            layer.linearAttn?.capture = captureGDN
        }
        captureGDN?.clear()

        var hiddenStates = model.embedTokens(inputs)

        let faMaskMode = createAttentionMask(h: hiddenStates, cache: cache[model.faIdx], returnArray: true)
        let faMask: MLXArray?
        if case .array(let arrayMask) = faMaskMode { faMask = arrayMask } else { faMask = nil }
        let ssmMask = createSSMMask(h: hiddenStates, cache: cache[model.ssmIdx] as? MambaCache)

        let captureSet = Set(targetLayerIds)
        var capturedByLayer = [Int: MLXArray]()

        for (index, layer) in model.layers.enumerated() {
            let layerSSMMask = layer.isLinear ? ssmMask : nil
            hiddenStates = layer(
                hiddenStates, attentionMask: faMask, ssmMask: layerSSMMask, cache: cache[index])
            if captureSet.contains(index) {
                capturedByLayer[index] = hiddenStates
            }
        }

        let orderedHidden = targetLayerIds.map { capturedByLayer[$0]! }
        let hidden = concatenated(orderedHidden, axis: -1)

        let logits = applyLMHead(model.norm(hiddenStates))
        return (logits, hidden)
    }
}

/// Configuration subset needed for the text backbone.
struct DFlashTargetConfig {
    var hiddenSize: Int
    var numHiddenLayers: Int
    var intermediateSize: Int
    var attentionHeads: Int
    var kvHeads: Int
    var headDim: Int
    var rmsNormEps: Float
    var vocabSize: Int
    var ropeTheta: Float
    var partialRotaryFactor: Float
    var mropeSection: [Int]
    var fullAttentionInterval: Int
    var attentionBias: Bool
    var tieWordEmbeddings: Bool
    var linearNumValueHeads: Int
    var linearNumKeyHeads: Int
    var linearKeyHeadDim: Int
    var linearValueHeadDim: Int
    var linearConvKernelDim: Int
}
