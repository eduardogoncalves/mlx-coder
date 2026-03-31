import Foundation

public enum AgentHookEvent: Sendable {
    case permissionRequest(toolName: String, isPlanMode: Bool)
    case preToolUse(toolName: String, argumentsPreview: String)
    case postToolUse(toolName: String, isError: Bool, resultPreview: String)
    case compression(toolName: String, beforeTokens: Int, afterTokens: Int, usedFallback: Bool)
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
