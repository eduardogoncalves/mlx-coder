import Foundation
import MLX
import MLXNN

// Gated-delta-net helpers. Ported verbatim from the (private) helpers in
// mlx-swift-lm `MLXVLM/Models/Qwen35.swift` so DFlash can reuse the exact numerics
// for the target's `linear_attention` layers and for speculative-decode rollback.

func dflashComputeGatedDeltaG(_ aLog: MLXArray, _ a: MLXArray, _ dtBias: MLXArray) -> MLXArray {
    let decay = exp(-exp(aLog.asType(.float32)) * softplus(a + dtBias))
    return decay.asType(a.dtype)
}

private func dflashGatedDeltaStepOps(
    q: MLXArray, k: MLXArray, v: MLXArray, g: MLXArray, beta: MLXArray, state: MLXArray,
    mask: MLXArray? = nil
) -> (MLXArray, MLXArray) {
    let oldState = state
    let decay: MLXArray
    if g.ndim == 2 {
        decay = expandedDimensions(g, axes: [2, 3])
    } else if g.ndim == 3 {
        decay = expandedDimensions(g, axis: -2)
    } else {
        fatalError("Unsupported gating shape \(g.shape)")
    }

    var state = state * decay
    let kvMem = (state * expandedDimensions(k, axis: -2)).sum(axis: -1)
    let delta = (v - kvMem) * expandedDimensions(beta, axis: -1)
    state = state + expandedDimensions(k, axis: -2) * expandedDimensions(delta, axis: -1)
    let y = (state * expandedDimensions(q, axis: -2)).sum(axis: -1)

    if let mask {
        let expandedMask: MLXArray
        if mask.ndim == 1 {
            expandedMask = expandedDimensions(mask, axes: [1, 2, 3])
        } else if mask.ndim == 2 {
            expandedMask = expandedDimensions(mask, axes: [2, 3])
        } else if mask.ndim == 3 {
            expandedMask = expandedDimensions(mask, axis: -1)
        } else {
            fatalError("Unsupported mask shape \(mask.shape)")
        }
        state = MLX.where(expandedMask, state, oldState)
    }

    return (y, state)
}

private func dflashGatedDeltaOps(
    q: MLXArray, k: MLXArray, v: MLXArray, g: MLXArray, beta: MLXArray, state: MLXArray? = nil,
    mask: MLXArray? = nil
) -> (MLXArray, MLXArray) {
    let B = q.dim(0)
    let T = q.dim(1)
    let Hk = q.dim(2)
    let Hv = v.dim(2)
    let Dv = v.dim(3)
    let Dk = q.dim(3)

    var q = q
    var k = k
    let repeatFactor = Hv / Hk
    if repeatFactor > 1 {
        q = repeated(q, count: repeatFactor, axis: -2)
        k = repeated(k, count: repeatFactor, axis: -2)
    }

    var state = state ?? MLXArray.zeros([B, Hv, Dv, Dk], dtype: q.dtype)
    var ys = [MLXArray]()
    ys.reserveCapacity(T)

    for t in 0..<T {
        let (y, newState) = dflashGatedDeltaStepOps(
            q: q[0..., t], k: k[0..., t], v: v[0..., t], g: g[0..., t], beta: beta[0..., t],
            state: state, mask: mask == nil ? nil : mask![0..., t])
        ys.append(y)
        state = newState
    }

    return (MLX.stacked(ys, axis: 1), state)
}

// MARK: - Fused Metal kernel

// Ported from mlx-swift-lm `MLXLLM/Models/GatedDelta.swift`. Performs the entire
// gated-delta scan in a single GPU launch (the time loop lives inside the kernel),
// so a `T`-token verify costs roughly the same as a single decode step — without it,
// DFlash's block verify is `T`x slower than a normal decode and speculation loses.

