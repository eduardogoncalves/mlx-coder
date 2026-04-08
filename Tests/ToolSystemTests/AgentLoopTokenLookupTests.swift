import XCTest
@testable import MLXCoder

final class AgentLoopTokenLookupTests: XCTestCase {
    func testMakeTokenCountLookupHandlesDuplicateContent() {
        let lookup = AgentLoop.makeTokenCountLookup(
            contents: [
                "<tool_call>",
                "{\"name\":\"list_dir\",\"arguments\":{\"path\":\"src/portal.core/Models\"}}",
                "</tool_call>",
                "<tool_call>"
            ],
            counts: [1, 12, 1, 1]
        )

        XCTAssertEqual(lookup["<tool_call>"], 1)
        XCTAssertEqual(lookup["</tool_call>"], 1)
        XCTAssertEqual(lookup["{\"name\":\"list_dir\",\"arguments\":{\"path\":\"src/portal.core/Models\"}}"], 12)
        XCTAssertEqual(lookup.count, 3)
    }

    func testMakeTokenCountLookupUsesShortestInputLength() {
        let lookup = AgentLoop.makeTokenCountLookup(
            contents: ["a", "b", "c"],
            counts: [10, 20]
        )

        XCTAssertEqual(lookup["a"], 10)
        XCTAssertEqual(lookup["b"], 20)
        XCTAssertNil(lookup["c"])
    }

    func testEvaluateReadFileLoopBlocksThirdConsecutiveReadOfSameFile() {
        var previousPath: String?
        var previousStreak = 0

        let first = AgentLoop.evaluateReadFileLoop(
            callName: "read_file",
            arguments: ["path": "hello-template.html"],
            previousPath: previousPath,
            previousStreak: previousStreak
        )
        previousPath = first.nextPath
        previousStreak = first.nextStreak

        let second = AgentLoop.evaluateReadFileLoop(
            callName: "read_file",
            arguments: ["path": "./hello-template.html"],
            previousPath: previousPath,
            previousStreak: previousStreak
        )
        previousPath = second.nextPath
        previousStreak = second.nextStreak

        let third = AgentLoop.evaluateReadFileLoop(
            callName: "read_file",
            arguments: ["path": "hello-template.html"],
            previousPath: previousPath,
            previousStreak: previousStreak
        )

        XCTAssertFalse(first.shouldBlock)
        XCTAssertFalse(second.shouldBlock)
        XCTAssertTrue(third.shouldBlock)
        XCTAssertEqual(third.nextStreak, 3)
    }

    func testEvaluateReadFileLoopResetsAfterDifferentCall() {
        let first = AgentLoop.evaluateReadFileLoop(
            callName: "read_file",
            arguments: ["path": "a.swift"],
            previousPath: nil,
            previousStreak: 0
        )

        let nonRead = AgentLoop.evaluateReadFileLoop(
            callName: "grep",
            arguments: ["pattern": "foo"],
            previousPath: first.nextPath,
            previousStreak: first.nextStreak
        )

        let second = AgentLoop.evaluateReadFileLoop(
            callName: "read_file",
            arguments: ["path": "a.swift"],
            previousPath: nonRead.nextPath,
            previousStreak: nonRead.nextStreak
        )

        XCTAssertFalse(second.shouldBlock)
        XCTAssertEqual(second.nextStreak, 1)
    }
}
