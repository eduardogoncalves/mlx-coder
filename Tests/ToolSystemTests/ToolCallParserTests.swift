// Tests/ToolSystemTests/ToolCallParserTests.swift

import XCTest
@testable import MLXCoder

final class ToolCallParserTests: XCTestCase {

    func testParseSimpleToolCall() {
        let text = """
        <tool_call>
        {"name": "read_file", "arguments": {"path": "/tmp/test.txt"}}
        </tool_call>
        """
        let calls = ToolCallParser.parse(text)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "read_file")
    }

    func testParseMultipleToolCalls() {
        let text = """
        <tool_call>
        {"name": "read_file", "arguments": {"path": "/tmp/a.txt"}}
        </tool_call>
        Some text in between.
        <tool_call>
        {"name": "write_file", "arguments": {"path": "/tmp/b.txt", "content": "hello"}}
        </tool_call>
        """
        let calls = ToolCallParser.parse(text)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].name, "read_file")
        XCTAssertEqual(calls[1].name, "write_file")
    }

    func testContainsToolCall() {
        XCTAssertTrue(ToolCallParser.containsToolCall("<tool_call>{}</tool_call>"))
        XCTAssertFalse(ToolCallParser.containsToolCall("just normal text"))
    }

    func testStripThinking() {
        let text = "<think>I need to think about this...</think>Here is my answer."
        let stripped = ToolCallParser.stripThinking(text)
        XCTAssertEqual(stripped, "Here is my answer.")
    }

    func testExtractThinking() {
        let text = "<think>Internal reasoning here</think>Response"
        let thinking = ToolCallParser.extractThinking(text)
        XCTAssertEqual(thinking, "Internal reasoning here")
    }
    
    func testRejectsMalformedJSONWithoutFallbackRepair() {
        let missingBraceText = """
        <tool_call>
        {"name": "test_tool", "arguments": {"key": "value"}
        </tool_call>
        """
        XCTAssertTrue(ToolCallParser.parse(missingBraceText).isEmpty)

        let malformedStringText = """
        <tool_call>
        {"name": "write_file", "arguments": {"path": "test.txt", "content": "line1
        line2"}}
        </tool_call>
        """
        XCTAssertTrue(ToolCallParser.parse(malformedStringText).isEmpty)
    }

    func testParsesTruncatedToolBlockWhenJSONIsValid() {
        let missingClosingTag = """
        <tool_call>
        {"name": "test_tool", "arguments": {"key": "value"}}
        """
        let calls = ToolCallParser.parse(missingClosingTag)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "test_tool")
    }

    func testParsesMalformedPositionalToolCallWrapper() {
        let text = """
        <tool_call>
        {"list_dir", "path": "."}
        </tool_call>
        """

        let calls = ToolCallParser.parse(text)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "list_dir")
        XCTAssertEqual(calls[0].arguments["path"] as? String, ".")
    }

    func testParsesFunctionStyleToolCallWrapper() {
        let text = """
        <tool_call>
        tool_call(tool: list_dir, path: .)
        </tool_call>
        """

        let calls = ToolCallParser.parse(text)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "list_dir")
        XCTAssertEqual(calls[0].arguments["path"] as? String, ".")
    }

    func testParsesToolCallWithTrailingQuoteNoise() {
        let text = """
        <tool_call>
        {"name": "write_file", "arguments": {"path": "index.html", "file_content": "<html>ok</html>"}}"
        </tool_call>
        """

        let calls = ToolCallParser.parse(text)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "write_file")
        XCTAssertEqual(calls[0].arguments["path"] as? String, "index.html")
    }

    func testIgnoresToolCallsInsideThinkBlock() {
        let text = """
        <think>
        <tool_call>
        {"name":"list_dir","arguments":{"path":"."}}
        </tool_call>
        </think>
        <tool_call>
        {"name":"read_file","arguments":{"path":"README.md"}}
        </tool_call>
        """

        let calls = ToolCallParser.parse(text)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "read_file")
    }

    func testUnclosedThinkSuppressesSubsequentToolTags() {
        let text = """
        prefix
        <think>
        still thinking
        <tool_call>{"name":"read_file","arguments":{"path":"README.md"}}</tool_call>
        """

        XCTAssertTrue(ToolCallParser.parse(text).isEmpty)
        XCTAssertFalse(ToolCallParser.containsToolCall(text))
    }
}

