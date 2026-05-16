import Foundation

public struct PlanFileTool: Tool {
    static let planFileName = "PLAN.MD"
    private static let validActions = ["write", "edit"]

    public let name = "plan_file"
    public let description = "Create or update the workspace-root PLAN.MD without leaving plan mode. Valid actions: \(Self.validActionsDescription). Use 'write' to create or replace the full document, and 'edit' for an exact search/replace update."
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "action": PropertySchema(type: "string", description: "Operation to perform on PLAN.MD", enumValues: Self.validActions),
            "content": PropertySchema(type: "string", description: "Full PLAN.MD content to write when action is 'write'"),
            "old_text": PropertySchema(type: "string", description: "Exact text to replace when action is 'edit'"),
            "new_text": PropertySchema(type: "string", description: "Replacement text when action is 'edit'")
        ],
        required: ["action"]
    )

    private let permissions: PermissionEngine

    public init(permissions: PermissionEngine) {
        self.permissions = permissions
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let action = arguments["action"] as? String else {
            return .error("Missing required argument: action")
        }

        switch action {
        case "write":
            guard let content = arguments["content"] as? String else {
                return .error("Missing required argument: content")
            }
            return FileMutationSupport.writeContent(content, to: Self.planFileName, permissions: permissions)

        case "edit":
            guard let oldText = arguments["old_text"] as? String else {
                return .error("Missing required argument: old_text")
            }
            guard let newText = arguments["new_text"] as? String else {
                return .error("Missing required argument: new_text")
            }
            return FileMutationSupport.editContent(in: Self.planFileName, oldText: oldText, newText: newText, permissions: permissions)

        default:
            return .error("Unknown action: \(action). Use \(Self.validActionsDescription).")
        }
    }

    private static var validActionsDescription: String {
        let quoted = validActions.map { "'\($0)'" }
        guard let last = quoted.last else { return "(none)" }
        if quoted.count == 1 { return last }
        return quoted.dropLast().joined(separator: ", ") + " or " + last
    }
}
