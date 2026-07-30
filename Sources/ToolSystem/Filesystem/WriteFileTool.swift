// Sources/ToolSystem/Filesystem/WriteFileTool.swift
// Create or overwrite files within the workspace

import Foundation

/// Creates or overwrites a file with the given content.
public struct WriteFileTool: Tool {
    public let name = "write_file"
    public let description = "Create a new file with the given content. By default it refuses to overwrite an existing file (use edit_file/append_file for targeted changes). To intentionally replace an existing file wholesale, pass overwrite: true."
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "path": PropertySchema(type: "string", description: "Path to the file to write (relative to workspace root)"),
            "content": PropertySchema(type: "string", description: "Content to write to the file"),
            "overwrite": PropertySchema(type: "boolean", description: "Set true to intentionally replace an existing file's entire contents. Omit (or false) to create a new file only — writing to an existing path then fails with guidance to use edit_file/append_file instead."),
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
        // `overwrite: true` is an explicit, auditable request to replace an
        // existing file wholesale. Offering this legitimate path matters: the
        // guard used to be absolute, so a small model that genuinely needed to
        // rewrite a file learned to escape it entirely via `python3 -c "open(...
        // 'w')"` — which bypasses every workspace safeguard. A first-class flag
        // keeps intentional overwrites inside the guarded tool.
        let overwrite = (arguments["overwrite"] as? Bool) ?? false
        return FileMutationSupport.writeContent(content, to: path, permissions: permissions, blockExistingFile: !overwrite)
    }
}
