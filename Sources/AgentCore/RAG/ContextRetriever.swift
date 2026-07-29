// Sources/AgentCore/RAG/ContextRetriever.swift
// Lightweight, Rider-faithful pre-turn context retrieval.
//
// Reproduces the cheap staged pipeline JetBrains Rider uses to turn a one-line
// request into an excellent edit — WITHOUT embeddings or a persistent index:
//
//   Stage 1  Subquery expansion    (1 LLM call → name-based search queries)
//   Stage 2  Candidate gathering   (lexical code_search, no LLM, deterministic)
//   Stage 3  Per-file relevance    (cheap LLM yes/no per candidate, budgeted)
//   Stage 4  Snippet materialize   (read the relevant region under a token cap)
//   Stage 5  Assemble a <context> block injected alongside the user turn
//
// Every stage degrades gracefully: offline / tiny-model / timeout / empty →
// skip that stage, never throw into the turn. The whole thing returns an
// optional context string; `nil` means "inject nothing, proceed as before".

import Foundation

/// Tunables for the pre-turn context retrieval stage. Defaults are conservative
/// and the feature ships **off** (`enabled == false`) until validated live.
public struct ContextRetrievalConfig: Sendable, Equatable, Codable {
    /// Master switch. When false, `ContextRetriever` is never constructed/run.
    public var enabled: Bool
    /// Hard cap on distinct candidate files handed to the relevance filter.
    public var maxCandidates: Int
    /// How many relevance (yes/no) calls run concurrently.
    public var relevanceConcurrency: Int
    /// Soft deadline for the whole relevance stage; on elapse, keep whatever
    /// resolved "yes" so far (or fall back to top-K lexical candidates).
    public var timeBudgetSeconds: Double
    /// Global token budget for the assembled context block (`chars/4` estimate).
    public var tokenBudget: Int
    /// Minimum user-message length (chars) for the gate to fire.
    public var minMessageChars: Int
    /// Max subqueries kept from Stage 1.
    public var maxSubqueries: Int
    /// Lines of each candidate fed to the relevance filter.
    public var relevanceFileHeadLines: Int
    /// Lines of context around a match materialized into the snippet.
    public var snippetContextLines: Int

    public init(
        enabled: Bool = false,
        maxCandidates: Int = 24,
        relevanceConcurrency: Int = 4,
        timeBudgetSeconds: Double = 20,
        tokenBudget: Int = 4000,
        minMessageChars: Int = 24,
        maxSubqueries: Int = 5,
        relevanceFileHeadLines: Int = 120,
        snippetContextLines: Int = 40
    ) {
        self.enabled = enabled
        self.maxCandidates = max(1, maxCandidates)
        self.relevanceConcurrency = max(1, relevanceConcurrency)
        self.timeBudgetSeconds = max(0, timeBudgetSeconds)
        self.tokenBudget = max(256, tokenBudget)
        self.minMessageChars = max(0, minMessageChars)
        self.maxSubqueries = max(1, maxSubqueries)
        self.relevanceFileHeadLines = max(10, relevanceFileHeadLines)
        self.snippetContextLines = max(4, snippetContextLines)
    }

    /// The disabled default — used everywhere the feature isn't explicitly on.
    public static let disabled = ContextRetrievalConfig(enabled: false)

    // Lenient decoding: every field is optional so a partial `contextRetrieval`
    // object in config.json falls back to the defaults above.
    private enum CodingKeys: String, CodingKey {
        case enabled, maxCandidates, relevanceConcurrency, timeBudgetSeconds
        case tokenBudget, minMessageChars, maxSubqueries
        case relevanceFileHeadLines, snippetContextLines
    }

