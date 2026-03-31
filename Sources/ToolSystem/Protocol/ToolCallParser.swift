// Sources/ToolSystem/Protocol/ToolCallParser.swift
// Parses model output to extract tool call invocations

import Foundation

/// Parses model-generated text to extract tool calls.
///
/// Expected format from Qwen3:
/// ```
/// <tool_call>
/// {"name": "tool_name", "arguments": {"key": "value"}}
/// </tool_call>
/// ```
public struct ToolCallParser: Sendable {

    /// A parsed tool call.
    public struct ParsedToolCall: @unchecked Sendable {
        public let name: String
        public let arguments: [String: Any]

        public init(name: String, arguments: [String: Any]) {
            self.name = name
            self.arguments = arguments
        }
    }

    /// Parse all tool calls from model output text.
    ///
    /// - Parameter text: The raw model output
    /// - Returns: Array of parsed tool calls (may be empty if none found)
    public static func parse(_ text: String) -> [ParsedToolCall] {
        var results: [ParsedToolCall] = []
        var searchRange = text.startIndex..<text.endIndex

        while let openRange = text.range(of: ToolCallPattern.toolCallOpen, range: searchRange) {
            
            let closeRange = text.range(of: ToolCallPattern.toolCallClose, range: openRange.upperBound..<text.endIndex)
            
            let jsonString: String
            let nextSearchIndex: String.Index
            
            if let closeRange = closeRange {
                jsonString = String(text[openRange.upperBound..<closeRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                nextSearchIndex = closeRange.upperBound
            } else {
                // If the closing tag is missing (e.g. cut off due to max_tokens), try to parse the remainder.
                jsonString = String(text[openRange.upperBound..<text.endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                nextSearchIndex = text.endIndex
            }

            if let call = parseJSON(jsonString) {
                results.append(call)
            }

            searchRange = nextSearchIndex..<text.endIndex
        }

        return results
    }

    /// Check if the text contains any tool calls.
    public static func containsToolCall(_ text: String) -> Bool {
        text.contains(ToolCallPattern.toolCallOpen) && text.contains(ToolCallPattern.toolCallClose)
    }

    /// Extract text outside of tool call blocks (the "normal" response).
    public static func extractNonToolText(_ text: String) -> String {
        var result = text
        var searchRange = result.startIndex..<result.endIndex

        while let openRange = result.range(of: ToolCallPattern.toolCallOpen, range: searchRange),
              let closeRange = result.range(of: ToolCallPattern.toolCallClose, range: openRange.upperBound..<result.endIndex) {
            let fullRange = openRange.lowerBound..<closeRange.upperBound
            result.removeSubrange(fullRange)
            searchRange = result.startIndex..<result.endIndex
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strip thinking blocks from text.
    public static func stripThinking(_ text: String) -> String {
        var result = text
        while let openRange = result.range(of: ToolCallPattern.thinkOpen),
              let closeRange = result.range(of: ToolCallPattern.thinkClose, range: openRange.upperBound..<result.endIndex) {
            result.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extract thinking content from text (for verbose display).
    public static func extractThinking(_ text: String) -> String? {
        guard let openRange = text.range(of: ToolCallPattern.thinkOpen),
              let closeRange = text.range(of: ToolCallPattern.thinkClose, range: openRange.upperBound..<text.endIndex) else {
            return nil
        }
        return String(text[openRange.upperBound..<closeRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private

    private static func parseJSON(_ jsonString: String) -> ParsedToolCall? {
        // Strict JSON parsing only - no fallback token insertion or quote replacement
        // This prevents malformed JSON payloads from bypassing validation.
        // LLMs are capable of generating valid JSON; accepting malformed JSON introduces security risks.
        return tryParse(jsonString)
    }

    private static func tryParse(_ jsonString: String) -> ParsedToolCall? {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String else {
            return nil
        }

        let arguments = json["arguments"] as? [String: Any] ?? [:]
        return ParsedToolCall(name: name, arguments: arguments)
    }
}
