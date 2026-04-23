// Sources/Memory/SearchKnowledgeTool.swift
// LLM tool for searching durable memory entries on demand.

import Foundation

/// Tool that allows the LLM to search previously logged knowledge entries.
public struct SearchKnowledgeTool: Tool {
    public let name = "search_knowledge"
    public let description = """
    Search previously logged knowledge entries from this and past sessions.
    Use this when the user asks about past decisions, gotchas, plans, or patterns,
    or when you need context from prior sessions about this project.
    Returns relevant entries ranked by relevance to the query.
    """

    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "query": PropertySchema(
                type: "string",
                description: "Keywords or phrase to search for in stored knowledge"
            ),
            "type": PropertySchema(
                type: "string",
                description: "Optional: filter by entry type (decision, gotcha, pattern, plan, session_state)",
                enumValues: ["decision", "gotcha", "pattern", "plan", "session_state"]
            )
        ],
        required: ["query"]
    )

    private let workspaceRoot: String

    public init(workspaceRoot: String) {
        self.workspaceRoot = URL(fileURLWithPath: workspaceRoot).standardized.path
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let query = arguments["query"] as? String, !query.isEmpty else {
            return .error("Missing required argument: query")
        }

        let typeFilter = (arguments["type"] as? String).flatMap(KnowledgeType.init(rawValue:))

        let store = KnowledgeStore.shared
        do {
            try await store.initialize()
        } catch {
            return .error("Failed to initialize memory store: \(error.localizedDescription)")
        }

        do {
            var entries = try await store.search(query: query, projectRoot: workspaceRoot)

            if let typeFilter {
                entries = entries.filter { $0.type == typeFilter }
            }

            if entries.isEmpty {
                // Fall back to listing recent entries if FTS returns nothing
                let all = try await store.list(projectRoot: workspaceRoot, type: typeFilter, limit: 10)
                if all.isEmpty {
                    return .success("No knowledge entries found for this project.")
                }
                return .success(formatEntries(all, query: query, fallback: true))
            }

            return .success(formatEntries(entries, query: query, fallback: false))
        } catch {
            return .error("Search failed: \(error.localizedDescription)")
        }
    }

    private func formatEntries(_ entries: [KnowledgeEntry], query: String, fallback: Bool) -> String {
        var lines: [String] = []
        if fallback {
            lines.append("No FTS matches for \"\(query)\". Recent entries for this project:\n")
        } else {
            lines.append("Found \(entries.count) knowledge \(entries.count == 1 ? "entry" : "entries") matching \"\(query)\":\n")
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]

        for entry in entries {
            lines.append("[\(entry.type.rawValue)] \(formatter.string(from: entry.createdAt))")
            lines.append(entry.content)
            if !entry.tags.isEmpty {
                lines.append("Tags: \(entry.tags.joined(separator: ", "))")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}
