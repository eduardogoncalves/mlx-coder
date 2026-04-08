// Sources/TurboQuant/TQEncodedData.swift
// Ported from osaurus-ai/mlx-swift-lm (TurboQuant — arXiv:2504.19874, Google DeepMind)
// Original copyright © 2025 Osaurus & JANG. All rights reserved.

import Foundation
import MLX

// MARK: - EncodedKeys

/// TurboQuant-compressed key cache for a single attention layer.
///
/// ## Storage Layout (b-bit compression, e.g., b=3):
///
///     indicesPacked   — (b-1)-bit codebook indices packed into uint32
///     qjlPacked       — 1-bit QJL projection signs packed into uint32
///     residualNorms   — float16 per-vector residual L2 norms
///     vectorNorms     — float16 per-vector original L2 norms
///     sinkData        — float16 full-precision sink tokens (first N tokens)
///
/// ## Compression Ratio (b=3, head_dim=128)
///
/// Per vector (128 float16 = 256 bytes):
///   - 2-bit MSE indices:   128 * 2 / 8 = 32 bytes
///   - 1-bit QJL signs:     128 * 1 / 8 = 16 bytes
///   - 2 norms (f16):       4 bytes
///   Total: 52 bytes → 4.9× compression
public struct EncodedKeys: @unchecked Sendable {
    public let indicesPacked: MLXArray
    public let qjlPacked: MLXArray
    public let residualNorms: MLXArray
    public let vectorNorms: MLXArray

    /// Original compressed tensor shape [batch, heads, tokens, head_dim]
    /// (excludes sink tokens).
    public let shape: [Int]

    /// Bits per codebook index (= keyBits - 1, since 1 bit goes to QJL).
    public let indexBits: Int

    /// Random seed used during encoding. Required for correct decoding.
    public let seed: Int

    /// Full-precision sink tokens (first N tokens preserved uncompressed).
    public let sinkData: MLXArray?

    public var sinkCount: Int { sinkData?.dim(2) ?? 0 }

    public init(
        indicesPacked: MLXArray,
        qjlPacked: MLXArray,
        residualNorms: MLXArray,
        vectorNorms: MLXArray,
        shape: [Int],
        indexBits: Int,
        seed: Int = 42,
        sinkData: MLXArray? = nil
    ) {
        self.indicesPacked = indicesPacked
        self.qjlPacked = qjlPacked
        self.residualNorms = residualNorms
        self.vectorNorms = vectorNorms
        self.shape = shape
        self.indexBits = indexBits
        self.seed = seed
        self.sinkData = sinkData
    }

    public var estimatedBytes: Int {
        var total = indicesPacked.nbytes + qjlPacked.nbytes
            + residualNorms.nbytes + vectorNorms.nbytes
        if let sink = sinkData { total += sink.nbytes }
        return total
    }

    public var compressionRatio: Float {
        guard shape.count == 4 else { return 1.0 }
        let originalBytes = shape.reduce(1, *) * 2
        guard estimatedBytes > 0 else { return Float.infinity }
        return Float(originalBytes) / Float(estimatedBytes)
    }
}

// MARK: - EncodedValues

/// TurboQuant-compressed value cache for a single attention layer.
///
/// ## Simpler Than Keys
///
/// Values don't need QJL correction because attention combines them linearly
/// (no exponential amplification through softmax). All b bits go to the codebook.
///
/// ## Storage Layout:
///
///     indicesPacked   — b-bit codebook indices packed into uint32
///     vectorNorms     — float16 per-vector L2 norms
///     sinkData        — float16 full-precision sink tokens
public struct EncodedValues: @unchecked Sendable {
    public let indicesPacked: MLXArray
    public let vectorNorms: MLXArray
    public let shape: [Int]
    public let indexBits: Int
    public let seed: Int
    public let sinkData: MLXArray?

    public var sinkCount: Int { sinkData?.dim(2) ?? 0 }

    public init(
        indicesPacked: MLXArray,
        vectorNorms: MLXArray,
        shape: [Int],
        indexBits: Int,
        seed: Int = 42,
        sinkData: MLXArray? = nil
    ) {
        self.indicesPacked = indicesPacked
        self.vectorNorms = vectorNorms
        self.shape = shape
        self.indexBits = indexBits
        self.seed = seed
        self.sinkData = sinkData
    }

    public var estimatedBytes: Int {
        var total = indicesPacked.nbytes + vectorNorms.nbytes
        if let sink = sinkData { total += sink.nbytes }
        return total
    }

    public var compressionRatio: Float {
        guard shape.count == 4 else { return 1.0 }
        let originalBytes = shape.reduce(1, *) * 2
        guard estimatedBytes > 0 else { return Float.infinity }
        return Float(originalBytes) / Float(estimatedBytes)
    }
}
