// Sources/TurboQuant/TQCodebook.swift
// Ported from osaurus-ai/mlx-swift-lm (TurboQuant — arXiv:2504.19874, Google DeepMind)
// Original copyright © 2025 Osaurus & JANG. All rights reserved.

import Foundation
import MLX

// MARK: - Codebook Cache

private struct CodebookKey: Hashable, Sendable {
    let dim: Int
    let bits: Int
}

private final class CodebookCache: @unchecked Sendable {
    private var cache: [CodebookKey: [Float]] = [:]
    private let lock = NSLock()

    func get(dim: Int, bits: Int) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        return cache[CodebookKey(dim: dim, bits: bits)]
    }

    func set(dim: Int, bits: Int, codebook: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        cache[CodebookKey(dim: dim, bits: bits)] = codebook
    }
}

private let sharedCodebookCache = CodebookCache()

// MARK: - TQCodebook

/// Lloyd-Max optimal scalar quantizer for TurboQuant.
///
/// After Hadamard rotation each component follows Beta((d-1)/2, (d-1)/2)
/// scaled to [-1, 1]. Lloyd-Max places codebook bins to minimize
/// E[(X - Q(X))^2] for this distribution, giving ~0.5 dB better SQNR
/// than a uniform quantizer at 3 bits.
public struct TQCodebook: Sendable {

    // MARK: - Beta PDF

    /// Evaluate the marginal density of a single component of a unit vector on S^{d-1}.
    static func betaPDF(_ x: Float, d: Int, logConst: Double) -> Float {
        let xd = Double(x)
        let safe = Swift.max(1.0 - xd * xd, 1e-30)
        return Float(Darwin.exp(logConst + (Double(d) - 3.0) / 2.0 * Darwin.log(safe)))
    }

    static func betaLogConst(d: Int) -> Double {
        let df = Double(d)
        return lgamma(df / 2.0) - 0.5 * Darwin.log(Double.pi) - lgamma((df - 1.0) / 2.0)
    }

    // MARK: - Trapezoidal Integration

    static func trapezoid(_ y: [Float], _ x: [Float]) -> Float {
        guard y.count == x.count, y.count >= 2 else { return 0 }
        var result: Float = 0
        for i in 0..<(y.count - 1) {
            result += (x[i + 1] - x[i]) * (y[i] + y[i + 1]) / 2.0
        }
        return result
    }

    // MARK: - Lloyd-Max Codebook

    /// Compute a Lloyd-Max optimal scalar codebook for the given dimension and bit width.
    ///
    /// Results are cached by (dim, bits) — repeated calls return instantly.
    ///
    /// - Parameters:
    ///   - dim: Vector dimension (determines marginal PDF shape).
    ///   - bits: Number of index bits. Codebook size = 2^bits.
    ///   - iterations: Lloyd-Max iterations (default 200).
    /// - Returns: Sorted array of 2^bits centroid values.
    public static func computeCodebook(dim: Int, bits: Int, iterations: Int = 200) -> [Float] {
        if let cached = sharedCodebookCache.get(dim: dim, bits: bits) {
            return cached
        }

        let nCodes = 1 << bits

        let nGrid = 10000
        var grid = [Float](repeating: 0, count: nGrid)
        for i in 0..<nGrid {
            grid[i] = -1.0 + 2.0 * Float(i) / Float(nGrid - 1)
        }

        let logConst = betaLogConst(d: dim)
        var pdf = grid.map { betaPDF($0, d: dim, logConst: logConst) }
        let totalMass = trapezoid(pdf, grid)
        if totalMass > 0 {
            for i in 0..<pdf.count { pdf[i] /= totalMass }
        }

        let support = 3.0 / sqrt(max(Float(dim), 1.0))
        var centroids = [Float](repeating: 0, count: nCodes)
        for i in 0..<nCodes {
            centroids[i] = -support + 2.0 * support * Float(i) / Float(max(nCodes - 1, 1))
        }

        for _ in 0..<iterations {
            var boundaries = [Float](repeating: 0, count: nCodes + 1)
            boundaries[0] = -1.0
            boundaries[nCodes] = 1.0
            for i in 0..<(nCodes - 1) {
                boundaries[i + 1] = (centroids[i] + centroids[i + 1]) / 2.0
            }

            for i in 0..<nCodes {
                let lo = boundaries[i]
                let hi = boundaries[i + 1]

                var maskedX = [Float]()
                var maskedPDF = [Float]()
                for j in 0..<nGrid {
                    if grid[j] >= lo && grid[j] < hi {
                        maskedX.append(grid[j])
                        maskedPDF.append(pdf[j])
                    }
                }

                guard maskedX.count >= 2 else { continue }
                let mass = trapezoid(maskedPDF, maskedX)
                let moment = trapezoid(
                    zip(maskedX, maskedPDF).map { $0.0 * $0.1 },
                    maskedX
                )
                centroids[i] = moment / max(mass, 1e-10)
            }
        }

        let result = centroids.sorted()
        sharedCodebookCache.set(dim: dim, bits: bits, codebook: result)
        return result
    }

    // MARK: - Scalar Quantization (MLXArray)

    /// Quantize float values to codebook indices via boundary comparison.
    public static func quantizeScalar(_ x: MLXArray, codebook: [Float]) -> MLXArray {
        var boundaries = [Float]()
        for i in 0..<(codebook.count - 1) {
            boundaries.append((codebook[i] + codebook[i + 1]) / 2.0)
        }

        var indices = MLXArray.zeros(like: x).asType(.uint8)
        for b in boundaries {
            indices = indices + (x .> MLXArray(b)).asType(.uint8)
        }
        return indices
    }

    /// Dequantize codebook indices to float values via table lookup.
    public static func dequantizeScalar(_ indices: MLXArray, codebook: [Float]) -> MLXArray {
        let codebookArray = MLXArray(codebook)
        return take(codebookArray, indices.asType(.int32))
    }
}
