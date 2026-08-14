import XCTest
@testable import MLXCoder

/// Verifies that image attachments on an `RemoteAPIMessage` are serialized as
/// an OpenAI-style multi-part `content` array (`[{type:text}, {type:image_url}]`)
/// instead of the plain string used when there are no images.
final class RemoteAPIImageAttachmentTests: XCTestCase {

    override func tearDown() {
        ImageRequestCapture.reset()
        super.tearDown()
    }

    private func makeClient() -> RemoteAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ImageRequestCapturingProtocol.self]
        let session = URLSession(configuration: config)
        return RemoteAPIClient(apiKey: "test-key", session: session)
    }

    private func drain(_ client: RemoteAPIClient, messages: [RemoteAPIMessage]) async {
        let stream = client.stream(model: "openai/gpt-4o", messages: messages)
        do {
            for try await _ in stream {}
        } catch {
            // Ignore stream errors — the assertion targets the captured request.
        }
    }

    func testPlainMessageContentIsAStringWhenNoImages() async throws {
        let client = makeClient()
        await drain(client, messages: [RemoteAPIMessage(role: .user, content: "Hello")])

        let body = try XCTUnwrap(ImageRequestCapture.lastBody)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["content"] as? String, "Hello")
    }

    func testImageAttachmentBecomesMultiPartContentArray() async throws {
        let client = makeClient()
        let dataURL = "data:image/png;base64,AAAA"
        await drain(client, messages: [
            RemoteAPIMessage(role: .user, content: "describe this", imageDataURLs: [dataURL])
        ])

        let body = try XCTUnwrap(ImageRequestCapture.lastBody)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let parts = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])

        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0]["type"] as? String, "text")
        XCTAssertEqual(parts[0]["text"] as? String, "describe this")
        XCTAssertEqual(parts[1]["type"] as? String, "image_url")
        let imageURL = try XCTUnwrap(parts[1]["image_url"] as? [String: Any])
        XCTAssertEqual(imageURL["url"] as? String, dataURL)
    }

    func testMultipleImagesProduceOneContentPartEach() async throws {
        let client = makeClient()
        await drain(client, messages: [
            RemoteAPIMessage(
                role: .user,
                content: "compare these",
                imageDataURLs: ["data:image/png;base64,AAAA", "data:image/png;base64,BBBB"]
            )
        ])

        let body = try XCTUnwrap(ImageRequestCapture.lastBody)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let parts = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 3) // 1 text + 2 images
    }
}

// MARK: - ImageDataURLEncoder

final class ImageDataURLEncoderTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageDataURLEncoderTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    func testPNGIsEncodedDirectlyWithoutReencoding() throws {
        let bytes = Data([0x01, 0x02, 0x03, 0x04])
        let url = tempDir.appendingPathComponent("img.png")
        try bytes.write(to: url)

        let dataURL = try ImageDataURLEncoder.dataURL(for: url)
        XCTAssertEqual(dataURL, "data:image/png;base64,\(bytes.base64EncodedString())")
    }

    func testJPEGMimeTypeIsMappedCorrectly() throws {
        let bytes = Data([0xFF, 0xD8, 0xFF])
        let url = tempDir.appendingPathComponent("img.jpg")
        try bytes.write(to: url)

        let dataURL = try ImageDataURLEncoder.dataURL(for: url)
        XCTAssertTrue(dataURL.hasPrefix("data:image/jpeg;base64,"))
    }
}

// MARK: - URLProtocol capture harness

private enum ImageRequestCapture {
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

private final class ImageRequestCapturingProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let data = Self.bodyData(from: request)
        if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            ImageRequestCapture.store(obj)
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
