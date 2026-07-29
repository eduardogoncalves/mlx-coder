// Sources/ToolSystem/ToolOutput/ToolOutputSpool.swift
// Disk spool for large tool outputs.
//
// When a tool (bash, and other non-web/non-paging tools) produces output too
// large to drop verbatim into the model's context, the FULL output is written
// here and only a bounded window is returned inline — with a pointer telling the
// model to page the rest via `read_tool_output` (line ranges). This generalizes
// the on-disk paging `web_fetch` already does for web pages to arbitrary tool
// output, and gives sub-agents a line-addressable artifact to hand back to the
// orchestrator instead of a long verbatim tail.
//
// Files live under `<system-temp>/mlx-coder-tool-output/` (0700). Old spool
// files are pruned opportunistically on write so the directory stays bounded.

import Foundation

/// Tunables for the large-tool-output spool. Ships **on** — it strictly improves
/// on the previous char-truncation fallback (the full output stays recoverable).
public struct ToolOutputSpoolConfig: Sendable, Equatable, Codable {
    /// Master switch. When false, condensation falls back to char-truncation.
    public var enabled: Bool
    /// Minimum estimated tokens (`chars/4`) of a tool result before it is
    /// spooled to disk rather than trimmed inline.
    public var minTokensToSpool: Int
    /// Lines of the output kept inline (head or tail depending on the tool)
    /// alongside the spool pointer.
    public var inlineWindowLines: Int
    /// Minimum characters of a sub-agent digest body before the sub-agent
    /// spools its full output and hands the orchestrator a pointer + line range.
    public var subAgentMinChars: Int

    public init(
        enabled: Bool = true,
        minTokensToSpool: Int = 1200,
        inlineWindowLines: Int = 60,
        subAgentMinChars: Int = 4000
    ) {
        self.enabled = enabled
        self.minTokensToSpool = max(1, minTokensToSpool)
        self.inlineWindowLines = max(5, inlineWindowLines)
        self.subAgentMinChars = max(512, subAgentMinChars)
    }

    public static let enabledDefault = ToolOutputSpoolConfig()
    public static let disabled = ToolOutputSpoolConfig(enabled: false)

    // Lenient decoding: every field optional → partial config falls back to defaults.
    private enum CodingKeys: String, CodingKey {
        case enabled, minTokensToSpool, inlineWindowLines, subAgentMinChars
    }

    public init(from decoder: Decoder) throws {
        let d = ToolOutputSpoolConfig()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled,
            minTokensToSpool: try c.decodeIfPresent(Int.self, forKey: .minTokensToSpool) ?? d.minTokensToSpool,
            inlineWindowLines: try c.decodeIfPresent(Int.self, forKey: .inlineWindowLines) ?? d.inlineWindowLines,
            subAgentMinChars: try c.decodeIfPresent(Int.self, forKey: .subAgentMinChars) ?? d.subAgentMinChars
        )
    }
}

/// Disk spool for large tool output. Thread-safe: each `spool` writes a fresh,
/// uniquely-named file; reads are stateless.
public struct ToolOutputSpool: Sendable {

    /// A written spool file.
    public struct Handle: Sendable, Equatable {
        /// Absolute path to the spool file (passed to `read_tool_output`).
        public let path: String
        /// Total number of lines written.
        public let totalLines: Int
        /// Byte size of the written content.
        public let byteCount: Int
    }

    /// Result of reading a line range back out of a spool file.
    public struct ReadResult: Sendable, Equatable {
        public let content: String
        public let totalLines: Int
        /// 1-indexed first line returned.
        public let firstLine: Int
        /// 1-indexed last line returned.
        public let lastLine: Int
    }

    /// Files older than this are pruned on the next write. Long enough that a
    /// pointer handed to the orchestrator stays valid across a normal turn.
    static let maxAge: TimeInterval = 6 * 60 * 60

    public let root: URL

