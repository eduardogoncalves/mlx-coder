// Sources/ToolSystem/Agent/ReadSubagentLogTool.swift
// Recover a sub-agent's full output from its archived run log.

import Foundation

/// Reads an archived sub-agent run and returns its final response verbatim.
///
/// Every `task(...)` delegation archives its full transcript under
/// `.native-agent/subagent-logs/<id>/` and prints that path on the digest's
/// `archive:` line. When a digest comes back truncated, the orchestrator — which
/// has no direct filesystem access of its own — previously had only one way to
/// recover the lost output: spawn *another* sub-agent just to read the log,
/// which is slow, costs a whole model turn, and can itself come back truncated.
///
/// This tool closes that gap: it reads the archived `history.json` directly and
/// returns the sub-agent's last assistant message (its real, un-compacted
/// summary) plus, optionally, the raw output of its final tool calls — no new
/// sub-agent required. It's read-only and scoped to the workspace sandbox, so
/// it's safe to expose to the orchestrator alongside its other manager tools.
public struct ReadSubagentLogTool: Tool {
    public let name = "read_subagent_log"
    public let description = "Recover the full, un-truncated output of a previous `task` delegation from its archived run log — no new sub-agent needed. Pass the `archive` path printed on a digest's `archive:` line (e.g. .native-agent/subagent-logs/<id>). Use this when a sub-agent digest came back truncated instead of re-running the work."
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "archive": PropertySchema(type: "string", description: "The archive path from a sub-agent digest's `archive:` line (workspace-relative, e.g. .native-agent/subagent-logs/<id>)."),
            "include_tool_output": PropertySchema(type: "boolean", description: "If true, also include the raw output of the sub-agent's last few tool calls (default: false — returns only its final assistant response)."),
        ],
        required: ["archive"]
    )

    /// Max characters of recovered content to return, mirroring `task`'s raw
    /// ceiling so a huge archived transcript can't blow up the orchestrator's
    /// own context.
    static let maxOutputCharacters = 50_000

    private let permissions: PermissionEngine

    public init(permissions: PermissionEngine) {
        self.permissions = permissions
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let archive = (arguments["archive"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !archive.isEmpty else {
            return .error("Missing required argument: archive (the path from a digest's `archive:` line)")
        }
        let includeToolOutput = arguments["include_tool_output"] as? Bool ?? false

        // Accept either the run directory itself or a direct path to history.json.
        let historyRelative = archive.hasSuffix(".json") ? archive : "\(archive)/history.json"

        let resolvedPath: String
        do {
            resolvedPath = try permissions.validateReadPath(historyRelative)
        } catch {
            return .error(error.localizedDescription)
        }

        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            return .error("Sub-agent log not found: \(historyRelative). Pass the exact `archive:` path from the digest.")
        }

        let messages: [Message]
        do {
            let data = try Data(contentsOf: URL(filePath: resolvedPath))
            messages = try JSONDecoder().decode([Message].self, from: data)
        } catch {
            return .error("Failed to read sub-agent log \(historyRelative): \(error.localizedDescription)")
        }

        let finalResponse = messages
            .last(where: { $0.role == .assistant })?
            .content
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var sections: [String] = []
        if let finalResponse, !finalResponse.isEmpty {
            sections.append("Final response from sub-agent:\n\(finalResponse)")
        } else {
            sections.append("Sub-agent wrote no final assistant response.")
        }

        if includeToolOutput {
            let toolMessages = messages.filter { $0.role == .tool }.suffix(5)
            if !toolMessages.isEmpty {
                let rendered = toolMessages.map { message -> String in
                    let name = message.toolCallId ?? "tool"
                    return "- \(name):\n\(message.content.trimmingCharacters(in: .whitespacesAndNewlines))"
                }.joined(separator: "\n\n")
                sections.append("Raw output from last \(toolMessages.count) tool call(s):\n\(rendered)")
            }
        }

        let combined = sections.joined(separator: "\n\n")
        if combined.count > Self.maxOutputCharacters {
            let clipped = String(combined.prefix(Self.maxOutputCharacters)).trimmingCharacters(in: .whitespacesAndNewlines)
            return ToolResult(
                content: clipped,
                truncationMarker: "[Recovered log exceeds \(Self.maxOutputCharacters) characters and was cut here.]"
            )
        }
        return .success(combined)
    }
}
