// Tests/ToolSystemTests/ToolOutputSpoolTests.swift
// Tests for the large-tool-output spool: disk round-trip, path scoping, the
// pure line slicer, the inline window/pointer rendering, spool eligibility, and
// the read_tool_output tool.

import XCTest
@testable import MLXCoder

final class ToolOutputSpoolTests: XCTestCase {

    private func makeSpool() throws -> ToolOutputSpool {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spool-test-\(UUID().uuidString)")
        return ToolOutputSpool(root: root)
    }

    // MARK: - Round-trip

    func testSpoolAndReadBack() throws {
        let spool = try makeSpool()
        defer { try? FileManager.default.removeItem(at: spool.root) }
        let content = (1...50).map { "line \($0)" }.joined(separator: "\n")

        let handle = try XCTUnwrap(spool.spool(content: content, toolName: "bash"))
        XCTAssertEqual(handle.totalLines, 50)
        XCTAssertTrue(handle.path.hasPrefix(spool.root.path))

        let result = try XCTUnwrap(spool.readRange(path: handle.path, start: 10, end: 12, maxLines: 500))
        XCTAssertEqual(result.content, "line 10\nline 11\nline 12")
        XCTAssertEqual(result.firstLine, 10)
        XCTAssertEqual(result.lastLine, 12)
        XCTAssertEqual(result.totalLines, 50)
    }

    func testSpoolEmptyReturnsNil() throws {
        let spool = try makeSpool()
        defer { try? FileManager.default.removeItem(at: spool.root) }
        XCTAssertNil(spool.spool(content: "", toolName: "bash"))
    }

    // MARK: - Path scoping

    func testIsWithinRootRejectsOutsidePaths() throws {
        let spool = try makeSpool()
        defer { try? FileManager.default.removeItem(at: spool.root) }
        XCTAssertFalse(spool.isWithinRoot("/etc/passwd"))
        XCTAssertFalse(spool.isWithinRoot(spool.root.path + "/../escape.txt"))
        let handle = try XCTUnwrap(spool.spool(content: "hi\nthere", toolName: "bash"))
        XCTAssertTrue(spool.isWithinRoot(handle.path))
    }

    func testReadRangeRejectsOutsideRoot() throws {
        let spool = try makeSpool()
        defer { try? FileManager.default.removeItem(at: spool.root) }
        XCTAssertNil(spool.readRange(path: "/etc/hosts", start: 1, end: nil, maxLines: 10))
    }

    // MARK: - Pure slicer

    func testSlice_clampsAndCounts() {
        let content = (1...10).map { "L\($0)" }.joined(separator: "\n")
        let r = ToolOutputSpool.slice(content, start: 8, end: 100, maxLines: 500)
        XCTAssertEqual(r.content, "L8\nL9\nL10")
        XCTAssertEqual(r.firstLine, 8)
        XCTAssertEqual(r.lastLine, 10)
        XCTAssertEqual(r.totalLines, 10)
    }

    func testSlice_maxLinesCap() {
        let content = (1...10).map { "L\($0)" }.joined(separator: "\n")
        let r = ToolOutputSpool.slice(content, start: 1, end: nil, maxLines: 3)
        XCTAssertEqual(r.content, "L1\nL2\nL3")
        XCTAssertEqual(r.lastLine, 3)
    }

    func testSlice_startBeyondEnd() {
        let r = ToolOutputSpool.slice("a\nb", start: 99, end: nil, maxLines: 10)
        XCTAssertEqual(r.firstLine, 0)
        XCTAssertEqual(r.totalLines, 2)
    }

    func testLineCount_dropsTrailingNewline() {
        XCTAssertEqual(ToolOutputSpool.lineCount("a\nb\nc\n"), 3)
        XCTAssertEqual(ToolOutputSpool.lineCount("a\nb\nc"), 3)
        XCTAssertEqual(ToolOutputSpool.lineCount(""), 0)
    }

    // MARK: - Eligibility

