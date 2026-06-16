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
    
    func testMalformedJSONHandling() {
        // Recover common truncation: missing trailing closing brace(s).
        let missingBraceText = """
        <tool_call>
        {"name": "test_tool", "arguments": {"key": "value"}
        </tool_call>
        """
        let recoveredCalls = ToolCallParser.parse(missingBraceText)
        XCTAssertEqual(recoveredCalls.count, 1)
        XCTAssertEqual(recoveredCalls[0].name, "test_tool")

        // Invalid canonical JSON with non-quoted token should still fail.
        let invalidTokenText = """
        <tool_call>
        {"name": "test_tool", "arguments": {"key": value}}
        </tool_call>
        """
        XCTAssertTrue(ToolCallParser.parse(invalidTokenText).isEmpty)

        // Literal newlines inside JSON strings are sanitized and parsed successfully.
        // Models commonly emit multi-line content this way (e.g. log_knowledge).
        let literalNewlineText = """
        <tool_call>
        {"name": "write_file", "arguments": {"path": "test.txt", "content": "line1
        line2"}}
        </tool_call>
        """
        let calls = ToolCallParser.parse(literalNewlineText)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "write_file")
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

    func testStartsThinkingSkipsImplicitThinkBlock() {
        // Models whose chat template pre-fills "<think>\n" generate responses
        // that begin inside an implicit think block — no opening tag is present
        // in the captured output. Tool calls emitted before the model closes
        // </think> must be ignored, otherwise junk emitted while reasoning is
        // executed as real tool calls.
        let text = """
        I should check the file.
        <tool_call>{"name":"read_file","arguments":{"path":"junk.txt"}}</tool_call>
        </think>
        <tool_call>{"name":"read_file","arguments":{"path":"README.md"}}</tool_call>
        """

        let calls = ToolCallParser.parse(text, startsThinking: true)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.arguments["path"] as? String, "README.md")

        XCTAssertTrue(ToolCallParser.containsToolCall(text, startsThinking: true))
    }

    func testStartsThinkingWithoutClosingTagSuppressesAllToolCalls() {
        // If the model never emits </think>, the entire generation is still
        // inside the implicit think block and no tool call should fire.
        let text = """
        I'll just call this tool to get information.
        <tool_call>{"name":"web_fetch","arguments":{"url":"https://example.com"}}</tool_call>
        more reasoning, never closed
        """

        XCTAssertTrue(ToolCallParser.parse(text, startsThinking: true).isEmpty)
        XCTAssertFalse(ToolCallParser.containsToolCall(text, startsThinking: true))
    }

    func testStartsThinkingDoesNotTouchToolCallAfterExplicitClose() {
        // Sanity: the legacy explicit-tag path still works when startsThinking
        // is true (the parser just enters search mode after </think>).
        let text = """
        thinking here
        </think>
        <tool_call>{"name":"list_dir","arguments":{"path":"."}}</tool_call>
        """

        let calls = ToolCallParser.parse(text, startsThinking: true)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "list_dir")
    }

    // MARK: - LFM2 dialect

    func testLFM2DialectParsesSingleCall() {
        let text = "<|tool_call_start|>[list_dir(path='/Users/eduardogoncalves/Developer/Personal/AI/idad-corrected-html')]<|tool_call_end|>"
        let calls = ToolCallParser.parse(text, dialect: .lfm2)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "list_dir")
        XCTAssertEqual(
            calls[0].arguments["path"] as? String,
            "/Users/eduardogoncalves/Developer/Personal/AI/idad-corrected-html"
        )
    }

    func testLFM2DialectParsesMultipleCallsInOneBracket() {
        let text = "<|tool_call_start|>[read_file(path='a.txt'), read_file(path='b.txt')]<|tool_call_end|>"
        let calls = ToolCallParser.parse(text, dialect: .lfm2)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].arguments["path"] as? String, "a.txt")
        XCTAssertEqual(calls[1].arguments["path"] as? String, "b.txt")
    }

    func testLFM2DialectParsesMixedLiteralTypes() {
        let text = "<|tool_call_start|>[some_tool(s='hi', n=42, ratio=1.5, flag=True, none=None, items=[1, 2, 3], obj={\"k\":\"v\"})]<|tool_call_end|>"
        let calls = ToolCallParser.parse(text, dialect: .lfm2)
        XCTAssertEqual(calls.count, 1)
        let args = calls[0].arguments
        XCTAssertEqual(args["s"] as? String, "hi")
        XCTAssertEqual(args["n"] as? Int, 42)
        XCTAssertEqual(args["ratio"] as? Double, 1.5)
        XCTAssertEqual(args["flag"] as? Bool, true)
        XCTAssertTrue(args["none"] is NSNull)
        XCTAssertEqual(args["items"] as? [Int], [1, 2, 3])
        XCTAssertEqual((args["obj"] as? [String: String])?["k"], "v")
    }

    func testLFM2DialectContainsToolCall() {
        XCTAssertTrue(ToolCallParser.containsToolCall(
            "<|tool_call_start|>[foo()]<|tool_call_end|>",
            dialect: .lfm2
        ))
        XCTAssertFalse(ToolCallParser.containsToolCall(
            "<tool_call>{}</tool_call>",
            dialect: .lfm2
        ))
    }

    func testLFM2DialectIgnoresQwenTagsAndViceVersa() {
        // A Qwen-style call should not be detected when the LFM2 dialect is active.
        let qwenText = "<tool_call>{\"name\":\"x\",\"arguments\":{}}</tool_call>"
        XCTAssertTrue(ToolCallParser.parse(qwenText, dialect: .lfm2).isEmpty)

        // And vice versa.
        let lfm2Text = "<|tool_call_start|>[x()]<|tool_call_end|>"
        XCTAssertTrue(ToolCallParser.parse(lfm2Text, dialect: .qwen).isEmpty)
    }

    func testLFM2DialectFallsBackToQwenStyleJSONBody() {
        // Some LFM2 checkpoints drift toward Qwen-shaped JSON inside the
        // LFM2 markers. The parser should still recognise it as a tool call.
        let text = "<|tool_call_start|>{\"name\":\"list_dir\",\"arguments\":{\"path\":\".\"}}<|tool_call_end|>"
        let calls = ToolCallParser.parse(text, dialect: .lfm2)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "list_dir")
        XCTAssertEqual(calls[0].arguments["path"] as? String, ".")
    }

    func testToolCallDialectDetectsLFM2FromModelPath() {
        XCTAssertEqual(
            ToolCallDialect.detect(modelPath: "/Users/me/models/LiquidAI/LFM2.5-8B-A1B-MLX-8bit"),
            .lfm2
        )
        XCTAssertEqual(
            ToolCallDialect.detect(modelPath: "mlx-community/Qwen3-8B-mlx-bf16"),
            .qwen
        )
    }
}

