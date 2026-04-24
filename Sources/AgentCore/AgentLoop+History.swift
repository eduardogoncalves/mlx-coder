// Sources/AgentCore/AgentLoop+History.swift
// Conversation history management and diagnostics.

import Foundation
import MLX

extension AgentLoop {

    /// Clears the conversation history and frees MLX memory.
    public func clearHistory() {
        history.clear()
        MLX.Memory.clearCache()
        renderer.printStatus("Conversation history and KV cache cleared")
    }

    /// Reverts the last conversation turn (User + Assistant).
    public func undoLastTurn() {
        if history.revertLastTurn() {
            renderer.printStatus("Reverted the last conversation turn")
        } else {
            renderer.printError("Nothing to undo")
        }
    }

    /// Export conversation history to a markdown transcript in the workspace.
    public func exportHistory(to path: String) throws -> String {
        let resolved = try permissions.validatePath(path)
        let transcript = history.asMarkdownTranscript()
        try transcript.write(toFile: resolved, atomically: true, encoding: .utf8)
        renderer.printStatus("Exported history to \(resolved)")
        return resolved
    }

    /// Export conversation history as JSON for later resume.
    public func exportHistoryJSON(to path: String) throws -> String {
        let resolved = try permissions.validatePath(path)
        let transcript = try history.asJSONTranscript()
        try transcript.write(toFile: resolved, atomically: true, encoding: .utf8)
        renderer.printStatus("Exported JSON history to \(resolved)")
        return resolved
    }

    /// Load conversation history from a JSON transcript.
    public func loadHistoryJSON(from path: String) throws -> String {
        let resolved = try permissions.validatePath(path)
        let data = try Data(contentsOf: URL(filePath: resolved))
        try history.restoreFromJSONTranscript(data)
        renderer.printStatus("Loaded JSON history from \(resolved)")
        return resolved
    }

    /// Returns a human-readable context usage report.
    public func contextUsageReport() -> String {
        var countByRole: [Message.Role: Int] = [:]
        var charsByRole: [Message.Role: Int] = [:]

        for message in history.messages {
            countByRole[message.role, default: 0] += 1
            charsByRole[message.role, default: 0] += message.content.count
        }

        func tokens(for role: Message.Role) -> Int {
            (charsByRole[role, default: 0]) / 4
        }

        let totalChars = history.messages.reduce(0) { $0 + $1.content.count }
        let totalTokens = totalChars / 4

        let systemCount = countByRole[.system, default: 0]
        let userCount = countByRole[.user, default: 0]
        let assistantCount = countByRole[.assistant, default: 0]
        let toolCount = countByRole[.tool, default: 0]

                let systemLayerTokens = promptSectionTokenEstimates[.core, default: 0] +
                        promptSectionTokenEstimates[.runtime, default: 0] +
                        promptSectionTokenEstimates[.customization, default: 0]
                let memoryLayerTokens = promptSectionTokenEstimates[.memory, default: 0]
                let skillsLayerTokens = promptSectionTokenEstimates[.skills, default: 0]
                let toolsLayerTokens = promptSectionTokenEstimates[.tools, default: 0]
                let messageTokens = tokens(for: .user) + tokens(for: .assistant) + tokens(for: .tool)
                let contextThreshold = max(currentGenerationConfig.longContextThreshold, contextReserveTokens + 1)
                let targetBudget = max(256, contextThreshold - contextReserveTokens)
                let toolsWarningThreshold = max(500, targetBudget / 3)
                let toolsWarning = toolsLayerTokens > toolsWarningThreshold
                    ? "- Warnings:\n  - tools section is large (\(toolsLayerTokens) tokens; threshold=\(toolsWarningThreshold))."
                    : "- Warnings: none"

        return """
        Context usage (estimated)
        - Messages: \(history.messages.count)
        - Estimated tokens: \(totalTokens)
                - Budget:
                    - threshold: \(contextThreshold)
                    - reserve: \(contextReserveTokens)
                    - target payload budget: \(targetBudget)
                - By category:
                    - system: \(systemLayerTokens) tokens
                    - tools: \(toolsLayerTokens) tokens
                    - memory: \(memoryLayerTokens) tokens
                    - skills: \(skillsLayerTokens) tokens
                    - messages: \(messageTokens) tokens
                    - reserve: \(contextReserveTokens) tokens
        - By role:
          - system: \(systemCount) msg, \(tokens(for: .system)) tokens
          - user: \(userCount) msg, \(tokens(for: .user)) tokens
          - assistant: \(assistantCount) msg, \(tokens(for: .assistant)) tokens
          - tool: \(toolCount) msg, \(tokens(for: .tool)) tokens
        - Runtime:
          - mode: \(mode.rawValue)
          - thinking: \(thinkingLevel.rawValue)
          - task: \(taskType.rawValue)
          - sandbox: \(useSandbox ? "enabled" : "disabled")
          - dry-run: \(dryRun ? "enabled" : "disabled")
          - context transforms: \(contextTransforms.count)
                \(toolsWarning)
        """
    }

    /// Process a side question without affecting the main conversation history.
    ///
    /// The current history snapshot is saved, the question is answered in the
    /// normal generation pipeline, and the history is restored afterwards so
    /// the main task context is completely unaffected.
    ///
    /// - Parameter message: The side question to answer.
    /// - Throws: On model loading or generation errors.
    public func processEphemeralMessage(_ message: String) async throws {
        // AgentLoop is an actor, so all access to `history` is already serialized.
        // Saving and restoring via defer is safe: no concurrent mutation can occur.
        let savedHistory = history
        defer { history = savedHistory }
        try await processUserMessage(message)
    }
}
