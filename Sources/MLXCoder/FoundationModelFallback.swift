// Sources/MLXCoder/FoundationModelFallback.swift
// Apple Foundation model integration — chat fallback, single-prompt fallback,
// Foundation tool loop, and argument normalization helpers.

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Foundation Fallback Runners

func runAppleFoundationChatFallback(renderer: StreamRenderer) async -> Bool {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
        do {
            let session = LanguageModelSession()
            print("\nmlx-coder (Apple Foundation fallback)")
            print("Type 'exit' or 'quit' to leave.\n")

            while true {
                print("> ", terminator: "")
                guard let line = readLine() else { break }
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                if trimmed == "exit" || trimmed == "quit" { break }

                let response = try await session.respond(to: trimmed)
                print(response.content)
                print("")
            }

            return true
        } catch {
            renderer.printError("Foundation fallback failed: \(error.localizedDescription)")
            return false
        }
    }
    return false
    #else
    _ = renderer
    return false
    #endif
}

func runAppleFoundationSinglePromptFallback(prompt: String, renderer: StreamRenderer) async -> Bool {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt)
            print(response.content)
            return true
        } catch {
            renderer.printError("Foundation fallback failed: \(error.localizedDescription)")
            return false
        }
    }
    return false
    #else
    _ = prompt
    _ = renderer
    return false
    #endif
}

let foundationAllowedToolNames: Set<String> = [
    "glob",
    "grep",
    "list_dir",
    "web_search",
    "web_fetch"
]

func runAppleFoundationSinglePromptWithTools(
    prompt: String,
    registry: ToolRegistry,
    renderer: StreamRenderer
) async -> Bool {
    if shouldBypassFoundationTools(for: prompt) {
        return await runAppleFoundationSinglePromptFallback(prompt: prompt, renderer: renderer)
    }

    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
        do {
            let session = LanguageModelSession()
            let maxIterations = 6
            var iteration = 0
            var pendingPrompt = foundationSystemToolPrompt(userPrompt: prompt)

            while iteration < maxIterations {
                iteration += 1
                let response = try await session.respond(to: pendingPrompt)
                let raw = response.content
                var toolCalls = ToolCallParser.parse(raw)
                if toolCalls.isEmpty {
                    toolCalls = parseFoundationFallbackToolCalls(from: raw)
                }
                let nonToolText = ToolCallParser.extractNonToolText(ToolCallParser.stripThinking(raw))

                if toolCalls.isEmpty {
                    if !nonToolText.isEmpty {
                        print(nonToolText)
                    } else {
                        print(raw)
                    }
                    return true
                }

                var toolResponses: [String] = []
                toolResponses.reserveCapacity(toolCalls.count)

                for rawCall in toolCalls {
                    let call = normalizeFoundationToolCall(rawCall)
                    renderer.printToolCall(name: call.name, arguments: call.arguments)

                    let result: ToolResult
                    if !foundationAllowedToolNames.contains(call.name) {
                        result = .error("Tool '\(call.name)' is not available in Foundation mode. Allowed tools: glob, grep, list_dir, web_search, web_fetch.")
                    } else if let tool = await registry.tool(named: call.name) {
                        do {
                            result = try await tool.execute(arguments: call.arguments)
                        } catch {
                            result = .error("Tool execution failed: \(error.localizedDescription)")
                        }
                    } else {
                        result = .error("Tool '\(call.name)' is not registered.")
                    }

                    renderer.printToolResult(result)
                    let boundedContent = String(result.content.prefix(8000))
                    let jsonObject: [String: Any] = [
                        "name": call.name,
                        "is_error": result.isError,
                        "content": boundedContent
                    ]

                    if let data = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys]),
                       let json = String(data: data, encoding: .utf8) {
                        toolResponses.append("\(ToolCallPattern.toolResponseOpen)\n\(json)\n\(ToolCallPattern.toolResponseClose)")
                    } else {
                        toolResponses.append("\(ToolCallPattern.toolResponseOpen)\n{\"name\":\"\(call.name)\",\"is_error\":\(result.isError ? "true" : "false"),\"content\":\"serialization_failed\"}\n\(ToolCallPattern.toolResponseClose)")
                    }
                }

                pendingPrompt = """
                Continue the task using these tool results.
                If another tool is required, emit only tool calls in the required format.
                If you have enough information, provide the final answer directly.

                \(toolResponses.joined(separator: "\n"))
                """
            }

            renderer.printError("Foundation tool loop exceeded maximum tool iterations (\(maxIterations)).")
            return false
        } catch {
            renderer.printError("Foundation fallback failed: \(error.localizedDescription)")
            return false
        }
    }
    return false
    #else
    _ = prompt
    _ = registry
    _ = renderer
    return false
    #endif
}

