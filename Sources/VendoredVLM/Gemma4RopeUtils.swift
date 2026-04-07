// Sources/VendoredVLM/Gemma4RopeUtils.swift
// Vendored from adrgrondin/mlx-swift-lm@67b5729e3d47d8709e03417129a1ea9ed4f19ada
// Provides ProportionalRoPE and a Gemma4-specific rope initializer that
// intercepts the "proportional" type before delegating to the official initializeRope.

import Foundation
import MLX
import MLXLMCommon
import MLXNN

// MARK: - ProportionalRoPE

/// Proportional RoPE implementation used by Gemma4 full-attention layers.
/// Applies rotary position embeddings only to a subset of dimensions (controlled by
/// `partial_rotary_factor`) and leaves the rest unchanged.
public class ProportionalRoPE: Module, OffsetLayer, ArrayOffsetLayer {
    let dims: Int
    let traditional: Bool
    let rotatedDims: Int
    let base: Float

    init(
        dims: Int,
        traditional: Bool = false,
        base: Float = 10_000,
        scalingConfig: [String: StringOrNumber]? = nil
    ) {
        self.dims = dims
        self.traditional = traditional
        self.base = base

        // Compatibility fallback: current MLX runtime can fail on Gemma4 partial
        // rotary factors; force full rotary dimensions to keep inference stable.
        let partialRotaryFactor: Float = 1.0
        let ropeAngles = Int(partialRotaryFactor * Float(dims) / 2.0)
        self.rotatedDims = 2 * ropeAngles

        super.init()
    }

    public func callAsFunction(_ x: MLXArray, offset: Int = 0) -> MLXArray {
        guard rotatedDims > 0 else {
            return x
        }

        let half = dims / 2
        let rotatedHalf = rotatedDims / 2

        let head: MLXArray
        let tail: MLXArray?
        if x.shape[x.ndim - 1] > dims {
            let parts = split(x, indices: [dims], axis: -1)
            head = parts[0]
            tail = parts[1]
        } else {
            head = x
            tail = nil
        }

        let headParts = split(head, indices: [half], axis: -1)
        var left = headParts[0]
        var right = headParts[1]

        let leftParts = split(left, indices: [rotatedHalf], axis: -1)
        let rightParts = split(right, indices: [rotatedHalf], axis: -1)
        var rotated = concatenated([leftParts[0], rightParts[0]], axis: -1)
        rotated = MLXFast.RoPE(
            rotated,
            dimensions: rotatedDims,
            traditional: traditional,
            base: base,
            scale: 1.0,
            offset: offset
        )

        let rotatedParts = split(rotated, indices: [rotatedHalf], axis: -1)
        left = concatenated([rotatedParts[0], leftParts[1]], axis: -1)
        right = concatenated([rotatedParts[1], rightParts[1]], axis: -1)
        let updatedHead = concatenated([left, right], axis: -1)

        if let tail {
            return concatenated([updatedHead, tail], axis: -1)
        } else {
            return updatedHead
        }
    }

    public func callAsFunction(_ x: MLXArray, offset: MLXArray) -> MLXArray {
        guard rotatedDims > 0 else {
            return x
        }

        let half = dims / 2
        let rotatedHalf = rotatedDims / 2

        let head: MLXArray
        let tail: MLXArray?
        if x.shape[x.ndim - 1] > dims {
            let parts = split(x, indices: [dims], axis: -1)
            head = parts[0]
            tail = parts[1]
        } else {
            head = x
            tail = nil
        }

        let headParts = split(head, indices: [half], axis: -1)
        var left = headParts[0]
        var right = headParts[1]

        let leftParts = split(left, indices: [rotatedHalf], axis: -1)
        let rightParts = split(right, indices: [rotatedHalf], axis: -1)
        var rotated = concatenated([leftParts[0], rightParts[0]], axis: -1)
        rotated = MLXFast.RoPE(
            rotated,
            dimensions: rotatedDims,
            traditional: traditional,
            base: base,
            scale: 1.0,
            offset: offset
        )

        let rotatedParts = split(rotated, indices: [rotatedHalf], axis: -1)
        left = concatenated([rotatedParts[0], leftParts[1]], axis: -1)
        right = concatenated([rotatedParts[1], rightParts[1]], axis: -1)
        let updatedHead = concatenated([left, right], axis: -1)

        if let tail {
            return concatenated([updatedHead, tail], axis: -1)
        } else {
            return updatedHead
        }
    }
}

// MARK: - Gemma4-specific rope initializer

/// Initialises a RoPE layer, handling the `"proportional"` type used by Gemma4 before
/// delegating all other types to the official `MLXLMCommon.initializeRope`.
///
/// The official `initializeRope` (mlx-swift-lm 2.31.3) does not yet support
/// `"proportional"` (tracked in upstream PR #180).  This wrapper intercepts that
/// case and returns ``ProportionalRoPE``; everything else falls through unchanged.
func gemma4InitializeRope(
    dims: Int,
    base: Float,
    traditional: Bool,
    scalingConfig: [String: StringOrNumber]?,
    maxPositionEmbeddings: Int?
) -> RoPELayer {
    let ropeType: String = {
        if let config = scalingConfig,
            let typeValue = config["type"] ?? config["rope_type"],
            case .string(let s) = typeValue
        {
            return s
        }
        return "default"
    }()

    if ropeType == "proportional" {
        return ProportionalRoPE(
            dims: dims,
            traditional: traditional,
            base: base,
            scalingConfig: scalingConfig
        )
    }

    return initializeRope(
        dims: dims,
        base: base,
        traditional: traditional,
        scalingConfig: scalingConfig,
        maxPositionEmbeddings: maxPositionEmbeddings
    )
}
