// Tests/ToolSystemTests/SubagentDigestSpoolTests.swift
// Tests that a sub-agent digest hands the orchestrator a line-addressable spool
// pointer (path + relevant line range) instead of a long verbatim tail, and
// that the recovery hint prefers it.

import XCTest
@testable import MLXCoder

final class SubagentDigestSpoolTests: XCTestCase {

    func testDigest_includesSpoolPointerAndRange() {
        let digest = TaskTool.makeSubagentDigest(
            status: "success",
            profileName: "executor",
            taskDescription: "Run the full test suite and report failures",
            summary: "Ran tests; see spooled output for the full log.",
            archivePath: ".native-agent/subagent-logs/run-1",
            summaryTruncated: false,
            spoolPath: "/tmp/mlx-coder-tool-output/123-task-executor-abcd.txt",
            spoolTotalLines: 812
        )
        XCTAssertTrue(digest.contains("tool_output: /tmp/mlx-coder-tool-output/123-task-executor-abcd.txt"))
        XCTAssertTrue(digest.contains("relevant_lines: 1-812 of 812"))
    }

    func testDigest_truncatedRecoveryPrefersSpool() {
        let digest = TaskTool.makeSubagentDigest(
            status: "partial",
            profileName: "terminal",
            taskDescription: "cat a huge file",
            summary: "…clipped…",
            archivePath: ".native-agent/subagent-logs/run-2",
            summaryTruncated: true,
            spoolPath: "/tmp/mlx-coder-tool-output/999-task-terminal-ef01.txt",
            spoolTotalLines: 5000
        )
        XCTAssertTrue(digest.contains("recovery:"))
        XCTAssertTrue(digest.contains("read_tool_output"))
        XCTAssertTrue(digest.contains("/tmp/mlx-coder-tool-output/999-task-terminal-ef01.txt"))
        XCTAssertTrue(digest.contains("5000 lines"))
    }

    func testDigest_noSpoolKeepsLegacyShape() {
        let digest = TaskTool.makeSubagentDigest(
            status: "partial",
            profileName: "executor",
            taskDescription: "do a thing",
            summary: "…clipped…",
            archivePath: ".native-agent/subagent-logs/run-3",
            summaryTruncated: true
        )
        XCTAssertFalse(digest.contains("tool_output:"))
        XCTAssertFalse(digest.contains("relevant_lines:"))
        // Legacy recovery hint still points at the raw re-run / task_output.
        XCTAssertTrue(digest.contains("response_mode:\"raw\""))
        XCTAssertTrue(digest.contains("task_output"))
    }

    // MARK: - lastSummaryLine (scoped verdict parsing for WorkflowStep.requiredSuccessMarker)

    func testLastSummaryLine_returnsFinalNonEmptyLineOfSummaryBody() {
        let digest = TaskTool.makeSubagentDigest(
            status: "success", profileName: "test_engineering",
            taskDescription: "verify the fix",
            summary: "Ran `swift test --filter FooTests`.\nAll tests passed.\n\nVERIFICATION: PASS",
            archivePath: nil
        )
        XCTAssertEqual(TaskTool.lastSummaryLine(fromDigest: digest), "VERIFICATION: PASS")
    }

    func testLastSummaryLine_ignoresTaskEchoEntirely() {
        // The task echo can itself contain marker-shaped text (e.g. the
        // step's own instructions asking for it) — lastSummaryLine must
        // never reach back into the `task:` line to find it.
        let digest = TaskTool.makeSubagentDigest(
            status: "success", profileName: "test_engineering",
            taskDescription: "End with VERIFICATION: PASS or VERIFICATION: FAIL, verbatim.",
            summary: "3 of 5 tests still fail.\nVERIFICATION: FAIL",
            archivePath: nil
        )
        XCTAssertEqual(TaskTool.lastSummaryLine(fromDigest: digest), "VERIFICATION: FAIL")
    }

    func testLastSummaryLine_stopsAtStdoutTruncatedBoundary() {
        // Confirms the extraction doesn't accidentally swallow fields that
        // come after the summary body (stdout_truncated / summary_bytes /
        // tool_calls / archive / modified_files).
        let digest = TaskTool.makeSubagentDigest(
            status: "success", profileName: "executor",
            taskDescription: "task", summary: "Done.\nmodified_files: not/a/real/field/this/is/summary/text",
            archivePath: "some/archive/path", modifiedFiles: ["Foo.swift"]
        )
        XCTAssertEqual(TaskTool.lastSummaryLine(fromDigest: digest), "modified_files: not/a/real/field/this/is/summary/text")
    }

    func testLastSummaryLine_returnsNilWhenNoSummaryMarker() {
        XCTAssertNil(TaskTool.lastSummaryLine(fromDigest: "not a real digest at all"))
    }
}
