// Sources/ToolSystem/Protocol/ToolRegistry.swift
// Thread-safe registry for tool lookup and system prompt generation

import Foundation

public struct ToolPromptFilter: Sendable {
    public let modeHint: String
    public let taskTypeHint: String
    public let maxTools: Int
    public let maxMCPTools: Int
    public let includeMCPTools: Bool

    public init(
        modeHint: String,
        taskTypeHint: String,
        maxTools: Int,
        maxMCPTools: Int,
        includeMCPTools: Bool = true
    ) {
        self.modeHint = modeHint
        self.taskTypeHint = taskTypeHint
        self.maxTools = max(1, maxTools)
        self.maxMCPTools = max(0, maxMCPTools)
        self.includeMCPTools = includeMCPTools
    }

    public static let unfiltered = ToolPromptFilter(
        modeHint: "agent",
        taskTypeHint: "general",
        maxTools: Int.max,
        maxMCPTools: Int.max,
        includeMCPTools: true
    )
}

/// Thread-safe registry of available tools.
/// Generates the <tools> XML block for the system prompt.
public actor ToolRegistry {

    private var tools: [String: any Tool] = [:]

    public init() {}

    /// Register a tool. Replaces any existing tool with the same name.
    public func register(_ tool: any Tool) {
        tools[tool.name] = tool
    }

    /// Look up a tool by name.
    public func tool(named name: String) -> (any Tool)? {
        tools[name]
    }

    /// All registered tool names.
    public var toolNames: [String] {
        Array(tools.keys).sorted()
    }

    /// Number of registered tools.
    public var count: Int {
        tools.count
    }

    /// Generate the <tools> XML block for the system prompt.
    /// This follows the Qwen3 format: tools are defined inside <tools></tools>
    /// using JSON Schema.
    public func generateToolsBlock(filter: ToolPromptFilter = .unfiltered) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        var toolDefinitions: [[String: Any]] = []

        let selectedTools = filteredTools(for: filter)

        for (_, tool) in selectedTools {
            let schemaData = try encoder.encode(tool.parameters)
            guard let schemaDict = try JSONSerialization.jsonObject(with: schemaData) as? [String: Any] else {
                continue
            }

            let definition: [String: Any] = [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": schemaDict
                ]
            ]
            toolDefinitions.append(definition)
        }

        let toolsJSON = try JSONSerialization.data(
            withJSONObject: toolDefinitions,
            options: [.prettyPrinted, .sortedKeys]
        )
        let toolsString = String(data: toolsJSON, encoding: .utf8) ?? "[]"

        return "\(ToolCallPattern.toolsOpen)\n\(toolsString)\n\(ToolCallPattern.toolsClose)"
    }

    private func filteredTools(for filter: ToolPromptFilter) -> [(String, any Tool)] {
        if filter.maxTools == Int.max,
           filter.maxMCPTools == Int.max,
           filter.includeMCPTools {
            return tools.sorted(by: { $0.key < $1.key })
        }

        let task = filter.taskTypeHint.lowercased()
        let mode = filter.modeHint.lowercased()
        let includeMCP = filter.includeMCPTools

        var ranked: [(String, any Tool, score: Int)] = []
        ranked.reserveCapacity(tools.count)

        for (name, tool) in tools {
            if !includeMCP, name.hasPrefix("mcp_") {
                continue
            }
            ranked.append((name, tool, relevanceScore(toolName: name, mode: mode, task: task)))
        }

        ranked.sort { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.0 < rhs.0
            }
            return lhs.score > rhs.score
        }

        let mcpCap = filter.maxMCPTools
        var mcpCount = 0
        var selected: [(String, any Tool)] = []
        selected.reserveCapacity(min(filter.maxTools, ranked.count))

        for candidate in ranked {
            if selected.count >= filter.maxTools {
                break
            }

            if candidate.0.hasPrefix("mcp_") {
                if mcpCount >= mcpCap {
                    continue
                }
                mcpCount += 1
            }

            selected.append((candidate.0, candidate.1))
        }

        return selected.sorted(by: { $0.0 < $1.0 })
    }

    private func relevanceScore(toolName name: String, mode: String, task: String) -> Int {
        let isPlan = mode == "plan"

        switch name {
        case "read_file", "list_dir", "glob", "grep", "code_search", "read_many":
            return task == "coding" ? 100 : 90
        case "edit_file", "write_file", "append_file", "patch":
            return isPlan ? 20 : (task == "coding" ? 95 : 70)
        case "bash":
            return isPlan ? 30 : (task == "coding" ? 94 : 75)
        case "task", "todo":
            return 88
        case "build_check":
            return task == "coding" ? 89 : 55
        case "lsp_diagnostics", "lsp_hover", "lsp_references", "lsp_definition", "lsp_completion", "lsp_signature_help", "lsp_document_symbols", "lsp_rename":
            return task == "coding" ? 93 : 25
        case "web_fetch", "web_search":
            return task == "general" ? 82 : 60
        default:
            if name.hasPrefix("mcp_") {
                return task == "general" ? 50 : 35
            }
            return 40
        }
    }
}
