import XCTest
@testable import MLXCoder

final class ToolResultCondensationTests: XCTestCase {

    func testLargeWebFetchResultTriggersCondensation() {
        let config = ToolResultCondensationConfig(
            largeResultTokenThreshold: 1000,
            charsPerTokenEstimate: 4
        )

        let largeHTML = String(repeating: "<div>Some long html body content</div>", count: 500)
        let result = ToolResult(content: largeHTML)

        XCTAssertTrue(
            ToolResultCondensationPolicy.shouldCondense(
                toolName: "web_fetch",
                result: result,
                config: config
            )
        )
    }

    func testCompactStructuredPayloadDoesNotCondense() {
        let config = ToolResultCondensationConfig(
            largeResultTokenThreshold: 20,
            charsPerTokenEstimate: 4
        )

        let compactJSON = "{\"status\":\"ok\",\"code\":200,\"message\":\"done\"}"
        let result = ToolResult(content: compactJSON)

        XCTAssertFalse(
            ToolResultCondensationPolicy.shouldCondense(
                toolName: "web_fetch",
                result: result,
                config: config
            )
        )
    }

    func testSmallPayloadDoesNotCondense() {
        let config = ToolResultCondensationConfig()
        let result = ToolResult(content: "short output")

        XCTAssertFalse(
            ToolResultCondensationPolicy.shouldCondense(
                toolName: "read_file",
                result: result,
                config: config
            )
        )
    }

    func testAlreadyExtractedWebFetchPayloadDoesNotCondense() {
        let config = ToolResultCondensationConfig(
            largeResultTokenThreshold: 20,
            charsPerTokenEstimate: 4
        )

        let extracted = "Extracted information for query 'rain forecast':\n\n" + String(repeating: "chance=80% precipitation window=14:00-18:00. ", count: 80)
        let result = ToolResult(content: extracted)

        XCTAssertFalse(
            ToolResultCondensationPolicy.shouldCondense(
                toolName: "web_fetch",
                result: result,
                config: config
            )
        )
    }

    func testTodoNeverCondensesEvenIfEligible() {
        let config = ToolResultCondensationConfig(
            largeResultTokenThreshold: 10,
            charsPerTokenEstimate: 4,
            eligibleTools: ["todo"]
        )

        let largeTodoOutput = String(repeating: "1. [ ] very long task line with details\n", count: 100)
        let result = ToolResult(content: largeTodoOutput)

        XCTAssertFalse(
            ToolResultCondensationPolicy.shouldCondense(
                toolName: "todo",
                result: result,
                config: config
            )
        )
    }

    func testListDirNeverCondensesEvenIfEligible() {
        let config = ToolResultCondensationConfig(
            largeResultTokenThreshold: 10,
            charsPerTokenEstimate: 4,
            eligibleTools: ["list_dir", "dir_list"]
        )

        let largeDirOutput = String(repeating: "📄 file.swift (12.3 KB)\n", count: 200)
        let result = ToolResult(content: largeDirOutput)

        XCTAssertFalse(
            ToolResultCondensationPolicy.shouldCondense(
                toolName: "list_dir",
                result: result,
                config: config
            )
        )

        XCTAssertFalse(
            ToolResultCondensationPolicy.shouldCondense(
                toolName: "dir_list",
                result: result,
                config: config
            )
        )
    }

    func testSanitizeSummaryStripsSpecialTokensAndBoundsLength() {
        let raw = "<|im_start|>assistant\nSummary body<|im_end|><|im_end|>"
        let cleaned = ToolResultCondensationPolicy.sanitizeSummary(raw, maxChars: 24)

        XCTAssertFalse(cleaned.contains(ToolCallPattern.imStart))
        XCTAssertFalse(cleaned.contains(ToolCallPattern.imEnd))
        XCTAssertLessThanOrEqual(cleaned.count, 24)
    }

    func testEstimatedTokenReductionIsSignificant() {
        let config = ToolResultCondensationConfig(charsPerTokenEstimate: 4)
        let raw = String(repeating: "A", count: 12_000)
        let condensed = ToolResultCondensationPolicy.formatCondensedToolMessage(
            toolName: "web_fetch",
            summary: "Title: Example\nKey facts: alpha, beta, gamma."
        )

        let before = ToolResultCondensationPolicy.estimatedTokenCount(
            for: raw,
            charsPerToken: config.charsPerTokenEstimate
        )
        let after = ToolResultCondensationPolicy.estimatedTokenCount(
            for: condensed,
            charsPerToken: config.charsPerTokenEstimate
        )

        XCTAssertGreaterThan(before, after)
        XCTAssertGreaterThan(before - after, 2000)
    }

    func testSimulatedWebFetchToolCallLogsBeforeAfterCounts() {
        let config = ToolResultCondensationConfig(
            largeResultTokenThreshold: 1000,
            charsPerTokenEstimate: 4,
            summaryTargetTokens: 300,
            maxSummaryChars: 1200
        )

        let largeHTML = "<html><body>" + String(repeating: "<p>price=123.45 version=v2.0.1 release-note alpha beta gamma</p>", count: 2500) + "</body></html>"
        let simulatedSummary = String(repeating: "price=123.45 version=v2.0.1 release-note alpha beta gamma ", count: 18)
        let boundedSummary = ToolResultCondensationPolicy.sanitizeSummary(simulatedSummary, maxChars: config.maxSummaryChars)
        let condensedMessage = ToolResultCondensationPolicy.formatCondensedToolMessage(toolName: "web_fetch", summary: boundedSummary)

        let before = ToolResultCondensationPolicy.estimatedTokenCount(
            for: largeHTML,
            charsPerToken: config.charsPerTokenEstimate
        )
        let after = ToolResultCondensationPolicy.estimatedTokenCount(
            for: condensedMessage,
            charsPerToken: config.charsPerTokenEstimate
        )

        print("[debug] Tool result condensed for web_fetch: before≈\(before) tokens, after≈\(after), saved≈\(max(0, before - after))")

        XCTAssertGreaterThan(before, 1000)
        XCTAssertGreaterThanOrEqual(after, 200)
        XCTAssertLessThanOrEqual(after, 400)
    }
}