    public static let shared = ToolOutputSpool()

    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            self.root = FileManager.default.temporaryDirectory
                .appendingPathComponent("mlx-coder-tool-output", isDirectory: true)
        }
        ensureRoot()
    }

    private func ensureRoot() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: root.path) {
            try? fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    // MARK: - Write

    /// Write `content` to a fresh spool file. Returns nil if the content is
    /// empty or the write fails (callers then fall back to inline truncation).
    public func spool(content: String, toolName: String) -> Handle? {
        let trimmed = content
        guard !trimmed.isEmpty else { return nil }
        ensureRoot()
        pruneOldFilesBestEffort()

        let safeTool = Self.sanitizeToolName(toolName)
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let unique = UUID().uuidString.prefix(8)
        let fileURL = root.appendingPathComponent("\(stamp)-\(safeTool)-\(unique).txt")

        guard let data = content.data(using: .utf8) else { return nil }
        do {
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            return nil
        }
        return Handle(
            path: fileURL.path,
            totalLines: Self.lineCount(content),
            byteCount: data.count
        )
    }

    // MARK: - Read

    /// Whether `absolutePath` resolves inside this spool's root — the only paths
    /// `read_tool_output` is permitted to read.
    public func isWithinRoot(_ absolutePath: String) -> Bool {
        let normalizedRoot = root.standardized.resolvingSymlinksInPath().path
        let normalized = URL(filePath: absolutePath).standardized.resolvingSymlinksInPath().path
        return normalized == normalizedRoot || normalized.hasPrefix(normalizedRoot + "/")
    }

    /// Read a 1-indexed inclusive line range, capped at `maxLines`. Returns nil
    /// if the path is outside the spool root or unreadable.
    public func readRange(path: String, start: Int, end: Int?, maxLines: Int) -> ReadResult? {
        guard isWithinRoot(path) else { return nil }
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return Self.slice(content, start: start, end: end, maxLines: maxLines)
    }

    /// Pure line-range slicer (1-indexed, inclusive), shared with tests. Mirrors
    /// `ReadFileTool`'s trailing-newline accounting.
    static func slice(_ content: String, start: Int, end: Int?, maxLines: Int) -> ReadResult {
        var lines = content.components(separatedBy: "\n")
        if lines.count > 1, lines.last?.isEmpty == true {
            lines.removeLast()
        }
        let totalLines = lines.count
        guard totalLines > 0 else {
            return ReadResult(content: "", totalLines: 0, firstLine: 0, lastLine: 0)
        }

        let startIdx = max(1, start) - 1
        guard startIdx < totalLines else {
            return ReadResult(content: "", totalLines: totalLines, firstLine: 0, lastLine: 0)
        }
        let requestedEnd = end ?? totalLines
        let clampedEnd = min(max(requestedEnd, start), totalLines) // 1-indexed inclusive
        var selected = Array(lines[startIdx..<clampedEnd])
        if selected.count > max(1, maxLines) {
            selected = Array(selected.prefix(max(1, maxLines)))
        }
        let lastLine = startIdx + selected.count
        return ReadResult(
            content: selected.joined(separator: "\n"),
            totalLines: totalLines,
            firstLine: startIdx + 1,
            lastLine: lastLine
        )
    }

    // MARK: - Helpers

    static func lineCount(_ content: String) -> Int {
        guard !content.isEmpty else { return 0 }
        var lines = content.components(separatedBy: "\n")
        if lines.count > 1, lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines.count
    }

    static func sanitizeToolName(_ name: String) -> String {
        let allowed = name.lowercased().map { ch -> Character in
            (ch.isLetter || ch.isNumber || ch == "_" || ch == "-") ? ch : "-"
        }
        let s = String(allowed)
        return s.isEmpty ? "tool" : String(s.prefix(24))
    }

    private func pruneOldFilesBestEffort() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-Self.maxAge)
        for url in entries {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }
}

/// Policy helpers for deciding whether/how to spool a tool result and for
/// rendering the inline window + pointer message. Pure — unit-tested directly.
public enum ToolOutputSpoolPolicy {

    /// Tools that must NOT be spooled:
    /// - web tools page through their own on-disk cache;
    /// - the read tools already return bounded line ranges the model can re-page;
    /// - the tiny structural tools are never large enough to matter;
    /// - `task` is exempt because a sub-agent digest is a structured artifact
    ///   that already carries its own spool pointer (see `TaskTool` /
    ///   `makeSubagentDigest`). Re-spooling it here would keep only the tail
    ///   window and hide the digest's header (status, `tool_output:` pointer,
    ///   contract) — and defeat `response_mode: raw`, whose whole point is to
    ///   return the sub-agent's output to the orchestrator directly.
    static let spoolExemptTools: Set<String> = [
        "web_fetch", "web_search",
        "read_file", "read_many", "read_tool_output", "read_skill",
        "todo", "list_dir", "dir_list", "plan_file", "task",
    ]

    /// Shell-style tools whose most valuable content is at the END (exit status,
    /// errors, final results), so the inline window keeps the tail rather than
    /// the head. Mirrors `ToolResultCondensationPolicy.boundedFallbackRawMessage`.
    static let tailWindowTools: Set<String> = ["bash"]

    /// Whether `toolName`'s output is eligible for disk spooling.
    public static func isSpoolEligible(toolName: String) -> Bool {
        !spoolExemptTools.contains(toolName)
    }

    /// Build the inline message returned to the model: a bounded window of the
    /// output plus a pointer to the full spool file and how to page it.
    public static func windowMessage(
        toolName: String,
        raw: String,
        handle: ToolOutputSpool.Handle,
        windowLines: Int,
        estimatedTokens: Int
    ) -> String {
        let lines = raw.isEmpty ? [] : raw.components(separatedBy: "\n")
        let total = handle.totalLines
        let keepTail = tailWindowTools.contains(toolName)
        let n = max(1, windowLines)

        let window: String
        let shownFirst: Int
        let shownLast: Int
        if lines.count <= n {
            window = raw
            shownFirst = 1
            shownLast = total
        } else if keepTail {
            let tail = lines.suffix(n)
            window = tail.joined(separator: "\n")
            shownFirst = max(1, total - tail.count + 1)
            shownLast = total
        } else {
            let head = lines.prefix(n)
            window = head.joined(separator: "\n")
            shownFirst = 1
            shownLast = head.count
        }

        let windowNote = keepTail ? "last \(shownLast - shownFirst + 1) line(s)" : "first \(shownLast - shownFirst + 1) line(s)"
        return """
        [Large tool output spooled to disk — \(total) lines, ~\(estimatedTokens) tokens]
        Tool: \(toolName)
        Full output saved to: \(handle.path)
        Showing \(windowNote) (lines \(shownFirst)-\(shownLast) of \(total)). To read any other range, call read_tool_output with path "\(handle.path)" and start_line/end_line. Do NOT re-run the tool to see more — the full output is already on disk.

        \(window)
        """
    }

    /// A compact pointer suffix appended to an already-summarized result, so the
    /// model can still recover exact detail the summary may have dropped.
    public static func pointerSuffix(handle: ToolOutputSpool.Handle) -> String {
        """

        [Full tool output on disk: \(handle.path) — \(handle.totalLines) lines. Read specific ranges with read_tool_output(path, start_line, end_line) if you need exact detail.]
        """
    }
}
