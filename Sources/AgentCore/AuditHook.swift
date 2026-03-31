import Foundation

public struct AuditHook: AgentHook {
    public let name = "audit"
    private let logger: ToolAuditLogger

    public init(logger: ToolAuditLogger) {
        self.logger = logger
    }

    public func handle(event: AgentHookEvent) async {
        switch event {
        case .permissionRequest(let toolName, let isPlanMode):
            await logger.logHookEvent(
                hookName: name,
                eventName: "permission_request",
                toolName: toolName,
                details: "is_plan_mode=\(isPlanMode)"
            )
        case .preToolUse(let toolName, let argumentsPreview):
            await logger.logHookEvent(
                hookName: name,
                eventName: "pre_tool_use",
                toolName: toolName,
                details: argumentsPreview
            )
        case .postToolUse(let toolName, let isError, let resultPreview):
            await logger.logHookEvent(
                hookName: name,
                eventName: "post_tool_use",
                toolName: toolName,
                details: "is_error=\(isError); result=\(resultPreview)"
            )
        case .compression(let toolName, let beforeTokens, let afterTokens, let usedFallback):
            await logger.logHookEvent(
                hookName: name,
                eventName: "compression",
                toolName: toolName,
                details: "before=\(beforeTokens); after=\(afterTokens); fallback=\(usedFallback)"
            )
        }
    }
}
