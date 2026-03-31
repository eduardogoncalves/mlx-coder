// Sources/ModelEngine/TokenizerWrapper.swift
// Thin wrapper around the model tokenizer for encoding/decoding

import Foundation
import MLXLMCommon

/// Provides convenient access to the model's tokenizer.
public struct TokenizerWrapper: Sendable {

    /// Check if a token ID is an end-of-sequence token.
    public static func isEOS(_ tokenId: Int, eosTokenIds: Set<Int>) -> Bool {
        eosTokenIds.contains(tokenId)
    }
}
