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
        case .steeringInjected(let message):
            await logger.logHookEvent(
                hookName: name,
                eventName: "steering_injected",
                toolName: nil,
                details: message
            )
        case .followUpStarted(let message):
            await logger.logHookEvent(
                hookName: name,
                eventName: "follow_up_started",
                toolName: nil,
                details: message
            )
        case .contextTransformApplied(let transformIndex, let messagesBefore, let messagesAfter):
            await logger.logHookEvent(
                hookName: name,
                eventName: "context_transform_applied",
                toolName: nil,
                details: "transform_index=\(transformIndex); messages_before=\(messagesBefore); messages_after=\(messagesAfter)"
            )
        }
    }
}
