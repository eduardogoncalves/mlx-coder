import XCTest
@testable import MLXCoder

final class HTMLTextExtractorTests: XCTestCase {

    func testStripsScriptAndStyleBlocks() {
        let html = """
            <html><head><style>body { color: red; }</style></head>
            <body><script>alert('hi');</script><p>Hello World</p></body></html>
            """
        let text = HTMLTextExtractor.extract(from: html)
        XCTAssertFalse(text.contains("color: red"), "CSS should be stripped")
        XCTAssertFalse(text.contains("alert"), "JS should be stripped")
        XCTAssertTrue(text.contains("Hello World"), "Content should be preserved")
    }

    func testConvertsEmphasisToMarkdown() {
        let html = "<p>Some <strong>bold</strong> and <em>italic</em> text.</p>"
        let text = HTMLTextExtractor.extract(from: html)
        XCTAssertEqual(text, "Some **bold** and *italic* text.")
    }

    func testDecodesCommonEntities() {
        let html = "<p>5 &lt; 10 &amp; 3 &gt; 1 &mdash; true</p>"
        let text = HTMLTextExtractor.extract(from: html)
        XCTAssertTrue(text.contains("5 < 10"), "less-than entity")
        XCTAssertTrue(text.contains("& 3 > 1"), "ampersand + greater-than")
        XCTAssertTrue(text.contains("—"), "mdash entity")
    }

    func testDecodesNumericEntities() {
        let html = "<p>&#65;&#66;&#67;</p>"  // ABC
        let text = HTMLTextExtractor.extract(from: html)
        XCTAssertTrue(text.contains("ABC"), "numeric decimal entities")
    }

    func testDecodesHexEntities() {
        let html = "<p>&#x41;&#x42;&#x43;</p>"  // ABC
        let text = HTMLTextExtractor.extract(from: html)
        XCTAssertTrue(text.contains("ABC"), "numeric hex entities")
    }

    func testBlockTagsProduceNewlines() {
        let html = "<div>First</div><div>Second</div><p>Third</p>"
        let text = HTMLTextExtractor.extract(from: html)
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertTrue(lines.contains("First"), "First block")
        XCTAssertTrue(lines.contains("Second"), "Second block")
        XCTAssertTrue(lines.contains("Third"), "Third block")
        XCTAssertGreaterThan(lines.count, 1, "block tags should produce separate lines")
    }

    func testCollapsesExcessiveWhitespace() {
        let html = "<p>Lots   of   spaces    here</p>"
        let text = HTMLTextExtractor.extract(from: html)
        XCTAssertFalse(text.contains("   "), "multiple spaces should be collapsed")
        XCTAssertTrue(text.contains("Lots of spaces here"))
    }

    func testPassThroughNonHTML() {
        let plain = "Just plain text with no HTML."
        let text = HTMLTextExtractor.extract(from: plain)
        XCTAssertEqual(text, plain)
    }

    // MARK: - Link preservation

    func testPreservesLinksAsMarkdown() {
        let html = "<p>See <a href=\"https://example.com/docs\">the docs</a> for details.</p>"
        let text = HTMLTextExtractor.extract(from: html)
        XCTAssertTrue(text.contains("[the docs](https://example.com/docs)"), "Link text and URL should survive as Markdown")
    }

    func testResolvesRelativeLinksAgainstBaseURL() {
        let html = "<p><a href=\"/docs/page\">docs</a></p>"
        let base = URL(string: "https://example.com/blog/post")!
        let text = HTMLTextExtractor.extract(from: html, baseURL: base)
        XCTAssertTrue(text.contains("[docs](https://example.com/docs/page)"), "Relative href should resolve to an absolute URL")
    }

    func testConvertsHeadingsAndLists() {
        let html = """
            <article>
            <h1>Title</h1>
            <p>Intro paragraph.</p>
            <ul><li>One</li><li>Two</li></ul>
            </article>
            """
        let text = HTMLTextExtractor.extract(from: html)
        XCTAssertTrue(text.contains("# Title"))
        XCTAssertTrue(text.contains("- One"))
        XCTAssertTrue(text.contains("- Two"))
    }

    // MARK: - Metadata extraction

    func testExtractsPublishedDateFromMetaTag() {
        let html = """
            <html><head>
            <title>Article Title</title>
            <meta property="article:published_time" content="2026-01-15T10:00:00Z">
            </head><body><article><p>Body text.</p></article></body></html>
            """
        let text = HTMLTextExtractor.extract(from: html)
        XCTAssertTrue(text.contains("Title: Article Title"))
        XCTAssertTrue(text.contains("Published: 2026-01-15T10:00:00Z"))
    }

    func testExtractsPublishedDateFromTimeTag() {
        let html = """
            <html><body><article>
            <time datetime="2025-11-03">November 3, 2025</time>
            <p>Body text long enough to be picked as the main article content block here.</p>
            </article></body></html>
            """
        let text = HTMLTextExtractor.extract(from: html)
        XCTAssertTrue(text.contains("Published: 2025-11-03"))
    }

    func testExtractsPublishedDateFromJSONLD() {
        let html = """
            <html><head>
            <script type="application/ld+json">{"@type": "Article", "datePublished": "2024-06-01"}</script>
            </head><body><article><p>Body text.</p></article></body></html>
            """
        let text = HTMLTextExtractor.extract(from: html)
        XCTAssertTrue(text.contains("Published: 2024-06-01"))
    }

    // MARK: - Boilerplate removal

    func testRemovesNavigationAndSidebarBoilerplate() {
        let html = """
            <html><body>
            <nav><a href="/">Home</a><a href="/about">About</a></nav>
            <article>
            <p>This is the real article content that should be kept in the extracted output.</p>
            </article>
            <aside class="sidebar"><p>Related links you should not care about.</p></aside>
            </body></html>
            """
        let text = HTMLTextExtractor.extract(from: html)
        XCTAssertTrue(text.contains("real article content"))
        XCTAssertFalse(text.contains("Related links"), "Sidebar content should be dropped")
        XCTAssertFalse(text.contains("[Home]"), "Nav links should be dropped")
    }
}
