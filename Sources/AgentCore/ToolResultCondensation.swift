// Sources/AgentCore/ToolResultCondensation.swift
// Policy/config for summarizing large tool outputs before storing in main history

import Foundation

public struct ToolResultCondensationConfig: Sendable {
    public let largeResultTokenThreshold: Int
    public let charsPerTokenEstimate: Int
    public let summaryTargetTokens: Int
    public let maxSummaryChars: Int
    public let fallbackRawChars: Int
    public let eligibleTools: Set<String>

    public init(
        largeResultTokenThreshold: Int = 1000,
        charsPerTokenEstimate: Int = 4,
        summaryTargetTokens: Int = 300,
        maxSummaryChars: Int = 1200,
        fallbackRawChars: Int = 4000,
        eligibleTools: Set<String> = ["web_fetch", "read_file", "read_many", "bash", "web_search"]
    ) {
        self.largeResultTokenThreshold = max(1, largeResultTokenThreshold)
        self.charsPerTokenEstimate = max(1, charsPerTokenEstimate)
        self.summaryTargetTokens = max(64, summaryTargetTokens)
        self.maxSummaryChars = max(256, maxSummaryChars)
        self.fallbackRawChars = max(512, fallbackRawChars)
        self.eligibleTools = eligibleTools
    }
}

enum ToolResultCondensationPolicy {
    private static let neverCondenseTools: Set<String> = ["todo", "list_dir", "dir_list"]

    static func joinedToolOutput(result: ToolResult) -> String {
        var text = result.content
        if let marker = result.truncationMarker {
            text += "\n\(marker)"
        }
        return text
    }

    static func estimatedTokenCount(for text: String, charsPerToken: Int) -> Int {
        guard !text.isEmpty else { return 0 }
        let divisor = max(1, charsPerToken)
        return max(1, text.count / divisor)
    }

    static func shouldCondense(toolName: String, result: ToolResult, config: ToolResultCondensationConfig) -> Bool {
        guard !result.isError else { return false }
        guard !neverCondenseTools.contains(toolName) else { return false }
        guard config.eligibleTools.contains(toolName) else { return false }

        let raw = joinedToolOutput(result: result)

        // web_fetch may already return query-focused extraction text.
        // Re-condensing it can drop critical details and trigger redundant refetch loops.
        if toolName == "web_fetch", isAlreadyQueryExtractedWebFetch(raw) {
            return false
        }

        let estimatedTokens = estimatedTokenCount(for: raw, charsPerToken: config.charsPerTokenEstimate)
        guard estimatedTokens > config.largeResultTokenThreshold else { return false }

        // Skip compact structured payloads (already concise and low-risk for context bloat).
        if isLikelyCompactStructuredPayload(raw) {
            return false
        }

        return true
    }

    static func isLikelyCompactStructuredPayload(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 2000 else { return false }

        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) ||
            (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) {
            return true
        }

        return false
    }

    static func isAlreadyQueryExtractedWebFetch(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        return lower.hasPrefix("extracted information for query '")
            || lower.hasPrefix("extracted information for query \"")
    }

    static func sanitizeSummary(_ text: String, maxChars: Int) -> String {
        let stripped = text
            .replacingOccurrences(of: ToolCallPattern.eosToken, with: "")
            .replacingOccurrences(of: ToolCallPattern.imEnd, with: "")
            .replacingOccurrences(of: ToolCallPattern.imStart, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if stripped.count <= maxChars {
            return stripped
        }

        return String(stripped.prefix(maxChars)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func formatCondensedToolMessage(toolName: String, summary: String) -> String {
        """
        [Tool output summarized for context efficiency]
        Tool: \(toolName)
        Summary:
        \(summary)
        """
    }

    static func boundedFallbackRawMessage(toolName: String, raw: String, maxChars: Int) -> String {
        guard raw.count > maxChars else { return raw }
        let kept = String(raw.prefix(maxChars))
        let omitted = raw.count - maxChars
        return """
        [Tool output could not be summarized; bounded raw fallback]
        Tool: \(toolName)
        \(kept)
        [... \(omitted) characters omitted ...]
        """
    }
}
