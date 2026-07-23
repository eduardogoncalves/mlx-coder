// Sources/AgentCore/AgentLoop+OpenRouterGeneration.swift
// Remote (OpenAI-compatible) generation path — works with any configured
// RemoteProvider (OpenRouter, LM Studio, vLLM, mlx-lm.server). Mirrors the return shape of
// AgentLoop+Generation.swift's local MLX path so the rest of the agent loop
// (tool dispatch, malformed-tool retry, history bookkeeping) is unchanged.
//
// Tool calls returned by the OpenAI-compatible streaming API arrive as
// structured `{id, name, arguments}` objects rather than inline `<tool_call>`
// markers. We accumulate them, then serialize each into the qwen wire format
// at the tail of the response text so the existing `ToolCallParser.parse`
// extracts them. The streamed-content writer (used for write_file's tmp-file
// streaming on local models) is returned empty — large tool args still work,
// they just land in memory instead of streaming straight to disk.

import Foundation

extension AgentLoop {

    func generateResponseViaRemote() async throws -> (text: String, writer: StreamingToolCallWriter, startedThinking: Bool, turnStats: (promptTokens: Int, completionTokens: Int, elapsed: TimeInterval, tokensPerSecond: Double?)?) {
        guard case .remote(let providerID, let modelID) = backend else {
            throw NSError(
                domain: "AgentLoop",
                code: 100,
                userInfo: [NSLocalizedDescriptionKey: "OpenRouter generation requested but backend is not OpenRouter."]
            )
        }

        guard let provider = RemoteProviderRegistry.provider(id: providerID) else {
            throw NSError(
                domain: "AgentLoop",
                code: 101,
                userInfo: [NSLocalizedDescriptionKey: "Unknown remote provider '\(providerID)'. Configure it in ~/.mlx-coder/config.json."]
            )
        }

        let apiKey = RemoteProviderRegistry.apiKey(for: providerID)

        // Apply context transforms — same flow as the local path so behavior
        // (compaction, summarization injection, etc.) stays consistent across backends.
        var transformedMessages = history.messages
        for (index, transform) in contextTransforms.enumerated() {
            let before = transformedMessages.count
            transformedMessages = await transform(transformedMessages)
            let after = transformedMessages.count
            if after != before {
                await hooks.emit(.contextTransformApplied(transformIndex: index, messagesBefore: before, messagesAfter: after))
            }
        }
        pendingImages = []   // OpenRouter image support is out of scope for v1

        let chatMessages = transformedMessages.map { msg -> OpenRouterMessage in
            let role: OpenRouterMessage.Role
            switch msg.role {
            case .system:    role = .system
            case .user:      role = .user
            case .assistant: role = .assistant
            case .tool:      role = .tool
            }
            // Automated (agent-injected) steering rides the user role wrapped in a
            // <system-reminder> marker — same treatment as the local ChatML path.
            return OpenRouterMessage(role: role, content: msg.wireContent, toolCallId: msg.toolCallId)
        }

        let tools: [OpenRouterToolSpec]
        if let toolDefsData = try? await registry.generateOpenAIToolDefinitionsJSON(filter: currentToolPromptFilter()),
           let decoded = (try? JSONSerialization.jsonObject(with: toolDefsData)) as? [[String: Any]] {
            tools = decoded.map { OpenRouterToolSpec(json: $0) }
        } else {
            tools = []
        }

        let base = provider.baseURLValue ?? URL(string: "https://openrouter.ai/api/v1")!
        let client = OpenRouterClient(apiKey: apiKey ?? "", baseURL: base, providerName: provider.name)
        let stream = client.stream(model: modelID, messages: chatMessages, tools: tools, sessionId: sessionId)

        // Lifecycle events — mirror the activity emissions of the local path so
        // the TUI spinner labels are consistent.
        frontend.emit(.tokenProcessingActivity(.started))
        frontend.emit(.tokenProcessingActivity(.ended))
        frontend.emit(.generationActivity(.started))
        defer { frontend.emit(.generationActivity(.ended)) }

        var responseText = ""
        // Accumulator for partial tool-call deltas, keyed by stream index.
        struct PartialToolCall {
            var id: String?
            var name: String?
            var arguments: String = ""
        }
        var pending: [Int: PartialToolCall] = [:]
        var usagePrompt = 0
        var usageCompletion = 0
        let generationStart = Date()

        do {
            for try await event in stream {
                if Task.isCancelled { throw CancellationError() }
                switch event {
                case .text(let chunk):
                    responseText += chunk
                    frontend.emit(.assistantTextChunk(chunk))
                    await Task.yield()
                case .toolCallDelta(let index, let id, let name, let argumentsChunk):
                    var entry = pending[index] ?? PartialToolCall()
                    if let id { entry.id = id }
                    if let name { entry.name = name }
                    entry.arguments += argumentsChunk
                    pending[index] = entry
                case .done:
                    // Stream may emit `.done` mid-completion (per-choice finish_reason)
                    // before `[DONE]`; let the loop continue and exit naturally.
                    break
                case .usage(let prompt, let completion):
                    usagePrompt = prompt
                    usageCompletion = completion
                }
            }
        } catch {
            throw error
        }

        // Capture stats to return to the caller for turn-level accumulation.
        // The spinner ↑ is still updated immediately; the formatted stats line
        // is emitted once by the outer loop after all rounds complete.
        var capturedTurnStats: (promptTokens: Int, completionTokens: Int, elapsed: TimeInterval, tokensPerSecond: Double?)? = nil
        if usagePrompt > 0 || usageCompletion > 0 {
            frontend.emit(.promptTokensKnown(usagePrompt))
            let elapsed = Date().timeIntervalSince(generationStart)
            capturedTurnStats = (promptTokens: usagePrompt, completionTokens: usageCompletion, elapsed: elapsed, tokensPerSecond: nil)
        }

        // Serialize accumulated tool calls as qwen-format `<tool_call>{...}</tool_call>`
        // so ToolCallParser.parse picks them up downstream. Skip empty/no-name entries.
        let orderedKeys = pending.keys.sorted()
        for key in orderedKeys {
            let partial = pending[key]!
            guard let name = partial.name, !name.isEmpty else { continue }

            // OpenAI streams arguments as a JSON-encoded string; parse it back into
            // a real object so the serialized tool call is well-formed JSON.
            let argumentsString = partial.arguments.isEmpty ? "{}" : partial.arguments
            let argumentsObject: Any
            if let data = argumentsString.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                argumentsObject = parsed
            } else {
                // Couldn't parse — preserve the raw string so the malformed-tool
                // retry path triggers with a useful error.
                argumentsObject = argumentsString
            }

            let payload: [String: Any] = [
                "name": name,
                "arguments": argumentsObject
            ]

            if let json = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
               let jsonString = String(data: json, encoding: .utf8) {
                if !responseText.isEmpty && !responseText.hasSuffix("\n") {
                    responseText += "\n"
                }
                responseText += "<tool_call>\(jsonString)</tool_call>"
            }
        }

