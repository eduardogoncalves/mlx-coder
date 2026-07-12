// Sources/ModelEngine/ToolCallDialect.swift
// Selects the tool-call wire format for the active model.

import Foundation

public enum ToolCallDialect: Sendable, Equatable {
    /// Qwen3 / Qwen2 ChatML — `<tool_call>{"name":..., "arguments":...}</tool_call>`.
    case qwen
    /// LFM2 — `<|tool_call_start|>[name(arg='value', ...)]<|tool_call_end|>`.
    case lfm2
    /// GLM4 (THUDM/ChatGLM) — `<tool_call>name<arg_key>k</arg_key><arg_value>v</arg_value>…</tool_call>`.
    case glm4

    public var toolCallOpen: String {
        switch self {
        case .qwen: return "<tool_call>"
        case .lfm2: return "<|tool_call_start|>"
        case .glm4: return "<tool_call>"
        }
    }

    public var toolCallClose: String {
        switch self {
        case .qwen: return "</tool_call>"
        case .lfm2: return "<|tool_call_end|>"
        case .glm4: return "</tool_call>"
        }
    }

    /// LFM2's wire format is not JSON, so the streaming writer cannot stream
    /// large `content` fields straight to disk. Falls back to buffered parsing.
    public var supportsStreamingJSONContent: Bool {
        switch self {
        case .qwen: return true
        case .lfm2: return false
        case .glm4: return false
        }
    }

    /// Detect dialect from a model path or hub id. Falls back to Qwen.
    public static func detect(modelPath: String) -> ToolCallDialect {
        let lower = modelPath.lowercased()
        if lower.contains("lfm2") || lower.contains("lfm-2") || lower.contains("lfm2.5") {
            return .lfm2
        }
        if lower.contains("glm-4") || lower.contains("glm4") || lower.contains("chatglm") {
            return .glm4
        }
        return .qwen
    }

    /// Returns the snippet shown to the model in the system prompt explaining
    /// the tool-call wire format. Dialect-specific because Qwen expects JSON
    /// and LFM2 expects Python-style function calls.
    public var promptCallFormatSection: String {
        switch self {
        case .qwen:
            return """
            When you need to use a tool, respond with the tool call in this format:
            \(toolCallOpen)
            {"name": "tool_name", "arguments": {"param": "value"}}
            \(toolCallClose)

            The object inside \(toolCallOpen) must be valid JSON with "name" and "arguments" keys.
            Do not write pseudo-JSON like {"tool_name", "path": "."} or function-style wrappers.

            You can call multiple tools in a single response. After tool results are returned, continue your reasoning.
            """
        case .lfm2:
            return """
            TOOL CALLING — STRICT FORMAT REQUIRED

            To use a tool, emit ONE LINE in this EXACT shape:
              \(toolCallOpen)[tool_name(param='value', param2='value2')]\(toolCallClose)

            Hard rules — any deviation will be rejected and you will be asked to retry:
            1. The call MUST be wrapped between the literal tokens \(toolCallOpen) and \(toolCallClose).
            2. Inside those tokens, write `[name(args)]` — square brackets around a Python-style function call. Multiple calls go inside the same brackets, comma-separated.
            3. `name` MUST be one of the exact tool names listed in the tools section above. Do NOT invent tools or kwargs that are not in the schema.
            4. NEVER emit a free-form JSON object as your response — e.g. shapes like `{"todo": ..., "plan": ..., "commands": [...], "workspace_root": ...}` are NOT tool calls and will be rejected.
            5. NEVER wrap output in ``` ```json fences. NEVER add prose before or after the tool call when calling a tool.
            6. Strings use single quotes; numbers, booleans (`True`/`False`), `None`, lists `[…]`, and JSON-style dicts `{"k": "v"}` are written as bare literals.
            7. ALL `path` arguments are RELATIVE to the workspace root shown above. Do not include the workspace prefix and do not use absolute paths starting with `/`.

            Concrete examples — copy this shape verbatim:
              \(toolCallOpen)[list_dir(path='.')]\(toolCallClose)
              \(toolCallOpen)[read_file(path='README.md')]\(toolCallClose)
              \(toolCallOpen)[glob(pattern='**/*.swift')]\(toolCallClose)
              \(toolCallOpen)[grep(pattern='TODO', path='.')]\(toolCallClose)
              \(toolCallOpen)[bash(command='ls -la')]\(toolCallClose)
              \(toolCallOpen)[write_file(path='notes.md', content='hello\\nworld')]\(toolCallClose)

            When no tool call is needed, respond with plain natural-language text (no JSON wrapper).
            After tool results return, continue your reasoning toward the final answer.
            """
        case .glm4:
            return """
            When you need to use a tool, respond with the tool call in this format:
            \(toolCallOpen)tool_name<arg_key>param_name</arg_key><arg_value>param_value</arg_value>\(toolCallClose)

            For multiple arguments, chain additional <arg_key>/<arg_value> pairs:
            \(toolCallOpen)tool_name<arg_key>param1</arg_key><arg_value>value1</arg_value><arg_key>param2</arg_key><arg_value>value2</arg_value>\(toolCallClose)

            The tool name goes DIRECTLY after \(toolCallOpen) with NO space or JSON wrapper.
            Do NOT use JSON inside \(toolCallOpen)…\(toolCallClose). Do NOT add prose before or after the tool call.

            Concrete examples:
              \(toolCallOpen)list_dir<arg_key>path</arg_key><arg_value>.</arg_value>\(toolCallClose)
              \(toolCallOpen)read_file<arg_key>path</arg_key><arg_value>README.md</arg_value>\(toolCallClose)
              \(toolCallOpen)bash<arg_key>command</arg_key><arg_value>ls -la</arg_value>\(toolCallClose)

            You can call multiple tools in a single response by emitting multiple \(toolCallOpen)…\(toolCallClose) blocks.
            After tool results are returned, continue your reasoning.
            """
        }
    }

    /// Wraps the JSON tool definitions array for inclusion in the system prompt.
    /// Qwen uses an XML-style `<tools>...</tools>` block; LFM2 expects a
    /// `List of tools: [...]` line per its chat template.
    public func formatToolsBlock(toolsJSON: String) -> String {
        switch self {
        case .qwen:
            return "\(ToolCallPattern.toolsOpen)\n\(toolsJSON)\n\(ToolCallPattern.toolsClose)"
        case .lfm2:
            return "List of tools: \(toolsJSON)"
        case .glm4:
            return "\(ToolCallPattern.toolsOpen)\n\(toolsJSON)\n\(ToolCallPattern.toolsClose)"
        }
    }
}
