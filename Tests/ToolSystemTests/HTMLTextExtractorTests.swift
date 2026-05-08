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

    func testStripsHTMLTags() {
        let html = "<p>Some <strong>bold</strong> and <em>italic</em> text.</p>"
        let text = HTMLTextExtractor.extract(from: html)
        XCTAssertEqual(text, "Some bold and italic text.")
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
}
