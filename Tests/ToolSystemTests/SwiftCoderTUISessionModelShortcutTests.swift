import XCTest
@testable import MLXCoder

final class SwiftCoderTUISessionModelShortcutTests: XCTestCase {
    func testCycledModelIndexMovesForward() {
        XCTAssertEqual(cycledModelIndex(from: 0, count: 3, reverse: false), 1)
        XCTAssertEqual(cycledModelIndex(from: 2, count: 3, reverse: false), 0)
    }

    func testCycledModelIndexMovesBackward() {
        XCTAssertEqual(cycledModelIndex(from: 0, count: 3, reverse: true), 2)
        XCTAssertEqual(cycledModelIndex(from: 2, count: 3, reverse: true), 1)
    }

    func testCycledModelIndexHandlesInvalidInputs() {
        XCTAssertNil(cycledModelIndex(from: 0, count: 0, reverse: false))
        XCTAssertEqual(cycledModelIndex(from: -1, count: 3, reverse: false), 1)
        XCTAssertEqual(cycledModelIndex(from: 99, count: 3, reverse: true), 1)
    }
}
