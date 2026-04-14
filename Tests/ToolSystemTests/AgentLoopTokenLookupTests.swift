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
        var previousSignature: String?
        var previousStreak = 0

        let first = AgentLoop.evaluateReadFileLoop(
            callName: "read_file",
            arguments: ["path": "hello-template.html", "start_line": 1, "end_line": 10],
            previousSignature: previousSignature,
            previousStreak: previousStreak
        )
        previousSignature = first.nextSignature
        previousStreak = first.nextStreak

        let second = AgentLoop.evaluateReadFileLoop(
            callName: "read_file",
            arguments: ["path": "./hello-template.html", "start_line": 1, "end_line": 10],
            previousSignature: previousSignature,
            previousStreak: previousStreak
        )
        previousSignature = second.nextSignature
        previousStreak = second.nextStreak

        let third = AgentLoop.evaluateReadFileLoop(
            callName: "read_file",
            arguments: ["path": "hello-template.html", "start_line": 1, "end_line": 10],
            previousSignature: previousSignature,
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
            arguments: ["path": "a.swift", "start_line": 1, "end_line": 5],
            previousSignature: nil,
            previousStreak: 0
        )

        let nonRead = AgentLoop.evaluateReadFileLoop(
            callName: "grep",
            arguments: ["pattern": "foo"],
            previousSignature: first.nextSignature,
            previousStreak: first.nextStreak
        )

        let second = AgentLoop.evaluateReadFileLoop(
            callName: "read_file",
            arguments: ["path": "a.swift", "start_line": 1, "end_line": 5],
            previousSignature: nonRead.nextSignature,
            previousStreak: nonRead.nextStreak
        )

        XCTAssertFalse(second.shouldBlock)
        XCTAssertEqual(second.nextStreak, 1)
    }

    func testEvaluateReadFileLoopAllowsDifferentLineRangesForSameFile() {
        let first = AgentLoop.evaluateReadFileLoop(
            callName: "read_file",
            arguments: ["path": "hello-template.html", "start_line": 1, "end_line": 10],
            previousSignature: nil,
            previousStreak: 0
        )

        let second = AgentLoop.evaluateReadFileLoop(
            callName: "read_file",
            arguments: ["path": "hello-template.html", "start_line": 11, "end_line": 20],
            previousSignature: first.nextSignature,
            previousStreak: first.nextStreak
        )

        XCTAssertFalse(second.shouldBlock)
        XCTAssertEqual(second.nextStreak, 1)
    }

    func testMissingRequiredArgumentNamesDetectsAbsentAndEmptyValues() {
        let missing = AgentLoop.missingRequiredArgumentNames(
            required: ["path", "old_text", "new_text", "paths"],
            arguments: [
                "path": "file.txt",
                "old_text": " ",
                "paths": []
            ]
        )

        XCTAssertEqual(Set(missing), Set(["old_text", "new_text", "paths"]))
    }

    func testMissingRequiredArgumentNamesReturnsEmptyWhenAllPresent() {
        let missing = AgentLoop.missingRequiredArgumentNames(
            required: ["path", "old_text", "new_text"],
            arguments: [
                "path": "f.txt",
                "old_text": "before",
                "new_text": "after"
            ]
        )

        XCTAssertTrue(missing.isEmpty)
    }

    func testEvaluateReadOnlyToolLoopBlocksSecondConsecutiveIdenticalCall() {
        let first = AgentLoop.evaluateReadOnlyToolLoop(
            callName: "list_dir",
            arguments: ["path": ".", "recursive": false],
            previousSignature: nil,
            previousStreak: 0
        )

        let second = AgentLoop.evaluateReadOnlyToolLoop(
            callName: "list_dir",
            arguments: ["path": "./", "recursive": false],
            previousSignature: first.nextSignature,
            previousStreak: first.nextStreak
        )

        XCTAssertFalse(first.shouldBlock)
        XCTAssertTrue(second.shouldBlock)
        XCTAssertEqual(second.nextStreak, 2)
    }

    func testEvaluateReadOnlyToolLoopResetsForDifferentArguments() {
        let first = AgentLoop.evaluateReadOnlyToolLoop(
            callName: "list_dir",
            arguments: ["path": ".", "recursive": false],
            previousSignature: nil,
            previousStreak: 0
        )

        let second = AgentLoop.evaluateReadOnlyToolLoop(
            callName: "list_dir",
            arguments: ["path": ".", "recursive": true],
            previousSignature: first.nextSignature,
            previousStreak: first.nextStreak
        )

        XCTAssertFalse(second.shouldBlock)
        XCTAssertEqual(second.nextStreak, 1)
    }

    func testEvaluateReadOnlyToolLoopIgnoresNonReadOnlyTools() {
        let state = AgentLoop.evaluateReadOnlyToolLoop(
            callName: "write_file",
            arguments: ["path": "a.txt", "content": "x"],
            previousSignature: "list_dir|{}",
            previousStreak: 3
        )

        XCTAssertNil(state.nextSignature)
        XCTAssertEqual(state.nextStreak, 0)
        XCTAssertFalse(state.shouldBlock)
    }
}
