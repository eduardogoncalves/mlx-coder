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
        // Try strict JSON parsing first
        if let call = tryParse(jsonString) {
            return call
        }

        // If strict parsing fails, attempt common fixes for LLM-generated JSON
        return tryParseWithFallbacks(jsonString)
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

    // MARK: - Fallback JSON parsing for malformed LLM output

    private static func tryParseWithFallbacks(_ jsonString: String) -> ParsedToolCall? {
        var fixed = jsonString

        // Fix 1: Remove trailing commas before } or ]
        fixed = fixed.replacingOccurrences(of: ",\\s*([}\\]])", with: "$1", options: .regularExpression)

        // Fix 2: Add missing closing brace if JSON starts with { but doesn't end with }
        if fixed.hasPrefix("{") && !fixed.hasSuffix("}") {
            fixed += "}"
        }

        // Fix 3: Fix unescaped quotes inside string values by finding the "arguments" block
        // and ensuring proper JSON structure
        if let name = extractName(fixed) {
            let args = extractArguments(fixed)
            return ParsedToolCall(name: name, arguments: args)
        }

        // Fix 4: Try wrapping in braces if missing
        if !fixed.hasPrefix("{") {
            fixed = "{" + fixed
        }
        if !fixed.hasSuffix("}") {
            fixed += "}"
        }

        if let data = fixed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = json["name"] as? String {
            let arguments = json["arguments"] as? [String: Any] ?? [:]
            return ParsedToolCall(name: name, arguments: arguments)
        }

        return nil
    }

    private static func extractName(_ json: String) -> String? {
        let pattern = "\"name\"\\s*:\\s*\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(json.startIndex..., in: json)
        guard let match = regex.firstMatch(in: json, range: range),
              let nameRange = Range(match.range(at: 1), in: json) else { return nil }
        return String(json[nameRange])
    }

    private static func extractArguments(_ json: String) -> [String: Any] {
        // Find the arguments block and try to parse it
        let pattern = "\"arguments\"\\s*:\\s*(\\{.*\\})"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else { return [:] }
        let range = NSRange(json.startIndex..., in: json)
        guard let match = regex.firstMatch(in: json, range: range),
              let argsRange = Range(match.range(at: 1), in: json) else { return [:] }

        let argsString = String(json[argsRange])
        if let data = argsString.data(using: .utf8),
           let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return args
        }

        // Fallback: extract individual key-value pairs
        var result: [String: Any] = [:]
        let kvPattern = "\"([^\"]+)\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\""
        guard let kvRegex = try? NSRegularExpression(pattern: kvPattern) else { return result }
        let argsRangeFull = NSRange(argsString.startIndex..., in: argsString)
        let matches = kvRegex.matches(in: argsString, range: argsRangeFull)
        for match in matches {
            if let keyRange = Range(match.range(at: 1), in: argsString),
               let valRange = Range(match.range(at: 2), in: argsString) {
                let key = String(argsString[keyRange])
                var val = String(argsString[valRange])
                // Unescape common sequences
                val = val.replacingOccurrences(of: "\\n", with: "\n")
                val = val.replacingOccurrences(of: "\\t", with: "\t")
                val = val.replacingOccurrences(of: "\\\"", with: "\"")
                val = val.replacingOccurrences(of: "\\\\", with: "\\")
                result[key] = val
            }
        }

        return result
    }
}
