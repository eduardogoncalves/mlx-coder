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

    func testCompactStructuredPayloadFromWebFetchAlwaysCondenses() {
        let config = ToolResultCondensationConfig(
            largeResultTokenThreshold: 20,
            charsPerTokenEstimate: 4
        )

        // web_fetch is always condensed regardless of payload size or structure,
        // because raw web content must never reach the main LLM context unfiltered.
        let compactJSON = "{\"status\":\"ok\",\"code\":200,\"message\":\"done\"}"
        let result = ToolResult(content: compactJSON)

        XCTAssertTrue(
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

    func testInstructionTemplateIsToolSpecificForBash() {
        let instruction = ToolResultCondensationPolicy.instructionTemplate(for: "bash")
        XCTAssertTrue(instruction.contains("final status"))
        XCTAssertTrue(instruction.contains("progress spam"))
    }

    func testInstructionTemplateIsToolSpecificForReadFile() {
        let instruction = ToolResultCondensationPolicy.instructionTemplate(for: "read_file")
        XCTAssertTrue(instruction.contains("structural snapshot"))
        XCTAssertTrue(instruction.contains("line ranges"))
    }

    // MARK: - Budget-aware trimming (`shouldTrimForBudget` and friends)

    func testShouldTrimForBudgetBelowBudgetDoesNotTrim() {
        // 100 current + 50 estimated = 150, well under a 1000-token window.
        let budget = ToolResultCondensationPolicy.BudgetContext(currentTokens: 100, windowTokens: 1000)
        XCTAssertFalse(
            ToolResultCondensationPolicy.shouldTrimForBudget(
                lineCount: 100,
                headLines: 30,
                estimatedResultTokens: 50,
                budget: budget
            )
        )
    }

    func testShouldTrimForBudgetAtExactBudgetDoesNotTrim() {
        // Exactly at the window: reference semantics are a strict ">" comparison
        // (RESERVE = 0), so landing exactly on the line should NOT trim.
        let budget = ToolResultCondensationPolicy.BudgetContext(currentTokens: 900, windowTokens: 1000)
        XCTAssertFalse(
            ToolResultCondensationPolicy.shouldTrimForBudget(
                lineCount: 100,
                headLines: 30,
                estimatedResultTokens: 100,
                budget: budget
            )
        )
    }

    func testShouldTrimForBudgetAboveBudgetTrims() {
        let budget = ToolResultCondensationPolicy.BudgetContext(currentTokens: 950, windowTokens: 1000)
        XCTAssertTrue(
            ToolResultCondensationPolicy.shouldTrimForBudget(
                lineCount: 100,
                headLines: 30,
                estimatedResultTokens: 100,
                budget: budget
            )
        )
    }

    func testShouldTrimForBudgetUnknownCurrentUsageFallsBackToFraction() {
        // No tokenizer/model loaded: currentTokens is nil. A result estimated at
        // 600 tokens against a 1000-token window exceeds the 0.5 fallback
        // fraction (500), so it should trim even though we have no idea what
        // the rest of history looks like.
        let overFraction = ToolResultCondensationPolicy.BudgetContext(currentTokens: nil, windowTokens: 1000)
        XCTAssertTrue(
            ToolResultCondensationPolicy.shouldTrimForBudget(
                lineCount: 100,
                headLines: 30,
                estimatedResultTokens: 600,
                budget: overFraction
            )
        )

        // 400 tokens is under the 500-token fallback fraction line — no trim.
        XCTAssertFalse(
            ToolResultCondensationPolicy.shouldTrimForBudget(
                lineCount: 100,
                headLines: 30,
                estimatedResultTokens: 400,
                budget: overFraction
            )
        )
    }

    func testShouldTrimForBudgetHeadLineNoOpCase() {
        // lineCount <= headLines: a head slice wouldn't shrink anything, so this
        // must never trim regardless of how tight the budget is.
        let starvedBudget = ToolResultCondensationPolicy.BudgetContext(currentTokens: 999, windowTokens: 1000)
        XCTAssertFalse(
            ToolResultCondensationPolicy.shouldTrimForBudget(
                lineCount: 30,
                headLines: 30,
                estimatedResultTokens: 5000,
                budget: starvedBudget
            )
        )
        XCTAssertFalse(
            ToolResultCondensationPolicy.shouldTrimForBudget(
                lineCount: 10,
                headLines: 30,
                estimatedResultTokens: 5000,
                budget: starvedBudget
            )
        )
    }

    func testShouldTrimForBudgetNoWindowNeverTrims() {
        let noWindow = ToolResultCondensationPolicy.BudgetContext(currentTokens: 10, windowTokens: 0)
        XCTAssertFalse(
            ToolResultCondensationPolicy.shouldTrimForBudget(
                lineCount: 1000,
                headLines: 30,
                estimatedResultTokens: 100_000,
                budget: noWindow
            )
        )
    }

    func testIsBudgetAwareEligibleRespectsNeverCondenseAndEligibleToolsExemptions() {
        let config = ToolResultCondensationConfig(eligibleTools: ["todo", "read_file"])

        // todo is in `neverCondenseTools` — must stay exempt even though it's
        // in the caller's eligibleTools set.
        XCTAssertFalse(ToolResultCondensationPolicy.isBudgetAwareEligible(toolName: "todo", config: config))

        // read_skill paginates itself and must stay exempt regardless of config.
        let permissiveConfig = ToolResultCondensationConfig(eligibleTools: ["read_skill", "read_file"])
        XCTAssertFalse(ToolResultCondensationPolicy.isBudgetAwareEligible(toolName: "read_skill", config: permissiveConfig))

        // read_file is eligible, in nonLLMCondensationTools, and not exempt.
        XCTAssertTrue(ToolResultCondensationPolicy.isBudgetAwareEligible(toolName: "read_file", config: config))

        // A hypothetical tool not in `nonLLMCondensationTools` (e.g. one that
        // would route through the LLM-summarization path) must never be
        // budget-aware-eligible — this is the guarantee that budget-aware
        // trimming can never increase LLM-summarization frequency.
        let grepConfig = ToolResultCondensationConfig(eligibleTools: ["grep"])
        XCTAssertFalse(ToolResultCondensationPolicy.isBudgetAwareEligible(toolName: "grep", config: grepConfig))
    }

    func testShouldForceBudgetTrimNeverFiresForErrorResults() {
        let config = ToolResultCondensationConfig()
        let budget = ToolResultCondensationPolicy.BudgetContext(currentTokens: 8000, windowTokens: 8192)
        let bigLines = Array(repeating: "line of content", count: 200).joined(separator: "\n")
        let errorResult = ToolResult(content: bigLines, isError: true)

        XCTAssertFalse(
            ToolResultCondensationPolicy.shouldForceBudgetTrim(
                toolName: "read_file",
                result: errorResult,
                config: config,
                budget: budget
            )
        )
    }

    func testShouldForceBudgetTrimFiresForReadFileWhenBudgetIsTight() {
        let config = ToolResultCondensationConfig()
        // Window 8192, already at 8000 tokens used → only ~192 tokens of
        // headroom left. A 300-line result (well over readGuardHeadLines) whose
        // estimated size exceeds that headroom should force a trim even though
        // it is nowhere near the static 1000-token `largeResultTokenThreshold`.
        let budget = ToolResultCondensationPolicy.BudgetContext(currentTokens: 8000, windowTokens: 8192)
        let manyLines = (1...300).map { "line \($0) of file content" }.joined(separator: "\n")
        let result = ToolResult(content: manyLines)

        XCTAssertTrue(
            ToolResultCondensationPolicy.shouldForceBudgetTrim(
                toolName: "read_file",
                result: result,
                config: config,
                budget: budget
            )
        )
    }

    func testShouldForceBudgetTrimNeverFiresForExemptToolsEvenUnderTightBudget() {
        let config = ToolResultCondensationConfig(eligibleTools: ["todo", "list_dir", "read_skill"])
        let budget = ToolResultCondensationPolicy.BudgetContext(currentTokens: 8190, windowTokens: 8192)
        let manyLines = Array(repeating: "task line", count: 500).joined(separator: "\n")

        for toolName in ["todo", "list_dir", "dir_list", "read_skill"] {
            let result = ToolResult(content: manyLines)
            XCTAssertFalse(
                ToolResultCondensationPolicy.shouldForceBudgetTrim(
                    toolName: toolName,
                    result: result,
                    config: config,
                    budget: budget
                ),
                "\(toolName) must remain exempt from budget-forced trim"
            )
        }
    }

    func testEffectiveFallbackRawCharsNeverExceedsStaticCapWithAmpleBudget() {
        // Plenty of headroom (window 8192, current 100): the effective cap must
        // equal the static cap unchanged — existing small/medium-result
        // behavior must not regress.
        let budget = ToolResultCondensationPolicy.BudgetContext(currentTokens: 100, windowTokens: 8192)
        let effective = ToolResultCondensationPolicy.effectiveFallbackRawChars(
            staticMaxChars: 4000,
            charsPerToken: 4,
            budget: budget
        )
        XCTAssertEqual(effective, 4000)
    }

    func testEffectiveFallbackRawCharsShrinksUnderTightBudget() {
        // Only ~92 tokens of headroom left (window 8192, current 8100) → ~368
        // chars at 4 chars/token, well under the 4000-char static cap.
        let budget = ToolResultCondensationPolicy.BudgetContext(currentTokens: 8100, windowTokens: 8192)
        let effective = ToolResultCondensationPolicy.effectiveFallbackRawChars(
            staticMaxChars: 4000,
            charsPerToken: 4,
            budget: budget
        )
        XCTAssertLessThan(effective, 4000)
        XCTAssertGreaterThanOrEqual(effective, 512) // floor
    }

    func testBudgetTrimmedReadMessageKeepsOnlyHeadLinesAndSteersAwayFromRereading() {
        let manyLines = (1...100).map { "line \($0)" }.joined(separator: "\n")
        let message = ToolResultCondensationPolicy.budgetTrimmedReadMessage(
            toolName: "read_file",
            raw: manyLines,
            headLines: 30,
            estimatedTokens: 2500
        )

        XCTAssertTrue(message.contains("line 1"))
        XCTAssertTrue(message.contains("line 30"))
        XCTAssertFalse(message.contains("line 31"))
        XCTAssertTrue(message.lowercased().contains("do not re-read this file in full"))
        XCTAssertTrue(message.contains("grep"))
    }

    func testBudgetTrimmedReadMessageIsNoOpWhenAlreadyAtOrBelowHeadLines() {
        let shortContent = (1...10).map { "line \($0)" }.joined(separator: "\n")
        let message = ToolResultCondensationPolicy.budgetTrimmedReadMessage(
            toolName: "read_file",
            raw: shortContent,
            headLines: 30,
            estimatedTokens: 50
        )
        XCTAssertEqual(message, shortContent)
    }
}
