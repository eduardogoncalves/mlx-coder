// Sources/ToolSystem/Filesystem/ReadManyTool.swift
// Batch-read multiple files in a single tool call

import Foundation

/// Reads multiple files in a single call, returning their contents.
public struct ReadManyTool: Tool {
    public let name = "read_many"
    public let description = "Read multiple files at once. Returns the content of each file."
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "paths": PropertySchema(
                type: "array",
                description: "Array of file paths to read (relative to workspace root)",
                items: PropertySchema(type: "string")
            ),
        ],
        required: ["paths"]
    )

    private let permissions: PermissionEngine
    private let maxLinesPerFile: Int

    public init(permissions: PermissionEngine, maxLinesPerFile: Int = 200) {
        self.permissions = permissions
        self.maxLinesPerFile = maxLinesPerFile
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let paths = arguments["paths"] as? [String] else {
            return .error("Missing required argument: paths (must be an array of strings)")
        }

        guard !paths.isEmpty else {
            return .error("paths array is empty")
        }

        var results: [String] = []
        var totalOmitted = 0

        for path in paths {
            let resolvedPath: String
            do {
                resolvedPath = try permissions.validatePath(path)
            } catch {
                // Generic error message - don't expose error details that might reveal system information
                results.append("=== \(path) ===\nERROR: Failed to validate path")
                continue
            }

            guard FileManager.default.fileExists(atPath: resolvedPath) else {
                results.append("=== \(path) ===\nERROR: File not found")
                continue
            }

            do {
                let content = try String(contentsOfFile: resolvedPath, encoding: .utf8)
                let lines = content.components(separatedBy: "\n")

                if lines.count > maxLinesPerFile {
                    let truncated = lines.prefix(maxLinesPerFile).joined(separator: "\n")
                    let omitted = lines.count - maxLinesPerFile
                    totalOmitted += omitted
                    results.append("=== \(path) ===\n\(truncated)\n[... \(omitted) lines omitted ...]")
                } else {
                    results.append("=== \(path) ===\n\(content)")
                }
            } catch {
                results.append("=== \(path) ===\nERROR: \(error.localizedDescription)")
            }
        }

        let marker = totalOmitted > 0 ? "[... \(totalOmitted) total lines omitted across files ...]" : nil
        return ToolResult(content: results.joined(separator: "\n\n"), truncationMarker: marker)
    }
}
