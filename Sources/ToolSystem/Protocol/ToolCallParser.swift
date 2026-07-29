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

    /// True when the text contains a `<tool_call>` whose body is valid JSON with
    /// an `arguments` object but no usable `name`/`tool_name`. This is a
    /// *recoverable* mistake — the model emitted the arguments but forgot the
    /// tool name (observed repeatedly on small quantized checkpoints as
    /// `{"arguments":{"path":"..."}}`) — and it cannot be routed, so the parser
    /// correctly drops it. The value of detecting it is a targeted steer ("add
    /// the missing name field") instead of the generic "malformed, re-emit"
    /// reminder, which tends to make the model thrash between wrong shapes.
    public static func containsNamelessToolCall(
        _ text: String,
        dialect: ToolCallDialect = .qwen,
        startsThinking: Bool = false
    ) -> Bool {
        guard dialect == .qwen else { return false }
        for body in qwenToolCallBodies(in: text, dialect: dialect, startsThinking: startsThinking) {
            guard let json = lenientToolCallObject(from: body) else { continue }
            let hasName = ((json["name"] as? String)?.isEmpty == false)
                || ((json["tool_name"] as? String)?.isEmpty == false)
            let hasArguments = json["arguments"] is [String: Any]
            if hasArguments && !hasName {
                return true
            }
        }
        return false
    }

    /// Best-effort parse of a `<tool_call>` body into a JSON object, tolerating
    /// the two malformations small quantized checkpoints emit around otherwise
    /// recoverable calls: a trailing junk tag after the object (e.g. a stray
    /// `</arguments>` in place of `</tool_call>`) and one or two missing trailing
    /// braces (the model stops generating before closing `arguments`/the
    /// envelope, observed as `{"arguments":{"description":…,"profile":…}`). Strict
    /// `JSONSerialization` is tried first; only if that fails do we strip junk
    /// (`extractLikelyJSONObject`) and balance braces (`appendMissingTrailing‑
    /// BracesIfSafe`) — the same repairs the main parse path already applies via
    /// `tryParseWithFallbacks`/`tryParseWithTrailingBraceRecovery`, so the
    /// nameless-detection gate is no stricter than dispatch itself. Returns nil
    /// when the body can't be salvaged into an object.
    private static func lenientToolCallObject(from body: String) -> [String: Any]? {
        func object(_ string: String) -> [String: Any]? {
            guard let data = string.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return json
        }
        if let json = object(body) { return json }
        let candidate = extractLikelyJSONObject(body) ?? body
        if let json = object(candidate) { return json }
        if let repaired = appendMissingTrailingBracesIfSafe(candidate) {
            return object(repaired)
        }
        return nil
    }

    /// Returns the `arguments` object of each `<tool_call>` whose body carries an
    /// `arguments` dict but no usable `name`/`tool_name` — the same recoverable
    /// shape `containsNamelessToolCall` flags, but exposing the arguments so a
    /// caller holding the tool registry can *infer* the intended tool from the
    /// argument keys and execute the call instead of merely re-steering (which,
    /// on small quantized checkpoints, tends to loop until the turn budget is
    /// exhausted — the model emits `{"arguments":{"description":…,"profile":…}}`
    /// over and over without ever adding the name).
    ///
    /// The body is parsed via `lenientToolCallObject`, which tolerates a trailing
    /// junk tag and one or two missing trailing braces — the same shapes the main
    /// parse path recovers — so this stays in lock-step with
    /// `containsNamelessToolCall`. Shapes that `tryParse` already recovers on its
    /// own — a name nested *inside* `arguments` — are skipped here. Only the
    /// qwen/JSON dialect is inspected.
    public static func namelessToolCallArguments(
        _ text: String,
        dialect: ToolCallDialect = .qwen,
        startsThinking: Bool = false
    ) -> [[String: Any]] {
        guard dialect == .qwen else { return [] }
        var results: [[String: Any]] = []
        for body in qwenToolCallBodies(in: text, dialect: dialect, startsThinking: startsThinking) {
            guard let json = lenientToolCallObject(from: body) else { continue }
            let hasName = ((json["name"] as? String)?.isEmpty == false)
                || ((json["tool_name"] as? String)?.isEmpty == false)
            guard !hasName, let args = json["arguments"] as? [String: Any], !args.isEmpty else {
                continue
            }
            // A name nested inside `arguments` is already recovered by tryParse
            // (Shape A/B). Don't double-handle it here.
            let hasNestedName = ((args["name"] as? String)?.isEmpty == false)
                || ((args["tool_name"] as? String)?.isEmpty == false)
            guard !hasNestedName else { continue }
            results.append(args)
        }
        return results
    }

    /// Extracts the raw body string of each `<tool_call>` region outside any
    /// think block, using the same open/close (and implicit next-open) boundary
    /// logic as `parse`. Used by `containsNamelessToolCall` to inspect bodies
    /// without committing to a full parse.
    private static func qwenToolCallBodies(
        in text: String,
        dialect: ToolCallDialect,
        startsThinking: Bool
    ) -> [String] {
        var bodies: [String] = []
        var searchRange = text.startIndex..<text.endIndex
        let openToken = dialect.toolCallOpen
        let closeToken = dialect.toolCallClose

        if startsThinking {
            guard let thinkClose = text.range(of: ToolCallPattern.thinkClose) else { return [] }
            searchRange = thinkClose.upperBound..<text.endIndex
        }

        while !searchRange.isEmpty {
            if let thinkOpen = text.range(of: ToolCallPattern.thinkOpen, range: searchRange),
               let toolOpen = text.range(of: openToken, range: searchRange),
               thinkOpen.lowerBound <= toolOpen.lowerBound {
                // Tool tag is inside/after a think block — skip the closed think
                // region (or stop if it never closes).
                if let thinkClose = text.range(of: ToolCallPattern.thinkClose, range: thinkOpen.upperBound..<text.endIndex) {
                    searchRange = thinkClose.upperBound..<text.endIndex
                    continue
                }
                break
            }

            guard let toolOpen = text.range(of: openToken, range: searchRange) else { break }

            let closeRange = text.range(of: closeToken, range: toolOpen.upperBound..<text.endIndex)
            let nextOpen = text.range(of: openToken, range: toolOpen.upperBound..<text.endIndex)

            // Same implicit-boundary rule as parseToolCall: an unclosed call whose
            // next sibling opens before any close must not swallow that sibling.
            if let nextOpen, closeRange == nil || nextOpen.lowerBound < closeRange!.lowerBound {
                bodies.append(String(text[toolOpen.upperBound..<nextOpen.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines))
                searchRange = nextOpen.lowerBound..<text.endIndex
            } else if let closeRange {
                bodies.append(String(text[toolOpen.upperBound..<closeRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines))
                searchRange = closeRange.upperBound..<text.endIndex
            } else {
                bodies.append(String(text[toolOpen.upperBound..<text.endIndex]).trimmingCharacters(in: .whitespacesAndNewlines))
                break
            }
        }

        return bodies
    }

    private static func parseToolCall(
        in text: String,
        openRange: Range<String.Index>,
        closeToken: String,
        dialect: ToolCallDialect,
        appendTo results: inout [ParsedToolCall]
    ) -> Range<String.Index> {
        let closeRange = text.range(of: closeToken, range: openRange.upperBound..<text.endIndex)
        let nextOpenRange = text.range(of: dialect.toolCallOpen, range: openRange.upperBound..<text.endIndex)

        let bodyEnd: String.Index
        let nextSearchIndex: String.Index

        if let nextOpenRange, closeRange == nil || nextOpenRange.lowerBound < closeRange!.lowerBound {
            // Another `<tool_call>` opens before this one is closed — i.e. this
            // call was emitted without its own closing tag. Use the next opening
            // tag as an implicit boundary so a following, well-formed call isn't
            // swallowed into this (unclosed) call's body and lost. This is common
            // when a small model emits a draft call, then re-emits the corrected
            // one right after: the corrected call must still be parsed.
            bodyEnd = nextOpenRange.lowerBound
            nextSearchIndex = nextOpenRange.lowerBound
        } else if let closeRange {
            bodyEnd = closeRange.lowerBound
            nextSearchIndex = closeRange.upperBound
        } else {
            bodyEnd = text.endIndex
            nextSearchIndex = text.endIndex
        }

        let bodyString = String(text[openRange.upperBound..<bodyEnd]).trimmingCharacters(in: .whitespacesAndNewlines)

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
        if let name = (json["name"] as? String) ?? (json["tool_name"] as? String), !name.isEmpty {
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

        // Recover a call whose name (and possibly its whole body) got nested
        // INSIDE `arguments` — a common small-model error. Only applied when
        // there is NO usable top-level name, so a well-formed call is never
        // rewritten. Two shapes are handled:
        if var innerArgs = json["arguments"] as? [String: Any],
           let innerName = (innerArgs["name"] as? String) ?? (innerArgs["tool_name"] as? String),
           !innerName.isEmpty, !looksLikeJSONObject(innerName) {

            // Shape A — the entire call was wrapped one level too deep, i.e. the
            // inner object is itself a complete `{"name":…,"arguments":{…}}` call:
            //   {"arguments":{"name":"task_output","arguments":{"archive":"…"}}}
            // Use the inner call's own arguments, else dispatch loses the real
            // args one level down and reports them "missing".
            if let deeperArgs = innerArgs["arguments"] as? [String: Any] {
                return ParsedToolCall(name: innerName, arguments: deeperArgs)
            }

            // Shape B — the tool name was dumped alongside the real arguments,
            // flat, inside `arguments` (e.g.
            //   {"arguments":{"description":"…","profile":"executor","name":"task"}}).
            innerArgs.removeValue(forKey: "name")
            innerArgs.removeValue(forKey: "tool_name")
            return ParsedToolCall(name: innerName, arguments: innerArgs)
        }

        return nil
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

        // A dangling escape (`…\`) can't be completed safely — the next char is
        // unknown, so we'd be guessing at the payload. Bail.
        guard !escaping else { return nil }

        // If generation stopped *inside* a quoted string, the model was mid-value
        // when it hit the token limit — the single most common local-model
        // truncation (a long `description`/`content` cut off). Close the string
        // before balancing braces, mirroring pi's smart JSON parser. The recovered
        // value is truncated but usable, which beats discarding the whole call;
        // the caller re-parses and falls back if this still isn't valid JSON.
        // Braces *inside* the string were never counted (the scan skips while
        // `inString`), so the structural brace tally below stays correct after we
        // close it.
        let stringClose = inString ? "\"" : ""

        let missing = openBraces - closeBraces
        guard missing > 0 && missing <= 2 else { return nil }

        return text + stringClose + String(repeating: "}", count: missing)
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
