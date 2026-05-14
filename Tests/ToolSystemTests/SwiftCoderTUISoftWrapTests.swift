import XCTest
@testable import MLXCoder

final class SwiftCoderTUISoftWrapTests: XCTestCase {
    func testWrapsLongInputIntoMultipleLines() {
        let wrapped = wrappedInputTextForSoftWrap(
            "abcdefghijk",
            cursor: 11,
            footerWidth: 12,
            isAutopilot: false
        )

        XCTAssertEqual(wrapped.text, "abcdefghij\nk")
        XCTAssertEqual(wrapped.cursor, 12)
    }

    func testKeepsShellPrefixAndWrapsDisplayText() {
        let wrapped = wrappedInputTextForSoftWrap(
            "!abcdefghijkl",
            cursor: 13,
            footerWidth: 12,
            isAutopilot: false
        )

        XCTAssertEqual(wrapped.text, "!abcdefghij\nkl")
        XCTAssertEqual(wrapped.cursor, 14)
    }
}
