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
            "include_build_dirs": PropertySchema(type: "boolean", description: "Include build output / dependency cache directories (bin, obj, node_modules, .build, etc.). Default: false."),
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
        let includeBuildDirs = arguments["include_build_dirs"] as? Bool ?? false

        let resolvedPath: String
        do {
            resolvedPath = try permissions.validatePath(searchPath)
        } catch {
            return .error(error.localizedDescription)
        }

        // Translate ** glob syntax into find(1) arguments.
        // find(1) uses -name (filename only) or -path (full path), neither
        // of which supports **. We decompose the pattern into:
        //   dirPart  — the directory prefix before ** (e.g. "src" from "src/**/*.cs")
        //   namePart — the filename glob after ** (e.g. "*.cs")
        // Then use: find <root> [-path "*/dirPart/*"] -name namePart
        let (dirPart, namePart) = decompose(pattern: pattern)

        var findArgs = [resolvedPath, "-type", "f"]

        if let dir = dirPart, !dir.isEmpty {
            findArgs += ["-path", "*/\(dir)/*"]
        }
        findArgs += ["-name", namePart]
        findArgs += ["-not", "-path", "*/.*"]

        // Exclude build output dirs via find -prune for efficiency when not requested.
        if !includeBuildDirs {
            for ignored in BuildOutputFilter.ignoredNames.sorted() {
                findArgs += ["-not", "-path", "*/\(ignored)/*"]
            }
        }

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/find")
        process.arguments = findArgs

        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe

        try process.run()
        // Drain concurrently — `find` over a deep workspace can produce more
        // than the kernel pipe buffer (~16-64 KiB) of paths, deadlocking the
        // child if we wait for exit before reading.
        let (output, _) = ProcessIO.drainAndWait(
            process: process,
            stdoutPipe: pipe,
            stderrPipe: errPipe
        )

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

    /// Splits a glob pattern into an optional directory prefix and a filename glob.
    ///
    /// Examples:
    /// - `"**/*.cs"`          → (nil, "*.cs")
    /// - `"**/Foo.cs"`        → (nil, "Foo.cs")
    /// - `"src/**/*.cs"`      → ("src", "*.cs")
    /// - `"a/b/**/*.swift"`   → ("a/b", "*.swift")
    /// - `"*.cs"`             → (nil, "*.cs")
    /// - `"src/*.cs"`         → ("src", "*.cs")
    private func decompose(pattern: String) -> (dirPart: String?, namePart: String) {
        if let starRange = pattern.range(of: "**") {
            let before = String(pattern[pattern.startIndex..<starRange.lowerBound])
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let after = String(pattern[starRange.upperBound...])
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let name = after.isEmpty ? "*" : after
            return (before.isEmpty ? nil : before, name)
        }

        if pattern.contains("/") {
            let parts = pattern.components(separatedBy: "/")
            let name = parts.last ?? pattern
            let dir = parts.dropLast().joined(separator: "/")
            return (dir.isEmpty ? nil : dir, name)
        }

        return (nil, pattern)
    }
}
