// Sources/AgentFrontend/AgentEvent.swift
// Typed semantic events emitted by AgentCore to any presentation layer
// (terminal, TUI, GUI). The frontend is the *only* consumer of these
// events — AgentCore must never reach into renderers directly.

import Foundation

// MARK: - AgentEvent

/// Semantic events the agent emits while running.
///
/// Every event is a pure value (`Sendable`) so the agent (an `actor`) can
/// hand them across the boundary without bridging concerns. Adapters render
/// each case in whatever idiom suits the surface (raw text, scroll lines,
/// status bar updates, GUI widgets, …).
public enum AgentEvent: Sendable {

    // MARK: Streaming text

    /// A chunk of visible assistant text (post-think-stripping).
    case assistantTextChunk(String)

    /// A chunk of content inside an open `<think>` block.
    case thinkingChunk(String)

    // MARK: Tool execution

    /// A tool call has been parsed from the model output and is about to
    /// execute (or has just been requested via the streamed-edit fast path).
    case toolCallStarted(ToolCallSnapshot)

    /// A tool call finished. `result` carries success/error and rendered
    /// content suitable for display.
    case toolCallResult(ToolResultSnapshot)

    // MARK: Lifecycle / status

    /// A short transient status line (info / success / warning).
    case status(StatusMessage)

    /// A surfaced error message.
    case error(String)

    /// End-of-generation token / throughput stats.
    case stats(StatsSnapshot)

    /// Working / thinking / task mode changed.
    case modeChanged(ModeSnapshot)

    /// Model loading lifecycle (loading, ready, reload, unload, switch).
    case modelLifecycle(ModelLifecycleEvent)

    /// Memory subsystem event (save/load/search/list/etc).
    case memoryEvent(MemoryEvent)

    /// Build-check progress.
    case buildCheck(BuildCheckEvent)

    /// Git orchestration progress (worktree, branch, merge, completion).
    case gitOrchestration(GitOrchestrationEvent)

    /// History compaction happened.
    case contextCompaction(before: Int, after: Int, target: Int, reason: String)

    /// Prompt/token processing lifecycle. This wraps prompt encoding and
    /// preparation *before* inference begins.
    case tokenProcessingActivity(ActivityLifecycle)

    /// Inference lifecycle. `.started` means the token stream has opened.
    /// `.ended` means the stream is drained.
    case generationActivity(ActivityLifecycle)

    /// `<think>` lifecycle nested inside generation.
    case thinkingActivity(ActivityLifecycle)

    /// Fired once per turn when the prompt token count is known (after
    /// tokenisation, before the first generated token). Used to display
    /// the ↑ count in the processing spinner.
    case promptTokensKnown(Int)

    /// A `TaskTool`-delegated sub-agent (internal agent) started or finished
    /// running. Lets the spinner/status UI show which agent/profile and model
    /// are currently generating, since sub-agents share the parent's frontend
    /// and can use a different model than the orchestrator's own.
    case subAgentActivity(SubAgentActivity)

    /// Progress of a deterministic `WorkflowEngine` run. Unlike prompt-steered
    /// delegation (where the model decides the order), a workflow's stage
    /// sequence is fixed in code, so the frontend can show exactly which stage
    /// of which pipeline is running, was skipped, or finished.
    case workflowStep(WorkflowStepEvent)
}

/// Lifecycle of a single stage in a deterministic `WorkflowEngine` pipeline.
/// `index`/`total` are 1-based for display (e.g. "step 2/4").
public enum WorkflowStepEvent: Sendable, Equatable {
    case started(workflow: String, step: String, index: Int, total: Int, profile: String)
    case finished(workflow: String, step: String, status: String)
    case skipped(workflow: String, step: String, reason: String)
    case completed(workflow: String, succeeded: Bool, stepsRun: Int)
}

/// Lifecycle of a `TaskTool`-delegated sub-agent run, carrying enough context
/// (profile + model) for a frontend to label its spinner/status UI while the
/// sub-agent is generating. Sub-agents cannot themselves spawn further
/// sub-agents (max depth 1), so at most one is ever active at a time.
public enum SubAgentActivity: Sendable, Equatable {
    case started(profile: String, modelPath: String)
    case ended
}

// MARK: - Snapshots

/// Lightweight, `Sendable` view of a tool invocation request.
public struct ToolCallSnapshot: Sendable {
    public let name: String
    /// JSON-encodable representation of arguments (string→string for
    /// portability across UIs that don't render arbitrary types).
    public let arguments: [String: String]
    public init(name: String, arguments: [String: String]) {
        self.name = name
        self.arguments = arguments
    }
}

/// Lightweight, `Sendable` view of a tool result.
public struct ToolResultSnapshot: Sendable {
    public let toolName: String
    public let isError: Bool
    public let content: String
    public let truncationMarker: String?
    public init(toolName: String, isError: Bool, content: String, truncationMarker: String? = nil) {
        self.toolName = toolName
        self.isError = isError
        self.content = content
        self.truncationMarker = truncationMarker
    }
}

public struct StatusMessage: Sendable {
    public enum Severity: Sendable, Equatable { case info, success, warning, debug }
    public let severity: Severity
    public let text: String
    public init(_ text: String, severity: Severity = .info) {
        self.text = text
        self.severity = severity
    }

