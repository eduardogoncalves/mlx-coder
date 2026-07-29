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

    func testUncachedContentsReturnsDedupedContentMissingFromCache() {
        let snapshot = ["<tool_call>", "hello world", "<tool_call>", "goodbye"]
        let cache = ["hello world": 2]

        let uncached = AgentLoop.uncachedContents(snapshot: snapshot, cache: cache)

        // "hello world" is already counted; "<tool_call>" appears twice but is
        // tokenized once. Order isn't guaranteed (Set), so compare as sets.
        XCTAssertEqual(Set(uncached), Set(["<tool_call>", "goodbye"]))
    }

    func testUncachedContentsIsEmptyWhenCacheIsWarm() {
        // Regression guard: once every live content is cached, a subsequent
        // context-management pass must tokenize nothing — this is what stops
        // `makeTokenCounter` from re-encoding the whole history each turn.
        let snapshot = ["system prompt", "user turn", "assistant turn"]
        let warmCache = ["system prompt": 3, "user turn": 2, "assistant turn": 2]

        XCTAssertTrue(AgentLoop.uncachedContents(snapshot: snapshot, cache: warmCache).isEmpty)
    }

    func testPrunedTokenCountCacheDropsContentNoLongerLive() {
        // A purged transient turn / compacted message leaves the history; its
        // cached count must not linger, so the cache stays bounded by the live
        // conversation.
        let cache = ["kept": 1, "purged transient": 5, "also kept": 3]
        let live = ["kept", "also kept"]

        let pruned = AgentLoop.prunedTokenCountCache(cache, live: live)

        XCTAssertEqual(pruned, ["kept": 1, "also kept": 3])
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

    func testEvaluateFailedCallLoopSteersThenBreaksOnIdenticalFailures() {
        let args: [String: Any] = ["action": "uncomplete", "item": 2]

        let first = AgentLoop.evaluateFailedCallLoop(
            callName: "todo", arguments: args,
            previousSignature: nil, previousStreak: 0
        )
        let second = AgentLoop.evaluateFailedCallLoop(
            callName: "todo", arguments: args,
            previousSignature: first.nextSignature, previousStreak: first.nextStreak
        )
        let third = AgentLoop.evaluateFailedCallLoop(
            callName: "todo", arguments: args,
            previousSignature: second.nextSignature, previousStreak: second.nextStreak
        )

        // 1st failure: nothing yet. 2nd: steer once. 3rd: abandon the turn.
        XCTAssertFalse(first.shouldSteer)
        XCTAssertFalse(first.shouldBreak)
        XCTAssertTrue(second.shouldSteer)
        XCTAssertFalse(second.shouldBreak)
        XCTAssertFalse(third.shouldSteer)
        XCTAssertTrue(third.shouldBreak)
        XCTAssertEqual(third.nextStreak, 3)
    }

    func testEvaluateFailedCallLoopResetsWhenCallChanges() {
        let first = AgentLoop.evaluateFailedCallLoop(
            callName: "todo", arguments: ["action": "uncomplete"],
            previousSignature: nil, previousStreak: 0
        )
        // A different call (or different args) restarts the streak.
        let second = AgentLoop.evaluateFailedCallLoop(
            callName: "todo", arguments: ["action": "complete"],
            previousSignature: first.nextSignature, previousStreak: first.nextStreak
        )

        XCTAssertEqual(second.nextStreak, 1)
        XCTAssertFalse(second.shouldSteer)
        XCTAssertFalse(second.shouldBreak)
    }

    func testApprovalCommandKeyForBashUsesSortedJSON() {
        let key = AgentLoop.approvalCommandKey(
            toolName: "bash",
            arguments: [
                "command": "echo hello",
                "initial_wait": 30,
                "mode": "sync"
            ]
        )

        XCTAssertEqual(key, #"bash {"command":"echo hello","initial_wait":30,"mode":"sync"}"#)
    }

    func testApprovalCommandKeyFallsBackToDescriptionForNonJSONArguments() {
        let key = AgentLoop.approvalCommandKey(
            toolName: "bash",
            arguments: [
                "command": "echo hello",
                "invalid": URL(fileURLWithPath: "/tmp/file")
            ]
        )

        XCTAssertTrue(key.hasPrefix("bash ["))
        XCTAssertTrue(key.contains("command"))
        XCTAssertTrue(key.contains("invalid"))
    }

    func testApprovalCommandDisplayForBashIncludesCommandAndOtherArguments() {
        let display = AgentLoop.approvalCommandDisplay(
            toolName: "bash",
            arguments: [
                "command": "ls -la",
                "mode": "sync",
                "initial_wait": 10
            ]
        )

        XCTAssertEqual(display, #"bash ls -la {"initial_wait":10,"mode":"sync"}"#)
    }

    func testSanitizeAuditFieldEscapesBackslashesAndControlCharacters() {
        let sanitized = AgentLoop.sanitizeAuditField("line1\\nline2\nrow\rcol\tend")
        XCTAssertEqual(sanitized, #"line1\\\\nline2\nrow\rcol\tend"#)
    }

    func testFollowUpQueueHelpersPreserveFIFOOrderForListingAndExecution() {
        var queue: [String] = []
        AgentLoop.enqueueFollowUp("first", onto: &queue)
        AgentLoop.enqueueFollowUp("second", onto: &queue)
        AgentLoop.enqueueFollowUp("third", onto: &queue)

        XCTAssertEqual(queue, ["first", "second", "third"])
        XCTAssertEqual(AgentLoop.dequeueFollowUp(from: &queue), "first")
        XCTAssertEqual(AgentLoop.dequeueFollowUp(from: &queue), "second")
        XCTAssertEqual(AgentLoop.dequeueFollowUp(from: &queue), "third")
        XCTAssertNil(AgentLoop.dequeueFollowUp(from: &queue))
    }

    func testFollowUpQueueHelpersAppendNewItemsAtEndDuringDraining() {
        var queue: [String] = []
        AgentLoop.enqueueFollowUp("a", onto: &queue)
        AgentLoop.enqueueFollowUp("b", onto: &queue)

        var processed: [String] = []
        while let message = AgentLoop.dequeueFollowUp(from: &queue) {
            processed.append(message)
            if message == "a" {
                AgentLoop.enqueueFollowUp("c", onto: &queue)
            }
        }

        XCTAssertEqual(processed, ["a", "b", "c"])
    }

    // MARK: - Shape C: tool name emitted as the wrapping key inside `arguments`

    func testWrappedNameToolCallRecoversNameAsKey() {
        // {"arguments":{"read_file":{"path":…,"start_line":100,"end_line":110}}}
        let args: [String: Any] = [
            "read_file": ["path": "IntegrationTests.cs", "start_line": 100, "end_line": 110]
        ]
        let recovered = AgentLoop.wrappedNameToolCall(
            from: args,
            knownToolNames: ["read_file", "list_dir", "grep"]
        )
        XCTAssertEqual(recovered?.name, "read_file")
        XCTAssertEqual(recovered?.arguments["path"] as? String, "IntegrationTests.cs")
        XCTAssertEqual(recovered?.arguments["start_line"] as? Int, 100)
    }

    func testWrappedNameToolCallIgnoresUnknownKey() {
        // A single key that is NOT a tool name is a real argument, not Shape C.
        let args: [String: Any] = ["path": "a.swift"]
        XCTAssertNil(AgentLoop.wrappedNameToolCall(from: args, knownToolNames: ["read_file"]))
    }

    func testWrappedNameToolCallIgnoresNonObjectValueAndMultipleKeys() {
        // Tool-name key but a non-object value — ambiguous, leave it.
        let scalarValue: [String: Any] = ["read_file": "a.swift"]
        XCTAssertNil(AgentLoop.wrappedNameToolCall(from: scalarValue, knownToolNames: ["read_file"]))
        // More than one key is a normal flat argument set, not Shape C.
        let multiKey: [String: Any] = ["read_file": ["path": "a"], "extra": 1]
        XCTAssertNil(AgentLoop.wrappedNameToolCall(from: multiKey, knownToolNames: ["read_file"]))
    }
}
