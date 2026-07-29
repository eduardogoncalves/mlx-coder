// Sources/ToolSystem/Protocol/ToolCallErrorFormatter.swift
// Actionable, schema-aware error messages for tool calls that name an unknown
// tool or omit a required parameter.
//
// The philosophy is opencode/pi's: a tool-call error is the model's next
// re-ask prompt, so it should say *what the model should have done* — the
// nearest valid tool name, the tools that exist, or the exact parameter shape —
// instead of a bare "Unknown tool" / "Missing required argument". All of it is
// computed deterministically; no extra model call is involved.

import Foundation

public enum ToolCallErrorFormatter {

    // MARK: - Unknown tool

    /// The closest name in `names` to `attempted`, or nil when nothing is near
    /// enough to be a plausible typo. The threshold scales with the attempted
    /// name's length (longer names tolerate more drift) and is never larger than
    /// the name itself, so a wholly unrelated hallucination yields no suggestion.
    public static func nearestName(to attempted: String, among names: [String]) -> String? {
        let attempt = attempted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !attempt.isEmpty, !names.isEmpty else { return nil }

        // Exact/case-insensitive hit isn't a "did you mean" — callers handle real
        // matches before reaching here, but guard against it anyway.
        if names.contains(attempt) { return attempt }

        let threshold = max(2, attempt.count / 3)
        var best: (name: String, distance: Int)?
        // Sorted so ties resolve deterministically to the lexicographically first.
        for name in names.sorted() {
            let distance = editDistance(attempt.lowercased(), name.lowercased())
            if distance <= threshold, distance < attempt.count,
               best == nil || distance < best!.distance {
                best = (name, distance)
            }
        }
        return best?.name
    }

    /// "Unknown tool: 'x'. Did you mean 'y'? Available tools: ..." — the trailing
    /// list is what the model should pick from on its retry.
    public static func unknownToolMessage(attempted: String, available: [String]) -> String {
        let names = available.sorted()
        var message = "Unknown tool: '\(attempted)'."
        if let suggestion = nearestName(to: attempted, among: names) {
            message += " Did you mean '\(suggestion)'?"
        }
        if !names.isEmpty {
            message += " Available tools: \(names.joined(separator: ", "))."
        }
        return message
    }

    // MARK: - Missing required parameters

    /// A required-parameter error that shows the tool's full expected shape and
    /// what the model actually sent, so the fix is unambiguous on the next turn.
    public static func missingRequiredMessage(
        toolName: String,
        missing: [String],
        expected: [String],
        provided: [String]
    ) -> String {
        let noun = missing.count == 1 ? "parameter" : "parameters"
        var message = "\(toolName): missing required \(noun): \(missing.joined(separator: ", "))."
        if !expected.isEmpty {
            message += " Expected: { \(expected.sorted().joined(separator: ", ")) }."
        }
        message += " You sent: { \(provided.sorted().joined(separator: ", ")) }."
        return message
    }

    // MARK: - Edit distance

    /// Classic Levenshtein distance (insert/delete/substitute, unit cost).
    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }

        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,       // deletion
                    current[j - 1] + 1,    // insertion
                    previous[j - 1] + cost // substitution
                )
            }
            swap(&previous, &current)
        }
        return previous[y.count]
    }
}
