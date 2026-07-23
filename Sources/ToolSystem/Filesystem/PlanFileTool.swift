import Foundation

public struct PlanFileTool: Tool {
    static let planFileName = "PLAN.MD"
    private static let validActions = ["read", "write", "edit"]

    public let name = "plan_file"
    public let description = "Create, read, or update the workspace-root PLAN.MD without leaving plan mode. 'read' checks the current plan (returns an empty-plan notice if none exists yet), 'write' creates or replaces the full document, 'edit' does an exact search/replace update."
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
        case "read":
            let result = FileMutationSupport.readContent(from: Self.planFileName, permissions: permissions)
            // "No plan yet" is an expected, common outcome (e.g. a fresh task)
            // rather than a failure — don't surface it as a tool error.
            if result.isError, result.content.hasPrefix("File not found:") {
                return .success("No plan has been written yet. Use action 'write' to create one.")
            }
            return result

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
