// Sources/ModelEngine/OpenRouterClient.swift
// Streaming client for OpenAI-compatible Chat Completions APIs. Despite the name
// (kept for source compatibility), this now serves ANY OpenAI-compatible
// endpoint — OpenRouter, LM Studio, vLLM, mlx-lm.server, etc. — driven by the
// `baseURL` init param. The `Authorization` header is only sent when an API key
// is provided, so keyless local servers work out of the box.
//
// Usage:
//     let client = OpenRouterClient(apiKey: "...")
//     for try await event in client.stream(model: "anthropic/claude-sonnet-4",
//                                          messages: ..., tools: ...) {
//         switch event { ... }
//     }
//
// The stream emits incremental text deltas, tool-call deltas (id+name first,
// then arguments arrive piecewise), and a terminal `.done` once the stream
// closes. Tool arguments are accumulated by the caller across `.toolCallDelta`
// events keyed by `index`, then parsed when `.done` is observed.

import Foundation

public enum OpenRouterError: Error, LocalizedError, Sendable {
    case notConfigured
    case http(status: Int, body: String)
    case decoding(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Remote provider is not configured. Add it to ~/.mlx-coder/config.json with a name, baseURL, and apiKey."
        case .http(let status, let body):
            let truncated = body.count > 400 ? String(body.prefix(400)) + "…" : body
            return "OpenRouter HTTP \(status): \(truncated)"
        case .decoding(let detail):
            return "Failed to decode OpenRouter response: \(detail)"
        case .transport(let detail):
            return "OpenRouter transport error: \(detail)"
        }
    }
}

public enum OpenRouterStreamEvent: Sendable {
    /// Incremental assistant text.
    case text(String)
    /// Incremental tool-call data. `index` identifies the call across deltas.
    /// `id` and `name` are non-nil only on the first delta for that index.
    case toolCallDelta(index: Int, id: String?, name: String?, argumentsChunk: String)
    /// End-of-stream sentinel. `finishReason` is "stop", "tool_calls", "length", etc.
    case done(finishReason: String?)
    /// Token usage reported in the final stream frame (requires stream_options.include_usage).
    case usage(promptTokens: Int, completionTokens: Int)
}

public struct OpenRouterMessage: Sendable {
    public enum Role: String, Sendable {
        case system, user, assistant, tool
    }
    public let role: Role
    public let content: String
    /// Only set for `.tool` role.
    public let toolCallId: String?

    public init(role: Role, content: String, toolCallId: String? = nil) {
        self.role = role
        self.content = content
        self.toolCallId = toolCallId
    }
}

/// One tool spec in OpenAI/OpenRouter format. The dictionary follows the shape
/// `{ "type": "function", "function": { "name", "description", "parameters" } }`
/// already produced by `ToolRegistry.generateToolsBlock`.
public struct OpenRouterToolSpec: @unchecked Sendable {
    public let json: [String: Any]
    public init(json: [String: Any]) { self.json = json }
}

public struct OpenRouterClient: Sendable {
    public let apiKey: String
    public let baseURL: URL
    public let referrer: String?
    public let appTitle: String?
    public let session: URLSession

    public init(
        apiKey: String,
        baseURL: URL = URL(string: "https://openrouter.ai/api/v1")!,
        referrer: String? = "https://github.com/eduardogoncalves/mlx-coder",
        appTitle: String? = "mlx-coder",
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.referrer = referrer
        self.appTitle = appTitle
        self.session = session
    }