func isAppleFoundationModelAvailable() -> Bool {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
        return true
    }
    return false
    #else
    return false
    #endif
}

// MARK: - Foundation Prompt & Parsing Helpers

private func foundationSystemToolPrompt(userPrompt: String) -> String {
    """
    You are running in mlx-coder Foundation mode with restricted tools.

    Available tools: glob, grep, list_dir, web_search, web_fetch.

    When a tool is needed, respond with one or more tool calls only, each in this exact format:
    <tool_call>
    {"name":"tool_name","arguments":{...}}
    </tool_call>

    Rules:
    - Do NOT call tools for greetings, acknowledgements, thanks, or casual chat. Reply directly.
    - Do NOT explore files or web content unless the user explicitly asks for that information.
    - Use only the five available tools listed above.
    - Do NOT emit custom tags like <list_dir>...</list_dir> or wrapper calls like tool_call(...).
    - Arguments must be valid JSON objects.
    - Do not include markdown fences around tool call JSON.
    - For list_dir, always provide a non-empty path. Use "." for current directory.
    - If no tool is needed, answer normally.

    User request:
    \(userPrompt)
    """
}

private func shouldBypassFoundationTools(for prompt: String) -> Bool {
    let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if trimmed.isEmpty { return true }

    let compact = trimmed.replacingOccurrences(of: "[^a-z0-9 ]", with: "", options: .regularExpression)
    let words = compact.split(separator: " ")

    let chatter: Set<String> = [
        "hi", "hello", "hey", "yo", "sup", "howdy", "ola",
        "thanks", "thank", "thx", "ok", "okay", "cool", "nice"
    ]

    // Single-token greetings/acknowledgements should never trigger tool usage.
    if words.count == 1, let only = words.first, chatter.contains(String(only)) {
        return true
    }

    // Very short social phrases should also bypass tools.
    if words.count <= 3 {
        let socialPhrases: Set<String> = [
            "good morning", "good afternoon", "good evening", "how are you", "whats up"
        ]
        if socialPhrases.contains(words.joined(separator: " ")) {
            return true
        }
    }

    return false
}

private func parseFoundationFallbackToolCalls(from raw: String) -> [ToolCallParser.ParsedToolCall] {
    var candidates: [String] = []

    // Handle fenced JSON blocks like:
    // ```json
    // {"name":"list_dir","arguments":{...}}
    // ```
    if let regex = try? NSRegularExpression(pattern: "```(?:json)?\\s*([\\s\\S]*?)```", options: [.caseInsensitive]) {
        let nsRaw = raw as NSString
        let matches = regex.matches(in: raw, range: NSRange(location: 0, length: nsRaw.length))
        for match in matches where match.numberOfRanges > 1 {
            let block = nsRaw.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !block.isEmpty {
                candidates.append(block)
            }
        }
    }

    // Also attempt parsing the full response as a raw JSON object.
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") {
        candidates.append(trimmed)
    }

    var parsed: [ToolCallParser.ParsedToolCall] = []
    for candidate in candidates {
        if let call = parseSingleToolCallJSON(candidate) {
            parsed.append(call)
        }
    }

    // Handle custom XML-like tags such as:
    // <list_dir>
    // {"path":"."}
    // </list_dir>
    parsed.append(contentsOf: parseFoundationTagWrappedToolCalls(from: raw))

    // Handle function-like wrappers such as:
    // tool_call(tool: list_dir, path: .)
    parsed.append(contentsOf: parseFoundationFunctionStyleToolCalls(from: raw))

    return parsed
}