        // Return a fresh, idle StreamingToolCallWriter. drainCompletedCalls / drainFailedCalls
        // / drainTruncatedStream all return empty — the downstream ToolCallParser path
        // handles extraction from `responseText`.
        let writer = StreamingToolCallWriter(
            toolCallOpen: "<tool_call>",
            toolCallClose: "</tool_call>",
            parsesJSONBody: true,
            onStatusChange: nil
        )

        return (text: responseText, writer: writer, startedThinking: false, turnStats: capturedTurnStats)
    }

    static func formatGenerationStats(
        promptTokens: Int,
        completionTokens: Int,
        elapsed: TimeInterval,
        tokensPerSecond: Double? = nil
    ) -> String {
        func kilo(_ n: Int) -> String {
            n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
        }
        let elapsedStr: String
        if elapsed >= 60 {
            let m = Int(elapsed) / 60
            let s = Int(elapsed) % 60
            elapsedStr = "\(m)m \(s)s"
        } else {
            elapsedStr = String(format: "%.1fs", elapsed)
        }
        var result = "↑ \(kilo(promptTokens)) · ↓ \(kilo(completionTokens)) tokens · \(elapsedStr)"
        if let tps = tokensPerSecond, tps > 0 {
            result += String(format: " · %.1f tok/s", tps)
        }
        return result
    }
}
