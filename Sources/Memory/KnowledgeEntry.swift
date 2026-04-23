// Sources/Memory/KnowledgeEntry.swift
// Data model for durable knowledge entries and restore tiers.

import Foundation

/// Types of knowledge that can be stored for future sessions.
public enum KnowledgeType: String, Codable, CaseIterable, Sendable {
    case sessionState = "session_state"  // What was I working on?
    case plan                             // What's the roadmap?
    case decision                         // What did we decide and why?
    case gotcha                           // What traps exist?
    case pattern                          // What approaches work?
}

/// A single knowledge entry persisted to durable storage.
public struct KnowledgeEntry: Codable, Identifiable, Sendable {
    public let id: UUID
    public let type: KnowledgeType
    public let content: String
    public let tags: [String]           // normalized: lowercase, sorted, deduplicated
    public let surface: String?         // e.g. "ios", "server", "tests" — inferred from workspace path
    public let branch: String?          // git branch at time of logging
    public let projectRoot: String      // absolute path, used for cross-project queries
    public let createdAt: Date
    public let expiresAt: Date?         // nil = permanent; session_state entries get 48h TTL
    
    public init(
        id: UUID = UUID(),
        type: KnowledgeType,
        content: String,
        tags: [String] = [],
        surface: String? = nil,
        branch: String? = nil,
        projectRoot: String,
        createdAt: Date = Date(),
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.type = type
        self.content = content
        self.tags = Self.normalizeTags(tags)
        self.surface = surface
        self.branch = branch
        self.projectRoot = projectRoot
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
    
    /// Normalize tags: lowercase, sorted, deduplicated.
    private static func normalizeTags(_ tags: [String]) -> [String] {
        Array(Set(tags.map { $0.lowercased() })).sorted()
    }

    /// Return a copy with a different project root (used for normalization).
    public func withProjectRoot(_ root: String) -> KnowledgeEntry {
        KnowledgeEntry(
            id: id,
            type: type,
            content: content,
            tags: tags,
            surface: surface,
            branch: branch,
            projectRoot: root,
            createdAt: createdAt,
            expiresAt: expiresAt
        )
    }
}

/// Priority tiers for deterministic restore.
public enum RestoreTier: Int, CaseIterable, Sendable {
    case sessionState = 1    // quota: 4 surface-matched + 2 other, window: 48h
    case plan = 2            // quota: 2, window: all time
    case decision = 3        // quota: 3, window: all time
    case gotchaPattern = 4   // quota: 4 combined, window: all time
    case crossProject = 5    // quota: 2, window: all time
}

/// Context used to query and restore knowledge entries.
public struct RestoreContext: Sendable {
    public let projectRoot: String
    public let surface: String?
    public let branch: String?
    
    public init(projectRoot: String, surface: String? = nil, branch: String? = nil) {
        self.projectRoot = projectRoot
        self.surface = surface
        self.branch = branch
    }
}

/// Result of a deterministic restore operation.
public struct RestoreResult: Sendable {
    public let entries: [KnowledgeEntry]   // ordered by restore tier priority
    public let tokenEstimate: Int          // len/4 approximation
    public let tiersUsed: [RestoreTier: Int]
    
    public init(entries: [KnowledgeEntry], tokenEstimate: Int, tiersUsed: [RestoreTier: Int]) {
        self.entries = entries
        self.tokenEstimate = tokenEstimate
        self.tiersUsed = tiersUsed
    }
}
