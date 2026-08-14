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

    /// Rebinds this loop's KV-cache slot-persistence id — call after
    /// `restoreConversation` on `/resume` so the restored conversation reuses
    /// its original remote slot-cache filename instead of minting a new
    /// (empty) one under this process's fresh `sessionId`.
    public func rebindKVCachePersistenceId(_ id: String) {
        kvCachePersistenceId = id
    }

    /// Queues a remote slot restore for the next remote generation, sourced
    /// from a persisted session's saved slot info. `sessionModelPath` is the
    /// `activeModelPath` the slot was saved under (`PersistedSession.model`);
    /// the restore is dropped unless it still matches the currently active
    /// model, since restoring one model's KV cache into another's slot would
    /// just feed it garbage context.
    public func primeRemoteSlotRestore(sessionModelPath: String, idSlot: Int, filename: String) {
        guard sessionModelPath == modelPath else { return }
        pendingRemoteSlotRestore = (idSlot: idSlot, filename: filename)
    }

    /// The active remote backend's slot id + cache filename, snapshotted for
    /// persisting alongside a saved session — nil unless a `saveSlot` call has
    /// actually succeeded this run (local backend, or a server without
    /// `--slot-save-path` configured, both leave this nil).
    public var remoteSlotSnapshot: (idSlot: Int, filename: String)? {
        guard remoteSlotHasSavedCache, let remoteSlotId else { return nil }
        return (idSlot: remoteSlotId, filename: kvCacheSlotFilename)
    }
}
