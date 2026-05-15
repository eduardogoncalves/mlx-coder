// Sources/Memory/Hybrid/HybridDocument.swift
// Data model for the hybrid SQLite memory stack (documents + metadata).

import Foundation

/// Top-level memory class.
///
/// - episodic: per-turn or per-session experiences (high churn, decays)
/// - semantic: distilled long-lived knowledge (low churn, stable)
/// - working: short-lived scratch state with hard TTL
public enum MemoryType: String, Codable, CaseIterable, Sendable {
    case episodic
    case semantic
    case working
}

/// Knowledge sub-classification within a memory type.
/// Aligns with the existing `KnowledgeType` cases plus `summary`.
public enum KnowledgeKind: String, Codable, CaseIterable, Sendable {
    case decision
    case gotcha
    case pattern
    case plan
    case sessionState = "session_state"
    case summary

    /// All knowledge kinds that participate in normal (persistent) retrieval.
    /// Excludes `.sessionState`, which is scratch context with TTL; callers
    /// that need session state in their results must opt in explicitly.
    public static let persistentKinds: [KnowledgeKind] =
        allCases.filter { $0 != .sessionState }
}

/// Lifecycle status for a document.
public enum DocumentStatus: String, Codable, CaseIterable, Sendable {
    case active
    case superseded
    case archived
    case deleted
}

/// Provenance tag for the writer that produced the document.
public enum DocumentSource: String, Codable, CaseIterable, Sendable {
    case user
    case assistant
    case tool
    case reflection
    case `import`
}

/// Input shape for `HybridKnowledgeStore.write`.
public struct DocumentInput: Sendable {
    public var memoryType: MemoryType
    public var knowledgeKind: KnowledgeKind
    public var content: String
    public var source: DocumentSource
    public var projectRoot: String
    public var branch: String?
    public var surface: String?
    public var tags: [String]
    public var entities: [String]
    public var sessionID: String?
    public var taskID: String?
    public var confidence: Double
    public var importance: Double
    public var ttl: TimeInterval?

    public init(
        memoryType: MemoryType,
        knowledgeKind: KnowledgeKind,
        content: String,
        source: DocumentSource,
        projectRoot: String,
        branch: String? = nil,
        surface: String? = nil,
        tags: [String] = [],
        entities: [String] = [],
        sessionID: String? = nil,
        taskID: String? = nil,
        confidence: Double = 0.5,
        importance: Double = 0.5,
        ttl: TimeInterval? = nil
    ) {
        self.memoryType = memoryType
        self.knowledgeKind = knowledgeKind
        self.content = content
        self.source = source
        self.projectRoot = projectRoot
        self.branch = branch
        self.surface = surface
        self.tags = tags
        self.entities = entities
        self.sessionID = sessionID
        self.taskID = taskID
        self.confidence = confidence.clampedUnit
        self.importance = importance.clampedUnit
        self.ttl = ttl
    }
}

/// Persisted memory document row joined with its metadata.
public struct MemoryDocument: Sendable, Identifiable {
    public let id: Int64
    public let uuid: UUID
    public let memoryType: MemoryType
    public let knowledgeKind: KnowledgeKind
    public let content: String
    public let contentHash: String
    public let source: DocumentSource
    public let projectRoot: String
    public let branch: String?
    public let surface: String?
    public let confidence: Double
    public let importance: Double
    public let status: DocumentStatus
    public let version: Int
    public let supersedesID: Int64?
    public let createdAt: Date
    public let updatedAt: Date
    public let expiresAt: Date?
    public let lastAccessAt: Date?
    public let accessCount: Int
    public let tags: [String]
    public let entities: [String]
    public let sessionID: String?
    public let taskID: String?
    public let feedbackScore: Double?

    public init(
        id: Int64,
        uuid: UUID,
        memoryType: MemoryType,
        knowledgeKind: KnowledgeKind,
        content: String,
        contentHash: String,
        source: DocumentSource,
        projectRoot: String,
        branch: String?,
        surface: String?,
        confidence: Double,
        importance: Double,
        status: DocumentStatus,
        version: Int,
        supersedesID: Int64?,
        createdAt: Date,
        updatedAt: Date,
        expiresAt: Date?,
        lastAccessAt: Date?,
        accessCount: Int,
        tags: [String],
        entities: [String],
        sessionID: String?,
        taskID: String?,
        feedbackScore: Double?
    ) {
        self.id = id
        self.uuid = uuid
        self.memoryType = memoryType
        self.knowledgeKind = knowledgeKind
        self.content = content
        self.contentHash = contentHash
        self.source = source
        self.projectRoot = projectRoot
        self.branch = branch
        self.surface = surface
        self.confidence = confidence
        self.importance = importance
        self.status = status
        self.version = version
        self.supersedesID = supersedesID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
        self.lastAccessAt = lastAccessAt
        self.accessCount = accessCount
        self.tags = tags
        self.entities = entities
        self.sessionID = sessionID
        self.taskID = taskID
        self.feedbackScore = feedbackScore
    }
}

/// Scoring container surfaced from retrieval pipelines.
public struct ScoredDocument: Sendable {
    public var document: MemoryDocument
    public var lexicalScore: Double?
    public var semanticScore: Double?
    public var fusedScore: Double
    public var rerankScore: Double?

    public init(
        document: MemoryDocument,
        lexicalScore: Double? = nil,
        semanticScore: Double? = nil,
        fusedScore: Double = 0,
        rerankScore: Double? = nil
    ) {
        self.document = document
        self.lexicalScore = lexicalScore
        self.semanticScore = semanticScore
        self.fusedScore = fusedScore
        self.rerankScore = rerankScore
    }

    /// Final score used for ordering: rerank if present, else fused.
    public var finalScore: Double { rerankScore ?? fusedScore }
}

/// Scope filter used when retrieving documents.
public struct RetrievalScope: Sendable {
    public var projectRoot: String
    public var memoryTypes: [MemoryType]
    public var knowledgeKinds: [KnowledgeKind]
    public var includeSuperseded: Bool

    public init(
        projectRoot: String,
        memoryTypes: [MemoryType] = [.episodic, .semantic],
        knowledgeKinds: [KnowledgeKind] = KnowledgeKind.persistentKinds,
        includeSuperseded: Bool = false
    ) {
        self.projectRoot = projectRoot
        self.memoryTypes = memoryTypes
        self.knowledgeKinds = knowledgeKinds
        self.includeSuperseded = includeSuperseded
    }
}

extension Double {
    fileprivate var clampedUnit: Double { Swift.min(1.0, Swift.max(0.0, self)) }
}