    func testSpoolEligibility() {
        XCTAssertTrue(ToolOutputSpoolPolicy.isSpoolEligible(toolName: "bash"))
        XCTAssertTrue(ToolOutputSpoolPolicy.isSpoolEligible(toolName: "grep"))
        XCTAssertTrue(ToolOutputSpoolPolicy.isSpoolEligible(toolName: "code_search"))
        XCTAssertFalse(ToolOutputSpoolPolicy.isSpoolEligible(toolName: "web_fetch"))
        XCTAssertFalse(ToolOutputSpoolPolicy.isSpoolEligible(toolName: "web_search"))
        XCTAssertFalse(ToolOutputSpoolPolicy.isSpoolEligible(toolName: "read_file"))
        XCTAssertFalse(ToolOutputSpoolPolicy.isSpoolEligible(toolName: "read_tool_output"))
        // `task` digests carry their own spool pointer; the orchestrator must
        // not re-spool them (that would hide the digest header behind a tail window).
        XCTAssertFalse(ToolOutputSpoolPolicy.isSpoolEligible(toolName: "task"))
    }

    // MARK: - Window / pointer rendering

    func testWindowMessage_bashKeepsTail() {
        let raw = (1...100).map { "line \($0)" }.joined(separator: "\n")
        let handle = ToolOutputSpool.Handle(path: "/tmp/spool/x.txt", totalLines: 100, byteCount: 900)
        let msg = ToolOutputSpoolPolicy.windowMessage(
            toolName: "bash", raw: raw, handle: handle, windowLines: 10, estimatedTokens: 250)
        XCTAssertTrue(msg.contains("Full output saved to: /tmp/spool/x.txt"))
        XCTAssertTrue(msg.contains("line 100"), "bash keeps the tail")
        XCTAssertFalse(msg.contains("line 1\n"), "head lines are not in a tail window")
        XCTAssertTrue(msg.contains("read_tool_output"))
        XCTAssertTrue(msg.contains("lines 91-100 of 100"))
    }

    func testWindowMessage_genericKeepsHead() {
        let raw = (1...100).map { "line \($0)" }.joined(separator: "\n")
        let handle = ToolOutputSpool.Handle(path: "/tmp/spool/x.txt", totalLines: 100, byteCount: 900)
        let msg = ToolOutputSpoolPolicy.windowMessage(
            toolName: "grep", raw: raw, handle: handle, windowLines: 10, estimatedTokens: 250)
        XCTAssertTrue(msg.contains("line 1"), "generic keeps the head")
        XCTAssertFalse(msg.contains("line 100"))
        XCTAssertTrue(msg.contains("lines 1-10 of 100"))
    }

    func testPointerSuffix() {
        let handle = ToolOutputSpool.Handle(path: "/tmp/spool/x.txt", totalLines: 42, byteCount: 500)
        let suffix = ToolOutputSpoolPolicy.pointerSuffix(handle: handle)
        XCTAssertTrue(suffix.contains("/tmp/spool/x.txt"))
        XCTAssertTrue(suffix.contains("42 lines"))
        XCTAssertTrue(suffix.contains("read_tool_output"))
    }

    // MARK: - read_tool_output tool

    func testReadToolOutputTool_pagesAndMarksContinuation() async throws {
        let spool = try makeSpool()
        defer { try? FileManager.default.removeItem(at: spool.root) }
        let content = (1...1000).map { "row \($0)" }.joined(separator: "\n")
        let handle = try XCTUnwrap(spool.spool(content: content, toolName: "bash"))

        let tool = ReadToolOutputTool(spool: spool, maxLines: 100)
        let result = try await tool.execute(arguments: ["path": handle.path, "start_line": 1])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.hasPrefix("row 1\n"))
        XCTAssertNotNil(result.truncationMarker, "more remains → continuation marker")
        XCTAssertTrue(result.truncationMarker?.contains("start_line: 101") ?? false)
    }

    func testReadToolOutputTool_rejectsWorkspacePath() async throws {
        let spool = try makeSpool()
        defer { try? FileManager.default.removeItem(at: spool.root) }
        let tool = ReadToolOutputTool(spool: spool)
        let result = try await tool.execute(arguments: ["path": "/etc/passwd"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("only reads files under the tool-output spool"))
    }

    func testReadToolOutputTool_missingPathArg() async throws {
        let tool = ReadToolOutputTool(spool: try makeSpool())
        let result = try await tool.execute(arguments: [:])
        XCTAssertTrue(result.isError)
    }

    // MARK: - Config decoding

    func testConfigDecoding_partialFallsBackToDefaults() throws {
        let json = #"{ "enabled": false, "inlineWindowLines": 20 }"#.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(ToolOutputSpoolConfig.self, from: json)
        XCTAssertFalse(cfg.enabled)
        XCTAssertEqual(cfg.inlineWindowLines, 20)
        XCTAssertEqual(cfg.minTokensToSpool, ToolOutputSpoolConfig().minTokensToSpool)
    }
}
