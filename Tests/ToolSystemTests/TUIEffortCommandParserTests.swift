import XCTest
@testable import MLXCoder

final class TUIEffortCommandParserTests: XCTestCase {
    func testEffortWithoutArgumentOpensMenu() {
        XCTAssertEqual(
            TUIEffortCommandParser.resolve(input: "/effort"),
            .openMenu(isLegacyAlias: false)
        )
    }

    func testThinkingWithoutArgumentOpensMenu() {
        XCTAssertEqual(
            TUIEffortCommandParser.resolve(input: "/thinking"),
            .openMenu(isLegacyAlias: true)
        )
    }

    func testEffortDirectInvocationStillParses() {
        XCTAssertEqual(
            TUIEffortCommandParser.resolve(input: "/effort low"),
            .setLevel(.low, isLegacyAlias: false)
        )
    }

    func testThinkingAliasDirectInvocationStillParses() {
        XCTAssertEqual(
            TUIEffortCommandParser.resolve(input: "/thinking high"),
            .setLevel(.high, isLegacyAlias: true)
        )
    }
}
