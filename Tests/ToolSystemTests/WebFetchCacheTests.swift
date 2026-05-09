import XCTest
@testable import MLXCoder

final class WebFetchCacheTests: XCTestCase {

    private var testURL: String { "https://example.com/test-\(UUID().uuidString)" }

    func testSaveAndReadRaw() {
        let url = testURL
        let cache = WebFetchCache.shared
        cache.save(raw: "raw content", text: nil, for: url)
        XCTAssertEqual(cache.rawContent(for: url), "raw content")
        XCTAssertNil(cache.textContent(for: url), "text file should not exist")
        cleanup(url: url)
    }

    func testSaveAndReadText() {
        let url = testURL
        let cache = WebFetchCache.shared
        cache.save(raw: "raw content", text: "stripped text", for: url)
        XCTAssertEqual(cache.rawContent(for: url), "raw content")
        XCTAssertEqual(cache.textContent(for: url), "stripped text")
        cleanup(url: url)
    }

    func testCacheMissReturnsNil() {
        let url = "https://example.com/definitely-not-cached-\(UUID().uuidString)"
        let cache = WebFetchCache.shared
        XCTAssertNil(cache.rawContent(for: url))
        XCTAssertNil(cache.textContent(for: url))
    }

    func testDistinctURLsHaveDistinctKeys() {
        let url1 = "https://example.com/page1"
        let url2 = "https://example.com/page2"
        let cache = WebFetchCache.shared
        cache.save(raw: "content1", text: nil, for: url1)
        cache.save(raw: "content2", text: nil, for: url2)
        XCTAssertEqual(cache.rawContent(for: url1), "content1")
        XCTAssertEqual(cache.rawContent(for: url2), "content2")
        cleanup(url: url1)
        cleanup(url: url2)
    }

    func testSaveWithoutTextRemovesPreviousStrippedEntry() {
        let url = testURL
        let cache = WebFetchCache.shared
        cache.save(raw: "raw v1", text: "stripped v1", for: url)
        XCTAssertEqual(cache.textContent(for: url), "stripped v1")

        cache.save(raw: "raw v2", text: nil, for: url)

        XCTAssertEqual(cache.rawContent(for: url), "raw v2")
        XCTAssertNil(cache.textContent(for: url))
        cleanup(url: url)
    }

    func testCacheDirectoryIsOwnerOnly() throws {
        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("mlx-coder-webcache", isDirectory: true)
        _ = WebFetchCache.shared
        let attrs = try FileManager.default.attributesOfItem(atPath: cacheDir.path)
        let perms = attrs[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o700)
    }

    // MARK: - Helpers

    private func cleanup(url: String) {
        let cache = WebFetchCache.shared
        try? FileManager.default.removeItem(at: cache.rawURL(for: url))
        try? FileManager.default.removeItem(at: cache.textURL(for: url))
    }
}
