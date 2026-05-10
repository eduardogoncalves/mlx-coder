import XCTest
@testable import MLXCoder

final class StreamParserTests: XCTestCase {

    func testEmitsOrderedThinkingLifecycleAcrossSplitTags() {
        var parser = StreamParser(openTag: "<think>", closeTag: "</think>")
        var events: [AgentEvent] = []

        events += parser.feed("Hello <thi")
        events += parser.feed("nk>a")
        events += parser.feed("b</th")
        events += parser.feed("ink> world")

        let startedIndex = events.firstIndex(where: { if case .thinkingActivity(.started) = $0 { return true }; return false })
        let endedIndex = events.firstIndex(where: { if case .thinkingActivity(.ended) = $0 { return true }; return false })
        let firstAssistantAfterThinkIndex = events.firstIndex(where: {
            if case .assistantTextChunk = $0 { return true }
            return false
        })
        XCTAssertEqual(firstAssistantAfterThinkIndex, 0)
        XCTAssertNotNil(startedIndex)
        XCTAssertNotNil(endedIndex)
        if let startedIndex, let endedIndex {
            XCTAssertLessThan(startedIndex, endedIndex)
            let thinkingChunks = events[(startedIndex + 1)..<endedIndex].compactMap {
                if case .thinkingChunk(let chunk) = $0 { return chunk }
                return nil
            }
            XCTAssertEqual(thinkingChunks.joined(), "ab")
            if let firstAssistantAfterEnd = events.indices.first(where: { idx in
                guard idx > endedIndex else { return false }
                if case .assistantTextChunk = events[idx] { return true }
                return false
            }) {
                XCTAssertGreaterThan(firstAssistantAfterEnd, endedIndex)
            } else {
                XCTFail("Expected assistantTextChunk after thinking end")
            }
        }
    }

    func testThinkingEndPrecedesFirstAssistantChunk() {
        var parser = StreamParser(openTag: "<think>", closeTag: "</think>", startsThinking: true)
        var events: [AgentEvent] = []

        events += parser.feed("Reasoning")
        events += parser.feed("</think>Done")

        XCTAssertEqual(events.count, 3)
        assertThinkingChunk(events[0], equals: "Reasoning")
        assertThinkingLifecycle(events[1], equals: .ended)
        assertAssistantChunk(events[2], equals: "Done")
    }

    func testFlushCanCloseUnterminatedThinkingBlock() {
        var parser = StreamParser(openTag: "<think>", closeTag: "</think>", startsThinking: true)
        let duringFeed = parser.feed("partial")
        XCTAssertEqual(duringFeed.count, 1)
        assertThinkingChunk(duringFeed[0], equals: "partial")

        let flushed = parser.flush(closeUnterminatedThinkingBlock: true)
        XCTAssertEqual(flushed.count, 1)
        assertThinkingLifecycle(flushed[0], equals: .ended)
        XCTAssertFalse(parser.isThinking)
    }

    private func assertAssistantChunk(_ event: AgentEvent, equals expected: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .assistantTextChunk(let chunk) = event else {
            return XCTFail("Expected assistantTextChunk", file: file, line: line)
        }
        XCTAssertEqual(chunk, expected, file: file, line: line)
    }

    private func assertThinkingChunk(_ event: AgentEvent, equals expected: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .thinkingChunk(let chunk) = event else {
            return XCTFail("Expected thinkingChunk", file: file, line: line)
        }
        XCTAssertEqual(chunk, expected, file: file, line: line)
    }

    private func assertThinkingLifecycle(_ event: AgentEvent, equals expected: ActivityLifecycle, file: StaticString = #filePath, line: UInt = #line) {
        guard case .thinkingActivity(let lifecycle) = event else {
            return XCTFail("Expected thinkingActivity", file: file, line: line)
        }
        XCTAssertEqual(lifecycle, expected, file: file, line: line)
    }
}
