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
        return formatChatML(messages: messages, enableThinking: enableThinking)
    }

    /// Format an explicit message list as ChatML. Used by `transformContext` to format
    /// a potentially modified copy of `messages` without mutating history.
    public func formatChatML(messages messagesOverride: [Message], enableThinking: Bool = true) -> String {
        var result = ""
        for message in messagesOverride {
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

    // MARK: - Turn-level data structures

    /// A logical conversation turn: one user message plus all assistant/tool messages that follow
    /// it before the next user message.
    public struct Turn: Sendable {
        public let userMessage: Message
        public let assistantAndToolMessages: [Message]

        public var allMessages: [Message] { [userMessage] + assistantAndToolMessages }

        /// Rough token estimate for this turn (4 chars ≈ 1 token).
        public var estimatedTokens: Int {
            allMessages.reduce(0) { $0 + $1.content.count / 4 }
        }

        /// Exact token count using an external counter (e.g. the model tokenizer).
        public func tokenCount(using counter: (String) -> Int) -> Int {
            allMessages.reduce(0) { $0 + counter($1.content) }
        }

        /// Heuristic importance score (higher = keep longer during compaction).
        /// Turns are given higher importance when the user is correcting/asking about an error,
        /// or when the turn itself surfaced an error.
        public var importanceScore: Int {
            var score = 0
            let userText = userMessage.content.lowercased()
            let correctionKeywords = ["error", "wrong", "actually", "wait", "no,", "no.", "stop",
                                      "mistake", "incorrect", "fix", "bug", "that's not", "that is not"]
            if correctionKeywords.contains(where: { userText.contains($0) }) { score += 10 }
            if userMessage.content.count < 60 { score += 3 } // Short corrections are important

            let errorSurface = assistantAndToolMessages.contains(where: { msg in
                let lower = msg.content.lowercased()
                return lower.contains("error:") || lower.contains("failed:") || lower.contains("exception:")
            })
            if errorSurface { score += 5 }
            return score
        }
    }

    /// Groups non-system messages into conversation turns in chronological order.
    public func turns() -> [Turn] {
        var result: [Turn] = []
        var currentUserMsg: Message? = nil
        var currentFollowers: [Message] = []

        for message in messages where message.role != .system {
            if message.role == .user {
                if let user = currentUserMsg {
                    result.append(Turn(userMessage: user, assistantAndToolMessages: currentFollowers))
                }
                currentUserMsg = message
                currentFollowers = []
            } else {
                currentFollowers.append(message)
            }
        }
        if let user = currentUserMsg {
            result.append(Turn(userMessage: user, assistantAndToolMessages: currentFollowers))
        }
        return result
    }

    // MARK: - Compaction

    /// Turn-aware compaction: drops the least-important oldest turns first, preserves the most
    /// recent `keepRecentTurns` turns intact, and replaces dropped turns with a richer summary.
    ///
    /// - Parameters:
    ///   - maxTokens: Token budget to compact down to.
    ///   - keepRecentTurns: Minimum number of recent turns always kept verbatim.
    ///   - tokenCounter: Optional exact token counter (e.g. model tokenizer). Falls back to `chars/4`.
    ///   - maxSummaryChars: Character ceiling for the generated summary block.
    /// - Returns: `true` if compaction was performed.
    @discardableResult
    public mutating func compactByTurns(
        maxTokens: Int,
        keepRecentTurns: Int,
        tokenCounter: ((String) -> Int)? = nil,
        maxSummaryChars: Int = 2400
    ) -> Bool {
        let count: (String) -> Int = tokenCounter ?? { $0.count / 4 }
        let total = messages.reduce(0) { $0 + count($1.content) }
        guard total > maxTokens else { return false }

        guard let systemMessage = messages.first(where: { $0.role == .system }) else { return false }

        let allTurns = turns()
        let keepCount = max(1, keepRecentTurns)
        guard allTurns.count > keepCount else { return false }

        let recentTurns  = Array(allTurns.suffix(keepCount))
        var candidateTurns = Array(allTurns.dropLast(keepCount))

        // Drop turns from least-important to most-important (stable: preserves order among ties).
        let systemTokens = count(systemMessage.content)
        let recentTokens = recentTurns.flatMap(\.allMessages).reduce(0) { $0 + count($1.content) }

        // Sort candidates by importance ascending so we drop least-important first.
        let sortedIndices = candidateTurns.indices.sorted {
            candidateTurns[$0].importanceScore < candidateTurns[$1].importanceScore
        }

        var dropped = Set<Int>()
        var runningTotal = total
        for idx in sortedIndices {
            if runningTotal <= maxTokens { break }
            let turnTokens = candidateTurns[idx].tokenCount(using: count)
            runningTotal -= turnTokens
            dropped.insert(idx)
        }

        let keptCandidates = candidateTurns.indices
            .filter { !dropped.contains($0) }
            .map { candidateTurns[$0] }
        let droppedTurns = dropped.sorted().map { candidateTurns[$0] }

        // Build summary from dropped turns (in chronological order).
        let summary = buildTurnAwareSummary(from: droppedTurns, maxChars: maxSummaryChars)

        var rebuilt: [Message] = [systemMessage]
        if !summary.isEmpty {
            rebuilt.append(Message(role: .assistant, content: summary))
        }
        rebuilt.append(contentsOf: keptCandidates.flatMap(\.allMessages))
        rebuilt.append(contentsOf: recentTurns.flatMap(\.allMessages))
        messages = rebuilt

        // Emergency trim: if still over budget, shorten the summary text progressively.
        if messages.reduce(0, { $0 + count($1.content) }) > maxTokens, messages.count >= 2,
           messages[1].role == .assistant {
            var summaryText = messages[1].content
            var current = messages.reduce(0) { $0 + count($1.content) }
            while current > maxTokens && summaryText.count > 80 {
                let nextLen = max(80, Int(Double(summaryText.count) * 0.75))
                summaryText = String(summaryText.prefix(nextLen))
                    .trimmingCharacters(in: .whitespacesAndNewlines) + "..."
                messages[1] = Message(role: .assistant, content: summaryText)
                current = messages.reduce(0) { $0 + count($1.content) }
            }
        }

        return true
    }

    /// Legacy single-message compaction — kept for compatibility.
    /// Prefer `compactByTurns` which removes whole turns and produces better summaries.
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

    /// Turn-aware summary: groups dropped turns into a readable narrative that captures
    /// what happened (user intent, files touched, errors surfaced, key decisions).
    private func buildTurnAwareSummary(from droppedTurns: [Turn], maxChars: Int) -> String {
        guard !droppedTurns.isEmpty else {
            return "[Context compaction summary] No earlier turns to summarize."
        }

        var lines: [String] = [
            "[Context compaction summary — \(droppedTurns.count) earlier turn(s) condensed]"
        ]

        for (idx, turn) in droppedTurns.enumerated() {
            let userSnippet = turn.userMessage.content
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let clippedUser = userSnippet.count > 160 ? String(userSnippet.prefix(160)) + "…" : userSnippet
            lines.append("Turn \(idx + 1): user: \(clippedUser)")

            // Extract file paths mentioned in any message of this turn (simple heuristic: tokens with "/" or ".")
            var fileMentions: [String] = []
            var seen = Set<String>()
            for msg in turn.allMessages {
                let tokens = msg.content.split(separator: " ").map(String.init)
                let paths = tokens.filter { $0.contains("/") || ($0.contains(".") && !$0.hasPrefix("http")) }
                    .map { $0.trimmingCharacters(in: .init(charactersIn: "\"'`(),;")) }
                    .filter { $0.count > 3 && $0.count < 120 }
                for path in paths where seen.insert(path).inserted {
                    fileMentions.append(path)
                }
            }
            let uniqueFiles = fileMentions.prefix(4)
            if !uniqueFiles.isEmpty {
                lines.append("  files: \(uniqueFiles.joined(separator: ", "))")
            }

            // Capture first error line if any
            for msg in turn.assistantAndToolMessages {
                let lower = msg.content.lowercased()
                if lower.contains("error:") || lower.contains("failed:") || lower.contains("exception:") {
                    let errLine = msg.content
                        .components(separatedBy: "\n")
                        .first(where: { $0.lowercased().contains("error") || $0.lowercased().contains("failed") })?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !errLine.isEmpty {
                        let clipped = errLine.count > 120 ? String(errLine.prefix(120)) + "…" : errLine
                        lines.append("  error: \(clipped)")
                        break
                    }
                }
            }

            // Final assistant text snippet (outcome/decision)
            if let lastAssistant = turn.assistantAndToolMessages.last(where: { $0.role == .assistant }),
               !lastAssistant.content.isEmpty {
                let snippet = lastAssistant.content
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let clipped = snippet.count > 120 ? String(snippet.prefix(120)) + "…" : snippet
                lines.append("  outcome: \(clipped)")
            }
        }

        var result = lines.joined(separator: "\n")
        if result.count > maxChars {
            result = String(result.prefix(maxChars)).trimmingCharacters(in: .whitespacesAndNewlines) + "\n…"
        }
        return result
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
