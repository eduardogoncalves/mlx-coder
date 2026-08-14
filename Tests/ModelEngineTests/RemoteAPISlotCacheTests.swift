import XCTest
@testable import MLXCoder

/// Verifies the pieces that let mlx-coder save/restore a llama.cpp slot's KV
/// cache across turns and process restarts: `id_slot` pinning on generation
/// requests, `id_slot` capture from stream frames, the `/slots` action-URL
/// derivation, and the save/restore request/response round trip.
final class RemoteAPISlotCacheTests: XCTestCase {

    override func tearDown() {
        SlotRequestCapture.reset()
        SlotCapturingProtocol.scriptedResponse = "data: [DONE]\n\n"
        SlotCapturingProtocol.statusCode = 200
        super.tearDown()
    }

    private func makeClient(baseURL: URL? = nil) -> RemoteAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SlotCapturingProtocol.self]
        let session = URLSession(configuration: config)
        if let baseURL {
            return RemoteAPIClient(apiKey: "test-key", baseURL: baseURL, session: session)
        }
        return RemoteAPIClient(apiKey: "test-key", session: session)
    }

    // MARK: - id_slot pinning on generation requests

    func testIdSlotIsIncludedInRequestBodyWhenProvided() async throws {
        let client = makeClient()
        let stream = client.stream(
            model: "qwen",
            messages: [RemoteAPIMessage(role: .user, content: "Hello")],
            idSlot: 3
        )
        do { for try await _ in stream {} } catch {}

        let body = try XCTUnwrap(SlotRequestCapture.lastBody)
        XCTAssertEqual(body["id_slot"] as? Int, 3)
    }

    func testIdSlotOmittedWhenNil() async throws {
        let client = makeClient()
        let stream = client.stream(
            model: "qwen",
            messages: [RemoteAPIMessage(role: .user, content: "Hello")]
        )
        do { for try await _ in stream {} } catch {}

        let body = try XCTUnwrap(SlotRequestCapture.lastBody)
        XCTAssertNil(body["id_slot"])
    }

    // MARK: - id_slot capture from stream frames

    func testSlotAssignedEventEmittedWhenFrameCarriesIdSlot() async throws {
        SlotCapturingProtocol.scriptedResponse = "data: {\"id_slot\":2,\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\ndata: [DONE]\n\n"
        let client = makeClient()
        let stream = client.stream(
            model: "qwen",
            messages: [RemoteAPIMessage(role: .user, content: "Hello")]
        )
        var sawSlot: Int?
        for try await event in stream {
            if case .slotAssigned(let idSlot) = event { sawSlot = idSlot }
        }
        XCTAssertEqual(sawSlot, 2)
    }

    // MARK: - slotActionURLs

    func testSlotActionURLsUnderBaseAndRootWhenVersioned() {
        let urls = RemoteAPIClient.slotActionURLs(
            baseURL: URL(string: "http://localhost:8080/v1")!,
            idSlot: 0,
            action: "save"
        )
        XCTAssertEqual(urls.map(\.absoluteString), [
            "http://localhost:8080/v1/slots/0?action=save",
            "http://localhost:8080/slots/0?action=save",
        ])
    }

    func testSlotActionURLsOnlyUnderBaseWhenUnversioned() {
        let urls = RemoteAPIClient.slotActionURLs(
            baseURL: URL(string: "http://localhost:8080")!,
            idSlot: 5,
            action: "restore"
        )
        XCTAssertEqual(urls.map(\.absoluteString), ["http://localhost:8080/slots/5?action=restore"])
    }

    // MARK: - saveSlot / restoreSlot round trip

    func testSaveSlotPostsFilenameAndReturnsResult() async throws {
        SlotCapturingProtocol.statusCode = 200
        SlotCapturingProtocol.scriptedResponse = "{\"id_slot\":1,\"filename\":\"a.bin\",\"n_saved\":10}"
        let client = makeClient(baseURL: URL(string: "http://localhost:8080/v1")!)

        let result = try await client.saveSlot(idSlot: 1, filename: "a.bin")
        XCTAssertEqual(result.idSlot, 1)
        XCTAssertEqual(result.filename, "a.bin")

        let body = try XCTUnwrap(SlotRequestCapture.lastBody)
        XCTAssertEqual(body["filename"] as? String, "a.bin")
        XCTAssertEqual(SlotRequestCapture.lastURL?.absoluteString, "http://localhost:8080/v1/slots/1?action=save")
    }

    func testRestoreSlotThrowsOnServerError() async throws {
        SlotCapturingProtocol.statusCode = 500
        SlotCapturingProtocol.scriptedResponse = "{\"error\":\"This server does not support slot save/restore\"}"
        let client = makeClient(baseURL: URL(string: "http://localhost:8080")!)

        do {
            _ = try await client.restoreSlot(idSlot: 0, filename: "missing.bin")
            XCTFail("expected restoreSlot to throw on a 500 response")
        } catch {
            // Any thrown error is acceptable — callers treat all failures as
            // "unsupported/unavailable" and fall back to a fresh prompt.
        }
    }
}

// MARK: - URLProtocol capture harness

private enum SlotRequestCapture {
    static let lock = NSLock()
    nonisolated(unsafe) private static var _lastBody: [String: Any]?
    nonisolated(unsafe) private static var _lastURL: URL?

    static var lastBody: [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        return _lastBody
    }

    static var lastURL: URL? {
        lock.lock(); defer { lock.unlock() }
        return _lastURL
    }

    static func store(body: [String: Any]?, url: URL?) {
        lock.lock(); defer { lock.unlock() }
        _lastBody = body
        _lastURL = url
    }

    static func reset() { store(body: nil, url: nil) }
}

/// Intercepts outgoing requests, records the decoded JSON body and URL, and
/// replies with a scripted body (SSE or a plain JSON object depending on the
/// endpoint under test).
private final class SlotCapturingProtocol: URLProtocol {
    nonisolated(unsafe) static var scriptedResponse = "data: [DONE]\n\n"
    nonisolated(unsafe) static var statusCode = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let data = Self.bodyData(from: request)
        let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        SlotRequestCapture.store(body: obj, url: request.url)

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.scriptedResponse.utf8))
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
