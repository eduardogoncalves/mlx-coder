// Tests/ModelEngineTests/ImageAttachmentParserTests.swift
// Covers @path image-attachment parsing, including space-containing paths
// (e.g. macOS screenshot filenames like "Screenshot 2026-07-31 at 21.46.35.png").

import XCTest
@testable import MLXCoder

final class ImageAttachmentParserTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageAttachmentParserTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    private func makeFile(named name: String) -> URL {
        let url = tempDir.appendingPathComponent(name)
        try? Data().write(to: url)
        return url
    }

    func testSimpleNoSpacePathIsDetected() {
        let result = ImageAttachmentParser.parse(prompt: "describe @img.png please")
        XCTAssertEqual(result.imageURLs.map(\.lastPathComponent), ["img.png"])
        XCTAssertEqual(result.cleanedPrompt, "describe please")
    }

    func testNonexistentSpacedPathFallsBackToFirstWord() {
        // No file exists on disk, so the parser should fall back to legacy
        // single-word behavior rather than guessing across the space.
        let result = ImageAttachmentParser.parse(
            prompt: "see @tmp/Screenshot 2026-07-31 at 21.46.35.png"
        )
        XCTAssertTrue(result.imageURLs.isEmpty)
    }

    func testExistingSpacedScreenshotFilenameIsAttached() {
        let file = makeFile(named: "Screenshot 2026-07-31 at 21.46.35.png")
        let prompt = "the layout did not render properly, describe the fail, see @\(file.path)"
        let result = ImageAttachmentParser.parse(prompt: prompt)

        XCTAssertEqual(result.imageURLs.count, 1)
        XCTAssertEqual(result.imageURLs.first?.path, file.path)
        XCTAssertFalse(result.cleanedPrompt.contains("Screenshot"))
        XCTAssertTrue(result.cleanedPrompt.hasPrefix("the layout did not render properly"))
    }

    func testMultipleSpacedAttachmentsAreBothResolved() {
        let first = makeFile(named: "Screenshot 2026-07-31 at 21.46.35.png")
        let second = makeFile(named: "Screenshot 2026-08-01 at 09.00.00.png")
        let prompt = "compare @\(first.path) and @\(second.path) please"
        let result = ImageAttachmentParser.parse(prompt: prompt)

        XCTAssertEqual(Set(result.imageURLs.map(\.path)), Set([first.path, second.path]))
        XCTAssertEqual(result.cleanedPrompt, "compare and please")
    }

    func testTrailingSentencePunctuationIsStripped() {
        let result = ImageAttachmentParser.parse(prompt: "look at @img.png, it's broken")
        XCTAssertEqual(result.imageURLs.map(\.lastPathComponent), ["img.png"])
    }

    func testNonImageExtensionIsIgnored() {
        let result = ImageAttachmentParser.parse(prompt: "see @notes.txt for details")
        XCTAssertTrue(result.imageURLs.isEmpty)
        XCTAssertEqual(result.cleanedPrompt, "see @notes.txt for details")
    }
}