    public init(from decoder: Decoder) throws {
        let d = ContextRetrievalConfig()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled,
            maxCandidates: try c.decodeIfPresent(Int.self, forKey: .maxCandidates) ?? d.maxCandidates,
            relevanceConcurrency: try c.decodeIfPresent(Int.self, forKey: .relevanceConcurrency) ?? d.relevanceConcurrency,
            timeBudgetSeconds: try c.decodeIfPresent(Double.self, forKey: .timeBudgetSeconds) ?? d.timeBudgetSeconds,
            tokenBudget: try c.decodeIfPresent(Int.self, forKey: .tokenBudget) ?? d.tokenBudget,
            minMessageChars: try c.decodeIfPresent(Int.self, forKey: .minMessageChars) ?? d.minMessageChars,
            maxSubqueries: try c.decodeIfPresent(Int.self, forKey: .maxSubqueries) ?? d.maxSubqueries,
            relevanceFileHeadLines: try c.decodeIfPresent(Int.self, forKey: .relevanceFileHeadLines) ?? d.relevanceFileHeadLines,
            snippetContextLines: try c.decodeIfPresent(Int.self, forKey: .snippetContextLines) ?? d.snippetContextLines
        )
    }
}

/// The staged pipeline. Constructed per-turn with the active model client and
/// workspace permissions; `retrieve` runs the stages and returns the assembled
/// `<context>` block (or nil).
public struct ContextRetriever: Sendable {

    /// A distinct candidate file, aggregated from one or more lexical hits.
    public struct Candidate: Sendable, Equatable {
        public let path: String
        /// A representative match line (1-indexed) used to center the snippet.
        public let line: Int
        /// The matched text of the representative hit (for debugging/logging).
        public let matchText: String
        /// How many lexical hits pointed at this file (relevance signal).
        public let matchCount: Int
    }

    let llm: LLMClient
    let permissions: PermissionEngine
    let config: ContextRetrievalConfig
    /// Optional verbose sink (assembled block, stage counts) for `--verbose`.
    let log: (@Sendable (String) -> Void)?

    public init(
        llm: LLMClient,
        permissions: PermissionEngine,
        config: ContextRetrievalConfig,
        log: (@Sendable (String) -> Void)? = nil
    ) {
        self.llm = llm
        self.permissions = permissions
        self.config = config
        self.log = log
    }

    // MARK: - Gate (Stage 0)

    /// Whether the pipeline should run for this turn. Pure so it can be tested
    /// without a model. Callers pass the primitives (AgentLoop's `role`,
    /// `taskType`, the flag, and the raw message).
    public static func gatePasses(
        enabled: Bool,
        isTopLevel: Bool,
        isCoding: Bool,
        message: String,
        minChars: Int
    ) -> Bool {
        guard enabled, isTopLevel, isCoding else { return false }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= minChars
    }

    // MARK: - Orchestration

    /// Run the full pipeline. Returns the assembled `<context>` block, or nil
    /// when nothing relevant was found / the stages degraded to empty. Never
    /// throws — every failure resolves to nil or a partial result.
    public func retrieve(userRequest: String) async -> String? {
        let request = userRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return nil }

        // Stage 1 — subquery expansion (LLM, with raw-request fallback).
        let subqueries = await expandSubqueries(request: request)
        log?("[context] stage1: \(subqueries.count) subquer\(subqueries.count == 1 ? "y" : "ies")")

        // Stage 2 — lexical candidate gathering (deterministic).
        let candidates = await gatherCandidates(subqueries: subqueries)
        guard !candidates.isEmpty else {
            log?("[context] stage2: no candidates — skipping injection")
            return nil
        }
        log?("[context] stage2: \(candidates.count) candidate file(s)")

        // Stage 3 — per-file relevance filter (LLM yes/no, budgeted).
        let survivors = await filterByRelevance(candidates: candidates, request: request)
        guard !survivors.isEmpty else {
            log?("[context] stage3: nothing survived relevance — skipping injection")
            return nil
        }
        log?("[context] stage3: \(survivors.count) file(s) kept")

        // Stage 4 — materialize snippets under the token budget.
        let materialized = await materialize(files: survivors)
        guard !materialized.isEmpty else { return nil }

