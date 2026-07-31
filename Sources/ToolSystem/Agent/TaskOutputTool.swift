// Sources/ToolSystem/Agent/TaskOutputTool.swift
// Rehydrate a previously-run sub-agent's full raw output from its archive.

import Foundation

/// Reads back the archived transcript of a previous `task(...)` delegation.
///
/// Every `task` call archives its sub-agent's full `[Message]` history under
/// `.native-agent/subagent-logs/<runID>/history.json` (see
/// `TaskTool.archiveSubagentRun`) and prints the run's directory on the
/// digest's `archive:` line. The orchestrator has no filesystem access of its
/// own, so when a digest comes back `status: partial` / `stdout_truncated:
/// true` its only previous recourse was to spawn *another* sub-agent just to
/// re-read the log — slow, costs a model turn, and can itself come back
/// truncated. This tool closes that gap: it reads the archived `history.json`
/// directly and returns the exact content that got cut. Read-only and
/// workspace-sandboxed, so it's safe to expose alongside the orchestrator's
/// other manager tools.
public struct TaskOutputTool: Tool {
    /// Default cap on returned characters — generous enough for a full
    /// truncated tool result, bounded so a huge archived transcript can't
    /// blow up the orchestrator's own context (mirrors `task`'s raw ceiling).
    static let defaultMaxCharacters = 50_000

