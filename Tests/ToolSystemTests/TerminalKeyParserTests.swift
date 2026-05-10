import XCTest
@testable import MLXCoder

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

    func testShiftTabDetectionForCSIAndSS3Sequences() {
        XCTAssertTrue(TerminalKeyParser.isShiftTab([91, 90])) // ESC [ Z
        XCTAssertTrue(TerminalKeyParser.isShiftTab([79, 90])) // ESC O Z
        XCTAssertTrue(TerminalKeyParser.isShiftTab([91, 49, 59, 50, 90])) // ESC [ 1 ; 2 Z
    }

    func testShiftTabDetectionRejectsOtherEscapes() {
        XCTAssertFalse(TerminalKeyParser.isShiftTab([]))
        XCTAssertFalse(TerminalKeyParser.isShiftTab([98])) // Alt+b
        XCTAssertFalse(TerminalKeyParser.isShiftTab([91, 65])) // Up arrow
        XCTAssertFalse(TerminalKeyParser.isShiftTab([91, 9])) // Plain tab byte in CSI payload
    }

    func testOptionEnterDetection() {
        XCTAssertTrue(TerminalKeyParser.isOptionEnter([13])) // Esc + CR
        XCTAssertTrue(TerminalKeyParser.isOptionEnter([10])) // Esc + LF
        XCTAssertTrue(TerminalKeyParser.isOptionEnter([91, 49, 51, 59, 51, 117])) // CSI u
    }

    func testOptionEnterDetectionRejectsOtherEscapes() {
        XCTAssertFalse(TerminalKeyParser.isOptionEnter([]))
        XCTAssertFalse(TerminalKeyParser.isOptionEnter([98])) // Alt+b
        XCTAssertFalse(TerminalKeyParser.isOptionEnter([91, 49, 51, 59, 50, 117])) // Shift+Enter (CSI u)
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

    func testNumericSelectionFromByteWithFourOptions() {
        XCTAssertEqual(TerminalKeyParser.numericSelection(for: 49, optionCount: 4), 0)
        XCTAssertEqual(TerminalKeyParser.numericSelection(for: 52, optionCount: 4), 3)
        XCTAssertNil(TerminalKeyParser.numericSelection(for: 53, optionCount: 4))
    }

    func testNumericSelectionFromEscapeSequenceWithFourOptions() {
        XCTAssertEqual(TerminalKeyParser.numericSelection(forEscapeSequence: [79, 113], optionCount: 4), 0)
        XCTAssertEqual(TerminalKeyParser.numericSelection(forEscapeSequence: [79, 116], optionCount: 4), 3)
        XCTAssertNil(TerminalKeyParser.numericSelection(forEscapeSequence: [79, 117], optionCount: 4))
    }
}
