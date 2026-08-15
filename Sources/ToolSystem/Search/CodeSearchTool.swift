// Sources/ToolSystem/Search/CodeSearchTool.swift
// Symbol-aware code search using grep with smart context

import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

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
    private let codeGraphIndexer: CodeGraphIndexer?

    public init(permissions: PermissionEngine, codeGraphIndexer: CodeGraphIndexer? = nil) {
        self.permissions = permissions
        self.codeGraphIndexer = codeGraphIndexer
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

        // Prefer the deterministic, tree-sitter/lexically-indexed code graph
        // when it's live: exact symbol-table lookups beat the regex
        // heuristics below (no per-language pattern guessing, no false
        // positives from comments/strings) and cover every indexed language,
        // not just the four hardcoded under `symbolPatterns`. Falls straight
        // through to the grep path below on a miss (graph not populated yet,
        // symbol not indexed, disabled, etc.) so behavior never regresses.
        if let codeGraphIndexer {
            do {
                let graphResult = try await graphMatches(for: query, in: resolvedPath, indexer: codeGraphIndexer, language: language)
                let graphResults = graphResult.lines
                if !graphResults.isEmpty {
                    let truncated = Array(graphResults.prefix(50))
                    let omitted = graphResults.count > 50 ? graphResults.count - 50 : 0
                    let marker = omitted > 0 ? "[... \(omitted) more results omitted ...]" : nil
                    return ToolResult(content: truncated.joined(separator: "\n"), truncationMarker: marker)
                }
                // Distinguishes "the SQL query itself found nothing" from "it
                // found rows but they got filtered out by scope/language/ignore
                // rules below" — same 0-results outcome, very different cause.
                let reason: String
                if let filterDebug = graphResult.filterDebug {
                    reason = "\(graphResult.rawMatchCount) raw match(es) from SQL, 0 survived post-filtering: \(filterDebug)"
                } else {
                    reason = "0 graph matches"
                }
                await Self.logGraphFallback(query: query, reason: reason, indexer: codeGraphIndexer)
            } catch {
                await Self.logGraphFallback(query: query, reason: "graph lookup threw: \(error)", indexer: codeGraphIndexer)
            }
        }

        // Build patterns for common code definitions
        let patterns = symbolPatterns(for: query, language: language)
        var allResults: [String] = []

        for pattern in patterns {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/grep")

            process.arguments = [
                "-rnI", "-E",
            ] + includeArguments(for: language) + excludeDirArguments() + [
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
                    return !permissions.isPathIgnored(pathPart) && !BuildOutputFilter.isBuildOutput(path: pathPart)
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

    /// Exact-name lookup, falling back to an FTS prefix search, against the
    /// auto-recorded code graph (`Sources/CodeGraph/`). Returns grep-shaped
    /// `path:line: kind name — signature` lines so callers can't tell the
    /// difference from the regex path below.
    private func graphMatches(for query: String, in resolvedPath: String, indexer: CodeGraphIndexer, language: String?) async throws -> (lines: [String], rawMatchCount: Int, filterDebug: String?) {
        guard await indexer.status().enabled else { return ([], 0, nil) }

        var matches = try await indexer.store.findSymbols(named: query, limit: 25)
        if matches.isEmpty {
            matches = try await indexer.store.searchSymbols(query: query, limit: 25)
        }
        guard !matches.isEmpty else { return ([], 0, nil) }
        let rawMatchCount = matches.count

        let scopePrefix = relativizePath(resolvedPath)
        let extFilter = language.flatMap(languageExtension(_:))

        func rejectionReason(_ match: CodeGraphStore.SymbolRow) -> String? {
            if let extFilter, !match.path.hasSuffix(".\(extFilter)") { return "ext(\(extFilter))" }
            if scopePrefix != "." && !(match.path == scopePrefix || match.path.hasPrefix(scopePrefix + "/")) {
                return "scope(prefix=\(scopePrefix))"
            }
            if permissions.isPathIgnored(match.path) { return "ignored" }
            if BuildOutputFilter.isBuildOutput(path: match.path) { return "buildOutput" }
            return nil
        }

        let lines = matches
            .filter { rejectionReason($0) == nil }
            .map { match in
                var line = "\(match.path):\(match.startLine): \(match.kind) \(match.symbolKey)"
                if let signature = match.signature, !signature.isEmpty {
                    line += " — \(signature)"
                }
                return line
            }

        // Only computed when everything got rejected — first raw match's
        // rejection reason plus the resolvedPath/scopePrefix this call used,
        // so a filtered-to-zero outcome is root-causeable instead of another
        // opaque "0 graph matches".
        let filterDebug: String? = lines.isEmpty
            ? "resolvedPath=\(resolvedPath) scopePrefix=\(scopePrefix) firstMatchPath=\(matches[0].path) reason=\(rejectionReason(matches[0]) ?? "unknown")"
            : nil

        return (lines, rawMatchCount, filterDebug)
    }

    /// Diagnostic-only breadcrumb for the "graph was wired but produced
    /// nothing" case, so a fallback to the grep path below is root-causeable
    /// after the fact instead of indistinguishable from a normal grep hit
    /// (see `graphMatches`'s doc comment — its output is deliberately
    /// grep-shaped). Fires only on a miss/error, never on a hit, so this
    /// stays silent during normal operation. Best-effort: any failure to
    /// write is swallowed, mirroring `ToolAuditLogger`'s non-fatal logging.
    private static func logGraphFallback(query: String, reason: String, indexer: CodeGraphIndexer) async {
        let status = await indexer.status()
        // Raw totals straight off this actor's own SQLite connection — tells
        // us whether the connection sees a populated DB at all (rules a
        // wrong/empty dbPath in or out) as distinct from "this one name
        // legitimately isn't in there yet".
        let stats = try? await indexer.store.stats()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let logPath = "\(home)/.mlx-coder/code_search_fallback.log"

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let payload: [String: Any] = [
            "timestamp": isoFormatter.string(from: Date()),
            "query": query,
            "reason": reason,
            "graph_enabled": status.enabled,
            "graph_pending_count": status.pendingCount,
            "graph_total_indexed": status.totalIndexed,
            "graph_last_error": status.lastError ?? "",
            "store_file_count": stats?.fileCount ?? -1,
            "store_symbol_count": stats?.symbolCount ?? -1,
            "store_edge_count": stats?.edgeCount ?? -1,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8)?.appending("\n"),
              let lineData = line.data(using: .utf8) else {
            return
        }

        let directory = URL(filePath: logPath).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // O_APPEND for atomic short writes across concurrent processes/sub-agents
        // — see ToolAuditLogger.write for the same rationale.
        let fd: Int32 = logPath.withCString { path in
            open(path, O_WRONLY | O_CREAT | O_APPEND, mode_t(0o600))
        }
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = lineData.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return write(fd, base, buffer.count)
        }
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

    private func excludeDirArguments() -> [String] {
        (BuildOutputFilter.ignoredNames.union(BuildOutputFilter.harnessArtifactNames))
            .map { "--exclude-dir=\($0)" }
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
