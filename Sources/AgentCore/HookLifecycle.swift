import Foundation

public enum AgentHookEvent: Sendable {
    case permissionRequest(toolName: String, isPlanMode: Bool)
    case preToolUse(toolName: String, argumentsPreview: String)
    case postToolUse(toolName: String, isError: Bool, resultPreview: String)
    case compression(toolName: String, beforeTokens: Int, afterTokens: Int, usedFallback: Bool)
    /// Emitted when a steering message is injected between turns.
    case steeringInjected(message: String)
    /// Emitted when an automatic follow-up is started after a completed run.
    case followUpStarted(message: String)
    /// Emitted after a context transform runs and produces a different message list.
    /// `transformIndex` is the zero-based position in the registered transform pipeline.
    case contextTransformApplied(transformIndex: Int, messagesBefore: Int, messagesAfter: Int)
}

public protocol AgentHook: Sendable {
    var name: String { get }
    func handle(event: AgentHookEvent) async
}

public actor HookPipeline {
    private var hooks: [any AgentHook] = []

    public init() {}

    public func register(_ hook: any AgentHook) {
        hooks.append(hook)
    }

    public func registeredHookNames() -> [String] {
        hooks.map(\.name)
    }

    public func emit(_ event: AgentHookEvent) async {
        for hook in hooks {
            await hook.handle(event: event)
        }
    }
}
