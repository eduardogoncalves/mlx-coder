// Sources/Memory/Hybrid/MemoryProvider.swift
// Lifecycle-oriented façade over the hybrid memory stack.
//
// `MemoryProvider` is the seam AgentLoop talks to. It hides the concrete
// store + reflector + reranker wiring behind a small protocol so:
//   * AgentLoop can be unit-tested with `NoopMemoryProvider`,
//   * alternate backends (e.g. a pure-FTS legacy store, or a remote service)
//     can be plugged in without touching AgentLoop,
//   * the reflection / recall / feedback paths each have one well-known
//     entry point instead of being scattered across the codebase.
//
// The protocol is deliberately **side-effect-only** for the post-turn paths
// (reflect, recordFeedback, shutdown). Recall paths return `String?`
// (already-formatted memory blocks) so callers can splice the result into
// the system prompt without depending on `MemoryDocument`.

import Foundation

// MARK: - Context structs

/// Information needed to bootstrap memory at the start of an interactive
/// session. Mirrors what `ChatCommand.restoreMemorySection` already passes
/// to the legacy `KnowledgeRetriever`.
public struct MemoryBootstrapContext: Sendable {
    public var projectRoot: String
    public var branch: String?
    public var surface: String?
    public var sessionID: String?

    public init(
        projectRoot: String,
        branch: String? = nil,
        surface: String? = nil,
        sessionID: String? = nil
    ) {
        self.projectRoot = projectRoot
        self.branch = branch
        self.surface = surface
        self.sessionID = sessionID
    }
}

/// Per-turn recall context. The query is usually the last user message; the
/// other fields scope retrieval to the active project / branch / surface.
public struct MemoryTurnContext: Sendable {
    public var query: String
    public var projectRoot: String
    public var branch: String?
    public var surface: String?
    public var sessionID: String?
    public var taskID: String?
    public var limit: Int

    public init(
        query: String,
        projectRoot: String,
        branch: String? = nil,
        surface: String? = nil,
        sessionID: String? = nil,
        taskID: String? = nil,
        limit: Int = 6
    ) {
        self.query = query
        self.projectRoot = projectRoot
        self.branch = branch
        self.surface = surface
        self.sessionID = sessionID
        self.taskID = taskID
        self.limit = Swift.max(1, limit)
    }
}

/// Identifies which document a feedback signal applies to. Either form is
/// valid; UUID is preferred when available since it survives compaction.
public enum MemoryFeedbackTarget: Sendable, Equatable {
    case documentID(Int64)
    case documentUUID(UUID)
}

// MARK: - Protocol

/// Lifecycle façade for the agent's long-term memory.
///
/// All methods are best-effort: implementations should swallow recoverable
/// errors and return `nil` / no-op rather than throwing into the agent loop.
/// This keeps memory failures from breaking inference.
public protocol MemoryProvider: Sendable {

    /// Open / migrate / warm the underlying store. Called once before the
    /// first user message. Returns an optional formatted memory section
    /// suitable for the initial system prompt (legacy parity with
    /// `restoreMemorySection`).
    func bootstrap(_ context: MemoryBootstrapContext) async -> String?

    /// Look up relevant memories for the current turn. Returns a
    /// pre-formatted markdown block ready to splice into the system prompt,
    /// or `nil` if nothing was found / retrieval is disabled.
    func recallForTurn(_ context: MemoryTurnContext) async -> String?

    /// Drive a reflection cycle. Implementations decide whether to run
    /// extraction synchronously or schedule it on a background task.
    func reflect(_ input: ReflectionInput) async

    /// Apply a feedback signal to a previously-recalled document.
    func recordFeedback(target: MemoryFeedbackTarget, delta: HybridKnowledgeStore.FeedbackDelta) async

    /// Flush any in-flight work and release resources. Called on REPL exit.
    func shutdown() async
}

// MARK: - No-op implementation

/// Default memory provider when the agent is configured without persistent
/// memory. All operations succeed silently and return empty results.
public struct NoopMemoryProvider: MemoryProvider {
    public init() {}

