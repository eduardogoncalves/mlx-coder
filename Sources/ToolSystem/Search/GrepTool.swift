// Sources/ToolSystem/Search/GrepTool.swift
// Search file contents with regex or literal patterns

import Foundation

/// Searches file contents for a pattern using grep.
public struct GrepTool: Tool {
    public let name = "grep"
    public let description = "Search file contents for a pattern. Returns matching lines with file paths and line numbers."
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "pattern": PropertySchema(type: "string", description: "Search pattern (regex or literal)"),
            "path": PropertySchema(type: "string", description: "Directory or file to search in (relative to workspace root, default: '.')"),
            "include": PropertySchema(type: "string", description: "File pattern to include (e.g. '*.swift')"),
            "case_insensitive": PropertySchema(type: "boolean", description: "If true, perform case-insensitive search (default: false)"),
        ],
        required: ["pattern"]
    )

    private let permissions: PermissionEngine
    private let maxResults: Int

    public init(permissions: PermissionEngine, maxResults: Int = 50) {
        self.permissions = permissions
        self.maxResults = maxResults
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let pattern = arguments["pattern"] as? String else {
            return .error("Missing required argument: pattern")
        }

        let searchPath = arguments["path"] as? String ?? "."
        let include = arguments["include"] as? String
        let caseInsensitive = arguments["case_insensitive"] as? Bool ?? false

        let resolvedPath: String
        do {
            resolvedPath = try permissions.validatePath(searchPath)
        } catch {
            return .error(error.localizedDescription)
        }

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/grep")

        var args = ["-rnI"] // recursive, line numbers, skip binary files
        if caseInsensitive { args.append("-i") }
        if let include { args.append(contentsOf: ["--include", include]) }
        args.append(contentsOf: ["--exclude-dir=.git", "--exclude-dir=.build", "--exclude-dir=node_modules"])
        args.append(pattern)
        args.append(resolvedPath)

        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        let lines = output
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .map { relativizeGrepLine($0) }
            .filter { line in
                let pathPart = String(line.split(separator: ":", maxSplits: 1).first ?? "")
                return !permissions.isPathIgnored(pathPart)
            }

        if lines.isEmpty {
            return .success("No matches found for '\(pattern)'")
        }

        let truncated = Array(lines.prefix(maxResults))
        let omitted = lines.count > maxResults ? lines.count - maxResults : 0
        let marker = omitted > 0 ? "[... \(omitted) more matches omitted ...]" : nil

        return ToolResult(
            content: truncated.joined(separator: "\n"),
            truncationMarker: marker
        )
    }

    private func relativizeGrepLine(_ line: String) -> String {
        guard let firstColon = line.firstIndex(of: ":") else {
            return line
        }

        let absolutePath = String(line[..<firstColon])
        let suffix = String(line[firstColon...])
        let relativePath = relativizePath(absolutePath)
        return relativePath + suffix
    }

    private func relativizePath(_ absolutePath: String) -> String {
        let workspaceRoot = normalizedWorkspaceRoot()

        if absolutePath == workspaceRoot {
            return "."
        }

        let prefix = workspaceRoot + "/"
        if absolutePath.hasPrefix(prefix) {
            return String(absolutePath.dropFirst(prefix.count))
        }

        return absolutePath
    }

    private func normalizedWorkspaceRoot() -> String {
        let root = permissions.workspaceRoot
        if root.count > 1 && root.hasSuffix("/") {
            return String(root.dropLast())
        }
        return root
    }
}
