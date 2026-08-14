import XCTest
@testable import MLXCoder

/// Verifies that `reasoning_effort`, when provided, is serialized into the
/// chat/completions request body (see
/// https://developers.openai.com/api/docs/guides/reasoning#reasoning-effort) —
/// and that it is omitted, not sent as some placeholder value, when absent.
final class RemoteAPIReasoningEffortTests: XCTestCase {

    override func tearDown() {
        ReasoningEffortRequestCapture.reset()
        super.tearDown()
    }

    private func makeClient() -> RemoteAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReasoningEffortCapturingProtocol.self]
        let session = URLSession(configuration: config)
        return RemoteAPIClient(apiKey: "test-key", session: session)
    }

    private func drain(_ client: RemoteAPIClient, reasoningEffort: String?) async {
        let stream = client.stream(
            model: "openai/gpt-5",
            messages: [RemoteAPIMessage(role: .user, content: "Hello")],
            reasoningEffort: reasoningEffort
        )
        do {
            for try await _ in stream {}
        } catch {
            // Ignore stream errors — the assertion targets the captured request.
        }
    }

    func testReasoningEffortIsIncludedInRequestBody() async throws {
        let client = makeClient()
        await drain(client, reasoningEffort: "high")

        let body = try XCTUnwrap(ReasoningEffortRequestCapture.lastBody)
        XCTAssertEqual(body["reasoning_effort"] as? String, "high")
    }

    func testReasoningEffortOmittedWhenNil() async throws {
        let client = makeClient()
        await drain(client, reasoningEffort: nil)

        let body = try XCTUnwrap(ReasoningEffortRequestCapture.lastBody)
        XCTAssertNil(body["reasoning_effort"], "reasoning_effort must not appear when not provided")
    }

    func testThinkingLevelMapsToOpenAIReasoningEffortStrings() {
        XCTAssertNil(AgentLoop.ThinkingLevel.fast.reasoningEffort)
        XCTAssertEqual(AgentLoop.ThinkingLevel.minimal.reasoningEffort, "minimal")
        XCTAssertEqual(AgentLoop.ThinkingLevel.low.reasoningEffort, "low")
        XCTAssertEqual(AgentLoop.ThinkingLevel.medium.reasoningEffort, "medium")
        XCTAssertEqual(AgentLoop.ThinkingLevel.high.reasoningEffort, "high")
    }
}

// MARK: - URLProtocol capture harness

private enum ReasoningEffortRequestCapture {
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
private final class ReasoningEffortCapturingProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let data = Self.bodyData(from: request)
        if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            ReasoningEffortRequestCapture.store(obj)
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
