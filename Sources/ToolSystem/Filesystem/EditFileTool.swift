// Sources/ToolSystem/Filesystem/EditFileTool.swift
// Targeted search-and-replace edits within files

import Foundation

/// Performs targeted search-and-replace edits on a file.
public struct EditFileTool: Tool {
    public let name = "edit_file"
    public let description = "Apply search-and-replace edits to an existing file. Preferred over full rewrites for making updates to existing files. Each edit replaces an exact match of old_text with new_text."
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "path": PropertySchema(type: "string", description: "Path to the file to edit (relative to workspace root)"),
            "old_text": PropertySchema(type: "string", description: "Exact text to find and replace"),
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

    // MARK: - Diff generation

    /// Produces a unified diff between `original` and `updated` content.
    /// Because `edit_file` always replaces exactly one occurrence, the changed
    /// region is always a single contiguous block, which keeps the implementation simple.
    func generateUnifiedDiff(original: String, updated: String, path: String) -> String {
        FileMutationSupport.generateUnifiedDiff(original: original, updated: updated, path: path)
    }
}
