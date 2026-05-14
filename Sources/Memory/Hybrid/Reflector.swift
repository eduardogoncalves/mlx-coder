// Sources/Memory/Hybrid/Reflector.swift
// Self-improvement loop driver — extracts learnings, decides append vs supersede,
// schedules consolidation/decay. Inspired by Hermes' background review agent.

import Foundation

/// Why a reflection cycle was triggered.
public enum ReflectionTrigger: Sendable, Equatable {
    /// A turn (or batch of turns) completed normally.
    case turnCompleted(turnIndex: Int)
    /// The agent reached a cadence threshold (every N turns).
    case cadence(everyNTurns: Int, currentCount: Int)
    /// A tool failure / retry cluster fired during the turn.
    case failure(reason: String)
    /// User-supplied feedback — usually a correction to remember.
    case userFeedback(text: String)
    /// A long-running session is wrapping up (compression / `/clear`).
    case sessionEnd
}

/// One candidate piece of knowledge extracted from a turn.
public struct ReflectionCandidate: Sendable {
    public var memoryType: MemoryType
    public var knowledgeKind: KnowledgeKind
    public var content: String
    public var tags: [String]
    public var entities: [String]
    public var confidence: Double
    public var importance: Double

    public init(
        memoryType: MemoryType,
        knowledgeKind: KnowledgeKind,
        content: String,
        tags: [String] = [],
        entities: [String] = [],
        confidence: Double = 0.5,
        importance: Double = 0.5
    ) {
        self.memoryType = memoryType
        self.knowledgeKind = knowledgeKind
        self.content = content
        self.tags = tags
        self.entities = entities
        self.confidence = confidence
        self.importance = importance
    }
}

/// Source signal a candidate extractor consumes. Mirrors the surface of
/// `AgentLoop` without requiring it as a dependency, so the reflector can
/// be unit-tested in isolation.
public struct ReflectionInput: Sendable {
    public var trigger: ReflectionTrigger
    public var projectRoot: String
    public var branch: String?
    public var surface: String?
    public var sessionID: String?
    public var taskID: String?
    /// Most recent assistant turns (raw text). Kept small (≤ a few KB).
    public var recentAssistantText: [String]
    /// Most recent user turns.
    public var recentUserText: [String]
    /// Optional explicit candidates supplied by the caller (e.g. when the
    /// LLM itself proposes memories via a tool).
    public var explicitCandidates: [ReflectionCandidate]

    public init(
        trigger: ReflectionTrigger,
        projectRoot: String,
        branch: String? = nil,
        surface: String? = nil,
        sessionID: String? = nil,
        taskID: String? = nil,
        recentAssistantText: [String] = [],
        recentUserText: [String] = [],
        explicitCandidates: [ReflectionCandidate] = []
    ) {
        self.trigger = trigger
        self.projectRoot = projectRoot
        self.branch = branch
        self.surface = surface
        self.sessionID = sessionID
        self.taskID = taskID
        self.recentAssistantText = recentAssistantText
        self.recentUserText = recentUserText
        self.explicitCandidates = explicitCandidates
    }
}

/// Pluggable extractor — turn raw turn-text into candidate memories.
///
/// Default implementation (`HeuristicCandidateExtractor`) is intentionally
/// lightweight (regex/keyword based) so the reflection loop has a usable
/// fallback when no LLM-backed extractor is wired in.
public protocol CandidateExtractor: Sendable {
    func extract(from input: ReflectionInput) async -> [ReflectionCandidate]
}

/// Outcome of a reflection cycle (one entry per processed candidate).
public struct ReflectionOutcome: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case inserted(uuid: UUID)
        case superseded(oldUUID: UUID, newUUID: UUID)
        case duplicate(uuid: UUID)
        case skipped(reason: String)
    }
    public let candidate: ReflectionCandidate
    public let action: Action

    public init(candidate: ReflectionCandidate, action: Action) {
        self.candidate = candidate
        self.action = action
    }
}

/// Cadence + trigger gating: returns true when a reflection cycle should run.
///
/// Mirrors Hermes' `memory.nudge_interval` — every N user turns, plus
/// always-on triggers for failure / userFeedback / sessionEnd.
public struct ReflectionCadence: Sendable {
    public var nudgeInterval: Int
    public var minContentChars: Int

    public init(nudgeInterval: Int = 6, minContentChars: Int = 24) {
        self.nudgeInterval = max(1, nudgeInterval)
        self.minContentChars = minContentChars
    }

    public func shouldFire(_ trigger: ReflectionTrigger) -> Bool {
        switch trigger {
        case .turnCompleted:
            return false  // wait for cadence to fire
        case .cadence(let every, let count):
            return count > 0 && count % every == 0
        case .failure, .userFeedback, .sessionEnd:
            return true
        }
    }
}

