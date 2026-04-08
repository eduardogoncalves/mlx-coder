// Sources/ModelEngine/GenerationEngine.swift
// Streaming token generation using MLXLMCommon

import Foundation
import MLX
import MLXLMCommon

/// Handles streaming text generation from a loaded model.
public struct GenerationEngine: Sendable {

    /// Configuration for text generation.
    public struct Config: Sendable {
        public let maxTokens: Int
        public let temperature: Float
        public let topP: Float
        public let topK: Int
        public let minP: Float
        public let repetitionPenalty: Float?
        public let repetitionContextSize: Int
        public let presencePenalty: Float?
        public let presenceContextSize: Int
        public let frequencyPenalty: Float?
        public let frequencyContextSize: Int
        public let kvBits: Int?
        public let kvGroupSize: Int
        public let quantizedKVStart: Int
        public let longContextThreshold: Int
        /// When non-nil, enables TurboQuant KV cache compression.
        /// Specifies the bit width per element (e.g., 3 means 2-bit codebook + 1-bit QJL for
        /// keys; 3-bit codebook for values). Requires at least 32 prefill tokens before
        /// compression kicks in. Incompatible with standard `kvBits` quantization.
        public let turboQuantBits: Int?

        public init(
            maxTokens: Int = 4096,
            temperature: Float = 0.6,
            topP: Float = 1.0,
            topK: Int = 0,
            minP: Float = 0.0,
            repetitionPenalty: Float? = nil,
            repetitionContextSize: Int = 20,
            presencePenalty: Float? = nil,
            presenceContextSize: Int = 20,
            frequencyPenalty: Float? = nil,
            frequencyContextSize: Int = 20,
            kvBits: Int? = nil,
            kvGroupSize: Int = 64,
            quantizedKVStart: Int = 0,
            longContextThreshold: Int = 8192,
            turboQuantBits: Int? = nil
        ) {
            self.maxTokens = maxTokens
            self.temperature = temperature
            self.topP = topP
            self.topK = topK
            self.minP = minP
            self.repetitionPenalty = repetitionPenalty
            self.repetitionContextSize = repetitionContextSize
            self.presencePenalty = presencePenalty
            self.presenceContextSize = presenceContextSize
            self.frequencyPenalty = frequencyPenalty
            self.frequencyContextSize = frequencyContextSize
            self.kvBits = kvBits
            self.kvGroupSize = kvGroupSize
            self.quantizedKVStart = quantizedKVStart
            self.longContextThreshold = longContextThreshold
            self.turboQuantBits = turboQuantBits
        }

        /// Convert to MLXLMCommon's GenerateParameters
        public var generateParameters: GenerateParameters {
            GenerateParameters(
                maxTokens: maxTokens,
                kvBits: kvBits,
                kvGroupSize: kvGroupSize,
                quantizedKVStart: quantizedKVStart,
                temperature: temperature,
                topP: topP,
                topK: topK,
                minP: minP,
                repetitionPenalty: repetitionPenalty,
                repetitionContextSize: repetitionContextSize,
                presencePenalty: presencePenalty,
                presenceContextSize: presenceContextSize,
                frequencyPenalty: frequencyPenalty,
                frequencyContextSize: frequencyContextSize
            )
        }
    }

    /// The result of a generation call.
    public enum GenerationItem: Sendable {
        case text(String)
        case toolCall
        case completed(GenerateCompletionInfo)
    }

}
