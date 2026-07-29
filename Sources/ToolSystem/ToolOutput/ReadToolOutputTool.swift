// Sources/ToolSystem/ToolOutput/ReadToolOutputTool.swift
// Read line ranges from a spooled large-tool-output file.
//
// Large tool results (bash, etc.) are written whole to the ToolOutputSpool and
// only a bounded window is returned inline (see ToolOutputSpoolPolicy). This
// tool lets the model — orchestrator or sub-agent — page the rest by line range.
//
// Deliberately separate from `read_file`: it reads ONLY from the spool root
// (system-temp), never the workspace, so it doesn't widen `read_file`'s
// workspace-scoped read boundary. Its own path check rejects anything outside
// the spool directory.

import Foundation

public struct ReadToolOutputTool: Tool {
    /// Default cap on lines returned per call — matches `ReadFileTool` so paging
    /// feels identical, and bounds how much a single read can pull into context.
    public static let defaultMaxLines = 500

    public let name = "read_tool_output"
    public let description = "Read a line range from a spooled tool-output file (the path printed on a '[Large tool output spooled to disk]' notice, or a sub-agent digest's `tool_output:` line). Use start_line/end_line to page through it — the full output is already on disk, so never re-run the original tool just to see more. Reads only spool files, not workspace files (use read_file for those)."
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "path": PropertySchema(type: "string", description: "Absolute path to the spool file, exactly as printed on the spool notice / digest `tool_output:` line."),
            "start_line": PropertySchema(type: "integer", description: "First line to read (1-indexed, default 1). Use the continuation hint from a previous read to resume."),
            "end_line": PropertySchema(type: "integer", description: "Last line to read (1-indexed, inclusive, optional; defaults to the end)."),
        ],
        required: ["path"]
    )

    private let spool: ToolOutputSpool
    private let maxLines: Int

    public init(spool: ToolOutputSpool = .shared, maxLines: Int = ReadToolOutputTool.defaultMaxLines) {
        self.spool = spool
        self.maxLines = max(1, maxLines)
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let path = (arguments["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return .error("Missing required argument: path (the spool file path from a '[Large tool output spooled to disk]' notice or a digest's `tool_output:` line).")
        }

        guard spool.isWithinRoot(path) else {
            return .error("'\(path)' is not a spooled tool-output file. read_tool_output only reads files under the tool-output spool directory. Use read_file for workspace files.")
        }

        guard FileManager.default.fileExists(atPath: path) else {
            return .error("Spool file not found: \(path). It may have expired — re-run the original tool to regenerate it.")
        }

        let startLine = arguments["start_line"] as? Int ?? 1
        let endLine = arguments["end_line"] as? Int

        guard let result = spool.readRange(path: path, start: startLine, end: endLine, maxLines: maxLines) else {
            return .error("Failed to read spool file: \(path)")
        }

        guard result.totalLines > 0, result.firstLine > 0 else {
            return .error("start_line \(startLine) is out of range (file has \(result.totalLines) lines).")
        }

        if result.lastLine < result.totalLines {
            let marker = "[Read lines \(result.firstLine)-\(result.lastLine) of \(result.totalLines). Output continues — call read_tool_output with start_line: \(result.lastLine + 1) to read the next section.]"
            return ToolResult(content: result.content, truncationMarker: marker)
        }
        return .success(result.content)
    }
}
