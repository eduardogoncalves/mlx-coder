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
}

// MARK: - Convenience helpers

public extension AgentFrontend {

    func emitText(_ chunk: String) {
        emit(.assistantTextChunk(chunk))
    }

    func emitStatus(_ text: String, severity: StatusMessage.Severity = .info) {
        emit(.status(StatusMessage(text, severity: severity)))
    }

    func emitError(_ text: String) {
        emit(.error(text))
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
