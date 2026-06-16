import XCTest
@testable import MLXCoder

final class StreamingToolCallWriterTests: XCTestCase {

    private final class StatusCollector: @unchecked Sendable {
        var messages: [String] = []
    }

    func testLFM2DialectHidesToolCallBodyWithoutReportingFailure() throws {
        let writer = StreamingToolCallWriter(
            toolCallOpen: "<|tool_call_start|>",
            toolCallClose: "<|tool_call_end|>",
            parsesJSONBody: false
        )

        let payload = "prefix <|tool_call_start|>[list_dir(path='.')]<|tool_call_end|> suffix"
        let result = writer.process(payload)

        // The call body must not bleed into the live display.
        XCTAssertFalse(result.displayText.contains("list_dir"))
        XCTAssertTrue(result.displayText.contains("prefix"))
        XCTAssertTrue(result.displayText.contains("suffix"))

        // LFM2 dialect is parsed from the raw response text — the streaming
        // writer must not flag it as a JSON parse failure.
        XCTAssertTrue(writer.drainCompletedCalls().isEmpty)
        XCTAssertTrue(writer.drainFailedCalls().isEmpty)

        writer.cleanupAllTmpFiles()
    }

    func testStreamsWriteFileWhenUsingFileContentAlias() throws {
        let writer = StreamingToolCallWriter(
            toolCallOpen: "<tool_call>",
            toolCallClose: "</tool_call>"
        )

        let payload = """
        <tool_call>
        {"name":"write_file","arguments":{"path":"index.html","file_content":"<!doctype html>\\n<html><body>ok</body></html>"}}
        </tool_call>
        """

        _ = writer.process(payload)
        let calls = writer.drainCompletedCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].toolName, "write_file")
        XCTAssertEqual(calls[0].path, "index.html")

        let streamedContent = try String(contentsOf: calls[0].contentFile, encoding: .utf8)
        XCTAssertTrue(streamedContent.contains("<html><body>ok</body></html>"))

        writer.cleanupAllTmpFiles()
    }

    func testEmitsStatusUpdatesForToolCallStreaming() throws {
        let collector = StatusCollector()
        let writer = StreamingToolCallWriter(
            toolCallOpen: "<tool_call>",
            toolCallClose: "</tool_call>",
            onStatusChange: { message in
                collector.messages.append(message)
            }
        )

        let payload = """
        <tool_call>
        {"name":"write_file","arguments":{"path":"index.html","file_content":"<html>ok</html>"}}
        </tool_call>
        done
        """

        let result = writer.process(payload)
        XCTAssertEqual(result.displayText.trimmingCharacters(in: .whitespacesAndNewlines), "done")
        XCTAssertEqual(collector.messages.first, "Generating tool call...")
        XCTAssertGreaterThanOrEqual(collector.messages.count, 1)
        if collector.messages.count > 1 {
            XCTAssertTrue(collector.messages[1].hasPrefix("Writing to tmp file "))
            XCTAssertTrue(collector.messages[1].contains("/"))
        }

        writer.cleanupAllTmpFiles()
    }

    func testRecoversOldTextForMalformedStreamedEditFileJSON() throws {
        let writer = StreamingToolCallWriter(
            toolCallOpen: "<tool_call>",
            toolCallClose: "</tool_call>"
        )

        let chunk1 = """
        <tool_call>
        {"name":"edit_file","arguments":{"path":"hello-template.html","old_text":"Hello, I'm Eduardo","new_text":
        """

        _ = writer.process(chunk1)
        _ = writer.process("\"Hello, I'm Eduardo Goncalves\"</tool_call>")
        let calls = writer.drainCompletedCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].toolName, "edit_file")
        XCTAssertEqual(calls[0].path, "hello-template.html")
        XCTAssertEqual(calls[0].otherArgs["old_text"] as? String, "Hello, I'm Eduardo")

        let streamedContent = try String(contentsOf: calls[0].contentFile, encoding: .utf8)
        XCTAssertEqual(streamedContent, "Hello, I'm Eduardo Goncalves")

        writer.cleanupAllTmpFiles()
    }

    func testRecoversOldTextAliasForMalformedStreamedEditFileJSON() throws {
        let writer = StreamingToolCallWriter(
            toolCallOpen: "<tool_call>",
            toolCallClose: "</tool_call>"
        )

        let chunk1 = """
        <tool_call>
        {"name":"edit_file","arguments":{"path":"hello-template.html","oldText":"Hello, I'm Eduardo","new_text":
        """

        _ = writer.process(chunk1)
        _ = writer.process("\"Hello, I'm Eduardo Goncalves\"</tool_call>")
        let calls = writer.drainCompletedCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].toolName, "edit_file")
        XCTAssertEqual(calls[0].path, "hello-template.html")
        XCTAssertEqual(calls[0].otherArgs["old_text"] as? String, "Hello, I'm Eduardo")

        writer.cleanupAllTmpFiles()
    }

    func testDrainTruncatedStreamRecoversPartialWriteFile() throws {
        // Simulates the model emitting an opening tool call and partial content,
        // then generation ending before the closing tag fires. The writer
        // should expose the in-progress file so the agent loop can recover the
        // bytes already streamed to disk.
        let writer = StreamingToolCallWriter(
            toolCallOpen: "<tool_call>",
            toolCallClose: "</tool_call>"
        )

        // Real generation hands tokens to `process` incrementally. The state
        // machine arms `inContentString` only when the opening quote of the
        // content value lands inside the streaming case, so split the header
        // before the colon-quote and feed the opening `"` plus body separately
        // — matching how tokens actually arrive during inference.
        let headerChunk = "<tool_call>{\"name\":\"write_file\",\"arguments\":{\"path\":\"big.html\",\"content\":"
        let openQuoteAndBody = "\"<!doctype html>\\n<html><body>partial bytes"

        _ = writer.process(headerChunk)
        _ = writer.process(openQuoteAndBody)

        XCTAssertTrue(writer.hasActiveStream, "Stream should still be active when no closing tag arrives")
        XCTAssertTrue(writer.drainCompletedCalls().isEmpty)

        let truncated = writer.drainTruncatedStream()
        XCTAssertNotNil(truncated)
        XCTAssertEqual(truncated?.toolName, "write_file")
        XCTAssertEqual(truncated?.path, "big.html")
        XCTAssertGreaterThan(truncated?.bytesWritten ?? 0, 0)

        let savedContent = try String(contentsOf: truncated!.contentFile, encoding: .utf8)
        XCTAssertTrue(savedContent.contains("<!doctype html>"))
        XCTAssertTrue(savedContent.contains("partial bytes"))
        XCTAssertFalse(writer.hasActiveStream, "Draining must reset state to idle")
        XCTAssertNil(writer.drainTruncatedStream(), "Draining twice should yield nil")

        writer.cleanupAllTmpFiles()
    }

    func testDrainTruncatedStreamIsNilWhenStreamCompletedCleanly() throws {
        let writer = StreamingToolCallWriter(
            toolCallOpen: "<tool_call>",
            toolCallClose: "</tool_call>"
        )

        let payload = "<tool_call>{\"name\":\"write_file\",\"arguments\":{\"path\":\"ok.txt\",\"content\":\"all good\"}}</tool_call>"
        _ = writer.process(payload)
        XCTAssertEqual(writer.drainCompletedCalls().count, 1)
        XCTAssertNil(writer.drainTruncatedStream())

        writer.cleanupAllTmpFiles()
    }

    func testProcessesToolCallsInPostThinkContent() {
        // Think-block filtering is the responsibility of StreamParser
        // (AgentLoop+Generation.swift). The writer is only called with
        // post-think assistant text, so it never needs to skip think tokens.
        // This test verifies the writer correctly handles a tool call that
        // arrives as post-think content (the common runtime path).
        let writer = StreamingToolCallWriter(
            toolCallOpen: "<tool_call>",
            toolCallClose: "</tool_call>"
        )

        let chunk = "<tool_call>{\"name\":\"write_file\",\"arguments\":{\"path\":\"out.txt\",\"content\":\"hello\"}}</tool_call>"
        _ = writer.process(chunk)
        let calls = writer.drainCompletedCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].toolName, "write_file")
        XCTAssertEqual(calls[0].path, "out.txt")

        writer.cleanupAllTmpFiles()
    }
}