    public func bootstrap(_ context: MemoryBootstrapContext) async -> String? { nil }
    public func recallForTurn(_ context: MemoryTurnContext) async -> String? { nil }
    public func reflect(_ input: ReflectionInput) async {}
    public func recordFeedback(
        target: MemoryFeedbackTarget,
        delta: HybridKnowledgeStore.FeedbackDelta
    ) async {}
    public func shutdown() async {}
}

// MARK: - Hybrid implementation

/// `MemoryProvider` backed by `HybridKnowledgeStore` + `Reflector`.
///
/// Reflection is dispatched to a detached task so the caller (AgentLoop) is
/// never blocked on extraction or LLM rerank work. Errors are logged via the
/// optional `logger` closure but never re-thrown.
public actor HybridMemoryProvider: MemoryProvider {

    public typealias Logger = @Sendable (String) -> Void

    private let store: HybridKnowledgeStore
    private let reflector: Reflector
    private let logger: Logger?
    private let retrieveLimit: Int
    private var bootstrapped = false
    /// Pending reflection tasks so `shutdown()` can await them.
    private var pendingReflections: [Task<Void, Never>] = []

    public init(
        store: HybridKnowledgeStore,
        reflector: Reflector,
        retrieveLimit: Int = 6,
        logger: Logger? = nil
    ) {
        self.store = store
        self.reflector = reflector
        self.retrieveLimit = Swift.max(1, retrieveLimit)
        self.logger = logger
    }

    public func bootstrap(_ context: MemoryBootstrapContext) async -> String? {
        if !bootstrapped {
            do {
                try await store.initialize()
                bootstrapped = true
            } catch {
                logger?("memory.bootstrap.failed: \(error)")
                return nil
            }
        }
        // Best-effort housekeeping at session start.
        _ = try? await store.prune()
        return nil
    }

    public func recallForTurn(_ context: MemoryTurnContext) async -> String? {
        guard bootstrapped else { return nil }
        let scope = RetrievalScope(projectRoot: context.projectRoot)
        do {
            let hits = try await store.retrieve(
                query: context.query,
                scope: scope,
                limit: Swift.min(context.limit, retrieveLimit)
            )
            guard !hits.isEmpty else { return nil }
            return Self.formatRecall(hits: hits)
        } catch {
            logger?("memory.recall.failed: \(error)")
            return nil
        }
    }

    public func reflect(_ input: ReflectionInput) async {
        guard bootstrapped else { return }
        let reflector = self.reflector
        let logger = self.logger
        // Detached so AgentLoop can return to the user immediately.
        let task = Task<Void, Never>.detached(priority: .utility) {
            let outcomes = await reflector.reflect(input)
            if outcomes.isEmpty { return }
            logger?("memory.reflect: \(outcomes.count) outcome(s) processed")
        }
        pendingReflections.append(task)
        _ = Task {
            _ = await task.value
            removePendingReflection(task)
        }
    }

    private func removePendingReflection(_ task: Task<Void, Never>) {
        pendingReflections.removeAll { $0 == task }
    }

    public func recordFeedback(
        target: MemoryFeedbackTarget,
        delta: HybridKnowledgeStore.FeedbackDelta
    ) async {
        guard bootstrapped else { return }
        do {
            switch target {
            case .documentID(let id):
                _ = try await store.recordFeedback(documentID: id, delta: delta)
            case .documentUUID(let uuid):
                _ = try await store.recordFeedback(documentUUID: uuid, delta: delta)
            }
        } catch {
            logger?("memory.feedback.failed: \(error)")
        }
    }

    public func shutdown() async {
        // Wait for in-flight reflections to finish before closing the DB.
        for task in pendingReflections { _ = await task.value }
        pendingReflections.removeAll()
        await store.close()
    }

    // MARK: - Formatting

    static func formatRecall(hits: [ScoredDocument]) -> String? {
        guard !hits.isEmpty else { return nil }
        var lines: [String] = []
        lines.append("## Relevant memory")
        for (idx, hit) in hits.enumerated() {
            let kind = hit.document.knowledgeKind.rawValue
            let score = String(format: "%.2f", hit.finalScore)
            let snippet = hit.document.content
                .components(separatedBy: .newlines)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            lines.append("\(idx + 1). [\(kind) · \(score)] \(snippet)")
        }
        return lines.joined(separator: "\n")
    }
}
