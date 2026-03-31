// Sources/ToolSystem/Filesystem/AppendFileTool.swift
// Appends content to an existing file or creates a new one

import Foundation

/// Appends content to a file.
public struct AppendFileTool: Tool {
    public let name = "append_file"
    public let description = "Appends content to the end of a file. Preferred for adding sections incrementally after the initial scaffold is created. This is much safer than search-and-replace for adding new content."
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "path": PropertySchema(type: "string", description: "Path to the file to append to (relative to workspace root)"),
            "content": PropertySchema(type: "string", description: "Content to append to the file"),
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

        let resolvedPath: String
        do {
            resolvedPath = try permissions.validatePath(path)
        } catch {
            return .error(error.localizedDescription)
        }

        do {
            // Create parent directories if needed
            let parentDir = (resolvedPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: parentDir,
                withIntermediateDirectories: true
            )

            if let handle = FileHandle(forWritingAtPath: resolvedPath) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                handle.write(Data(content.utf8))
                
                let lineCount = content.components(separatedBy: "\n").count
                return .success("Appended \(lineCount) lines to \(path)")
            } else {
                // File does not exist, fall back to writing
                try content.write(toFile: resolvedPath, atomically: true, encoding: .utf8)
                let lineCount = content.components(separatedBy: "\n").count
                return .success("Created and wrote \(lineCount) lines to \(path) as the file did not exist.")
            }
        } catch {
            return .error("Failed to append to file: \(error.localizedDescription)")
        }
    }
}
