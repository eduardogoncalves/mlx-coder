// Sources/TurboQuant/TQQJL.swift
// Ported from osaurus-ai/mlx-swift-lm (TurboQuant — arXiv:2504.19874, Google DeepMind)
// Original copyright © 2025 Osaurus & JANG. All rights reserved.

import Foundation
import MLX
import MLXRandom

/// Quantized Johnson-Lindenstrauss (QJL) random projection for key residual correction.
///
/// ## Why Keys Need QJL But Values Don't
///
/// Attention scores are computed as `softmax(Q * K^T / sqrt(d))`. The softmax
/// exponentiates the inner products, so a small additive error epsilon in
/// `<q, k>` becomes a multiplicative error `exp(epsilon)` in the attention weight.
///
/// Values are linearly combined: `output = softmax(...) * V`. Error in V scales
/// linearly with attention weights — no exponential amplification.
///
/// ## How QJL Works
///
/// After MSE quantization of the rotated key with (b-1) bits, the residual
/// `r = x_rotated - Q(x_rotated)` is compressed to 1 bit per dimension:
///
/// 1. Project residual through random Gaussian matrix S: `p = r @ S^T`
/// 2. Store only the signs: `s = sign(p)` — 1 bit each
/// 3. Store the residual norm: `||r||`
///
/// To decode: `r_hat = sqrt(pi/2) / d * ||r|| * (s @ S)`
public struct TQQJL: Sendable {

    // MARK: - Projection Matrix Generation

    /// Generate a random Gaussian projection matrix for QJL.
    ///
    /// Entries are i.i.d. N(0,1), generated deterministically from seed.
    /// Same seed always produces the same matrix, so encode/decode match
    /// without storing the matrix.
    ///
    /// - Parameters:
    ///   - dim: Vector dimension. Produces a dim × dim square matrix.
    ///   - seed: Random seed for deterministic generation.
    /// - Returns: MLXArray of shape [dim, dim] with float32 Gaussian entries.
    public static func generateProjection(dim: Int, seed: Int = 0) -> MLXArray {
        let rngKey = MLXRandom.key(UInt64(seed))
        return MLXRandom.normal([dim, dim], key: rngKey)
    }
}
