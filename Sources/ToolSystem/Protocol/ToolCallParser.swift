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

        /// Set when the parser detected that the source text for this call was
        /// structurally incomplete — e.g. a quoted argument value, a Python
        /// dict/list literal, or the argument list itself was cut off before a
        /// closing delimiter appeared. This is distinct from `arguments` being
        /// merely empty or from the call being unparsable entirely (which
        /// yields no `ParsedToolCall` at all); it flags a call that *looks*
        /// complete but may carry a truncated value.
        ///
        /// Only the LFM2 "Pythonic" dialect (`LFM2ToolCallBodyParser`) sets
        /// this to `true` today — it deliberately tolerates missing closing
        /// brackets/parens/quotes for robustness, so this flag is how it still
        /// surfaces that tolerance was exercised. The qwen and glm4 paths
        /// leave it at its default `false`, since a truncated JSON/XML body
        /// for those dialects already fails to produce a `ParsedToolCall` in
        /// the first place (see `tryParseWithTrailingBraceRecovery`, etc.),
        /// so there is no analogous "looks complete but isn't" case to flag.
        ///
        /// Callers that want truncation-aware retry/steering behavior (e.g.
        /// treating a truncated call the same as a malformed one instead of
        /// silently executing it) should check this flag per-call rather than
        /// relying solely on `toolCalls.isEmpty`.
        public let wasTruncated: Bool

        public init(name: String, arguments: [String: Any], wasTruncated: Bool = false) {
            self.name = name
            self.arguments = arguments
            self.wasTruncated = wasTruncated
        }
    }

    public static func parse(
        _ text: String,
        dialect: ToolCallDialect = .qwen,
        startsThinking: Bool = false
    ) -> [ParsedToolCall] {
        var results: [ParsedToolCall] = []
        var searchRange = text.startIndex..<text.endIndex
        let toolOpenToken = dialect.toolCallOpen
        let toolCloseToken = dialect.toolCallClose

        // Chat templates that pre-fill "<think>\n" leave the response without an
        // explicit opening tag. Without this skip, tool_call tags emitted before
        // the model closes </think> would be executed as real tool calls.
        if startsThinking {
            guard let thinkClose = text.range(of: ToolCallPattern.thinkClose) else {
                return []
            }
            searchRange = thinkClose.upperBound..<text.endIndex
        }

        while !searchRange.isEmpty {
            if let thinkOpen = text.range(of: ToolCallPattern.thinkOpen, range: searchRange) {
                if let toolOpen = text.range(of: toolOpenToken, range: searchRange),
                   toolOpen.lowerBound < thinkOpen.lowerBound {
                    searchRange = parseToolCall(
                        in: text,
                        openRange: toolOpen,
                        closeToken: toolCloseToken,
                        dialect: dialect,
                        appendTo: &results
                    )
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

            guard let toolOpen = text.range(of: toolOpenToken, range: searchRange) else {
                break
            }

            searchRange = parseToolCall(
                in: text,
                openRange: toolOpen,
                closeToken: toolCloseToken,
                dialect: dialect,
                appendTo: &results
            )
        }

        return results
    }

    /// Returns true if `text` contains a `<tool_call>` tag outside any think block.
    /// Used to detect malformed tool call attempts that need re-prompting.
    /// Tool call tags that appear inside `<think>…</think>` (or an unclosed think block)
    /// are suppressed, matching the behaviour of `parse(_:)`.
    public static func containsToolCall(
        _ text: String,
        dialect: ToolCallDialect = .qwen,
        startsThinking: Bool = false
    ) -> Bool {
        var searchRange = text.startIndex..<text.endIndex
        let toolOpenToken = dialect.toolCallOpen

        if startsThinking {
            guard let thinkClose = text.range(of: ToolCallPattern.thinkClose) else {
                return false
            }
            searchRange = thinkClose.upperBound..<text.endIndex
        }

        while !searchRange.isEmpty {
            if let thinkOpen = text.range(of: ToolCallPattern.thinkOpen, range: searchRange) {
                // A tool call that starts before the think block counts.
                if let toolOpen = text.range(of: toolOpenToken, range: searchRange),
                   toolOpen.lowerBound < thinkOpen.lowerBound {
                    return true
                }
                // Skip the closed think block.
                if let thinkClose = text.range(of: ToolCallPattern.thinkClose,
                                               range: thinkOpen.upperBound..<text.endIndex) {
                    searchRange = thinkClose.upperBound..<text.endIndex
                    continue
                }
                // Unclosed think block — all remaining text is still thinking.
                return false
            }
            // No think block — any tool call tag counts.
            return text.range(of: toolOpenToken, range: searchRange) != nil
        }
        return false
    }

    private static func parseToolCall(
        in text: String,
        openRange: Range<String.Index>,
        closeToken: String,
        dialect: ToolCallDialect,
        appendTo results: inout [ParsedToolCall]
    ) -> Range<String.Index> {
        let closeRange = text.range(of: closeToken, range: openRange.upperBound..<text.endIndex)

        let bodyString: String
        let nextSearchIndex: String.Index

        if let closeRange {
            bodyString = String(text[openRange.upperBound..<closeRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            nextSearchIndex = closeRange.upperBound
        } else {
            // No closing tag — check if another opening tag follows immediately (model emitted
            // multiple calls without closing tags). Use the next open tag as an implicit
            // boundary so all calls in the response are parsed rather than lumped together.
            let openToken = dialect.toolCallOpen
            let nextOpenRange = text.range(of: openToken, range: openRange.upperBound..<text.endIndex)
            if let nextOpenRange {
                bodyString = String(text[openRange.upperBound..<nextOpenRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                nextSearchIndex = nextOpenRange.lowerBound
            } else {
                bodyString = String(text[openRange.upperBound..<text.endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                nextSearchIndex = text.endIndex
            }
        }

        switch dialect {
        case .qwen:
            if let call = parseJSON(bodyString) {
                results.append(call)
            }
        case .lfm2:
            results.append(contentsOf: LFM2ToolCallBodyParser.parse(bodyString))
        case .glm4:
            if let call = parseGLM4Body(bodyString) {
                results.append(call)
            }
        }

        return nextSearchIndex..<text.endIndex
    }

    public static func extractNonToolText(_ text: String, dialect: ToolCallDialect = .qwen) -> String {
        var result = text
        var searchRange = result.startIndex..<result.endIndex
        let openToken = dialect.toolCallOpen
        let closeToken = dialect.toolCallClose

        while let openRange = result.range(of: openToken, range: searchRange),
              let closeRange = result.range(of: closeToken, range: openRange.upperBound..<result.endIndex) {
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

    /// Parses GLM4's native XML format: `name<arg_key>k</arg_key><arg_value>v</arg_value>…`
    private static func parseGLM4Body(_ body: String) -> ParsedToolCall? {
        let argKeyOpen  = "<arg_key>"
        let argKeyClose = "</arg_key>"
        let argValOpen  = "<arg_value>"
        let argValClose = "</arg_value>"

        // Tool name is everything before the first <arg_key> (or the whole body if no args).
        let toolName: String
        var rest: Substring
        if let firstKey = body.range(of: argKeyOpen) {
            toolName = String(body[body.startIndex..<firstKey.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            rest = body[firstKey.lowerBound...]
        } else {
            // No arguments — bare tool name.
            toolName = body.trimmingCharacters(in: .whitespacesAndNewlines)
            rest = ""
        }

        guard !toolName.isEmpty else { return nil }

        var arguments: [String: Any] = [:]
        var searchStr = String(rest)

        while let keyOpen = searchStr.range(of: argKeyOpen),
              let keyClose = searchStr.range(of: argKeyClose, range: keyOpen.upperBound..<searchStr.endIndex),
              let valOpen  = searchStr.range(of: argValOpen,  range: keyClose.upperBound..<searchStr.endIndex),
              let valClose = searchStr.range(of: argValClose, range: valOpen.upperBound..<searchStr.endIndex) {
            let key   = String(searchStr[keyOpen.upperBound..<keyClose.lowerBound])
            let value = String(searchStr[valOpen.upperBound..<valClose.lowerBound])
            arguments[key] = looseToolCallValue(from: value)
            searchStr = String(searchStr[valClose.upperBound...])
        }

        return ParsedToolCall(name: toolName, arguments: arguments)
    }

    private static func parseJSON(_ jsonString: String) -> ParsedToolCall? {
        if let call = tryParse(jsonString) {
            return call
        }

        if let call = tryParseWithFallbacks(jsonString) {
            return call
        }

        // Recover a common truncation: canonical tool-call JSON missing only
        // trailing closing brace(s), e.g. {"name":...,"arguments":{...}
        if let call = tryParseWithTrailingBraceRecovery(jsonString) {
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
            if let call = tryParseWithTrailingBraceRecovery(sanitized) {
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
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // Some models (observed on smaller/quantized local checkpoints) emit
        // `"tool_name"` instead of the documented `"name"` key — otherwise a
        // correctly-structured call gets rejected as malformed, and the
        // generic "re-emit in the exact format" steering message doesn't
        // pinpoint the actual mistake, so the model tends to thrash between
        // wrong shapes instead of converging.
        guard let name = (json["name"] as? String) ?? (json["tool_name"] as? String), !name.isEmpty else {
            return nil
        }

        let arguments = json["arguments"] as? [String: Any] ?? [:]

        // Recover a "double-wrapped" call: some smaller/quantized checkpoints emit
        // the entire intended tool call as a JSON *string* in the name field, e.g.
        //   {"name": "{\"name\":\"todo\",\"arguments\":{...}}", "arguments": {}}
        // Left as-is this dispatches with the raw JSON as the tool name and fails
        // with "Unknown tool: {…json…}"; the model then sees the error and keeps
        // re-wrapping instead of converging. Unwrap the inner call so it reaches a
        // real tool. Recursion terminates once the inner name is a plain identifier.
        if looksLikeJSONObject(name), let nested = tryParse(name) {
            // Prefer the inner arguments; fall back to the outer ones only when the
            // inner call carried none.
            if nested.arguments.isEmpty && !arguments.isEmpty {
                return ParsedToolCall(name: nested.name, arguments: arguments)
            }
            return nested
        }

        return ParsedToolCall(name: name, arguments: arguments)
    }

    /// True when `text` looks like a JSON object literal (a wrapped tool call
    /// smuggled into a string field), not a plain tool-name identifier.
    private static func looksLikeJSONObject(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{") && trimmed.hasSuffix("}")
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

    private static func tryParseWithTrailingBraceRecovery(_ jsonString: String) -> ParsedToolCall? {
        let trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("\"name\"") && trimmed.contains("\"arguments\"") else {
            return nil
        }

        guard let repaired = appendMissingTrailingBracesIfSafe(trimmed), repaired != trimmed else {
            return nil
        }

        if let call = tryParse(repaired) {
            return call
        }
        return tryParseWithFallbacks(repaired)
    }

    private static func appendMissingTrailingBracesIfSafe(_ text: String) -> String? {
        guard text.hasPrefix("{") else { return nil }

        var openBraces = 0
        var closeBraces = 0
        var inString = false
        var escaping = false

        for char in text {
            if escaping {
                escaping = false
                continue
            }

            if char == "\\" && inString {
                escaping = true
                continue
            }

            if char == "\"" {
                inString.toggle()
                continue
            }

            guard !inString else { continue }

            if char == "{" {
                openBraces += 1
            } else if char == "}" {
                closeBraces += 1
                if closeBraces > openBraces {
                    return nil
                }
            }
        }

        // If parsing ended inside a quoted string or escape sequence,
        // the payload is too malformed for structural recovery.
        guard !inString && !escaping else { return nil }

        let missing = openBraces - closeBraces
        guard missing > 0 && missing <= 2 else { return nil }

        return text + String(repeating: "}", count: missing)
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
