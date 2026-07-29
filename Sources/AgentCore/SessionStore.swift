// Sources/AgentCore/SessionStore.swift
// On-disk persistence for resumable chat sessions.
//
// Every interactive TUI session is auto-saved to `~/.mlx-coder/sessions/<id>.json`
// after each completed turn, so a session can be restored later with
// `mlx-coder chat --resume <id>` or the in-session `/resume` picker (Claude
// Code-style). Only the conversation body is stored — the system prompt is
// re-derived from the live environment on resume, never restored from a
// stale snapshot.

import Foundation

/// Lightweight metadata for one persisted session, used to render the `/resume`
/// picker without decoding every message.
public struct SessionSummary: Sendable, Equatable {
    public let id: String
    public let updatedAt: Date
    public let cwd: String
    public let model: String
    /// First human message, trimmed to a single readable line.
    public let title: String
    public let messageCount: Int
}

/// Full on-disk representation of a session.
public struct PersistedSession: Codable, Sendable {
    public var version: Int
    public var id: String
    public var createdAt: Date
    public var updatedAt: Date
    public var cwd: String
    public var model: String
    public var title: String
    public var messages: [Message]

    public init(
        version: Int = 1,
        id: String,
        createdAt: Date,
        updatedAt: Date,
        cwd: String,
        model: String,
        title: String,
        messages: [Message]
    ) {
        self.version = version
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.cwd = cwd
        self.model = model
        self.title = title
        self.messages = messages
    }
}

/// Manages the `~/.mlx-coder/sessions/` directory.
public enum SessionStore {

    /// Directory holding session files. Created on demand. Honors the
    /// `MLX_CODER_SESSIONS_DIR` environment override (used by tests) so a run
    /// never has to touch the real `~/.mlx-coder/sessions/`.
    public static func directory() -> URL {
        if let override = ProcessInfo.processInfo.environment["MLX_CODER_SESSIONS_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".mlx-coder", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// File path for a given session id.
    public static func url(for id: String) -> URL {
        directory().appendingPathComponent("\(id).json", isDirectory: false)
    }

    /// Persist a session. No-op (and no file written) when the transcript has no
    /// human turn yet, so empty sessions never clutter the picker. When a file
    /// already exists its original `createdAt` is preserved.
    ///
    /// - Returns: the written file URL, or `nil` when nothing was worth saving.
    @discardableResult
    public static func save(
        id: String,
        cwd: String,
        model: String,
        messages: [Message]
    ) -> URL? {
        let body = messages.filter { $0.role != .system }
        guard body.contains(where: { $0.role == .user && $0.origin == .human }) else {
            return nil
        }

        let dir = directory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = url(for: id)

        let now = Date()
        let createdAt = (try? load(id: id))?.createdAt ?? now
        let session = PersistedSession(
            id: id,
            createdAt: createdAt,
            updatedAt: now,
            cwd: cwd,
            model: model,
            title: title(from: body),
            messages: body
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(session) else { return nil }
        do {
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            return nil
        }
    }

    /// Decode a full session by id.
    public static func load(id: String) throws -> PersistedSession {
        let data = try Data(contentsOf: url(for: id))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(PersistedSession.self, from: data)
    }

    /// Summaries of persisted sessions, newest first. When `cwd` is non-nil, only
    /// sessions started in that working directory are returned (like Claude Code,
    /// which scopes `/resume` to the current project).
    public static func list(cwd: String? = nil) -> [SessionSummary] {
        let dir = directory()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        var summaries: [SessionSummary] = []
        for entry in entries where entry.pathExtension == "json" {
            guard let data = try? Data(contentsOf: entry),
                  let session = try? decoder.decode(PersistedSession.self, from: data) else {
                continue
            }
            if let cwd, session.cwd != cwd { continue }
            summaries.append(SessionSummary(
                id: session.id,
                updatedAt: session.updatedAt,
                cwd: session.cwd,
                model: session.model,
                title: session.title,
                messageCount: session.messages.count
            ))
        }
        return summaries.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Most recent session for a directory, used by `--continue`.
    public static func mostRecent(cwd: String? = nil) -> SessionSummary? {
        list(cwd: cwd).first
    }

    /// Derive a one-line title from the first human message.
    static func title(from messages: [Message]) -> String {
        let first = messages.first(where: { $0.role == .user && $0.origin == .human })?.content ?? ""
        let collapsed = first
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count > 72 {
            return String(collapsed.prefix(72)) + "…"
        }
        return collapsed.isEmpty ? "(untitled session)" : collapsed
    }
}
