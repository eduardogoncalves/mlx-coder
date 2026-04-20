import XCTest
@testable import MLXCoder

final class StreamingToolCallWriterTests: XCTestCase {

    private final class StatusCollector: @unchecked Sendable {
        var messages: [String] = []
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

    func testIgnoresToolCallsInsideThinkUntilThinkIsClosed() {
        let writer = StreamingToolCallWriter(
            toolCallOpen: "<tool_call>",
            toolCallClose: "</tool_call>"
        )

        let chunk1 = "<think>still reasoning <tool_call>{\"name\":\"list_dir\",\"arguments\":{\"path\":\".\"}}</tool_call>"
        let result1 = writer.process(chunk1)
        XCTAssertTrue(result1.displayText.contains("<tool_call>"))
        XCTAssertTrue(writer.drainCompletedCalls().isEmpty)

        let chunk2 = "</think><tool_call>{\"name\":\"read_file\",\"arguments\":{\"path\":\"README.md\"}}</tool_call>"
        _ = writer.process(chunk2)
        let calls = writer.drainCompletedCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].toolName, "read_file")
        XCTAssertEqual(calls[0].path, "README.md")

        writer.cleanupAllTmpFiles()
    }
}
