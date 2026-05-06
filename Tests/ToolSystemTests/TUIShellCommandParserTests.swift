import XCTest
@testable import MLXCoder

final class TUIShellCommandParserTests: XCTestCase {
    func testRepeatDetectionForDoubleBang() {
        let parsed = TUIShellCommandParser.parse("!!", lastShellCommand: "pwd")
        XCTAssertTrue(parsed.isRepeat)
        XCTAssertEqual(parsed.command, "pwd")
    }

    func testDoubleBangPrefixedCommandParsesToCommandWithoutBang() {
        let parsed = TUIShellCommandParser.parse("!!ls", lastShellCommand: "pwd")
        XCTAssertFalse(parsed.isRepeat)
        XCTAssertEqual(parsed.command, "ls")
    }

    func testSingleBangPrefixedCommandParsesToCommandWithoutBang() {
        let parsed = TUIShellCommandParser.parse("!ls", lastShellCommand: "pwd")
        XCTAssertFalse(parsed.isRepeat)
        XCTAssertEqual(parsed.command, "ls")
    }

    func testParsedShellCommandHasNoLeadingBang() {
        XCTAssertEqual(TUIShellCommandParser.parse("!!ls -la", lastShellCommand: "").command, "ls -la")
        XCTAssertEqual(TUIShellCommandParser.parse("!ls -la", lastShellCommand: "").command, "ls -la")
        XCTAssertFalse(TUIShellCommandParser.parse("!!ls -la", lastShellCommand: "").command?.hasPrefix("!") ?? true)
        XCTAssertFalse(TUIShellCommandParser.parse("!ls -la", lastShellCommand: "").command?.hasPrefix("!") ?? true)
    }
}
