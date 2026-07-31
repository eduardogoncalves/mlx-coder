// Sources/AgentFrontend/AgentFrontend.swift
// The single seam between AgentCore and any presentation layer.
//
// Concrete adapters (LegacyTerminalFrontend, SwiftCoderTUIFrontend, future
// GUI frontends) implement this protocol. AgentCore depends only on this
// abstraction and never imports a UI module.

import Foundation

public protocol AgentFrontend: AnyObject, Sendable {

    /// Fire-and-forget event delivery. **Synchronous** so the agent's
    /// non-async streaming paths (e.g. inside `ModelContainer.perform { ... }`
    /// closures) can call it without restructuring. Implementations must be
    /// reentrant and thread-safe — AgentCore may emit from concurrent
    /// contexts and from non-async closures.
    func emit(_ event: AgentEvent)

    /// Synchronous request/response for interactive prompts (approval,
    /// option select, free-form text). Implementations must respect Task
    /// cancellation; cancellation should resolve to a "cancelled" response
    /// (`.deny(suggestion: nil)`, `.optionSelect(nil)`, `.textInput(nil)`).
    func request(_ request: AgentRequest) async -> AgentResponse

    /// Whether this frontend already renders its own managed tool-execution
    /// spinner (in a fixed footer region, above the input) in response to
    /// `.toolCallStarted`/`.toolCallResult`. When `true`, AgentCore must NOT
    /// spin up its own raw stdout `Spinner` for slow tools (web_search /
    /// web_fetch): doing so would draw a second animation at the current
    /// cursor position — i.e. inside the input area — fighting the frontend's
    /// own footer spinner. Frontends that own their spinner surface tool
    /// progress phases through `.status` lines prefixed with
    /// `StatusMessage.toolProgressPrefix` instead. Defaults to `false` (raw
    /// terminal frontends that expect AgentCore to drive the spinner).
    var rendersOwnToolSpinner: Bool { get }
}

// MARK: - Convenience helpers

public extension AgentFrontend {

    /// Default: AgentCore drives the tool spinner (raw terminal frontends).
    /// The TUI overrides this to `true`.
    var rendersOwnToolSpinner: Bool { false }

    func emitText(_ chunk: String) {
        emit(.assistantTextChunk(chunk))
    }

    func emitStatus(_ text: String, severity: StatusMessage.Severity = .info) {
        emit(.status(StatusMessage(text, severity: severity)))
    }

    func emitError(_ text: String) {
        emit(.error(text))
    }

    // MARK: - Harness intervention

    /// The single, uniformly-worded channel for a "harness intervention" —
    /// any moment the scaffolding overrides, corrects, blocks, or redirects
    /// the model, as opposed to the model deciding something for itself.
    ///
    /// Ported in spirit from little-coder's `_shared/intervention.ts`:
    ///
    /// ```ts
    /// export function harnessIntervention(ctx: InterventionCtx, message: string): void {
    ///   ctx.ui.notify(`harness intervention: ${message}`, "info");
    /// }
    /// ```
    ///
    /// Their rationale applies here verbatim: before this helper, every
    /// subsystem (auto-correction, context compaction, thinking-budget
    /// enforcement, malformed tool-call recovery, steering, ...) emitted its
    /// own free-form `emitStatus`/`emitError` call in its own voice and
    /// severity, so a single harness decision could surface as several
    /// stacked, differently-worded lines. Routing every genuine intervention
    /// through this one call site gives the user ONE recognizable prefix to
    /// scan for, no matter which subsystem fired it.
    ///
    /// `message` should lead with the consequence — what the harness just
    /// did to the model's turn — not with the internal cause, e.g. "the
    /// model has thought long enough — forcing it to start implementing"
    /// rather than "thinking budget exceeded".
    ///
    /// **This covers the user-visible half only.** Text injected into the
    /// model's own conversation history (steering messages, corrective
    /// re-prompts) must NEVER be routed through this — it would pollute the
    /// model's context with harness chrome it has no use for reading back.
    /// Callers that both notify the user and steer the model keep those two
    /// strings entirely separate; only the notify half goes through here.
    ///
    /// `severity` follows the same "how loud" convention as `emitStatus` —
    /// it is orthogonal to the fixed "harness intervention:" prefix, which
    /// answers *who* caused the message, not how urgent it is. A routine
    /// auto-correction stays `.info`; a thinking-budget or malformed-call
    /// recovery that costs the model a whole round typically wants
    /// `.warning`.
    func harnessIntervention(_ message: String, severity: StatusMessage.Severity = .info) {
        emitStatus("harness intervention: \(message)", severity: severity)
    }

    /// Same wording convention as `harnessIntervention(_:severity:)`, but
    /// routed through the hard-error channel (`.error`) for interventions
    /// severe enough that the harness is abandoning the turn outright (e.g.
    /// a repeated identical tool-call failure, or hitting the tool-iteration
    /// cap). Those already get the frontends' strongest visual treatment
    /// (red text / "✗"), so they keep using `.error` rather than `.status`,
    /// but still carry the same recognizable prefix as every other
    /// intervention so the user can tell it was the harness giving up, not
    /// the model.
    func harnessInterventionError(_ message: String) {
        emitError("harness intervention: \(message)")
    }
}

// MARK: - No-op frontend (useful for tests and `RunCommand` non-interactive use)

/// A frontend that drops every event and denies every request. Useful for
/// non-interactive batch invocations and unit tests of `AgentCore` that only
/// care about side-effects on history/tools, not presentation.
public final class NullAgentFrontend: AgentFrontend {
    public init() {}
    public func emit(_ event: AgentEvent) {}
    public func request(_ request: AgentRequest) async -> AgentResponse {
        switch request {
        case .approval:     return .approval(.deny(suggestion: nil))
        case .optionSelect: return .optionSelect(nil)
        case .textInput:    return .textInput(nil)
        }
    }
}