private func makeDFlashGatedDeltaKernel(hasMask: Bool) -> MLXFast.MLXFastKernel? {
    let maskSource = hasMask ? "mask[b_idx * T + t]" : "true"
    let source = """
            auto n = thread_position_in_grid.z;
            auto b_idx = n / Hv;
            auto hv_idx = n % Hv;
            auto hk_idx = hv_idx / (Hv / Hk);
            constexpr int n_per_t = Dk / 32;

            auto q_ = q + b_idx * T * Hk * Dk + hk_idx * Dk;
            auto k_ = k + b_idx * T * Hk * Dk + hk_idx * Dk;

            auto v_ = v + b_idx * T * Hv * Dv + hv_idx * Dv;
            y += b_idx * T * Hv * Dv + hv_idx * Dv;

            auto dk_idx = thread_position_in_threadgroup.x;
            auto dv_idx = thread_position_in_grid.y;

            auto g_ = g + b_idx * T * Hv;
            auto beta_ = beta + b_idx * T * Hv;

            auto i_state = state_in + (n * Dv + dv_idx) * Dk;
            auto o_state = state_out + (n * Dv + dv_idx) * Dk;

            float state[n_per_t];
            for (int i = 0; i < n_per_t; ++i) {
              auto s_idx = n_per_t * dk_idx + i;
              state[i] = static_cast<float>(i_state[s_idx]);
            }

            for (int t = 0; t < T; ++t) {
              if (\(maskSource)) {
                float kv_mem = 0.0f;
                for (int i = 0; i < n_per_t; ++i) {
                  auto s_idx = n_per_t * dk_idx + i;
                  state[i] = state[i] * g_[hv_idx];
                  kv_mem += state[i] * k_[s_idx];
                }
                kv_mem = simd_sum(kv_mem);

                auto delta = (v_[dv_idx] - kv_mem) * beta_[hv_idx];

                float out = 0.0f;
                for (int i = 0; i < n_per_t; ++i) {
                  auto s_idx = n_per_t * dk_idx + i;
                  state[i] = state[i] + k_[s_idx] * delta;
                  out += state[i] * q_[s_idx];
                }
                out = simd_sum(out);
                if (thread_index_in_simdgroup == 0) {
                  y[dv_idx] = static_cast<InT>(out);
                }
              }
              q_ += Hk * Dk;
              k_ += Hk * Dk;
              v_ += Hv * Dv;
              y += Hv * Dv;
              g_ += Hv;
              beta_ += Hv;
            }
            for (int i = 0; i < n_per_t; ++i) {
              auto s_idx = n_per_t * dk_idx + i;
              o_state[s_idx] = static_cast<InT>(state[i]);
            }
        """

    var inputNames = ["q", "k", "v", "g", "beta", "state_in", "T"]
    if hasMask { inputNames.append("mask") }
    let suffix = hasMask ? "_mask" : ""
    return MLXFast.metalKernel(
        name: "dflash_gated_delta_step\(suffix)",
        inputNames: inputNames,
        outputNames: ["y", "state_out"],
        source: source)
}

private final class DFlashGatedDeltaKernelManager: Sendable {
    static let shared = DFlashGatedDeltaKernelManager()
    let kernel: MLXFast.MLXFastKernel?
    let kernelMasked: MLXFast.MLXFastKernel?
    private init() {
        kernel = makeDFlashGatedDeltaKernel(hasMask: false)
        kernelMasked = makeDFlashGatedDeltaKernel(hasMask: true)
    }
}

private func dflashGatedDeltaKernel(
    q: MLXArray, k: MLXArray, v: MLXArray, g: MLXArray, beta: MLXArray, state: MLXArray,
    mask: MLXArray? = nil
) -> (MLXArray, MLXArray) {
    let B = k.dim(0)
    let T = k.dim(1)
    let Hk = k.dim(2)
    let Dk = k.dim(3)
    let Hv = v.dim(2)
    let Dv = v.dim(3)
    let inputType = q.dtype

    let selectedKernel: MLXFast.MLXFastKernel?
    var inputs: [MLXArray] = [q, k, v, g, beta, state, MLXArray(T)]
    if let mask {
        selectedKernel = DFlashGatedDeltaKernelManager.shared.kernelMasked
        inputs.append(mask)
    } else {
        selectedKernel = DFlashGatedDeltaKernelManager.shared.kernel
    }
    guard let kernel = selectedKernel else { fatalError("DFlash gated delta kernel unavailable") }

    let outputs = kernel(
        inputs,
        template: [("InT", inputType), ("Dk", Dk), ("Dv", Dv), ("Hk", Hk), ("Hv", Hv)],
        grid: (32, Dv, B * Hv),
        threadGroup: (32, 4, 1),
        outputShapes: [[B, T, Hv, Dv], state.shape],
        outputDTypes: [inputType, inputType])
    return (outputs[0], outputs[1])
}

func dflashGatedDeltaUpdate(
    q: MLXArray, k: MLXArray, v: MLXArray, a: MLXArray, b: MLXArray, aLog: MLXArray,
    dtBias: MLXArray, state: MLXArray? = nil, mask: MLXArray? = nil
) -> (MLXArray, MLXArray) {
    let beta = sigmoid(b)
    let g = dflashComputeGatedDeltaG(aLog, a, dtBias)

    let B = q.dim(0)
    let Dk = q.dim(3)
    let Hv = v.dim(2)
    let Dv = v.dim(3)

    let state = state ?? MLXArray.zeros([B, Hv, Dv, Dk], dtype: q.dtype)

    // The kernel handles GQA internally (no q/k repeat) and accumulates in fp32.
    if DFlashGatedDeltaKernelManager.shared.kernel != nil {
        return dflashGatedDeltaKernel(q: q, k: k, v: v, g: g, beta: beta, state: state, mask: mask)
    }
    return dflashGatedDeltaOps(q: q, k: k, v: v, g: g, beta: beta, state: state, mask: mask)
}