    public func stream(
        model: String,
        messages: [OpenRouterMessage],
        tools: [OpenRouterToolSpec] = [],
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        sessionId: String? = nil
    ) -> AsyncThrowingStream<OpenRouterStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await runStream(
                        model: model,
                        messages: messages,
                        tools: tools,
                        temperature: temperature,
                        maxTokens: maxTokens,
                        sessionId: sessionId,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runStream(
        model: String,
        messages: [OpenRouterMessage],
        tools: [OpenRouterToolSpec],
        temperature: Double?,
        maxTokens: Int?,
        sessionId: String?,
        continuation: AsyncThrowingStream<OpenRouterStreamEvent, Error>.Continuation
    ) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // Only authenticate when a key is present — local servers (LM Studio,
        // vLLM, mlx-lm.server) need no key, and an empty Bearer can break them.
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if let referrer { request.setValue(referrer, forHTTPHeaderField: "HTTP-Referer") }
        if let appTitle { request.setValue(appTitle, forHTTPHeaderField: "X-Title") }

        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": messages.map(Self.encodeMessage)
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { $0.json }
        }
        if let temperature { body["temperature"] = temperature }
        if let maxTokens { body["max_tokens"] = maxTokens }
        // Groups all generations from one conversation under a single OpenRouter
        // session so multi-step agent runs can be followed and debugged together.
        if let sessionId, !sessionId.isEmpty { body["session_id"] = sessionId }
        // Request usage counts in the final stream frame (OpenAI spec; supported by
        // OpenRouter, LM Studio, vLLM). Ignored silently by providers that don't support it.
        body["stream_options"] = ["include_usage": true]

        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw OpenRouterError.transport(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenRouterError.transport("Non-HTTP response from OpenRouter")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            var body = ""
            for try await line in bytes.lines {
                body.append(line)
                body.append("\n")
                if body.count > 4096 { break }
            }
            throw OpenRouterError.http(status: httpResponse.statusCode, body: body)
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { continue }
            if payload == "[DONE]" {
                continuation.yield(.done(finishReason: nil))
                return
            }
            guard let data = payload.data(using: .utf8) else { continue }
            try Self.dispatchFrame(data: data, continuation: continuation)
        }
    }

    // MARK: - Frame parsing

    private static func dispatchFrame(
        data: Data,
        continuation: AsyncThrowingStream<OpenRouterStreamEvent, Error>.Continuation
    ) throws {
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            // OpenRouter occasionally emits comment frames (`: ping`) or other
            // non-JSON keepalives. Silently ignore parse failures so the stream
            // doesn't tear down on a benign heartbeat.
            return
        }
        guard let dict = obj as? [String: Any] else { return }

        // Usage appears in its own frame (choices may be empty or absent).
        if let usage = dict["usage"] as? [String: Any] {
            let prompt = (usage["prompt_tokens"] as? Int) ?? 0
            let completion = (usage["completion_tokens"] as? Int) ?? 0
            if prompt > 0 || completion > 0 {
                continuation.yield(.usage(promptTokens: prompt, completionTokens: completion))
            }
        }

        guard let choices = dict["choices"] as? [[String: Any]],
              let first = choices.first
        else {
            return
        }

        if let finish = first["finish_reason"] as? String, !finish.isEmpty {
            continuation.yield(.done(finishReason: finish))
        }

        guard let delta = first["delta"] as? [String: Any] else { return }

        if let text = delta["content"] as? String, !text.isEmpty {
            continuation.yield(.text(text))
        }

        if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
            for call in toolCalls {
                let index = (call["index"] as? Int) ?? 0
                let id = call["id"] as? String
                let function = call["function"] as? [String: Any]
                let name = function?["name"] as? String
                let argsChunk = (function?["arguments"] as? String) ?? ""
                continuation.yield(.toolCallDelta(
                    index: index,
                    id: id,
                    name: name,
                    argumentsChunk: argsChunk
                ))
            }
        }
    }

    // MARK: - Model catalog

    /// A subset of the fields returned by `GET /api/v1/models`. The fields we
    /// keep are the ones we surface in the model picker (id, display name,
    /// context window) plus the `tools` filter signal.
    public struct ModelInfo: Sendable, Codable {
        public let id: String
        public let name: String?
        public let contextLength: Int?
        public let supportsTools: Bool
        public let isFree: Bool

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case contextLength
            case supportsTools
            case isFree
        }

        public init(id: String, name: String?, contextLength: Int?, supportsTools: Bool, isFree: Bool) {
            self.id = id
            self.name = name
            self.contextLength = contextLength
            self.supportsTools = supportsTools
            self.isFree = isFree
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(String.self, forKey: .id)
            self.name = try c.decodeIfPresent(String.self, forKey: .name)
            self.contextLength = try c.decodeIfPresent(Int.self, forKey: .contextLength)
            self.supportsTools = try c.decode(Bool.self, forKey: .supportsTools)
            self.isFree = try c.decodeIfPresent(Bool.self, forKey: .isFree) ?? false
        }
    }

    /// Fetch all models from OpenRouter and return only the tool-capable ones
    /// (`supported_parameters` contains `"tools"`). The `/models` endpoint is
    /// public — no API key is required — so this works even when the configured
    /// provider omits an apiKey, letting us pre-populate the picker on first launch.
    public func listToolCapableModels() async throws -> [ModelInfo] {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Only authenticate when a key is present — see note in runStream.
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if let referrer { request.setValue(referrer, forHTTPHeaderField: "HTTP-Referer") }
        if let appTitle { request.setValue(appTitle, forHTTPHeaderField: "X-Title") }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OpenRouterError.transport(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenRouterError.transport("Non-HTTP response from OpenRouter")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OpenRouterError.http(status: httpResponse.statusCode, body: body)
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [[String: Any]]
        else {
            throw OpenRouterError.decoding("Missing `data` array in /models response")
        }

        var models: [ModelInfo] = []
        models.reserveCapacity(entries.count)
        for entry in entries {
            guard let id = entry["id"] as? String, !id.isEmpty else { continue }
            // `supported_parameters` is OpenRouter-specific. Local servers (LM Studio,
            // vLLM, mlx-lm.server) omit it entirely — treat absence as "tools supported".
            if let supports = entry["supported_parameters"] as? [String] {
                guard supports.contains("tools") else { continue }
            }
            let displayName = entry["name"] as? String
            let context = entry["context_length"] as? Int
            let isFree = Self.isFreeModel(entry: entry, id: id)
            models.append(ModelInfo(
                id: id,
                name: displayName,
                contextLength: context,
                supportsTools: true,
                isFree: isFree
            ))
        }
        // Sort by id for stable ordering in the picker.
        models.sort { $0.id < $1.id }
        return models
    }

    // MARK: - Encoding

    private static func encodeMessage(_ message: OpenRouterMessage) -> [String: Any] {
        var dict: [String: Any] = [
            "role": message.role.rawValue,
            "content": message.content
        ]
        if message.role == .tool, let id = message.toolCallId {
            dict["tool_call_id"] = id
        }
        return dict
    }

    private static func isFreeModel(entry: [String: Any], id: String) -> Bool {
        if id.lowercased().contains(":free") {
            return true
        }

        guard let pricing = entry["pricing"] as? [String: Any] else {
            return false
        }

        let keys = ["prompt", "completion", "request", "input", "output", "image"]
        var sawPrice = false
        for key in keys {
            guard let raw = pricing[key] else { continue }
            guard let value = numericPrice(from: raw) else { continue }
            sawPrice = true
            if value > 0 {
                return false
            }
        }
        return sawPrice
    }

    private static func numericPrice(from raw: Any) -> Double? {
        if let n = raw as? NSNumber {
            return n.doubleValue
        }
        if let s = raw as? String {
            return Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}
