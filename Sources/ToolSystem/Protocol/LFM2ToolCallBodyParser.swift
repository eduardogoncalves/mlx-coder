// Sources/ToolSystem/Protocol/LFM2ToolCallBodyParser.swift
// Parses the body emitted by LFM2 between <|tool_call_start|> and <|tool_call_end|>.
//
// Format:
//   [name(arg='value', arg2=42), name2(flag=True, items=[1, 2, 3], obj={"k":"v"})]
//
// String values use single (or double) quotes; numbers/bools/lists/dicts are
// written as literals. Multiple calls are comma-separated inside the brackets.

import Foundation

enum LFM2ToolCallBodyParser {

    /// Parse the captured body and return zero or more tool calls.
    /// Tolerates a missing outer `[ ]` (model occasionally drops it) and
    /// recovers as much as possible from malformed segments.
    static func parse(_ body: String) -> [ToolCallParser.ParsedToolCall] {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Some LFM2 checkpoints drift toward Qwen-style JSON inside the
        // LFM2 markers (`{"name":..., "arguments":...}`). Accept that shape
        // so the call still executes instead of being flagged malformed.
        if trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = json["name"] as? String {
            let arguments = (json["arguments"] as? [String: Any]) ?? [:]
            return [ToolCallParser.ParsedToolCall(name: name, arguments: arguments)]
        }

        let inner: String
        if trimmed.hasPrefix("[") {
            // Strip outer brackets; if the trailing one is missing (truncation),
            // accept the unterminated body and parse what we have.
            let afterOpen = String(trimmed.dropFirst())
            if afterOpen.hasSuffix("]") {
                inner = String(afterOpen.dropLast())
            } else {
                inner = afterOpen
            }
        } else {
            inner = trimmed
        }

        let calls = splitTopLevel(inner, separator: ",")
        var results: [ToolCallParser.ParsedToolCall] = []
        for raw in calls {
            let segment = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !segment.isEmpty else { continue }
            if let call = parseSingleCall(segment) {
                results.append(call)
            }
        }
        return results
    }

