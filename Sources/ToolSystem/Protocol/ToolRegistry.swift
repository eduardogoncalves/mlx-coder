// Sources/ToolSystem/Protocol/ToolRegistry.swift
// Thread-safe registry for tool lookup and system prompt generation

import Foundation

public struct ToolPromptFilter: Sendable {
    public let modeHint: String
    public let taskTypeHint: String
    public let includeMCPTools: Bool
    public let selectedToolNames: [String]?

    public init(
        modeHint: String,
        taskTypeHint: String,
        includeMCPTools: Bool = true,
        selectedToolNames: [String]? = nil
    ) {
        self.modeHint = modeHint
        self.taskTypeHint = taskTypeHint
        self.includeMCPTools = includeMCPTools
        self.selectedToolNames = selectedToolNames
    }

    public static let unfiltered = ToolPromptFilter(
        modeHint: "agent",
        taskTypeHint: "general",
        includeMCPTools: true,
        selectedToolNames: nil
    )
}

public enum ToolInjectionSelection {
    public static let baseTools = [
        "read_file", "read_many", "read_skill", "search_knowledge", "log_knowledge",
        "list_dir", "glob", "grep",
        "write_file", "edit_file", "bash", "todo",
        "web_fetch", "web_search"
    ]

    // LSP and semantic search tools help the agent inspect symbols precisely before editing code.
    public static let lspTools = [
        "lsp_diagnostics", "lsp_definition", "lsp_references",
        "lsp_rename", "lsp_hover", "lsp_completion",
        "lsp_signature_help", "code_search"
    ]

    // Patch-oriented mutation tools support targeted edits without broad file rewrites.
    public static let patchTools = [
        "patch", "append_file"
    ]

    // Planning tools let the agent persist structured implementation plans when the task is exploratory.
    public static let planningTools = [
        "plan_file"
    ]

    // Agent tools enable orchestration by delegating bounded work to sub-agents.
    public static let agentTools = [
        "task"
    ]

    public static func toolNames(forTaskType taskType: String) -> [String] {
        let ephemeralGroups: [[String]]

        switch taskType.lowercased() {
        case "code_edit":
            ephemeralGroups = [lspTools, patchTools]
        case "planning":
            ephemeralGroups = [planningTools]
        case "orchestration":
            ephemeralGroups = [agentTools]
        case "general":
            ephemeralGroups = []
        default:
            ephemeralGroups = []
        }

        var selected: [String] = []
        var seen = Set<String>()

        for name in baseTools + ephemeralGroups.flatMap({ $0 }) {
            if seen.insert(name).inserted {
                selected.append(name)
            }
        }

        return selected
    }
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

    /// Return the tool instances that should be injected for the given task type.
    /// Unknown task types fall back to the base tool set for backwards compatibility.
    public func getToolsForTask(taskType: String) -> [any Tool] {
        ToolInjectionSelection.toolNames(forTaskType: taskType).compactMap { tools[$0] }
    }

    /// Remove all registered tools.
    public func clear() {
        tools.removeAll()
    }

    /// Generate the tools block for the system prompt.
    ///
    /// The wrapper differs by dialect:
    /// - Qwen wraps the JSON array in `<tools>...</tools>`.
    /// - LFM2 prepends `List of tools: ` to match its chat-template convention.
    public func generateToolsBlock(
        filter: ToolPromptFilter = .unfiltered,
        dialect: ToolCallDialect = .qwen
    ) throws -> String {
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

        return dialect.formatToolsBlock(toolsJSON: toolsString)
    }

    private func filteredTools(for filter: ToolPromptFilter) -> [(String, any Tool)] {
        var selected: [(String, any Tool)]

        if let selectedToolNames = filter.selectedToolNames {
            let selectedNameSet = Set(selectedToolNames)
            selected = selectedToolNames.compactMap { name in
                guard let tool = tools[name] else { return nil }
                if !filter.includeMCPTools, name.hasPrefix("mcp_") {
                    return nil
                }
                return (name, tool)
            }

            if filter.includeMCPTools {
                let additionalMCPTools = tools
                    .filter { name, _ in
                        name.hasPrefix("mcp_") && !selectedNameSet.contains(name)
                    }
                    .sorted(by: { $0.key < $1.key })
                selected.append(contentsOf: additionalMCPTools.map { ($0.key, $0.value) })
            }
        } else {
            selected = tools
                .filter { name, _ in
                    filter.includeMCPTools || !name.hasPrefix("mcp_")
                }
                .sorted(by: { $0.key < $1.key })
        }

        return selected.sorted(by: { $0.0 < $1.0 })
    }
}
