import XCTest
@testable import MLXCoder

/// Verifies that a large cached page is returned to the model as a bounded
/// window with a continuation marker, and that follow-up offset reads are
/// served from the disk cache (no network) — so the model can page through a
/// large JSON/page in order instead of receiving a silently clipped prefix.
final class WebFetchToolPaginationTests: XCTestCase {

    private var testURL: String { "https://example.com/large-json-\(UUID().uuidString)" }

    private func cleanup(url: String) {
        let cache = WebFetchCache.shared
        try? FileManager.default.removeItem(at: cache.rawURL(for: url))
        try? FileManager.default.removeItem(at: cache.textURL(for: url))
    }

    func testLargePageIsWindowedWithContinuationMarker() async throws {
        let url = testURL
        defer { cleanup(url: url) }

        // JSON-like payload larger than one window so truncation kicks in.
        let total = WebFetchTool.defaultMaxOutputLength + 8_000
        let body = "{\"items\":[" + String(repeating: "{\"k\":\"v\"},", count: total / 10)
        WebFetchCache.shared.save(raw: body, text: nil, for: url)

        let tool = WebFetchTool()
        let result = try await tool.execute(arguments: ["url": url])

        XCTAssertFalse(result.isError)
        XCTAssertLessThanOrEqual(result.content.count, WebFetchTool.defaultMaxOutputLength)

        let marker = try XCTUnwrap(result.truncationMarker, "large page should report a continuation marker")
        XCTAssertTrue(marker.contains("offset: \(WebFetchTool.defaultMaxOutputLength)"),
                      "marker must tell the model the exact next offset — got: \(marker)")
        XCTAssertTrue(marker.lowercased().contains("continue reading"))
    }

    func testOffsetReadIsServedFromCacheAndReachesEndOfPage() async throws {
        let url = testURL
        defer { cleanup(url: url) }

        let total = WebFetchTool.defaultMaxOutputLength + 3_000
        let body = String(repeating: "A", count: WebFetchTool.defaultMaxOutputLength)
            + String(repeating: "B", count: 3_000)
        XCTAssertEqual(body.count, total)
        WebFetchCache.shared.save(raw: body, text: nil, for: url)

        let tool = WebFetchTool()
        let result = try await tool.execute(arguments: [
            "url": url,
            "offset": WebFetchTool.defaultMaxOutputLength,
        ])

        XCTAssertFalse(result.isError)
        // Final chunk fits in one window: no further truncation, end-of-page banner.
        XCTAssertNil(result.truncationMarker)
        XCTAssertTrue(result.content.contains("end of page"))
        XCTAssertTrue(result.content.contains(String(repeating: "B", count: 3_000)),
                      "the tail of the page must be delivered verbatim, not invented")
    }

    func testOffsetBeyondEndReportsNoMoreContent() async throws {
        let url = testURL
        defer { cleanup(url: url) }

        let body = "{\"ok\":true}"
        WebFetchCache.shared.save(raw: body, text: nil, for: url)

        let tool = WebFetchTool()
        let result = try await tool.execute(arguments: ["url": url, "offset": 999_999])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("no more content"))
    }
}
