import XCTest
@testable import NativeAgent

final class TerminalKeyParserTests: XCTestCase {
    func testClassifyEscapeSequenceBare() {
        XCTAssertEqual(TerminalKeyParser.classifyEscapeSequence([]), .bare)
    }

    func testClassifyEscapeSequenceCSI() {
        XCTAssertEqual(TerminalKeyParser.classifyEscapeSequence([91, 65]), .csiOrSS3([91, 65]))
    }

    func testClassifyEscapeSequenceSS3() {
        XCTAssertEqual(TerminalKeyParser.classifyEscapeSequence([79, 113]), .csiOrSS3([79, 113]))
    }

    func testClassifyEscapeSequenceAlt() {
        XCTAssertEqual(TerminalKeyParser.classifyEscapeSequence([98]), .alt([98]))
    }

    func testArrowDirectionMapping() {
        XCTAssertEqual(TerminalKeyParser.arrowDirection(for: [91, 65]), .up)
        XCTAssertEqual(TerminalKeyParser.arrowDirection(for: [91, 66]), .down)
        XCTAssertEqual(TerminalKeyParser.arrowDirection(for: [91, 67]), .right)
        XCTAssertEqual(TerminalKeyParser.arrowDirection(for: [91, 68]), .left)
        XCTAssertNil(TerminalKeyParser.arrowDirection(for: [98]))
    }

    func testNumericSelectionFromByte() {
        XCTAssertEqual(TerminalKeyParser.numericSelection(for: 49, allowThirdOption: true), 0)
        XCTAssertEqual(TerminalKeyParser.numericSelection(for: 50, allowThirdOption: true), 1)
        XCTAssertEqual(TerminalKeyParser.numericSelection(for: 51, allowThirdOption: true), 2)
        XCTAssertNil(TerminalKeyParser.numericSelection(for: 51, allowThirdOption: false))
    }

    func testNumericSelectionFromEscapeSequence() {
        XCTAssertEqual(TerminalKeyParser.numericSelection(forEscapeSequence: [79, 113], allowThirdOption: true), 0)
        XCTAssertEqual(TerminalKeyParser.numericSelection(forEscapeSequence: [79, 114], allowThirdOption: true), 1)
        XCTAssertEqual(TerminalKeyParser.numericSelection(forEscapeSequence: [79, 115], allowThirdOption: true), 2)
        XCTAssertNil(TerminalKeyParser.numericSelection(forEscapeSequence: [79, 115], allowThirdOption: false))
        XCTAssertNil(TerminalKeyParser.numericSelection(forEscapeSequence: [91, 49, 126], allowThirdOption: true))
    }
}
