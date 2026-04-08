// Sources/TurboQuant/TQBitPack.swift
// Ported from osaurus-ai/mlx-swift-lm (TurboQuant — arXiv:2504.19874, Google DeepMind)
// Original copyright © 2025 Osaurus & JANG. All rights reserved.

import Foundation
import MLX

/// Bit-level packing/unpacking for TurboQuant indices and signs.
///
/// ## Packing Layout
///
/// **Index packing** (for codebook indices, 1-8 bits each):
///
///     uint32 word:  [val_0 | val_1 | val_2 | ... | val_{n-1} | padding]
///
/// For 3-bit indices: 10 values per uint32 (30 bits used, 2 wasted).
/// For 4-bit indices: 8 values per uint32 (32 bits, no waste).
///
/// **Sign packing** (for QJL signs, 1 bit each):
///
///     uint32 word:  [sign_0 | sign_1 | ... | sign_31]
///
/// 32 signs per uint32, zero waste.
public struct TQBitPack: Sendable {

    // MARK: - Index Packing

    /// Pack low-bit index values into uint32 words.
    ///
    /// Values are packed little-endian: value 0 in the lowest bits.
    /// Input is flattened and zero-padded to a multiple of `32/bits`.
    public static func packBits(_ values: MLXArray, bits: Int) -> MLXArray {
        let valsPerU32 = 32 / bits
        var flat = values.reshaped([-1]).asType(.uint32)
        let count = flat.dim(0)

        let pad = (valsPerU32 - (count % valsPerU32)) % valsPerU32
        if pad > 0 {
            flat = concatenated([flat, MLXArray.zeros([pad]).asType(.uint32)], axis: 0)
        }

        let numWords = flat.dim(0) / valsPerU32
        flat = flat.reshaped([numWords, valsPerU32])

        var packed = MLXArray.zeros([numWords]).asType(.uint32)
        for i in 0..<valsPerU32 {
            packed = packed | (flat[0..., i] << MLXArray(UInt32(i * bits)))
        }
        return packed
    }

    // MARK: - Index Unpacking

    /// Unpack uint32 words back to individual low-bit index values.
    public static func unpackBits(_ packed: MLXArray, bits: Int, nElements: Int) -> MLXArray {
        let valsPerU32 = 32 / bits
        let mask = MLXArray(UInt32((1 << bits) - 1))

        var columns = [MLXArray]()
        for i in 0..<valsPerU32 {
            columns.append(((packed >> MLXArray(UInt32(i * bits))) & mask).asType(.uint8))
        }

        let stacked = MLX.stacked(columns, axis: -1).reshaped([-1])
        return stacked[..<nElements]
    }

    // MARK: - Sign Packing

    /// Pack float sign values (+1/-1) into uint32 bitmasks. 32 signs per word.
    ///
    /// Mapping: +1.0 → bit 1, -1.0 → bit 0.
    public static func packSigns(_ signs: MLXArray) -> MLXArray {
        var bits = ((signs.reshaped([-1]) + MLXArray(Float(1.0))) / MLXArray(Float(2.0)))
            .asType(.uint32)
        let count = bits.dim(0)

        let pad = (32 - (count % 32)) % 32
        if pad > 0 {
            bits = concatenated([bits, MLXArray.zeros([pad]).asType(.uint32)], axis: 0)
        }

        let numWords = bits.dim(0) / 32
        bits = bits.reshaped([numWords, 32])

        var packed = MLXArray.zeros([numWords]).asType(.uint32)
        for i in 0..<32 {
            packed = packed | (bits[0..., i] << MLXArray(UInt32(i)))
        }
        return packed
    }

    // MARK: - Sign Unpacking

    /// Unpack uint32 bitmasks back to float signs (+1/-1).
    public static func unpackSigns(_ packed: MLXArray, nElements: Int) -> MLXArray {
        var columns = [MLXArray]()
        for i in 0..<32 {
            columns.append(((packed >> MLXArray(UInt32(i))) & MLXArray(UInt32(1))).asType(.float32))
        }

        let flat = MLX.stacked(columns, axis: -1).reshaped([-1])
        return flat[..<nElements] * MLXArray(Float(2.0)) - MLXArray(Float(1.0))
    }
}
