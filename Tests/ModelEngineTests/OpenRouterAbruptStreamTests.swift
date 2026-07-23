import XCTest
@testable import MLXCoder

/// Verifies that when the underlying HTTP connection is dropped/canceled
/// server-side mid-stream — closing the response body without ever sending
/// `data: [DONE]` or a `finish_reason` — `OpenRouterClient.stream` surfaces a
/// thrown error instead of finishing "successfully" with a silently
/// truncated (or empty) completion. Without this, callers (and thus the TUI)
/// have no signal that the turn never actually completed.
final class OpenRouterAbruptStreamTests: XCTestCase {

    private func makeClient(response: Data) -> OpenRouterClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AbruptEndingProtocol.self]
        AbruptEndingProtocol.responseBody = response
        let session = URLSession(configuration: config)
        return OpenRouterClient(apiKey: "test-key", session: session)
    }

    func testStreamThrowsWhenConnectionEndsWithoutDoneSentinel() async throws {
        // Simulates a server that streamed a partial text delta and then had
        // its connection canceled (as in the llama.cpp `Connection handling
        // canceled` case) — no `[DONE]`, no `finish_reason`.
        let body = Data("""
        data: {"choices":[{"delta":{"content":"Hello"}}]}

        """.utf8)
        let client = makeClient(response: body)
        let stream = client.stream(
            model: "openai/gpt-4o",
            messages: [OpenRouterMessage(role: .user, content: "Hi")]
        )

        var receivedText = false
        var thrownError: Error?
        do {
            for try await event in stream {
                if case .text = event { receivedText = true }
            }
        } catch {
            thrownError = error
        }

        XCTAssertTrue(receivedText, "the partial text delta should still have been yielded")
        let error = try XCTUnwrap(thrownError, "an abruptly-closed stream (no [DONE]/finish_reason) must throw")
        guard case OpenRouterError.transport = error else {
            return XCTFail("expected OpenRouterError.transport, got \(error)")
        }
    }

    func testStreamCompletesNormallyWithDoneSentinel() async throws {
        // Sanity check: a clean stream (still terminated by `[DONE]`) must NOT throw.
        let body = Data("""
        data: {"choices":[{"delta":{"content":"Hi"}}]}

        data: [DONE]

        """.utf8)
        let client = makeClient(response: body)
        let stream = client.stream(
            model: "openai/gpt-4o",
            messages: [OpenRouterMessage(role: .user, content: "Hi")]
        )

        var sawDone = false
        for try await event in stream {
            if case .done = event { sawDone = true }
        }
        XCTAssertTrue(sawDone)
    }

    func testStreamCompletesNormallyWithFinishReasonOnly() async throws {
        // Some servers signal completion via `finish_reason` on the final
        // choice frame without ever sending a distinct `[DONE]` frame.
        let body = Data("""
        data: {"choices":[{"delta":{"content":"Hi"},"finish_reason":"stop"}]}

        """.utf8)
        let client = makeClient(response: body)
        let stream = client.stream(
            model: "openai/gpt-4o",
            messages: [OpenRouterMessage(role: .user, content: "Hi")]
        )

        var sawDone = false
        for try await event in stream {
            if case .done = event { sawDone = true }
        }
        XCTAssertTrue(sawDone)
    }
}

// MARK: - URLProtocol stub that ends the body without `[DONE]`

/// Replies with a fixed SSE body and then finishes loading — simulating a
/// connection that the server closed (or canceled) before sending a
/// completion sentinel. Foundation's `URLSession.bytes(for:)` surfaces this
/// as a clean end of the byte stream (no error), which is exactly the gap
/// under test.
private final class AbruptEndingProtocol: URLProtocol {
    nonisolated(unsafe) static var responseBody = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        // No error reported — the body just ends, mirroring a proxy that
        // cancels request handling and closes the connection cleanly.
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