/// Reflection driver — orchestrates extraction → write → consolidation.
public actor Reflector {

    private let store: HybridKnowledgeStore
    private let extractor: CandidateExtractor
    private let cadence: ReflectionCadence

    public init(
        store: HybridKnowledgeStore,
        extractor: CandidateExtractor = HeuristicCandidateExtractor(),
        cadence: ReflectionCadence = ReflectionCadence()
    ) {
        self.store = store
        self.extractor = extractor
        self.cadence = cadence
    }

    /// Run a reflection pass. Safe to call from a background task.
    /// Returns one outcome per candidate that was processed.
    @discardableResult
    public func reflect(_ input: ReflectionInput) async -> [ReflectionOutcome] {
        guard cadence.shouldFire(input.trigger) else { return [] }

        var candidates = await extractor.extract(from: input)
        candidates.append(contentsOf: input.explicitCandidates)

        // Filter out empty / too-short content
        candidates = candidates.filter {
            $0.content.trimmingCharacters(in: .whitespacesAndNewlines).count
                >= cadence.minContentChars
        }
        guard !candidates.isEmpty else { return [] }

        var outcomes: [ReflectionOutcome] = []
        outcomes.reserveCapacity(candidates.count)

        for candidate in candidates {
            let docInput = DocumentInput(
                memoryType: candidate.memoryType,
                knowledgeKind: candidate.knowledgeKind,
                content: candidate.content,
                source: .reflection,
                projectRoot: input.projectRoot,
                branch: input.branch,
                surface: input.surface,
                tags: candidate.tags,
                entities: candidate.entities,
                sessionID: input.sessionID,
                taskID: input.taskID,
                confidence: candidate.confidence,
                importance: candidate.importance,
                ttl: candidate.memoryType == .working ? 24 * 3600 : nil
            )
            do {
                let outcome = try await store.write(docInput)
                switch outcome {
                case .inserted(_, let uuid):
                    outcomes.append(.init(candidate: candidate, action: .inserted(uuid: uuid)))
                case .superseded(let oldID, _, let uuid):
                    let oldUUID = (try? await fetchUUID(forID: oldID)) ?? uuid
                    outcomes.append(.init(candidate: candidate,
                                          action: .superseded(oldUUID: oldUUID, newUUID: uuid)))
                case .duplicate(_, let uuid):
                    outcomes.append(.init(candidate: candidate, action: .duplicate(uuid: uuid)))
                }
            } catch {
                outcomes.append(.init(candidate: candidate,
                                      action: .skipped(reason: "\(error)")))
            }
        }

        // Best-effort housekeeping: consolidation + prune. Non-fatal.
        if case .sessionEnd = input.trigger {
            _ = try? await store.consolidate(scope: RetrievalScope(projectRoot: input.projectRoot))
            _ = try? await store.prune()
        }

        return outcomes
    }

    private func fetchUUID(forID id: Int64) async throws -> UUID {
        // Helper retained for symmetry with the supersede outcome shape; we
        // intentionally do not expose a public lookup-by-id from the store
        // (the supersede path returns the new UUID directly, and the old
        // UUID is only used for observability). If we ever need the real
        // value, route through `HybridKnowledgeStore.fetchDocuments(ids:)`.
        _ = id
        return UUID()
    }
}

// MARK: - Default heuristic extractor

/// Bare-minimum extractor: scans the latest assistant turn for actionable
/// statements (decisions, gotchas, plans). Replace with an LLM-backed
/// extractor for higher-quality memories — the protocol is the seam.
public struct HeuristicCandidateExtractor: CandidateExtractor {

    public init() {}

    public func extract(from input: ReflectionInput) async -> [ReflectionCandidate] {
        var candidates: [ReflectionCandidate] = []

        // 1) explicit user feedback ⇒ high-importance, high-confidence semantic note
        if case .userFeedback(let text) = input.trigger {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                candidates.append(ReflectionCandidate(
                    memoryType: .semantic,
                    knowledgeKind: .decision,
                    content: trimmed,
                    tags: ["user-feedback"],
                    confidence: 0.85,
                    importance: 0.9
                ))
            }
        }

        // 2) failure summary ⇒ episodic gotcha
        if case .failure(let reason) = input.trigger {
            let cleaned = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                candidates.append(ReflectionCandidate(
                    memoryType: .episodic,
                    knowledgeKind: .gotcha,
                    content: "Tool failure observed: \(cleaned)",
                    tags: ["failure"],
                    confidence: 0.6,
                    importance: 0.7
                ))
            }
        }

        // 3) scan the most recent assistant text for actionable lines
        let actionMarkers = ["decided to", "we should", "always ", "never ",
                             "next step", "next, ", "gotcha", "watch out",
                             "remember to", "use ", "prefer "]
        for assistantTurn in input.recentAssistantText.suffix(2) {
            for rawLine in assistantTurn.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard line.count >= 24 && line.count <= 400 else { continue }
                let lower = line.lowercased()
                guard actionMarkers.contains(where: { lower.contains($0) }) else { continue }

                let kind: KnowledgeKind
                if lower.contains("gotcha") || lower.contains("watch out") {
                    kind = .gotcha
                } else if lower.contains("next step") || lower.contains("next, ") {
                    kind = .plan
                } else if lower.contains("always ") || lower.contains("never ") || lower.contains("prefer ") {
                    kind = .pattern
                } else {
                    kind = .decision
                }
                candidates.append(ReflectionCandidate(
                    memoryType: .episodic,
                    knowledgeKind: kind,
                    content: line,
                    confidence: 0.4,
                    importance: 0.5
                ))
            }
        }

        return candidates
    }
}
