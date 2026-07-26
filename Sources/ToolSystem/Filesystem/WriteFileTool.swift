// Sources/ToolSystem/Filesystem/WriteFileTool.swift
// Create or overwrite files within the workspace

import Foundation

/// Creates or overwrites a file with the given content.
public struct WriteFileTool: Tool {
    public let name = "write_file"
    public let description = "Create a new file or overwrite an existing file with the given content. Use this to scaffold the minimal valid structure of a file before adding sections incrementally."
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "path": PropertySchema(type: "string", description: "Path to the file to write (relative to workspace root)"),
            "content": PropertySchema(type: "string", description: "Content to write to the file"),
        ],
        required: ["path", "content"]
    )

    private let permissions: PermissionEngine

    public init(permissions: PermissionEngine) {
        self.permissions = permissions
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let path = arguments["path"] as? String else {
            return .error("Missing required argument: path")
        }
        guard let content = arguments["content"] as? String else {
            return .error("Missing required argument: content")
        }
        return FileMutationSupport.writeContent(content, to: path, permissions: permissions, blockExistingFile: true)
    }
}