    public let name = "task_output"
    public let description = "Recover the full, un-truncated output of a prior `task` delegation — no re-run or new sub-agent needed. Pass `archive` from a digest's `archive:` line (e.g. .native-agent/subagent-logs/<id>), the bare run id, or the digest's `tool_output:` spool path (which is read back directly). `include`: 'tool_output' (default — every tool result the sub-agent saw, i.e. what got truncated), 'final' (its last message), or 'all' (full transcript); ignored when reading a spool path. `max_chars` caps the result (default 50000)."
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "archive": PropertySchema(type: "string", description: "Archive path from a digest's `archive:` line (e.g. .native-agent/subagent-logs/<id>), a direct path to its history.json, or just the bare <id>."),
            "include": PropertySchema(type: "string", description: "What to extract (default: tool_output).", enumValues: ["tool_output", "final", "all"]),
            "max_chars": PropertySchema(type: "integer", description: "Max characters to return (default 50000)."),
        ],
        required: ["archive"]
    )

    private let permissions: PermissionEngine

    public init(permissions: PermissionEngine) {
        self.permissions = permissions
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let rawArchive = (arguments["archive"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !rawArchive.isEmpty else {
            return .error("Missing required argument: archive (the path from a `task` digest's `archive:` line, or the bare run id).")
        }

        let include = (arguments["include"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "tool_output"
        guard ["tool_output", "final", "all"].contains(include) else {
            return .error("Invalid argument value: include must be one of 'tool_output', 'final', 'all'.")
        }

        let maxChars = (arguments["max_chars"] as? Int).map { max(0, $0) } ?? Self.defaultMaxCharacters

        // A digest carries two different pointers — `archive:` (the run log) and
        // `tool_output:` (a large-output spool file under the system temp dir).
        // Small models routinely pass the spool path here instead of the archive
        // path; treated as a run dir it becomes `<spool>.txt/history.json`, which
        // is nonsense and lands outside the read roots. Recognize a spool path
        // and read the already-flat tool output straight back — that's exactly
        // what the caller was reaching for anyway. `include` doesn't apply (the
        // spool holds raw tool output, not a transcript), so it's ignored here.
        if ToolOutputSpool.shared.isWithinRoot(rawArchive) {
            guard FileManager.default.fileExists(atPath: rawArchive) else {
                return .error("No spooled output at \(rawArchive) — it may have been pruned. Re-run the task with response_mode:\"raw\" to regenerate it.")
            }
            guard let content = try? String(contentsOfFile: rawArchive, encoding: .utf8) else {
                return .error("Failed to read spooled tool output at \(rawArchive).")
            }
            return Self.capped(content, maxChars: maxChars)
        }

        let historyRelative = Self.resolveHistoryPath(rawArchive)

        let resolvedPath: String
        do {
            resolvedPath = try permissions.validateReadPath(historyRelative)
        } catch {
            return .error(error.localizedDescription)
        }

        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            return .error("No archive found: \(historyRelative). Pass the exact `archive:` path from the digest, or its bare run id.")
        }

        let messages: [Message]
        do {
            let data = try Data(contentsOf: URL(filePath: resolvedPath))
            messages = try JSONDecoder().decode([Message].self, from: data)
        } catch {
            return .error("Failed to read archived sub-agent log \(historyRelative): \(error.localizedDescription)")
        }

        let extracted: String
        switch include {
        case "final":
            extracted = Self.extractFinal(from: messages)
        case "all":
            extracted = Self.extractAll(from: messages)
        default:
            extracted = Self.extractToolOutput(from: messages)
        }

        return Self.capped(extracted, maxChars: maxChars)
    }

    /// Resolves the `archive` argument to a workspace-relative `history.json`
    /// path. Accepts three forms the orchestrator might have on hand:
    ///   - a direct path to the log file (`.../history.json`) — used as-is;
    ///   - the run directory (`.native-agent/subagent-logs/<id>`) — the common
    ///     `archive:` digest form — gets `/history.json` appended;
    ///   - a bare `<id>` (if it only remembers the run id or copied just the
    ///     trailing path component) — expanded to the full log path.
    static func resolveHistoryPath(_ archive: String) -> String {
        if archive.hasSuffix(".json") {
            return archive
        }
        // Models sometimes append the digest's `tool_output:` label onto the
        // `archive:` run dir (e.g. ".../subagent-logs/<id>/tool_output"). That
        // isn't a real file — strip it back to the run dir so the archive still
        // resolves instead of forming a nonsense ".../tool_output/history.json".
        var normalized = archive
        for suffix in ["/tool_output", "/tool_output.txt"] where normalized.hasSuffix(suffix) {
            normalized.removeLast(suffix.count)
            break
        }
        if normalized.contains("/") {
            return "\(normalized)/history.json"
        }
        return ".native-agent/subagent-logs/\(normalized)/history.json"
    }

    static func extractToolOutput(from messages: [Message]) -> String {
        let toolMessages = messages.filter { $0.role == .tool }
        guard !toolMessages.isEmpty else {
            return "Sub-agent produced no tool output."
        }
        return toolMessages.map { message in
            let label = message.toolCallId ?? "tool"
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return "--- \(label) ---\n\(content)"
        }.joined(separator: "\n\n")
    }

    static func extractFinal(from messages: [Message]) -> String {
        let final = messages
            .last(where: { $0.role == .assistant })?
            .content
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let final, !final.isEmpty else {
            return "Sub-agent wrote no final assistant response."
        }
        return final
    }

    static func extractAll(from messages: [Message]) -> String {
        guard !messages.isEmpty else {
            return "Archived log has no messages."
        }
        return messages.map { message -> String in
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if let toolCallId = message.toolCallId {
                return "[\(message.role.rawValue):\(toolCallId)] \(content)"
            }
            return "[\(message.role.rawValue)] \(content)"
        }.joined(separator: "\n\n")
    }

    /// Caps `text` to `maxChars`. When truncation actually happens it surfaces
    /// a structured `truncationMarker` (with the returned/total counts) rather
    /// than silently cutting the recovered output — silently dropping content
    /// would defeat the whole point of this tool.
    static func capped(_ text: String, maxChars: Int) -> ToolResult {
        guard maxChars > 0, text.count > maxChars else { return .success(text) }
        let clipped = String(text.prefix(maxChars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return ToolResult(
            content: clipped,
            truncationMarker: "[Recovered output is \(text.count) chars; cut to the first \(maxChars). Raise max_chars or narrow `include` to see more.]"
        )
    }
}
