// Sources/ToolSystem/Filesystem/ReadFileTool.swift
// Read file contents with optional line range and output capping

import Foundation

/// Reads the contents of a file, optionally limited to a line range.
public struct ReadFileTool: Tool {
    public let name = "read_file"
    public let description = "Read the contents of a file. Supports optional line range. Output is capped per call; when a file is not fully read, the result states which lines were returned and the total line count — call read_file again with start_line set to the next line to continue reading."
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "path": PropertySchema(type: "string", description: "Path to the file to read (relative to workspace root)"),
            "start_line": PropertySchema(type: "integer", description: "First line to read (1-indexed, optional). Use the continuation hint from a previous read_file result to resume a partially read file."),
            "end_line": PropertySchema(type: "integer", description: "Last line to read (1-indexed, inclusive, optional)"),
            "include_build_dirs": PropertySchema(type: "boolean", description: "If true, allow reading files inside build-output or dependency-cache directories such as bin, obj, node_modules, __pycache__, .build, target, etc. (default: false)"),
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

        let includeBuildDirs = arguments["include_build_dirs"] as? Bool ?? false
        if !includeBuildDirs, let matched = BuildOutputFilter.matchedComponent(in: path) {
            return .error("'\(path)' is inside a build-output directory ('\(matched)'). Reading build artefacts is skipped by default. If you genuinely need this file, retry with include_build_dirs: true.")
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
            var allLines = content.components(separatedBy: "\n")
            // A trailing newline yields one empty final component; drop it from line accounting.
            if allLines.count > 1, allLines.last?.isEmpty == true {
                allLines.removeLast()
            }
            let totalLines = allLines.count

            let startLine = (arguments["start_line"] as? Int ?? 1) - 1 // Convert to 0-indexed
            let endLine = (arguments["end_line"] as? Int ?? totalLines) // 1-indexed inclusive

            guard startLine >= 0, startLine < totalLines else {
                return .error("start_line \(startLine + 1) is out of range (file has \(totalLines) lines)")
            }

            let clampedEnd = min(endLine, totalLines)
            var selectedLines = Array(allLines[startLine..<clampedEnd])
            if selectedLines.count > maxOutputLines {
                selectedLines = Array(selectedLines.prefix(maxOutputLines))
            }

            // Last line actually returned, 1-indexed.
            let lastLineRead = startLine + selectedLines.count

            if lastLineRead < totalLines {
                var marker = "[Read lines \(startLine + 1)-\(lastLineRead) of \(totalLines). File continues — call read_file with start_line: \(lastLineRead + 1) to read the next section.]"
                if path.hasSuffix("SKILL.md") {
                    marker += " [This is a skill file — prefer the read_skill tool with the skill name to load it in full.]"
                }
                return ToolResult(
                    content: selectedLines.joined(separator: "\n"),
                    truncationMarker: marker
                )
            }

            return .success(selectedLines.joined(separator: "\n"))
        } catch {
            return .error("Failed to read file: \(error.localizedDescription)")
        }
    }
}
