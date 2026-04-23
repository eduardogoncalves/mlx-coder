// Sources/AgentCore/AgentLoop+ContextManagement.swift
// Context transforms, steering queue, follow-up queue, and deterministic compaction.

import Foundation

extension AgentLoop {

    // MARK: - Steering & Follow-up

    /// Queues a steering message to be injected before the next generation turn within the
    /// current run. Steering messages let you redirect the agent mid-run — they are consumed
    /// between tool-execution rounds, before the model generates its next response.
    public func steer(_ message: String) {
        steeringQueue.append(message)
    }

    /// Returns the pending steering messages without consuming them.
    public func pendingSteeringMessages() -> [String] {
        steeringQueue
    }

    /// Clears all pending steering messages.
    public func clearSteeringQueue() {
        steeringQueue.removeAll()
    }

    /// Queues a follow-up message for automatic processing after the current run completes.
    /// The CLI drains this queue and calls `processUserMessage` for each entry without
    /// requiring the user to type anything.
    public func queueFollowUp(_ message: String) {
        followUpQueue.append(message)
    }

    /// Dequeues and returns the next follow-up message, or `nil` if the queue is empty.
    public func dequeueFollowUp() -> String? {
        guard !followUpQueue.isEmpty else { return nil }
        return followUpQueue.removeFirst()
    }

    /// Dequeues all pending follow-ups at once and clears the queue in O(1).
    /// Prefer this over calling `dequeueFollowUp()` in a loop.
    public func drainFollowUpQueue() -> [String] {
        let all = followUpQueue
        followUpQueue.removeAll()
        return all
    }

    /// Returns the pending follow-up messages without consuming them.
    public func pendingFollowUps() -> [String] {
        followUpQueue
    }

    /// Clears all pending follow-up messages.
    public func clearFollowUpQueue() {
        followUpQueue.removeAll()
    }

    // MARK: - Context Transforms

    /// Registers a context transform that is applied to the message list before every model
    /// generation call. Transforms are applied in registration order and receive a snapshot —
    /// they never mutate the stored history.
    ///
    /// **Common uses:**
    /// - Memory injection: retrieve relevant documents and prepend them as synthetic user messages.
    /// - Dynamic pruning: drop old tool-result messages that are no longer relevant.
    /// - Context enrichment: inject a live file snapshot, git diff, or environment state.
    ///
    /// Example (memory injection):
    /// ```swift
    /// agentLoop.addContextTransform { messages in
    ///     let query  = messages.last?.content ?? ""
    ///     let recalled = await myVectorStore.retrieve(query: query, topK: 3)
    ///     var out = messages
    ///     let injection = Message(role: .user, content: "[Memory]\n\(recalled.joined(separator: "\n"))")
    ///     out.insert(injection, at: out.endIndex - 1)
    ///     return out
    /// }
    /// ```
    public func addContextTransform(_ transform: @escaping ContextTransform) {
        contextTransforms.append(transform)
    }

    /// Removes all registered context transforms.
    public func removeAllContextTransforms() {
        contextTransforms.removeAll()
    }

    /// Returns the number of currently registered context transforms.
    public var contextTransformCount: Int {
        contextTransforms.count
    }

    // MARK: - Deterministic Context Compaction

    func applyDeterministicContextCompactionIfNeeded(reason: String) async {
        let threshold = max(currentGenerationConfig.longContextThreshold, contextReserveTokens + 1)
        let target = max(256, threshold - contextReserveTokens)

        // Use the real tokenizer for accurate token counts when the model is loaded.
        // We snapshot message contents, compute counts inside perform (which is Sendable-safe),
        // then use a lookup table as the tokenCounter closure to avoid capturing non-Sendable state.
        let contentSnapshot = history.messages.map(\.content)
        let tokenCounts: [Int]? = if let modelContainer {
            await modelContainer.perform { context in
                contentSnapshot.map { context.tokenizer.encode(text: $0).count }
            }
        } else {
            nil
        }

        let tokenCounter: ((String) -> Int)?
        if let counts = tokenCounts {
            // Build a lookup from content → token count. Falls back to chars/4 for content not
            // in the snapshot (shouldn't happen, but safe).
            let lookup = LoopDetectionService.makeTokenCountLookup(contents: contentSnapshot, counts: counts)
            tokenCounter = { text in lookup[text] ?? (text.count / 4) }
        } else {
            tokenCounter = nil
        }

        let currentTokens = tokenCounter.map { counter in
            history.messages.reduce(0) { $0 + counter($1.content) }
        } ?? history.estimatedTokenCount

        guard currentTokens > target else { return }

        let before = currentTokens
        let compacted = history.compactByTurns(
            maxTokens: target,
            keepRecentTurns: contextKeepRecentTurns,
            tokenCounter: tokenCounter
        )
        guard compacted else { return }

        // Re-snapshot after compaction for the "after" count.
        let afterContentSnapshot = history.messages.map(\.content)
        let after: Int
        if let modelContainer {
            let afterCounts = await modelContainer.perform { context in
                afterContentSnapshot.map { context.tokenizer.encode(text: $0).count }
            }
            after = afterCounts.reduce(0, +)
        } else {
            after = history.estimatedTokenCount
        }

        renderer.printStatus("[Context] Turn-aware compaction triggered (\(reason)): before≈\(before), after≈\(after), target≈\(target)")
        await hooks.emit(.compression(toolName: "context_history", beforeTokens: before, afterTokens: after, usedFallback: false))
    }
}
