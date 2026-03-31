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

        let resolvedPath: String
        do {
            resolvedPath = try permissions.validatePath(path)
        } catch {
            return .error(error.localizedDescription)
        }

        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            return .error("File not found: \(path)")
        }

        do {
            var content = try String(contentsOfFile: resolvedPath, encoding: .utf8)

            // Count occurrences
            let occurrences = content.components(separatedBy: oldText).count - 1

            guard occurrences > 0 else {
                return .error("old_text not found in file. Make sure the text matches exactly, including whitespace.")
            }

            if occurrences > 1 {
                return .error("old_text found \(occurrences) times in file. It must be unique. Add more surrounding context to old_text to make it unique.")
            }

            // Apply the replacement
            content = content.replacingOccurrences(of: oldText, with: newText)
            try content.write(toFile: resolvedPath, atomically: true, encoding: .utf8)

            return .success("Applied edit to \(path)")
        } catch {
            return .error("Failed to edit file: \(error.localizedDescription)")
        }
    }
}
