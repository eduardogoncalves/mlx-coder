// Sources/ToolSystem/Search/GlobTool.swift
// Find files matching glob patterns

import Foundation

/// Finds files matching a glob pattern within the workspace.
public struct GlobTool: Tool {
    public let name = "glob"
    public let description = "Find files matching a glob pattern within the workspace."
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "pattern": PropertySchema(type: "string", description: "Glob pattern to match (e.g. '**/*.swift', 'Sources/**/*.swift')"),
            "path": PropertySchema(type: "string", description: "Directory to search in (relative to workspace root, default: '.')"),
        ],
        required: ["pattern"]
    )

    private let permissions: PermissionEngine
    private let maxResults: Int

    public init(permissions: PermissionEngine, maxResults: Int = 100) {
        self.permissions = permissions
        self.maxResults = maxResults
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let pattern = arguments["pattern"] as? String else {
            return .error("Missing required argument: pattern")
        }

        let searchPath = arguments["path"] as? String ?? "."

        let resolvedPath: String
        do {
            resolvedPath = try permissions.validatePath(searchPath)
        } catch {
            return .error(error.localizedDescription)
        }

        // Use `find` command for glob matching since Foundation lacks glob traversal
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/find")
        process.arguments = [resolvedPath, "-name", pattern, "-not", "-path", "*/.*"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        let files = output
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .map { path in
                // Make relative to workspace root
                if path.hasPrefix(permissions.workspaceRoot) {
                    return String(path.dropFirst(permissions.workspaceRoot.count + 1))
                }
                return path
            }
            .filter { !permissions.isPathIgnored($0) }

        if files.isEmpty {
            return .success("No files matching '\(pattern)' found")
        }

        let truncated = Array(files.prefix(maxResults))
        let omitted = files.count > maxResults ? files.count - maxResults : 0
        let marker = omitted > 0 ? "[... \(omitted) more files omitted ...]" : nil

        return ToolResult(
            content: truncated.joined(separator: "\n"),
            truncationMarker: marker
        )
    }
}