    private static func parseSingleCall(_ segment: String) -> ToolCallParser.ParsedToolCall? {
        // Split name and argument body at the first top-level "(".
        guard let openIdx = indexOfFirstTopLevel(segment, char: "(") else {
            return nil
        }
        let name = String(segment[..<openIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        // Capture from after "(" up to the matching ")". Tolerate a missing
        // trailing ")" so a truncated stream still yields the partial call.
        let afterOpen = segment.index(after: openIdx)
        let argsBody: String
        if let closeIdx = indexOfMatchingClose(segment, openAt: openIdx) {
            argsBody = String(segment[afterOpen..<closeIdx])
        } else {
            argsBody = String(segment[afterOpen...])
        }

        let arguments = parseArguments(argsBody)
        return ToolCallParser.ParsedToolCall(name: name, arguments: arguments)
    }

    private static func parseArguments(_ body: String) -> [String: Any] {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }

        var result: [String: Any] = [:]
        for pair in splitTopLevel(trimmed, separator: ",") {
            let trimmedPair = pair.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPair.isEmpty else { continue }
            guard let eq = indexOfFirstTopLevel(trimmedPair, char: "=") else {
                continue
            }
            let key = String(trimmedPair[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
            let valueRaw = String(trimmedPair[trimmedPair.index(after: eq)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            result[key] = parseValue(valueRaw)
        }
        return result
    }

    private static func parseValue(_ raw: String) -> Any {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "" }

        // Quoted string (single or double quote). LFM2 emits single quotes by
        // default per the chat template, but accept double quotes too.
        if first == "'" || first == "\"" {
            return unquote(trimmed, quote: first)
        }

        // JSON object / array.
        if first == "{" || first == "[" {
            if let data = trimmed.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                return json
            }
            // Fall through to literal handling if JSON parse fails.
        }

        // Python literals.
        switch trimmed {
        case "True": return true
        case "False": return false
        case "None", "null": return NSNull()
        default: break
        }

        if let intValue = Int(trimmed) { return intValue }
        if let doubleValue = Double(trimmed) { return doubleValue }

        // Last resort: treat as bare string.
        return trimmed
    }

    private static func unquote(_ token: String, quote: Character) -> String {
        var s = token
        guard let first = s.first, first == quote else { return s }
        s.removeFirst()
        if s.last == quote {
            s.removeLast()
        }
        // Decode standard escape sequences. Single-quoted strings in LFM2
        // commonly survive a roundtrip through Python's repr; handle the
        // common cases. Full JSON decoding via a wrapped key avoids
        // hand-rolling escape state.
        let wrapped = "{\"v\":\"" + escapeForJSONStringValue(s, originalQuote: quote) + "\"}"
        if let data = wrapped.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = json["v"] as? String {
            return value
        }
        return s
    }

    /// Re-escape the captured token so it slots into a JSON string literal
    /// without breaking it. We intentionally preserve already-valid backslash
    /// escape sequences (`\n`, `\t`, `\\`, `\'`, `\"`, `\uXXXX`) so the JSON
    /// decoder produces the right characters.
    private static func escapeForJSONStringValue(_ raw: String, originalQuote: Character) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        var iterator = raw.makeIterator()
        while let ch = iterator.next() {
            if ch == "\\" {
                // Preserve the escape pair verbatim — JSONSerialization will
                // interpret it. If the escape uses a single quote (Python),
                // convert to a literal apostrophe since JSON has no \'.
                if let next = iterator.next() {
                    if next == "'" {
                        out.append("'")
                    } else {
                        out.append("\\")
                        out.append(next)
                    }
                } else {
                    out.append("\\\\")
                }
            } else if ch == "\"" {
                out.append("\\\"")
            } else if ch == "\n" {
                out.append("\\n")
            } else if ch == "\r" {
                out.append("\\r")
            } else if ch == "\t" {
                out.append("\\t")
            } else {
                let v = ch.unicodeScalars.first!.value
                if v < 0x20 {
                    out.append(String(format: "\\u%04x", v))
                } else {
                    out.append(ch)
                }
            }
        }
        _ = originalQuote // reserved for future divergence; suppress unused warning
        return out
    }

    // MARK: - Top-level scanning helpers

    private static func splitTopLevel(_ s: String, separator: Character) -> [String] {
        var pieces: [String] = []
        var current = ""
        var depthParen = 0
        var depthBracket = 0
        var depthBrace = 0
        var quote: Character? = nil
        var escape = false

        for ch in s {
            if escape {
                current.append(ch)
                escape = false
                continue
            }
            if let q = quote {
                if ch == "\\" {
                    current.append(ch)
                    escape = true
                    continue
                }
                if ch == q {
                    quote = nil
                }
                current.append(ch)
                continue
            }
            switch ch {
            case "'", "\"":
                quote = ch
                current.append(ch)
            case "(": depthParen += 1; current.append(ch)
            case ")": depthParen = max(0, depthParen - 1); current.append(ch)
            case "[": depthBracket += 1; current.append(ch)
            case "]": depthBracket = max(0, depthBracket - 1); current.append(ch)
            case "{": depthBrace += 1; current.append(ch)
            case "}": depthBrace = max(0, depthBrace - 1); current.append(ch)
            default:
                if ch == separator && depthParen == 0 && depthBracket == 0 && depthBrace == 0 {
                    pieces.append(current)
                    current = ""
                } else {
                    current.append(ch)
                }
            }
        }
        if !current.isEmpty {
            pieces.append(current)
        }
        return pieces
    }

    private static func indexOfFirstTopLevel(_ s: String, char target: Character) -> String.Index? {
        var depthParen = 0
        var depthBracket = 0
        var depthBrace = 0
        var quote: Character? = nil
        var escape = false
        var idx = s.startIndex
        while idx < s.endIndex {
            let ch = s[idx]
            if escape {
                escape = false
                idx = s.index(after: idx)
                continue
            }
            if let q = quote {
                if ch == "\\" { escape = true }
                else if ch == q { quote = nil }
                idx = s.index(after: idx)
                continue
            }
            switch ch {
            case "'", "\"": quote = ch
            case "(":
                if target == "(" && depthParen == 0 && depthBracket == 0 && depthBrace == 0 { return idx }
                depthParen += 1
            case ")": depthParen = max(0, depthParen - 1)
            case "[": depthBracket += 1
            case "]": depthBracket = max(0, depthBracket - 1)
            case "{": depthBrace += 1
            case "}": depthBrace = max(0, depthBrace - 1)
            default:
                if ch == target && depthParen == 0 && depthBracket == 0 && depthBrace == 0 {
                    return idx
                }
            }
            idx = s.index(after: idx)
        }
        return nil
    }

    private static func indexOfMatchingClose(_ s: String, openAt: String.Index) -> String.Index? {
        // openAt points at "("; find its matching ")" respecting nested groups and quotes.
        var depth = 0
        var quote: Character? = nil
        var escape = false
        var idx = openAt
        while idx < s.endIndex {
            let ch = s[idx]
            if escape {
                escape = false
                idx = s.index(after: idx)
                continue
            }
            if let q = quote {
                if ch == "\\" { escape = true }
                else if ch == q { quote = nil }
                idx = s.index(after: idx)
                continue
            }
            switch ch {
            case "'", "\"": quote = ch
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return idx }
            default: break
            }
            idx = s.index(after: idx)
        }
        return nil
    }
}
