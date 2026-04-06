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
        /// Bits for KV cache quantization. Supports integer (4, 8) and fractional
        /// values (2.5, 3.5); fractional widths automatically select TurboQuant.
        public let kvBits: Float?
        public let kvGroupSize: Int
        /// Explicit quantization scheme. `.turboQuant` forces TurboQuant even for
        /// integer bit widths; `.uniform` uses standard uniform quantization.
        public let kvQuantizationScheme: KVQuantizationScheme
        public let quantizedKVStart: Int
        public let longContextThreshold: Int

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
            kvBits: Float? = nil,
            kvGroupSize: Int = 64,
            kvQuantizationScheme: KVQuantizationScheme = .uniform,
            quantizedKVStart: Int = 0,
            longContextThreshold: Int = 8192
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
            self.kvQuantizationScheme = kvQuantizationScheme
            self.quantizedKVStart = quantizedKVStart
            self.longContextThreshold = longContextThreshold
        }

        /// Convert to MLXLMCommon's GenerateParameters
        public var generateParameters: GenerateParameters {
            GenerateParameters(
                maxTokens: maxTokens,
                kvBits: kvBits,
                kvGroupSize: kvGroupSize,
                kvQuantizationScheme: kvQuantizationScheme,
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
