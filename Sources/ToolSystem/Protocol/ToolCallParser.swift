// Sources/ToolSystem/Protocol/ToolCallParser.swift
// Parses model output to extract tool call invocations.

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

    public struct ParsedToolCall: @unchecked Sendable {
        public let name: String
        public let arguments: [String: Any]

        public init(name: String, arguments: [String: Any]) {
            self.name = name
            self.arguments = arguments
        }
    }

    public static func parse(_ text: String) -> [ParsedToolCall] {
        var results: [ParsedToolCall] = []
        var searchRange = text.startIndex..<text.endIndex

        while !searchRange.isEmpty {
            if let thinkOpen = text.range(of: ToolCallPattern.thinkOpen, range: searchRange) {
                if let toolOpen = text.range(of: ToolCallPattern.toolCallOpen, range: searchRange),
                   toolOpen.lowerBound < thinkOpen.lowerBound {
                    searchRange = parseToolCall(in: text, openRange: toolOpen, appendTo: &results)
                    continue
                }

                // Ignore any tool tags inside thinking. If think is unclosed, the
                // remainder is still thinking and must be ignored for tool execution.
                if let thinkClose = text.range(of: ToolCallPattern.thinkClose, range: thinkOpen.upperBound..<text.endIndex) {
                    searchRange = thinkClose.upperBound..<text.endIndex
                    continue
                }
                break
            }

            guard let toolOpen = text.range(of: ToolCallPattern.toolCallOpen, range: searchRange) else {
                break
            }

            searchRange = parseToolCall(in: text, openRange: toolOpen, appendTo: &results)
        }

        return results
    }

    public static func containsToolCall(_ text: String) -> Bool {
        !parse(text).isEmpty
    }

    private static func parseToolCall(
        in text: String,
        openRange: Range<String.Index>,
        appendTo results: inout [ParsedToolCall]
    ) -> Range<String.Index> {
        let closeRange = text.range(of: ToolCallPattern.toolCallClose, range: openRange.upperBound..<text.endIndex)

        let jsonString: String
        let nextSearchIndex: String.Index

        if let closeRange {
            jsonString = String(text[openRange.upperBound..<closeRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            nextSearchIndex = closeRange.upperBound
        } else {
            jsonString = String(text[openRange.upperBound..<text.endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            nextSearchIndex = text.endIndex
        }

        if let call = parseJSON(jsonString) {
            results.append(call)
        }

        return nextSearchIndex..<text.endIndex
    }

    public static func extractNonToolText(_ text: String) -> String {
        var result = text
        var searchRange = result.startIndex..<result.endIndex

        while let openRange = result.range(of: ToolCallPattern.toolCallOpen, range: searchRange),
              let closeRange = result.range(of: ToolCallPattern.toolCallClose, range: openRange.upperBound..<result.endIndex) {
            result.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
            searchRange = result.startIndex..<result.endIndex
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func stripThinking(_ text: String) -> String {
        var result = text
        while let openRange = result.range(of: ToolCallPattern.thinkOpen),
              let closeRange = result.range(of: ToolCallPattern.thinkClose, range: openRange.upperBound..<result.endIndex) {
            result.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func extractThinking(_ text: String) -> String? {
        guard let openRange = text.range(of: ToolCallPattern.thinkOpen),
              let closeRange = text.range(of: ToolCallPattern.thinkClose, range: openRange.upperBound..<text.endIndex) else {
            return nil
        }
        return String(text[openRange.upperBound..<closeRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseJSON(_ jsonString: String) -> ParsedToolCall? {
        if let call = tryParse(jsonString) {
            return call
        }

        if let call = tryParseWithFallbacks(jsonString) {
            return call
        }

        // Models frequently emit multi-line content strings using literal newlines
        // instead of JSON-escaped \n sequences, making the JSON invalid.
        // Sanitize control characters within string values and retry.
        let sanitized = sanitizeControlCharsInJSONStrings(jsonString)
        if sanitized != jsonString {
            if let call = tryParse(sanitized) {
                return call
            }
            if let call = tryParseWithFallbacks(sanitized) {
                return call
            }
        }

        return tryParseLooseToolCall(jsonString)
    }

    /// Escapes unescaped ASCII control characters (newlines, carriage returns, tabs)
    /// that appear inside JSON string values. Uses a simple state machine to track
    /// whether the current character is inside a quoted string.
    private static func sanitizeControlCharsInJSONStrings(_ json: String) -> String {
        var result = ""
        result.reserveCapacity(json.count + 32)
        var inString = false
        var escaping = false

        for char in json {
            if escaping {
                result.append(char)
                escaping = false
            } else if char == "\\" && inString {
                result.append(char)
                escaping = true
            } else if char == "\"" {
                result.append(char)
                inString = !inString
            } else if inString {
                switch char {
                case "\n": result += "\\n"
                case "\r": result += "\\r"
                case "\t": result += "\\t"
                default:
                    // Escape any other ASCII control character
                    let v = char.unicodeScalars.first!.value
                    if v < 32 {
                        result += String(format: "\\u%04x", v)
                    } else {
                        result.append(char)
                    }
                }
            } else {
                result.append(char)
            }
        }
        return result
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

    private static func tryParseWithFallbacks(_ jsonString: String) -> ParsedToolCall? {
        var fixed = jsonString

        if let extracted = extractLikelyJSONObject(fixed) {
            fixed = extracted
        }

        fixed = fixed.replacingOccurrences(of: ",\\s*([}\\]])", with: "$1", options: .regularExpression)

        guard fixed.hasPrefix("{") && fixed.hasSuffix("}") else {
            return nil
        }

        return tryParse(fixed)
    }

    private static func extractLikelyJSONObject(_ text: String) -> String? {
        guard let first = text.firstIndex(of: "{"),
              let last = text.lastIndex(of: "}"),
              first <= last else {
            return nil
        }

        return String(text[first...last]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tryParseLooseToolCall(_ jsonString: String) -> ParsedToolCall? {
        let trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)

        if let body = extractFunctionStyleBody(from: trimmed) {
            return parseLooseToolCallBody(body)
        }

        if let body = extractPseudoObjectBody(from: trimmed) {
            return parseLooseToolCallBody(body)
        }

        return nil
    }

    private static func extractFunctionStyleBody(from text: String) -> String? {
        let pattern = #"^tool_call\s*\((.*)\)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let nsText = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)),
              match.numberOfRanges >= 2 else {
            return nil
        }

        return nsText.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractPseudoObjectBody(from text: String) -> String? {
        guard text.hasPrefix("{") && text.hasSuffix("}") else {
            return nil
        }
        return String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseLooseToolCallBody(_ body: String) -> ParsedToolCall? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Do not reinterpret canonical JSON-like payloads here. If the model tried
        // to emit the standard {"name": ..., "arguments": ...} shape but broke it,
        // keep that strict path rejected so the caller can surface the error.
        if trimmed.contains("\"name\"") || trimmed.contains("\"arguments\"") {
            return nil
        }

        let positionalPattern = #"^\s*"?([A-Za-z_][A-Za-z0-9_-]*)"?\s*,\s*(.*)$"#
        var toolName: String?
        var argumentsBody = trimmed

        if let regex = try? NSRegularExpression(pattern: positionalPattern, options: []),
           let match = regex.firstMatch(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length)),
           match.numberOfRanges >= 3 {
            let candidate = (trimmed as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            let remainder = (trimmed as NSString).substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty {
                toolName = candidate
                argumentsBody = remainder
            }
        }

        let arguments = parseLooseArguments(argumentsBody)
        if toolName == nil {
            toolName = extractLooseToolName(from: arguments)
        }

        guard let toolName, !toolName.isEmpty else {
            return nil
        }

        var normalizedArguments = arguments
        normalizedArguments.removeValue(forKey: "tool")
        normalizedArguments.removeValue(forKey: "name")
        return ParsedToolCall(name: toolName, arguments: normalizedArguments)
    }

    private static func parseLooseArguments(_ text: String) -> [String: Any] {
        let pattern = #"(?:^|,)\s*"?([A-Za-z_][A-Za-z0-9_-]*)"?\s*:\s*("(?:\\.|[^"\\])*"|[^,{}\[\]]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return [:]
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var result: [String: Any] = [:]

        for match in matches where match.numberOfRanges >= 3 {
            let key = nsText.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            let rawValue = nsText.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            result[key] = looseToolCallValue(from: rawValue)
        }

        return result
    }

    private static func looseToolCallValue(from rawValue: String) -> Any {
        var value = rawValue

        if value.hasPrefix("\"") && value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }

        if value.lowercased() == "true" { return true }
        if value.lowercased() == "false" { return false }
        if value.lowercased() == "null" { return NSNull() }
        if let intValue = Int(value) { return intValue }
        if let doubleValue = Double(value) { return doubleValue }
        return value
    }

    private static func extractLooseToolName(from arguments: [String: Any]) -> String? {
        if let tool = arguments["tool"] as? String, !tool.isEmpty {
            return tool
        }
        if let name = arguments["name"] as? String, !name.isEmpty {
            return name
        }
        return nil
    }
}
