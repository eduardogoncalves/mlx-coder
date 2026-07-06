import XCTest
@testable import MLXCoder

/// Verifies that `session_id`, when provided, is serialized into the OpenRouter
/// chat/completions request body so all generations in one conversation are
/// grouped into a single session — and that it is omitted otherwise.
final class OpenRouterSessionIdTests: XCTestCase {

    override func tearDown() {
        RequestCapture.reset()
        super.tearDown()
    }

    private func makeClient() -> OpenRouterClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RequestCapturingProtocol.self]
        let session = URLSession(configuration: config)
        return OpenRouterClient(apiKey: "test-key", session: session)
    }

    private func drain(_ client: OpenRouterClient, sessionId: String?) async {
        let stream = client.stream(
            model: "openai/gpt-4o",
            messages: [OpenRouterMessage(role: .user, content: "Hello")],
            sessionId: sessionId
        )
        // The mock returns `data: [DONE]` immediately; consume the stream so the
        // request is actually issued and captured.
        do {
            for try await _ in stream {}
        } catch {
            // Ignore stream errors — the assertion targets the captured request.
        }
    }

    func testSessionIdIsIncludedInRequestBody() async throws {
        let client = makeClient()
        await drain(client, sessionId: "my-session-123")

        let body = try XCTUnwrap(RequestCapture.lastBody, "request body should have been captured")
        XCTAssertEqual(body["session_id"] as? String, "my-session-123")
        XCTAssertEqual(body["model"] as? String, "openai/gpt-4o")
    }

    func testSessionIdOmittedWhenNil() async throws {
        let client = makeClient()
        await drain(client, sessionId: nil)

        let body = try XCTUnwrap(RequestCapture.lastBody)
        XCTAssertNil(body["session_id"], "session_id must not appear when not provided")
    }

    func testEmptySessionIdIsOmitted() async throws {
        let client = makeClient()
        await drain(client, sessionId: "")

        let body = try XCTUnwrap(RequestCapture.lastBody)
        XCTAssertNil(body["session_id"], "empty session_id must not be sent")
    }
}

// MARK: - URLProtocol capture harness

private enum RequestCapture {
    static let lock = NSLock()
    nonisolated(unsafe) private static var _lastBody: [String: Any]?

    static var lastBody: [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        return _lastBody
    }

    static func store(_ body: [String: Any]?) {
        lock.lock(); defer { lock.unlock() }
        _lastBody = body
    }

    static func reset() { store(nil) }
}

/// Intercepts outgoing requests, records the decoded JSON body, and replies with
/// a minimal SSE stream terminated by `[DONE]`.
private final class RequestCapturingProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession strips httpBody into httpBodyStream; read whichever is set.
        let data = Self.bodyData(from: request)
        if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            RequestCapture.store(obj)
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("data: [DONE]\n\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
