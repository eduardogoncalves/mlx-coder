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
        // trailing ")" so a truncated stream still yields the partial call —
        // but remember that we had to tolerate it, since that almost always
        // means the argument list (and likely the last value in it) was cut
        // off mid-generation rather than the model simply forgetting a paren.
        let afterOpen = segment.index(after: openIdx)
        let argsBody: String
        var truncated = false
        if let closeIdx = indexOfMatchingClose(segment, openAt: openIdx) {
            argsBody = String(segment[afterOpen..<closeIdx])
        } else {
            argsBody = String(segment[afterOpen...])
            truncated = true
        }

        let (arguments, argumentsTruncated) = parseArguments(argsBody)
        return ToolCallParser.ParsedToolCall(
            name: name,
            arguments: arguments,
            wasTruncated: truncated || argumentsTruncated
        )
    }

    /// Returns the parsed `key: value` map plus whether any part of it had to
    /// tolerate a missing closing delimiter (see `wasTruncated` on
    /// `ParsedToolCall` for how callers should use this).
    private static func parseArguments(_ body: String) -> (arguments: [String: Any], truncated: Bool) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([:], false) }

        var result: [String: Any] = [:]
        var truncated = false
        let pairs = splitTopLevel(trimmed, separator: ",")
        for pair in pairs {
            let trimmedPair = pair.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPair.isEmpty else { continue }
            guard let eq = indexOfFirstTopLevel(trimmedPair, char: "=") else {
                // A fragment with no "=" at all is dropped, same as before we
                // tracked truncation. Deliberately NOT flagged as truncated:
                // it's indistinguishable from a legitimate (if non-standard)
                // keyless/positional value (e.g. `f('some_value')`), and any
                // *genuine* cut-off-before-"=" case already leaves the call's
                // own closing ")" unmatched — caught by the check in
                // `parseSingleCall` — so this heuristic would only add false
                // positives without adding real detection coverage.
                continue
            }
            let key = String(trimmedPair[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
            let valueRaw = String(trimmedPair[trimmedPair.index(after: eq)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            let (value, valueTruncated) = parseValue(valueRaw)
            result[key] = value
            if valueTruncated { truncated = true }
        }
        return (result, truncated)
    }

    /// Returns the decoded value plus whether it had to tolerate a missing
    /// closing quote/bracket/brace (a truncation signal — see `wasTruncated`
    /// on `ParsedToolCall`).
    private static func parseValue(_ raw: String) -> (value: Any, truncated: Bool) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return ("", false) }

        // Quoted string (single or double quote). LFM2 emits single quotes by
        // default per the chat template, but accept double quotes too.
        if first == "'" || first == "\"" {
            return unquote(trimmed, quote: first)
        }

        // JSON object / array.
        if first == "{" || first == "[" {
            if let data = trimmed.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                return (json, false)
            }
            // Strict JSON failed. A model emitting genuine Python syntax
            // (single-quoted keys/strings, bare True/False/None) produces a
            // structure that is invalid JSON but perfectly well-formed
            // Python — normalize it to JSON and retry before giving up.
            if let normalized = normalizePythonLiteralToJSON(trimmed),
               let data = normalized.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                return (json, false)
            }
            // Neither decodes. If the literal isn't even balanced at the top
            // level (an unterminated string, or an unmatched `{`/`[`), that's
            // very likely mid-value truncation rather than just unsupported
            // syntax — flag it. Fall through to the bare-string last resort
            // either way so behavior doesn't regress.
            return (trimmed, !isBalanced(trimmed))
        }

        // Python literals.
        switch trimmed {
        case "True": return (true, false)
        case "False": return (false, false)
        case "None", "null": return (NSNull(), false)
        default: break
        }

        if let intValue = Int(trimmed) { return (intValue, false) }
        if let doubleValue = Double(trimmed) { return (doubleValue, false) }

        // Last resort: treat as bare string.
        return (trimmed, false)
    }

    private static func unquote(_ token: String, quote: Character) -> (value: String, truncated: Bool) {
        var s = token
        guard let first = s.first, first == quote else { return (s, false) }
        s.removeFirst()
        let closed = s.last == quote
        if closed {
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
            return (value, !closed)
        }
        return (s, !closed)
    }

    /// Converts a Python dict/list literal into JSON text by re-quoting only
    /// the string tokens it actually scans as string delimiters (never a
    /// naive global `'` → `"` replace, which would corrupt values containing
    /// apostrophes) and mapping bare `True`/`False`/`None` identifiers to
    /// their JSON equivalents. Returns `nil` if a quoted string inside the
    /// literal never closes (caller treats that as a truncation signal via
    /// `isBalanced` instead of guessing at a repair).
    private static func normalizePythonLiteralToJSON(_ raw: String) -> String? {
        let chars = Array(raw)
        let n = chars.count
        var out = ""
        out.reserveCapacity(n + 8)
        var i = 0

        func isIdentifierStart(_ c: Character) -> Bool { c.isLetter || c == "_" }
        func isIdentifierChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

        while i < n {
            let ch = chars[i]

            if ch == "'" || ch == "\"" {
                let quote = ch
                var body = ""
                var j = i + 1
                var closed = false
                while j < n {
                    let c = chars[j]
                    if c == "\\", j + 1 < n {
                        let next = chars[j + 1]
                        if quote == "'" && next == "'" {
                            // Python's `\'` escape (only meaningful inside a
                            // single-quoted string) — unescape to a literal
                            // apostrophe; `escapeForJSONStringValue` will
                            // re-escape it correctly for the JSON string.
                            body.append("'")
                        } else {
                            body.append(c)
                            body.append(next)
                        }
                        j += 2
                        continue
                    }
                    if c == quote {
                        closed = true
                        j += 1
                        break
                    }
                    body.append(c)
                    j += 1
                }
                guard closed else { return nil }
                out.append("\"")
                out.append(escapeForJSONStringValue(body, originalQuote: quote))
                out.append("\"")
                i = j
                continue
            }

            if isIdentifierStart(ch) {
                var word = ""
                var j = i
                while j < n, isIdentifierChar(chars[j]) {
                    word.append(chars[j])
                    j += 1
                }
                switch word {
                case "True": out.append("true")
                case "False": out.append("false")
                case "None": out.append("null")
                default: out.append(word)
                }
                i = j
                continue
            }

            out.append(ch)
            i += 1
        }

        return out
    }

    /// True when `s` has no unterminated quote and every `{`/`[` it opens is
    /// closed by the end of the string. Used as a last-ditch truncation
    /// signal for a `{`/`[` value that failed both strict-JSON and
    /// Python-literal decoding.
    private static func isBalanced(_ s: String) -> Bool {
        var depthBrace = 0
        var depthBracket = 0
        var quote: Character? = nil
        var escape = false
        for ch in s {
            if escape {
                escape = false
                continue
            }
            if let q = quote {
                if ch == "\\" { escape = true }
                else if ch == q { quote = nil }
                continue
            }
            switch ch {
            case "'", "\"": quote = ch
            case "{": depthBrace += 1
            case "}": depthBrace -= 1
            case "[": depthBracket += 1
            case "]": depthBracket -= 1
            default: break
            }
        }
        return quote == nil && !escape && depthBrace == 0 && depthBracket == 0
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
