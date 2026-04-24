// Sources/ToolSystem/Filesystem/WriteFileTool.swift
// Create or overwrite files within the workspace

import Foundation

/// Creates or overwrites a file with the given content.
public struct WriteFileTool: Tool {
    public let name = "write_file"
    public let description = """
        Create a brand-new file only — fails if the file already exists. \
        Use this to scaffold a new file that does not yet exist. \
        For partial modifications to an existing file, use patch_file (for multi-location changes) \
        or edit_file (for a single targeted substitution). \
        Do NOT use to append content at the end of a file (use append_file instead).
        """
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

        let resolvedPath: String
        do {
            resolvedPath = try permissions.validatePath(path)
        } catch {
            return .error(error.localizedDescription)
        }

        do {
            // Fail if file already exists — use patch_file or edit_file for modifications
            guard !FileManager.default.fileExists(atPath: resolvedPath) else {
                return .error(
                    "File already exists: \(path). Use patch_file to modify an existing file, " +
                    "or edit_file for a single targeted substitution."
                )
            }

            // Create parent directories if needed
            let parentDir = (resolvedPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: parentDir,
                withIntermediateDirectories: true
            )

            // Security: Verify parent directory is still within workspace after creation
            // This additional check protects against TOCTOU attacks where symlinks
            // are created in the parent directory between validation and write operations.
            let canonicalParent = URL(filePath: parentDir).standardized.resolvingSymlinksInPath().path()
            let canonicalWorkspaceRoot = URL(filePath: permissions.workspaceRoot)
                .standardized
                .resolvingSymlinksInPath()
                .path()
            let parentInsideWorkspace = canonicalParent == canonicalWorkspaceRoot
                || canonicalParent.hasPrefix(canonicalWorkspaceRoot + "/")
            guard parentInsideWorkspace else {
                return .error("Security violation: Parent directory path validation failed")
            }

            try content.write(toFile: resolvedPath, atomically: true, encoding: .utf8)

            let lineCount = content.components(separatedBy: "\n").count
            return .success("Wrote \(lineCount) lines to \(path)")
        } catch {
            return .error("Failed to write file: \(error.localizedDescription)")
        }
    }
}
