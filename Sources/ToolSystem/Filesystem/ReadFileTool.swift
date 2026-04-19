// Sources/ToolSystem/Filesystem/ReadFileTool.swift
// Read file contents with optional line range and output capping

import Foundation

/// Reads the contents of a file, optionally limited to a line range.
public struct ReadFileTool: Tool {
    public let name = "read_file"
    public let description = "Read the contents of a file. Supports optional line range."
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "path": PropertySchema(type: "string", description: "Path to the file to read (relative to workspace root)"),
            "start_line": PropertySchema(type: "integer", description: "First line to read (1-indexed, optional)"),
            "end_line": PropertySchema(type: "integer", description: "Last line to read (1-indexed, inclusive, optional)"),
        ],
        required: ["path"]
    )

    private let permissions: PermissionEngine
    private let maxOutputLines: Int

    public init(permissions: PermissionEngine, maxOutputLines: Int = 500) {
        self.permissions = permissions
        self.maxOutputLines = maxOutputLines
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let path = arguments["path"] as? String else {
            return .error("Missing required argument: path")
        }

        let resolvedPath: String
        do {
            resolvedPath = try permissions.validateReadPath(path)
        } catch {
            return .error(error.localizedDescription)
        }

        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            return .error("File not found: \(path)")
        }

        do {
            let content = try String(contentsOfFile: resolvedPath, encoding: .utf8)
            let allLines = content.components(separatedBy: "\n")

            let startLine = (arguments["start_line"] as? Int ?? 1) - 1 // Convert to 0-indexed
            let endLine = (arguments["end_line"] as? Int ?? allLines.count) // 1-indexed inclusive

            guard startLine >= 0, startLine < allLines.count else {
                return .error("start_line \(startLine + 1) is out of range (file has \(allLines.count) lines)")
            }

            let clampedEnd = min(endLine, allLines.count)
            let selectedLines = Array(allLines[startLine..<clampedEnd])

            // Apply output cap
            if selectedLines.count > maxOutputLines {
                let truncated = Array(selectedLines.prefix(maxOutputLines))
                let omitted = selectedLines.count - maxOutputLines
                let marker = "[... \(omitted) lines omitted ...]"
                return ToolResult(
                    content: truncated.joined(separator: "\n"),
                    truncationMarker: marker
                )
            }

            return .success(selectedLines.joined(separator: "\n"))
        } catch {
            return .error("Failed to read file: \(error.localizedDescription)")
        }
    }
}
