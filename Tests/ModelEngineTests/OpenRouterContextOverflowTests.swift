import XCTest
@testable import MLXCoder

/// Verifies `OpenRouterError.isContextOverflow` / `.reportedContextWindow` — the
/// detection used by AgentLoop to trigger emergency context compaction when a remote
/// (llama.cpp / OpenAI-compatible) server rejects a request for exceeding its context
/// window, instead of blindly retrying the same oversized request.
final class OpenRouterContextOverflowTests: XCTestCase {

    func testDetectsLlamaCppExceedContextSizeError() {
        let body = #"{"error":{"code":400,"message":"request (18521 tokens) exceeds the available context size (18432 tokens), try increasing it","type":"exceed_context_size_error","n_prompt_tokens":18521,"n_ctx":18432}}"#
        let error = OpenRouterError.http(provider: "rtx5060ti", status: 400, body: body)
        XCTAssertTrue(error.isContextOverflow)
        XCTAssertEqual(error.reportedContextWindow, 18432)
        XCTAssertEqual(error.reportedPromptTokens, 18521)
    }

    func testReportedPromptTokensExtractedForOverflowRecovery() {
        // The exact shape from the field report: n_prompt_tokens is the server's
        // ground-truth token count used to calibrate the chars/4 estimate.
        let body = #"{"error":{"code":400,"message":"request (36428 tokens) exceeds the available context size (32768 tokens), try increasing it","type":"exceed_context_size_error","n_prompt_tokens":36428,"n_ctx":32768}}"#
        let error = OpenRouterError.http(provider: "rtx5060ti", status: 400, body: body)
        XCTAssertEqual(error.reportedContextWindow, 32768)
        XCTAssertEqual(error.reportedPromptTokens, 36428)
    }

    func testReportedPromptTokensNilWhenAbsent() {
        let body = #"{"error":{"message":"This model's maximum context length is 8192 tokens","type":"invalid_request_error","code":"context_length_exceeded"}}"#
        let error = OpenRouterError.http(provider: "OpenRouter", status: 400, body: body)
        XCTAssertNil(error.reportedPromptTokens)
    }

    func testDetectsOpenAIStyleContextLengthExceeded() {
        let body = #"{"error":{"message":"This model's maximum context length is 8192 tokens","type":"invalid_request_error","code":"context_length_exceeded"}}"#
        let error = OpenRouterError.http(provider: "OpenRouter", status: 400, body: body)
        XCTAssertTrue(error.isContextOverflow)
        XCTAssertNil(error.reportedContextWindow) // No `n_ctx` field in this shape.
    }

    func testIgnoresUnrelated400Errors() {
        let body = #"{"error":{"message":"Invalid API key","type":"invalid_request_error"}}"#
        let error = OpenRouterError.http(provider: "OpenRouter", status: 400, body: body)
        XCTAssertFalse(error.isContextOverflow)
        XCTAssertNil(error.reportedContextWindow)
    }

    func testIgnoresNon400Errors() {
        let body = #"{"error":{"type":"exceed_context_size_error","n_ctx":18432}}"#
        let error = OpenRouterError.http(provider: "OpenRouter", status: 500, body: body)
        XCTAssertFalse(error.isContextOverflow)
    }

    func testIgnoresNonHTTPErrorCases() {
        XCTAssertFalse(OpenRouterError.notConfigured.isContextOverflow)
        XCTAssertFalse(OpenRouterError.transport(provider: "OpenRouter", detail: "reset").isContextOverflow)
        XCTAssertFalse(OpenRouterError.decoding(provider: "OpenRouter", detail: "bad json").isContextOverflow)
    }
}
