// Tests/ToolSystemTests/ToolCallErrorFormatterTests.swift

import XCTest
@testable import MLXCoder

final class ToolCallErrorFormatterTests: XCTestCase {
    private let toolNames = [
        "read_file", "write_file", "edit_file", "list_dir", "bash", "grep", "glob", "task",
    ]

    func testNearestNameMatchesCommonTypos() {
        XCTAssertEqual(ToolCallErrorFormatter.nearestName(to: "raed_file", among: toolNames), "read_file")
        XCTAssertEqual(ToolCallErrorFormatter.nearestName(to: "lsit_dir", among: toolNames), "list_dir")
        // Case-insensitive drift still resolves.
        XCTAssertEqual(ToolCallErrorFormatter.nearestName(to: "WriteFile", among: toolNames), "write_file")
    }

    func testNearestNameReturnsNilForUnrelatedName() {
        XCTAssertNil(ToolCallErrorFormatter.nearestName(to: "xyzzy", among: toolNames))
        XCTAssertNil(ToolCallErrorFormatter.nearestName(to: "", among: toolNames))
        XCTAssertNil(ToolCallErrorFormatter.nearestName(to: "read_file", among: []))
    }

    func testUnknownToolMessageIncludesSuggestionAndList() {
        let message = ToolCallErrorFormatter.unknownToolMessage(attempted: "raed_file", available: toolNames)
        XCTAssertTrue(message.contains("Unknown tool: 'raed_file'."))
        XCTAssertTrue(message.contains("Did you mean 'read_file'?"))
        XCTAssertTrue(message.contains("Available tools:"))
        XCTAssertTrue(message.contains("bash"))
    }

    func testUnknownToolMessageOmitsSuggestionWhenNothingClose() {
        let message = ToolCallErrorFormatter.unknownToolMessage(attempted: "frobnicate", available: toolNames)
        XCTAssertTrue(message.contains("Unknown tool: 'frobnicate'."))
        XCTAssertFalse(message.contains("Did you mean"))
        XCTAssertTrue(message.contains("Available tools:"))
    }

    func testMissingRequiredMessageEchoesSchemaAndProvided() {
        let message = ToolCallErrorFormatter.missingRequiredMessage(
            toolName: "edit_file",
            missing: ["new_text"],
            expected: ["path", "old_text", "new_text"],
            provided: ["path", "old_text"]
        )
        XCTAssertTrue(message.contains("edit_file: missing required parameter: new_text."))
        XCTAssertTrue(message.contains("Expected: { new_text, old_text, path }."))
        XCTAssertTrue(message.contains("You sent: { old_text, path }."))
    }

    func testMissingRequiredMessagePluralizes() {
        let message = ToolCallErrorFormatter.missingRequiredMessage(
            toolName: "edit_file",
            missing: ["old_text", "new_text"],
            expected: ["path", "old_text", "new_text"],
            provided: ["path"]
        )
        XCTAssertTrue(message.contains("missing required parameters: old_text, new_text."))
    }

    func testEditDistanceBasics() {
        XCTAssertEqual(ToolCallErrorFormatter.editDistance("read_file", "read_file"), 0)
        XCTAssertEqual(ToolCallErrorFormatter.editDistance("raed_file", "read_file"), 2)
        XCTAssertEqual(ToolCallErrorFormatter.editDistance("", "abc"), 3)
    }
}
