// Sources/ToolSystem/Web/WebFetchTool.swift
// Fetch URL content

import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Fetches content from a URL and returns it as text, optionally extracting relevant context via LLM.
public struct WebFetchTool: Tool {
    public let name = "web_fetch"
    public let description = "Fetch content from a URL. Can optionally extract specific information using a query to avoid flooding the context."
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "url": PropertySchema(type: "string", description: "URL to fetch"),
            "query": PropertySchema(type: "string", description: "Specific question or context to extract from the page. If empty, returns the full text (truncated if too long)."),
            "timeout": PropertySchema(type: "integer", description: "Timeout in seconds (default: 15)"),
        ],
        required: ["url"]
    )

    private let maxOutputLength: Int
    private let modelContainer: ModelContainer?
    private let generationConfig: GenerationEngine.Config?

    public init(maxOutputLength: Int = 50_000, modelContainer: ModelContainer? = nil, generationConfig: GenerationEngine.Config? = nil) {
        self.maxOutputLength = maxOutputLength
        self.modelContainer = modelContainer
        self.generationConfig = generationConfig
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        try await execute(arguments: arguments, reportProgress: { _ in })
    }
}

extension WebFetchTool: ProgressReportingTool {
    public func execute(arguments: [String: Any], reportProgress: @escaping ToolProgressHandler) async throws -> ToolResult {
        guard let urlString = arguments["url"] as? String else {
            return .error("Missing required argument: url")
        }

        guard let url = URL(string: urlString) else {
            return .error("Invalid URL: \(urlString)")
        }

        if let host = url.host, !host.isEmpty {
            reportProgress("preparing request for \(host)")
        } else {
            reportProgress("preparing request")
        }

        let query = arguments["query"] as? String

        let timeout = arguments["timeout"] as? Int ?? 15

        var request = URLRequest(url: url)
        request.timeoutInterval = TimeInterval(timeout)
        request.setValue("mlx-coder/0.1", forHTTPHeaderField: "User-Agent")

        do {
            reportProgress("sending request")
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .error("Non-HTTP response received")
            }

            reportProgress("received response (HTTP \(httpResponse.statusCode))")

            guard (200...299).contains(httpResponse.statusCode) else {
                return .error("HTTP \(httpResponse.statusCode): \(HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode))")
            }

            reportProgress("reading response body")
            guard let text = String(data: data, encoding: .utf8) else {
                return .error("Response body is not valid UTF-8 text")
            }

            // If a query is provided and we have the LLM container, run extraction
            if let query = query, !query.isEmpty, let container = modelContainer, let config = generationConfig {
                reportProgress("processing page content")
                reportProgress("extracting relevant information")
                let extracted = try await extractWithLLM(text: text, query: query, container: container, config: config)
                reportProgress("finalizing result")
                return .success("Extracted information for query '\(query)':\n\n\(extracted)")
            }

            // Fallback to raw text
            if text.count > maxOutputLength {
                reportProgress("truncating long response")
                let truncated = String(text.prefix(maxOutputLength))
                let omitted = text.count - maxOutputLength
                reportProgress("finalizing result")
                return ToolResult(
                    content: truncated,
                    truncationMarker: "[... \(omitted) characters omitted ...]"
                )
            }

            reportProgress("finalizing result")
            return .success(text)
        } catch {
            return .error("Fetch failed: \(error.localizedDescription)")
        }
    }

    private func extractWithLLM(text: String, query: String, container: ModelContainer, config: GenerationEngine.Config) async throws -> String {
        // Truncate text context slightly to ensure it fits in prompt
        let maxLength = 30_000
        let safeText = text.count > maxLength ? String(text.prefix(maxLength)) + "...(truncated)" : text
        
        // Fast deterministic config
        let extractConfig = GenerationEngine.Config(
            maxTokens: 1024,
            temperature: 0.1,
            topP: config.topP,
            topK: config.topK,
            minP: config.minP,
            repetitionPenalty: config.repetitionPenalty,
            repetitionContextSize: config.repetitionContextSize,
            presencePenalty: config.presencePenalty,
            presenceContextSize: config.presenceContextSize,
            frequencyPenalty: config.frequencyPenalty,
            frequencyContextSize: config.frequencyContextSize,
            kvBits: config.kvBits,
            kvGroupSize: config.kvGroupSize,
            quantizedKVStart: config.quantizedKVStart
        )
        let prompt = """
        [INSTRUCTION]
        You are an expert information extractor. The user fetched a webpage to answer their question.

        USER'S QUESTION:
        \(query)

        Your task:
        - Read the webpage text below and answer the user's question directly and concisely.
        - Base your answer ONLY on the webpage content — do not use outside knowledge.
        - If the answer involves data (temperatures, times, percentages), include the exact values from the page.
        - If the webpage does not contain enough information to answer the question, respond with: "The requested information was not found on this page."

        WEBPAGE TEXT:
        \(safeText)
        [INSTRUCTION]
        """
        
        // Perform generation
        let extractedText = try await container.perform { context in
            let chatML = "<|im_start|>system\nYou are a helpful AI.<|im_end|>\n<|im_start|>user\n\(prompt)<|im_end|>\n<|im_start|>assistant\n"
            let tokens = context.tokenizer.encode(text: chatML)
            let inputTokens = MLXArray(tokens)
            let input = LMInput(tokens: inputTokens)
            
            var responseText = ""
            
            for try await item in try MLXLMCommon.generateTokens(
                input: input,
                parameters: extractConfig.generateParameters,
                context: context
            ) {
                if Task.isCancelled { throw CancellationError() }
                switch item {
                case .token(let id):
                    responseText += context.tokenizer.decode(tokens: [id])
                case .info:
                    break
                }
            }
            
            return responseText.replacingOccurrences(of: "<|im_end|>", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return extractedText
    }
}
