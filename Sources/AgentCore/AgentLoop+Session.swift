// Sources/AgentCore/AgentLoop+Session.swift
// Bridges the AgentLoop actor to SessionStore for resumable sessions.

import Foundation
import MLX

extension AgentLoop {

    /// The conversation body (without the system prompt) for persistence.
    public var persistableConversation: [Message] {
        history.persistableMessages
    }

    /// The carrier string identifying the active model (round-trips through
    /// `InferenceBackend`). Recorded alongside a saved session for display.
    public var activeModelPath: String {
        modelPath
    }

    /// Restore a previously-saved conversation body, keeping this launch's
    /// freshly-derived system prompt in place. The MLX KV cache is dropped so
    /// the next turn re-prefills against the restored history rather than a
    /// stale cache from whatever was in context before.
    public func restoreConversation(_ messages: [Message]) {
        history.restoreConversation(messages)
        // The live KV / prompt cache was built for the pre-restore context; drop
        // it so the next turn re-prefills against the restored history.
        promptCache.invalidate(reason: "session restored")
        MLX.Memory.clearCache()
        frontend.emitStatus("Restored \(messages.count) message(s) from a saved session")
    }
}