private func parseFoundationTagWrappedToolCalls(from raw: String) -> [ToolCallParser.ParsedToolCall] {
    guard let regex = try? NSRegularExpression(
        pattern: "<([a-zA-Z_][a-zA-Z0-9_]*)>\\s*([\\s\\S]*?)\\s*</\\1>",
        options: []
    ) else {
        return []
    }

    let nsRaw = raw as NSString
    let matches = regex.matches(in: raw, range: NSRange(location: 0, length: nsRaw.length))
    var calls: [ToolCallParser.ParsedToolCall] = []

    for match in matches where match.numberOfRanges >= 3 {
        let tagName = nsRaw.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard foundationAllowedToolNames.contains(tagName) else { continue }

        let body = nsRaw.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = body.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            calls.append(ToolCallParser.ParsedToolCall(name: tagName, arguments: object))
        } else {
            // If body is not JSON, pass an empty object so normalization can still run.
            calls.append(ToolCallParser.ParsedToolCall(name: tagName, arguments: [:]))
        }
    }

    return calls
}

private func parseFoundationFunctionStyleToolCalls(from raw: String) -> [ToolCallParser.ParsedToolCall] {
    guard let regex = try? NSRegularExpression(
        pattern: "tool_call\\s*\\(([^)]*)\\)",
        options: [.caseInsensitive]
    ) else {
        return []
    }

    let nsRaw = raw as NSString
    let matches = regex.matches(in: raw, range: NSRange(location: 0, length: nsRaw.length))
    var calls: [ToolCallParser.ParsedToolCall] = []

    for match in matches where match.numberOfRanges >= 2 {
        let paramsText = nsRaw.substring(with: match.range(at: 1))
        let pairs = paramsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        var toolName: String?
        var args: [String: Any] = [:]

        for pair in pairs {
            guard let colonIndex = pair.firstIndex(of: ":") else { continue }
            let rawKey = String(pair[..<colonIndex]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var rawValue = String(pair[pair.index(after: colonIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)

            // Strip optional surrounding quotes.
            if (rawValue.hasPrefix("\"") && rawValue.hasSuffix("\"")) ||
                (rawValue.hasPrefix("'") && rawValue.hasSuffix("'")) {
                rawValue = String(rawValue.dropFirst().dropLast())
            }

            if rawKey == "tool" || rawKey == "name" {
                toolName = rawValue
                continue
            }

            if let intValue = Int(rawValue) {
                args[rawKey] = intValue
            } else if rawValue.lowercased() == "true" {
                args[rawKey] = true
            } else if rawValue.lowercased() == "false" {
                args[rawKey] = false
            } else {
                args[rawKey] = rawValue
            }
        }

        if let toolName, foundationAllowedToolNames.contains(toolName) {
            calls.append(ToolCallParser.ParsedToolCall(name: toolName, arguments: args))
        }
    }

    return calls
}

private func parseSingleToolCallJSON(_ jsonString: String) -> ToolCallParser.ParsedToolCall? {
    guard let data = jsonString.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let name = object["name"] as? String else {
        return nil
    }
    let arguments = object["arguments"] as? [String: Any] ?? [:]
    return ToolCallParser.ParsedToolCall(name: name, arguments: arguments)
}

private func normalizeFoundationToolCall(_ call: ToolCallParser.ParsedToolCall) -> ToolCallParser.ParsedToolCall {
    var args = call.arguments

    switch call.name {
    case "list_dir":
        let path = (args["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if path.isEmpty {
            args["path"] = "."
        }

    case "grep":
        if args["pattern"] == nil, let query = args["query"] as? String, !query.isEmpty {
            args["pattern"] = query
        }
        if let path = args["path"] as? String, path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args["path"] = "."
        }

    case "glob":
        if args["pattern"] == nil, let query = args["query"] as? String, !query.isEmpty {
            args["pattern"] = query
        }
        if let path = args["path"] as? String, path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args["path"] = "."
        }

    case "web_search":
        if args["query"] == nil, let q = args["q"] as? String, !q.isEmpty {
            args["query"] = q
        }

    case "web_fetch":
        if args["url"] == nil,
           let urls = args["urls"] as? [String],
           let first = urls.first,
           !first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args["url"] = first
        }

    default:
        break
    }

    return ToolCallParser.ParsedToolCall(name: call.name, arguments: args)
}