    /// Leading sentinel (a bare ESC) shared by every *control* status — a
    /// `.status` whose text is a machine-readable instruction to the display
    /// layer, never user-facing prose. A frontend that doesn't recognize a
    /// given control prefix must silently drop it rather than print it.
    public static let controlChannelSentinel = "\u{001B}"

    /// Prefix marking a `.status` line as a *tool progress phase* (e.g.
    /// web_fetch's "fetching" / "extracting" steps) rather than a transcript
    /// line. Frontends that render their own footer spinner
    /// (`AgentFrontend.rendersOwnToolSpinner`) intercept these to update the
    /// spinner label in place instead of printing them into the scroll area.
    /// The remaining text after the prefix is the human-readable phase.
    public static let toolProgressPrefix = "\u{001B}toolphase\u{001B} "

    /// Prefix marking a `.status` line as a *steering-queue depth* update. The
    /// remaining text is the new pending count as a decimal integer. Emitted
    /// whenever AgentCore drains queued steering messages mid-run so a
    /// frontend showing a "[N queued]" badge can update it the moment the
    /// messages are consumed, rather than only when the whole turn ends.
    public static let steeringQueuePrefix = "\u{001B}steerqueue\u{001B} "

    /// Whether `text` is a control status (see `controlChannelSentinel`) that
    /// non-handling frontends must drop instead of rendering.
    public var isControlChannel: Bool { text.hasPrefix(StatusMessage.controlChannelSentinel) }
}

public struct StatsSnapshot: Sendable {
    public let generationTokens: Int
    public let tokensPerSecond: Double
    public let promptTokens: Int
    public let promptTokensPerSecond: Double
    /// Wall-clock time this round of generation took. Drives the elapsed
    /// segment of `formatted`; 0 renders as `0.0s`.
    public let elapsed: TimeInterval
    public init(
        generationTokens: Int,
        tokensPerSecond: Double,
        promptTokens: Int,
        promptTokensPerSecond: Double,
        elapsed: TimeInterval = 0
    ) {
        self.generationTokens = generationTokens
        self.tokensPerSecond = tokensPerSecond
        self.promptTokens = promptTokens
        self.promptTokensPerSecond = promptTokensPerSecond
        self.elapsed = elapsed
    }

    /// Canonical one-line render — `↑ <prompt> · ↓ <gen> tokens · <elapsed>
    /// [· <tps> tok/s]` — shared by the per-message stats line and the
    /// turn-total appended to "Turn complete." so both always match.
    public var formatted: String {
        func kilo(_ n: Int) -> String {
            n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
        }
        let elapsedStr: String
        if elapsed >= 60 {
            let m = Int(elapsed) / 60
            let s = Int(elapsed) % 60
            elapsedStr = "\(m)m \(s)s"
        } else {
            elapsedStr = String(format: "%.1fs", elapsed)
        }
        var result = "↑ \(kilo(promptTokens)) · ↓ \(kilo(generationTokens)) tokens · \(elapsedStr)"
        if tokensPerSecond > 0 {
            result += String(format: " · %.1f tok/s", tokensPerSecond)
        }
        return result
    }
}

public struct ModeSnapshot: Sendable {
    public let workingMode: String      // raw value of WorkingMode (plan/agent/coding)
    public let thinkingLevel: String    // raw value of ThinkingLevel
    public let taskType: String         // raw value of TaskType
    public init(workingMode: String, thinkingLevel: String, taskType: String) {
        self.workingMode = workingMode
        self.thinkingLevel = thinkingLevel
        self.taskType = taskType
    }
}

public enum ModelLifecycleEvent: Sendable {
    case unloading(String)
    case loading(String)
    case ready(String)
    case reloaded(String)
    case alreadyActive(String)
    case error(String)
}

public enum MemoryEvent: Sendable {
    case checkpointSaved(summary: String)
    case checkpointFailed(reason: String)
    case factSaved(subject: String, fact: String)
    case factsListed(action: String, count: Int, lines: [String])
    case searchResults(action: String, query: String, lines: [String])
    case undone(message: String)
    case status(action: String, lines: [String])
    case error(String)
}

public enum BuildCheckEvent: Sendable {
    case skipped(reason: String)
    case started(message: String)
    case progress(String)
    case passed
    case failed(errorCount: Int?, firstErrors: [String])
    case warning(String)
}

public enum GitOrchestrationEvent: Sendable {
    case info(String)
    case warning(String)
    case worktreeCreated(path: String, branch: String)
    case worktreeSwitched(path: String, branch: String)
    case branchDeleted(name: String, force: Bool)
    case merged(message: String, warnings: [String])
    case proposal(title: String, value: String)
    case skipped(reason: String)
}

public enum ActivityLifecycle: Sendable, Equatable {
    case started
    case ended
}

// MARK: - Argument stringification

/// Converts an arbitrary `[String: Any]` argument map into the
/// `[String: String]` shape used by `ToolCallSnapshot`. Non-string values are
/// rendered through `String(describing:)`; this is intentionally lossy — UIs
/// only need a human-readable preview of arguments.
public func stringifyArgs(_ args: [String: Any]) -> [String: String] {
    var out: [String: String] = [:]
    out.reserveCapacity(args.count)
    for (k, v) in args {
        if let s = v as? String { out[k] = s }
        else { out[k] = String(describing: v) }
    }
    return out
}
