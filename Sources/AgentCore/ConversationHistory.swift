// Sources/AgentCore/ConversationHistory.swift
// Manages message history with ChatML formatting

import Foundation

/// A message in the conversation.
public struct Message: Sendable {
    public enum Role: String, Sendable, Codable {
        case system
        case user
        case assistant
        case tool
    }

    public let role: Role
    public let content: String
    public let toolCallId: String?

    public init(role: Role, content: String, toolCallId: String? = nil) {
        self.role = role
        self.content = content
        self.toolCallId = toolCallId
    }
}

extension Message: Codable {}

/// Manages the conversation history and formats it for the model.
public struct ConversationHistory: Sendable {

    struct JSONTranscriptEnvelope: Codable, Sendable {
        let version: Int
        let messages: [Message]
    }

    private(set) public var messages: [Message] = []

    public init(systemPrompt: String) {
        messages.append(Message(role: .system, content: systemPrompt))
    }

    /// Add a user message.
    public mutating func addUser(_ content: String) {
        messages.append(Message(role: .user, content: content))
    }

    /// Add an assistant message.
    public mutating func addAssistant(_ content: String, stripThinking: Bool = true) {
        var finalContent = content
        if stripThinking {
            // 1. Full block: <think>...</think>
            while let thinkOpenRange = finalContent.range(of: "<think>"),
                  let thinkCloseRange = finalContent.range(of: "</think>", range: thinkOpenRange.upperBound..<finalContent.endIndex) {
                 let before = finalContent[..<thinkOpenRange.lowerBound]
                 let after = finalContent[thinkCloseRange.upperBound...]
                 finalContent = (String(before) + String(after)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            
            // 2. Partial block: If thinking was force-started in the prompt, 
            // the response might start with reasoning and end with </think>.
            if let thinkCloseRange = finalContent.range(of: "</think>") {
                let after = finalContent[thinkCloseRange.upperBound...]
                finalContent = String(after).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        messages.append(Message(role: .assistant, content: finalContent))
    }

    /// Add a tool response.
    public mutating func addToolResponse(_ content: String, toolCallId: String? = nil) {
        messages.append(Message(role: .tool, content: content, toolCallId: toolCallId))
    }

    /// Most recent user message, used to keep extraction prompts task-relevant.
    public var latestUserMessage: String? {
        messages.last(where: { $0.role == .user })?.content
    }

    /// Clears the history, retaining only the initial system prompt.
    public mutating func clear() {
        guard let systemPrompt = messages.first(where: { $0.role == .system }) else { return }
        messages = [systemPrompt]
    }

    /// Update the initial system prompt.
    public mutating func updateSystemPrompt(_ newPrompt: String) {
        if let index = messages.firstIndex(where: { $0.role == .system }) {
            messages[index] = Message(role: .system, content: newPrompt)
        } else {
            // Should not happen if initialized correctly, but as a safety:
            messages.insert(Message(role: .system, content: newPrompt), at: 0)
        }
    }

    /// Reverts the conversation to the state before the last user message.
    /// Returns true if a turn was successfully reverted.
    public mutating func revertLastTurn() -> Bool {
        if let lastUserIndex = messages.lastIndex(where: { $0.role == .user }) {
            messages.removeSubrange(lastUserIndex...)
            return true
        }
        return false
    }

    /// Format the full conversation as ChatML.
    ///
    /// Example output:
    /// ```
    /// <|im_start|>system
    /// You are a helpful assistant.
    /// <|im_end|>
    /// <|im_start|>user
    /// Hello!
    /// <|im_end|>
    /// ```
    public func formatChatML(enableThinking: Bool = true) -> String {
        var result = ""
        for message in messages {
            result += "\(ToolCallPattern.imStart)\(message.role.rawValue)\n"
            result += message.content
            result += "\n\(ToolCallPattern.imEnd)\n"
        }
        // Add the opening for the assistant's next turn
        result += "\(ToolCallPattern.imStart)\(ToolCallPattern.roleAssistant)\n"
        
        if !enableThinking {
            // Pre-fill an empty think block to "skip" reasoning
            result += "<think>\n\n</think>\n\n"
        } else {
            // Force start of thinking for thinking models
            result += "<think>\n"
        }
        
        return result
    }

    /// Total estimated token count (rough: 4 chars ≈ 1 token).
    public var estimatedTokenCount: Int {
        let totalChars = messages.reduce(0) { $0 + $1.content.count }
        return totalChars / 4
    }

    /// Deterministically compacts older context into a summary message while preserving
    /// system prompt and recent turns.
    @discardableResult
    public mutating func compactDeterministically(
        maxEstimatedTokens: Int,
        keepRecentMessages: Int,
        maxSummaryChars: Int = 1800
    ) -> Bool {
        guard estimatedTokenCount > maxEstimatedTokens else {
            return false
        }
        guard let systemMessage = messages.first(where: { $0.role == .system }) else {
            return false
        }

        let nonSystem = Array(messages.dropFirst())
        guard nonSystem.count > keepRecentMessages else {
            return false
        }

        let recentCount = max(1, keepRecentMessages)
        let recentMessages = Array(nonSystem.suffix(recentCount))
        let middleMessages = Array(nonSystem.dropLast(recentCount))
        let summary = buildCompactionSummary(from: middleMessages, maxChars: maxSummaryChars)

        var rebuilt: [Message] = [systemMessage]
        rebuilt.append(Message(role: .assistant, content: summary))
        rebuilt.append(contentsOf: recentMessages)
        messages = rebuilt

        // If still above budget, drop the oldest preserved message deterministically.
        while estimatedTokenCount > maxEstimatedTokens && messages.count > 2 {
            messages.remove(at: 2)
        }

        if estimatedTokenCount > maxEstimatedTokens, messages.count >= 2 {
            var summary = messages[1].content
            while estimatedTokenCount > maxEstimatedTokens && summary.count > 80 {
                let nextLength = max(80, Int(Double(summary.count) * 0.75))
                summary = String(summary.prefix(nextLength)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
                messages[1] = Message(role: .assistant, content: summary)
            }
        }

        return true
    }

    /// Export conversation as a Markdown transcript.
    /// By default, excludes the initial system prompt. Set `includeSystemPrompt` to true to include it.
    public func asMarkdownTranscript(includeSystemPrompt: Bool = false) -> String {
        var lines: [String] = []
        lines.append("# mlx-coder Session Transcript")
        lines.append("")

        let messagesToExport = includeSystemPrompt ? messages : messages.filter { $0.role != .system }
        for (index, message) in messagesToExport.enumerated() {
            lines.append("## \(index + 1). \(message.role.rawValue.capitalized)")
            lines.append("")
            lines.append("```")
            lines.append(message.content)
            lines.append("```")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func buildCompactionSummary(from source: [Message], maxChars: Int) -> String {
        guard !source.isEmpty else {
            return "[Context compaction summary] No prior messages were available for compaction."
        }

        let roleCounts = Dictionary(grouping: source, by: \.role).mapValues(\.count)
        let header = "[Context compaction summary]"
        var lines: [String] = [
            header,
            "Condensed \(source.count) earlier messages.",
            "Role counts: user=\(roleCounts[.user, default: 0]), assistant=\(roleCounts[.assistant, default: 0]), tool=\(roleCounts[.tool, default: 0]).",
            "Key excerpts:"
        ]

        for message in source.prefix(10) {
            let snippet = message.content
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let clipped = snippet.count > 120 ? String(snippet.prefix(120)) + "..." : snippet
            lines.append("- [\(message.role.rawValue)] \(clipped)")
        }

        var result = lines.joined(separator: "\n")
        if result.count > maxChars {
            result = String(result.prefix(maxChars)) + "..."
        }
        return result
    }

    /// Export conversation messages as pretty-printed JSON.
    /// By default, excludes the initial system prompt. Set `includeSystemPrompt` to true to include it.
    public func asJSONTranscript(includeSystemPrompt: Bool = false) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let messagesToExport = includeSystemPrompt ? messages : messages.filter { $0.role != .system }
        let envelope = JSONTranscriptEnvelope(version: 1, messages: messagesToExport)
        let data = try encoder.encode(envelope)
        return String(decoding: data, as: UTF8.self)
    }

    /// Replace history with a decoded transcript.
    public mutating func restoreFromJSONTranscript(_ json: Data) throws {
        let decoder = JSONDecoder()
        let decoded: [Message]
        if let envelope = try? decoder.decode(JSONTranscriptEnvelope.self, from: json) {
            decoded = envelope.messages
        } else {
            decoded = try decoder.decode([Message].self, from: json)
        }
        guard let first = decoded.first, first.role == .system else {
            throw NSError(
                domain: "ConversationHistory",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Transcript must start with a system message"]
            )
        }
        messages = decoded
    }
}
