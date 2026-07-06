// Sources/ToolSystem/Filesystem/EditFileTool.swift
// Targeted search-and-replace edits within files

import Foundation

/// Performs targeted search-and-replace edits on a file.
public struct EditFileTool: Tool {
    public let name = "edit_file"
    public let description = "Surgical search-and-replace for small, localized changes — not full rewrites. Match the shortest possible old_text (1–3 lines). Prefer multiple small edits. Omit unchanged context. If >30% of the file must change, ask first."
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "path": PropertySchema(type: "string", description: "File path (relative to workspace root)"),
            "old_text": PropertySchema(type: "string", description: "Exact snippet to replace (minimal, 1–3 lines)"),
            "new_text": PropertySchema(type: "string", description: "Replacement text"),
        ],
        required: ["path", "old_text", "new_text"]
    )

    private let permissions: PermissionEngine

    public init(permissions: PermissionEngine) {
        self.permissions = permissions
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let path = arguments["path"] as? String else {
            return .error("Missing required argument: path")
        }
        guard let oldText = arguments["old_text"] as? String else {
            return .error("Missing required argument: old_text")
        }
        guard let newText = arguments["new_text"] as? String else {
            return .error("Missing required argument: new_text")
        }
        return FileMutationSupport.editContent(in: path, oldText: oldText, newText: newText, permissions: permissions)
    }
}