        // Stage 5 — assemble.
        let block = Self.assembleContextBlock(files: materialized)
        log?("[context] stage5: injecting \(materialized.count) file(s), ~\(Self.estimateTokens(block)) tokens")
        return block
    }

    // MARK: - Stage 1: subquery expansion

    func expandSubqueries(request: String) async -> [String] {
        guard llm.isUsable else { return [request] }
        let prompt = Self.subqueryPrompt(userRequest: request)
        guard let raw = try? await llm.complete(prompt: prompt, maxTokens: 128, temperature: 0),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return [request]
        }
        let parsed = Self.parseSubqueries(raw, max: config.maxSubqueries)
        return parsed.isEmpty ? [request] : parsed
    }

    /// Parse the model's line-per-query output into a clean, deduped list.
    /// Strips numbering, bullets, quotes, and Markdown fences.
    static func parseSubqueries(_ raw: String, max: Int) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for rawLine in raw.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("```") { continue }
            // Strip common list markers: "1.", "1)", "-", "*", "•".
            line = stripLeadingListMarker(line)
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
                .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // Skip obvious prose lines the model sometimes prepends.
            let lower = line.lowercased()
            if lower.hasPrefix("here are") || lower.hasPrefix("search queries")
                || lower.hasPrefix("queries:") { continue }
            let key = line.lowercased()
            if seen.insert(key).inserted {
                out.append(line)
                if out.count >= max { break }
            }
        }
        return out
    }

    private static func stripLeadingListMarker(_ line: String) -> String {
        var s = Substring(line)
        // Numbered: leading digits followed by '.' or ')'.
        if let first = s.first, first.isNumber {
            var idx = s.startIndex
            while idx < s.endIndex, s[idx].isNumber { idx = s.index(after: idx) }
            if idx < s.endIndex, s[idx] == "." || s[idx] == ")" {
                s = s[s.index(after: idx)...]
            }
        }
        // Bullets.
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "• ", "-", "*", "•"] {
            if trimmed.hasPrefix(marker) {
                return String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return trimmed
    }

    // MARK: - Stage 2: candidate gathering

    func gatherCandidates(subqueries: [String]) async -> [Candidate] {
        let tool = CodeSearchTool(permissions: permissions)
        var rawHits: [(path: String, line: Int, text: String)] = []
        for query in subqueries {
            if Task.isCancelled { break }
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let result = try? await tool.execute(arguments: ["query": trimmed]),
                  !result.isError else { continue }
            rawHits.append(contentsOf: Self.parseSearchLines(result.content))
        }
        return aggregateCandidates(from: rawHits, cap: config.maxCandidates)
    }

    /// Parse `code_search` / `grep`-style `.content` into raw hits. Accepts the
    /// `path:line:text` form; skips markers, empties, and unparsable lines.
    static func parseSearchLines(_ content: String) -> [(path: String, line: Int, text: String)] {
        var hits: [(String, Int, String)] = []
        for rawLine in content.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // Skip truncation markers and "no results" sentinels.
            if line.hasPrefix("[...") || line.hasPrefix("[Read") { continue }
            if line.hasPrefix("No code symbols") { continue }
            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }
            let path = String(parts[0]).trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty, let lineNo = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { continue }
            let text = String(parts[2])
            hits.append((path, lineNo, text))
        }
        return hits
    }

    /// Aggregate raw hits into distinct candidates: dedupe by path, drop ignored
    /// paths, rank by hit count (desc, stable on first-seen order), cap.
    func aggregateCandidates(
        from rawHits: [(path: String, line: Int, text: String)],
        cap: Int
    ) -> [Candidate] {
        struct Acc { var line: Int; var text: String; var count: Int; var order: Int }
        var byPath: [String: Acc] = [:]
        var order = 0
        for hit in rawHits {
            if permissions.isPathIgnored(hit.path) { continue }
            if var acc = byPath[hit.path] {
                acc.count += 1
                byPath[hit.path] = acc
            } else {
                byPath[hit.path] = Acc(line: hit.line, text: hit.text, count: 1, order: order)
                order += 1
            }
        }
        let sorted = byPath.sorted { lhs, rhs in
            if lhs.value.count != rhs.value.count { return lhs.value.count > rhs.value.count }
            return lhs.value.order < rhs.value.order
        }
        return sorted.prefix(cap).map { entry in
            Candidate(path: entry.key, line: entry.value.line, matchText: entry.value.text, matchCount: entry.value.count)
        }
    }

    // MARK: - Stage 3: relevance filter

    func filterByRelevance(candidates: [Candidate], request: String) async -> [Candidate] {
        // Offline / tiny-model with no usable LLM: keep the top-K lexical
        // candidates so the pipeline still injects useful context.
        guard llm.isUsable else {
            return Array(candidates.prefix(topKFallbackCount))
        }

        let indexByPath = Dictionary(uniqueKeysWithValues: candidates.enumerated().map { ($0.element.path, $0.offset) })
        let sink = RelevanceSink()
        let concurrency = config.relevanceConcurrency

        let filterOp: @Sendable () async -> Void = {
            await withTaskGroup(of: Void.self) { group in
                var iterator = candidates.makeIterator()
                func addNext(_ next: Candidate?) {
                    guard let cand = next else { return }
                    group.addTask {
                        if Task.isCancelled { return }
                        if await self.isRelevant(cand, request: request) {
                            await sink.add(cand)
                        }
                    }
                }
                for _ in 0..<concurrency { addNext(iterator.next()) }
                while await group.next() != nil {
                    if Task.isCancelled { break }
                    addNext(iterator.next())
                }
            }
        }

        _ = await Self.raceWithBudget(timeBudget: config.timeBudgetSeconds, filterOp)
        var kept = await sink.snapshot()

        if kept.isEmpty {
            // Nothing resolved "yes" (all no, or the budget elapsed before any
            // call returned) — fall back to the top-K lexical candidates.
            return Array(candidates.prefix(topKFallbackCount))
        }

        // Restore the lexical (match-count) ordering; completion order is arbitrary.
        kept.sort { (indexByPath[$0.path] ?? .max) < (indexByPath[$1.path] ?? .max) }
        return kept
    }

    /// Number of lexical candidates to keep when the relevance stage can't run
    /// or produces nothing — bounded so we never dump the whole candidate set.
    private var topKFallbackCount: Int { max(1, min(5, config.maxCandidates)) }

    func isRelevant(_ candidate: Candidate, request: String) async -> Bool {
        guard let head = await readFileRegion(
            path: candidate.path,
            start: 1,
            end: config.relevanceFileHeadLines
        ), !head.isEmpty else { return false }

        let prompt = Self.relevancePrompt(userRequest: request, path: candidate.path, fileOrSnippet: head)
        guard let raw = try? await llm.complete(prompt: prompt, maxTokens: 4, temperature: 0) else {
            return false
        }
        return Self.parseYesNo(raw)
    }

    /// Lowercase + `hasPrefix("yes")` — matches the Rider capture's contract.
    static func parseYesNo(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("yes")
    }

    // MARK: - Stage 4: materialize snippets

    struct MaterializedFile: Sendable, Equatable {
        let path: String
        let snippet: String
    }

    func materialize(files: [Candidate]) async -> [MaterializedFile] {
        var out: [MaterializedFile] = []
        var usedTokens = 0
        let ctx = config.snippetContextLines

        for file in files {
            if Task.isCancelled { break }
            let start = max(1, file.line - ctx)
            let end = file.line <= 1 ? (ctx * 2) : (file.line + ctx)
            guard let snippet = await readFileRegion(path: file.path, start: start, end: end),
                  !snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }

            let entry = MaterializedFile(path: file.path, snippet: snippet)
            let cost = Self.estimateTokens(Self.renderFile(entry))
            if usedTokens + cost > config.tokenBudget {
                // Budget hit — most-relevant-first, so stop adding here.
                if out.isEmpty {
                    // Always inject at least the single most relevant file, even
                    // if it alone exceeds the budget: clamp it and include it.
                    let clamped = Self.clampSnippet(snippet, tokenBudget: config.tokenBudget)
                    out.append(MaterializedFile(path: file.path, snippet: clamped))
                }
                break
            }
            usedTokens += cost
            out.append(entry)
        }
        return out
    }

    func readFileRegion(path: String, start: Int, end: Int) async -> String? {
        let tool = ReadFileTool(permissions: permissions)
        let args: [String: Any] = ["path": path, "start_line": max(1, start), "end_line": max(start, end)]
        guard let result = try? await tool.execute(arguments: args), !result.isError else { return nil }
        return result.content
    }

    // MARK: - Stage 5: assembly

    /// Build the `<context>` block injected alongside the user turn. Mirrors the
    /// sub-agent `<task>` envelope style already used in TaskTool.
    static func assembleContextBlock(files: [MaterializedFile]) -> String {
        var lines: [String] = []
        lines.append("<context>")
        lines.append("Files that may be relevant to the task (gathered automatically; ignore any that aren't needed):")
        for file in files {
            lines.append(renderFile(file))
        }
        lines.append("</context>")
        lines.append("Don't reference these context files unless they're actually needed for the task.")
        return lines.joined(separator: "\n")
    }

    static func renderFile(_ file: MaterializedFile) -> String {
        let lang = languageHint(forPath: file.path)
        return """
        <file path="\(file.path)">
        ```\(lang)
        \(file.snippet)
        ```
        </file>
        """
    }

    static func languageHint(forPath path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "py": return "python"
        case "js", "mjs", "cjs": return "javascript"
        case "ts", "tsx": return "typescript"
        case "cs": return "csharp"
        case "java": return "java"
        case "go": return "go"
        case "rs": return "rust"
        case "rb": return "ruby"
        case "kt", "kts": return "kotlin"
        case "c", "h": return "c"
        case "cpp", "cc", "hpp": return "cpp"
        case "json": return "json"
        case "md": return "markdown"
        case "sh", "bash", "zsh": return "bash"
        default: return ""
        }
    }

    // MARK: - Budget helpers

    /// Rough token estimate — mirrors `KnowledgeRetriever.estimateTokens` (len/4).
    static func estimateTokens(_ text: String) -> Int { text.count / 4 }

    /// Clamp a single snippet so its rendered form fits under the token budget.
    static func clampSnippet(_ snippet: String, tokenBudget: Int) -> String {
        let maxChars = max(64, tokenBudget * 4 - 128) // leave room for the wrapper
        guard snippet.count > maxChars else { return snippet }
        return String(snippet.prefix(maxChars)) + "\n… [truncated]"
    }

    // MARK: - Time-budget race

    /// Run `op` with a soft deadline. Returns true if `op` completed, false on
    /// timeout. The op task is cancelled on timeout so its child tasks stop and
    /// any partial results already collected remain usable. Mirrors
    /// `LLMReranker.raceWithBudget` (adapted for a Void op).
    static func raceWithBudget(
        timeBudget: TimeInterval,
        _ op: @escaping @Sendable () async -> Void
    ) async -> Bool {
        guard timeBudget > 0 else {
            await op()
            return true
        }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { await op(); return true }
            group.addTask {
                let nanos = UInt64(max(0, timeBudget) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    // MARK: - Prompt templates (adapted from the Rider captures)

    static func subqueryPrompt(userRequest: String) -> String {
        """
        You are given a developer's request about a codebase. Produce a short list of search \
        queries that would help LOCATE the relevant code BY NAME (symbols, classes, methods, files). \
        Most important query first. Output ONLY the queries, one per line — no numbering, no prose.

        Request:
        \(userRequest)
        """
    }

    static func relevancePrompt(userRequest: String, path: String, fileOrSnippet: String) -> String {
        """
        Determine whether the following file is required to solve this task:
        "\(userRequest)"

        File: \(path)
        ```
        \(fileOrSnippet)
        ```
        Answer with exactly one word: yes or no.
        """
    }
}

/// Concurrency-safe collector for relevance survivors so a budgeted TaskGroup
/// can be cancelled mid-flight while keeping whatever already resolved "yes".
actor RelevanceSink {
    private var kept: [ContextRetriever.Candidate] = []
    func add(_ candidate: ContextRetriever.Candidate) { kept.append(candidate) }
    func snapshot() -> [ContextRetriever.Candidate] { kept }
}
