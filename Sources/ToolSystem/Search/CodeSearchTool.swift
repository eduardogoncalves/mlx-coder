// Sources/ToolSystem/Search/CodeSearchTool.swift
// Symbol-aware code search using grep with smart context

import Foundation

/// Searches for code symbols (functions, classes, structs, enums, protocols) in the workspace.
public struct CodeSearchTool: Tool {
    public let name = "code_search"
    public let description = "Search for code symbols like function, class, struct, enum, or protocol definitions. Returns matching definitions with context."
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "query": PropertySchema(type: "string", description: "Symbol name or pattern to search for"),
            "path": PropertySchema(type: "string", description: "Directory to search in (relative to workspace root, default: '.')"),
            "language": PropertySchema(type: "string", description: "Language filter (e.g. 'swift', 'python')"),
        ],
        required: ["query"]
    )

    private let permissions: PermissionEngine

    public init(permissions: PermissionEngine) {
        self.permissions = permissions
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let query = arguments["query"] as? String else {
            return .error("Missing required argument: query")
        }

        let searchPath = arguments["path"] as? String ?? "."
        let language = arguments["language"] as? String

        let resolvedPath: String
        do {
            resolvedPath = try permissions.validatePath(searchPath)
        } catch {
            return .error(error.localizedDescription)
        }

        // Build patterns for common code definitions
        let patterns = symbolPatterns(for: query, language: language)
        var allResults: [String] = []

        for pattern in patterns {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/grep")

            process.arguments = [
                "-rnI", "-E",
            ] + includeArguments(for: language) + [
                "--exclude-dir=.git", "--exclude-dir=.build",
                "-A", "2",  // 2 lines of context after match
                pattern,
                resolvedPath
            ]

            let pipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = pipe
            process.standardError = errPipe

            try process.run()
            // Drain concurrently — see GrepTool for the deadlock rationale.
            // Off-pool wait: this `execute` runs on an async context, and a
            // synchronous `waitUntilExit()` here would park a
            // cooperative-pool thread for the duration of the search.
            let (output, _, _) = await ProcessIO.drainAndWaitAsync(
                process: process,
                stdoutPipe: pipe,
                stderrPipe: errPipe
            )

            let lines = output
                .components(separatedBy: "\n")
                .filter { !$0.isEmpty }
                .map { relativizeGrepLine($0) }
                .filter { line in
                    let pathPart = String(line.split(separator: ":", maxSplits: 1).first ?? "")
                    return !permissions.isPathIgnored(pathPart)
                }

            allResults.append(contentsOf: lines)
        }

        allResults.append(contentsOf: await pathMatches(for: query, in: resolvedPath, language: language))

        if allResults.isEmpty {
            return .success("No code symbols matching '\(query)' found")
        }

        // Deduplicate safely without forced cast
        let uniqueSet = NSOrderedSet(array: allResults)
        let unique = (uniqueSet.array as? [String]) ?? allResults
        let truncated = Array(unique.prefix(50))
        let omitted = unique.count > 50 ? unique.count - 50 : 0
        let marker = omitted > 0 ? "[... \(omitted) more results omitted ...]" : nil

        return ToolResult(content: truncated.joined(separator: "\n"), truncationMarker: marker)
    }

    // MARK: - Private

    private func symbolPatterns(for query: String, language: String?) -> [String] {
        guard let language else {
            return [query]
        }

        switch language.lowercased() {
        case "swift":
            return [
                "(func|class|struct|enum|protocol|actor|typealias)\\s+\(query)",
                "let\\s+\(query)\\s*[:=]",
                "var\\s+\(query)\\s*[:=]",
            ]
        case "python":
            return [
                "(def|class)\\s+\(query)",
            ]
        case "javascript", "typescript":
            return [
                "(function|class|const|let|var)\\s+\(query)",
            ]
        default:
            return [query]
        }
    }

    private func languageExtension(_ language: String) -> String? {
        switch language.lowercased() {
        case "swift": return "swift"
        case "python": return "py"
        case "javascript": return "js"
        case "typescript": return "ts"
        case "c#", "csharp", "cs": return "cs"
        default: return nil
        }
    }

    private func includeArguments(for language: String?) -> [String] {
        guard let language, let ext = languageExtension(language) else {
            return []
        }
        return ["--include", "*.\(ext)"]
    }

    private func pathMatches(for query: String, in resolvedPath: String, language: String?) async -> [String] {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/find")

        var arguments = [resolvedPath]
        arguments.append(contentsOf: findPruneArguments())
        arguments.append(contentsOf: ["-type", "f"])
        if let language, let ext = languageExtension(language) {
            arguments.append(contentsOf: ["-name", "*.\(ext)"])
        }
        arguments.append(contentsOf: ["-iname", "*\(query)*", "-print"])
        process.arguments = arguments

        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return []
        }
        // Drain concurrently — see GrepTool for the deadlock rationale.
        // Off-pool wait — see rationale above.
        let (output, _, _) = await ProcessIO.drainAndWaitAsync(
            process: process,
            stdoutPipe: pipe,
            stderrPipe: errPipe
        )

        return output
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .map { relativizePath($0) + ":1:[path match]" }
            .filter { line in
                let pathPart = String(line.split(separator: ":", maxSplits: 1).first ?? "")
                return !permissions.isPathIgnored(pathPart) && !BuildOutputFilter.isBuildOutput(path: pathPart)
            }
    }

    private func findPruneArguments() -> [String] {
        let prunedDirectoryNames = [".git"] + Array(BuildOutputFilter.ignoredNames)
        guard !prunedDirectoryNames.isEmpty else { return [] }

        var arguments = ["("]
        for (index, name) in prunedDirectoryNames.enumerated() {
            if index > 0 {
                arguments.append("-o")
            }
            arguments.append(contentsOf: ["-type", "d", "-name", name])
        }
        arguments.append(contentsOf: [")", "-prune", "-o"])
        return arguments
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
