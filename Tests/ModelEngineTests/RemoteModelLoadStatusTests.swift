import XCTest
@testable import MLXCoder

/// Verifies `RemoteAPIClient.remoteModelLoadStatus` — the best-effort check
/// used when switching to a remote model so router-mode servers (llama.cpp
/// `--models-dir`/`--models-preset`, llama-swap) can report that a model is
/// "unloaded"/"sleeping"/"loading" and will be autoloaded lazily on first
/// request. Plain OpenAI-compatible servers (OpenRouter, LM Studio, vLLM)
/// omit the `status` field entirely and must resolve to `nil`.
final class RemoteModelLoadStatusTests: XCTestCase {

    override func tearDown() {
        StatusResponseStub.reset()
        super.tearDown()
    }

    private func makeClient() -> RemoteAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StatusStubbingProtocol.self]
        let session = URLSession(configuration: config)
        return RemoteAPIClient(apiKey: "", session: session)
    }

    func testReturnsStatusValueForMatchingModel() async {
        StatusResponseStub.body = [
            "data": [
                ["id": "other-model", "status": ["value": "unloaded"]],
                ["id": "qwen2.5-coder", "status": ["value": "sleeping"]]
            ]
        ]
        let status = await makeClient().remoteModelLoadStatus(modelID: "qwen2.5-coder")
        XCTAssertEqual(status, "sleeping")
    }

    func testReturnsNilWhenStatusFieldAbsent() async {
        // Plain OpenAI-compatible /models response — no router status annotation.
        StatusResponseStub.body = [
            "data": [
                ["id": "qwen2.5-coder", "object": "model"]
            ]
        ]
        let status = await makeClient().remoteModelLoadStatus(modelID: "qwen2.5-coder")
        XCTAssertNil(status)
    }

    func testReturnsNilWhenModelNotFound() async {
        StatusResponseStub.body = [
            "data": [
                ["id": "some-other-model", "status": ["value": "loaded"]]
            ]
        ]
        let status = await makeClient().remoteModelLoadStatus(modelID: "qwen2.5-coder")
        XCTAssertNil(status)
    }

    func testReturnsNilOnHTTPError() async {
        StatusResponseStub.statusCode = 500
        StatusResponseStub.body = [:]
        let status = await makeClient().remoteModelLoadStatus(modelID: "qwen2.5-coder")
        XCTAssertNil(status)
    }
}

// MARK: - URLProtocol stub harness

private enum StatusResponseStub {
    static let lock = NSLock()
    nonisolated(unsafe) private static var _body: [String: Any] = ["data": []]
    nonisolated(unsafe) private static var _statusCode: Int = 200

    static var body: [String: Any] {
        get { lock.lock(); defer { lock.unlock() }; return _body }
        set { lock.lock(); defer { lock.unlock() }; _body = newValue }
    }

    static var statusCode: Int {
        get { lock.lock(); defer { lock.unlock() }; return _statusCode }
        set { lock.lock(); defer { lock.unlock() }; _statusCode = newValue }
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        _body = ["data": []]
        _statusCode = 200
    }
}

private final class StatusStubbingProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let data = (try? JSONSerialization.data(withJSONObject: StatusResponseStub.body)) ?? Data()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: StatusResponseStub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
