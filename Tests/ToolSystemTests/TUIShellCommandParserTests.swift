import XCTest
@testable import MLXCoder

final class TUIShellCommandParserTests: XCTestCase {
    func testBareDoubleBangDoesNotParseToCommand() {
        let parsed = TUIShellCommandParser.parse("!!")
        XCTAssertEqual(parsed.command, "")
        XCTAssertTrue(parsed.suppressHistory)
    }

    func testDoubleBangPrefixedCommandParsesToCommandWithoutBang() {
        let parsed = TUIShellCommandParser.parse("!!ls")
        XCTAssertTrue(parsed.suppressHistory)
        XCTAssertEqual(parsed.command, "ls")
    }

    func testSingleBangPrefixedCommandParsesToCommandWithoutBang() {
        let parsed = TUIShellCommandParser.parse("!ls")
        XCTAssertFalse(parsed.suppressHistory)
        XCTAssertEqual(parsed.command, "ls")
    }

    func testParsedShellCommandHasNoLeadingBang() {
        XCTAssertEqual(TUIShellCommandParser.parse("!!ls -la").command, "ls -la")
        XCTAssertEqual(TUIShellCommandParser.parse("!ls -la").command, "ls -la")
        XCTAssertFalse(TUIShellCommandParser.parse("!!ls -la").command?.hasPrefix("!") ?? true)
        XCTAssertFalse(TUIShellCommandParser.parse("!ls -la").command?.hasPrefix("!") ?? true)
    }
}
