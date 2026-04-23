// Sources/ToolSystem/Filesystem/AppendFileTool.swift
// Appends content to an existing file or creates a new one

import Foundation

/// Appends content to a file.
public struct AppendFileTool: Tool {
    public let name = "append_file"
    public let description = """
        Add new content after the last line of a file. \
        Use this only when inserting at the very end of the file — never for modifying or replacing \
        existing lines (use edit_file for a single targeted substitution or patch for multi-location changes). \
        For intentionally creating a brand-new file use write_file instead. \
        Note: if the target file does not exist it will be created silently; \
        prefer write_file when creating new files on purpose.
        """
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "path": PropertySchema(type: "string", description: "Path to the file to append to (relative to workspace root). If the file does not exist it will be created; prefer write_file for intentional new-file creation."),
            "content": PropertySchema(type: "string", description: "Content to append after the last line of the file."),
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
