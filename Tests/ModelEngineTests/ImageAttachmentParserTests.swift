// Tests/ModelEngineTests/ImageAttachmentParserTests.swift

import XCTest
@testable import MLXCoder

final class ImageAttachmentParserTests: XCTestCase {

    func testDescribeWithSingleImageUsesExplicitImagePrompt() {
        let result = ImageAttachmentParser.parse(prompt: "describe @image.jpg")

        XCTAssertEqual(result.cleanedPrompt, "Describe the attached image.")
        XCTAssertEqual(result.imageURLs.count, 1)
        XCTAssertEqual(result.imageURLs.first?.lastPathComponent, "image.jpg")
    }

    func testDescribeWithMultipleImagesUsesPluralPrompt() {
        let result = ImageAttachmentParser.parse(prompt: "describe @a.jpg @b.png")

        XCTAssertEqual(result.cleanedPrompt, "Describe the attached images.")
        XCTAssertEqual(result.imageURLs.count, 2)
    }

    func testImageOnlyPromptUsesExplicitImagePrompt() {
        let result = ImageAttachmentParser.parse(prompt: "@image.jpg")

        XCTAssertEqual(result.cleanedPrompt, "Describe the attached image.")
        XCTAssertEqual(result.imageURLs.count, 1)
    }

    func testNonDescribePromptWithImageIsPreserved() {
        let result = ImageAttachmentParser.parse(prompt: "summarize @image.jpg")

        XCTAssertEqual(result.cleanedPrompt, "summarize")
        XCTAssertEqual(result.imageURLs.count, 1)
    }
}
