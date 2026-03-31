// Tests/ModelEngineTests/ToolCallPatternTests.swift

import XCTest
@testable import NativeAgent

final class ToolCallPatternTests: XCTestCase {

    func testTokensAreDefined() {
        XCTAssertFalse(ToolCallPattern.imStart.isEmpty)
        XCTAssertFalse(ToolCallPattern.imEnd.isEmpty)
        XCTAssertFalse(ToolCallPattern.toolCallOpen.isEmpty)
        XCTAssertFalse(ToolCallPattern.toolCallClose.isEmpty)
        XCTAssertFalse(ToolCallPattern.eosToken.isEmpty)
    }

    func testChatMLDelimiters() {
        XCTAssertEqual(ToolCallPattern.imStart, "<|im_start|>")
        XCTAssertEqual(ToolCallPattern.imEnd, "<|im_end|>")
    }
}
