import XCTest
@testable import MLXCoder

final class EditFileToolTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempWorkspace() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mlx-coder-edit-file-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ content: String, named name: String, in workspace: URL) throws -> URL {
        let url = workspace.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Success path: replacement applied and diff returned

    func testSuccessfulEditReturnsDiff() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try write("line1\nfoo\nline3\n", named: "file.txt", in: workspace)

        let tool = EditFileTool(permissions: PermissionEngine(workspaceRoot: workspace.path))
        let result = try await tool.execute(arguments: [
            "path": "file.txt",
            "old_text": "foo",
            "new_text": "bar"
        ])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Applied edit to file.txt"))
        XCTAssertTrue(result.content.contains("-foo"), "diff should show removed line")
        XCTAssertTrue(result.content.contains("+bar"), "diff should show added line")

        let written = try String(contentsOf: workspace.appendingPathComponent("file.txt"), encoding: .utf8)
        XCTAssertEqual(written, "line1\nbar\nline3\n")
    }

    func testSuccessfulEditDiffContainsHunkHeader() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try write("alpha\nbeta\ngamma\n", named: "f.txt", in: workspace)

        let tool = EditFileTool(permissions: PermissionEngine(workspaceRoot: workspace.path))
        let result = try await tool.execute(arguments: [
            "path": "f.txt",
            "old_text": "beta",
            "new_text": "BETA"
        ])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("@@"), "diff should contain a hunk header")
        XCTAssertTrue(result.content.contains("--- a/f.txt"))
        XCTAssertTrue(result.content.contains("+++ b/f.txt"))
    }

    // MARK: - Error: old_text not found

    func testOldTextNotFoundReturnsError() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try write("hello world\n", named: "file.txt", in: workspace)

        let tool = EditFileTool(permissions: PermissionEngine(workspaceRoot: workspace.path))
        let result = try await tool.execute(arguments: [
            "path": "file.txt",
            "old_text": "does not exist",
            "new_text": "replacement"
        ])

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.lowercased().contains("not found"))
    }

    // MARK: - Error: old_text appears more than once

    func testDuplicateOldTextReturnsError() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try write("foo\nfoo\n", named: "file.txt", in: workspace)

        let tool = EditFileTool(permissions: PermissionEngine(workspaceRoot: workspace.path))
        let result = try await tool.execute(arguments: [
            "path": "file.txt",
            "old_text": "foo",
            "new_text": "bar"
        ])

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("2"), "error should mention occurrence count")
        XCTAssertTrue(result.content.contains("unique"),
                      "error should say old_text must be unique")
    }

    // MARK: - CRLF tolerance: models generate "\n"-only old_text/new_text, but
    // Windows-authored/.NET repos routinely have CRLF files on disk. edit_file
    // must still match and must not leave the edited region's line endings
    // inconsistent with the rest of the (untouched) CRLF file.

    func testMultiLineOldTextMatchesAcrossCRLFFile() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try write("line1\r\nfoo\r\nbar\r\nline4\r\n", named: "file.txt", in: workspace)

        let tool = EditFileTool(permissions: PermissionEngine(workspaceRoot: workspace.path))
        let result = try await tool.execute(arguments: [
            "path": "file.txt",
            "old_text": "foo\nbar",
            "new_text": "foo\nbaz\nbar"
        ])

        XCTAssertFalse(result.isError, "old_text with \\n line endings should match a CRLF file: \(result.content)")

        let written = try String(contentsOf: workspace.appendingPathComponent("file.txt"), encoding: .utf8)
        XCTAssertEqual(written, "line1\r\nfoo\r\nbaz\r\nbar\r\nline4\r\n",
                       "inserted new_text should adopt the file's CRLF convention, and untouched lines must stay byte-identical")
    }

    func testSingleLineOldTextStillMatchesExactlyOnCRLFFile() async throws {
        // A single-line snippet doesn't straddle a line ending, so the plain
        // exact-match path (not the CRLF fallback) should already handle it.
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try write("line1\r\nfoo\r\nline3\r\n", named: "file.txt", in: workspace)

        let tool = EditFileTool(permissions: PermissionEngine(workspaceRoot: workspace.path))
        let result = try await tool.execute(arguments: [
            "path": "file.txt",
            "old_text": "foo",
            "new_text": "bar"
        ])

        XCTAssertFalse(result.isError)
        let written = try String(contentsOf: workspace.appendingPathComponent("file.txt"), encoding: .utf8)
        XCTAssertEqual(written, "line1\r\nbar\r\nline3\r\n")
    }

    func testMultiLineOldTextAmbiguousAcrossCRLFFileReturnsUniqueError() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try write("foo\r\nbar\r\nfoo\r\nbar\r\n", named: "file.txt", in: workspace)

        let tool = EditFileTool(permissions: PermissionEngine(workspaceRoot: workspace.path))
        let result = try await tool.execute(arguments: [
            "path": "file.txt",
            "old_text": "foo\nbar",
            "new_text": "baz"
        ])

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("2"))
        XCTAssertTrue(result.content.contains("unique"))
    }

    func testOldTextGenuinelyMissingFromCRLFFileStillReturnsNotFoundError() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try write("line1\r\nfoo\r\nline3\r\n", named: "file.txt", in: workspace)

        let tool = EditFileTool(permissions: PermissionEngine(workspaceRoot: workspace.path))
        let result = try await tool.execute(arguments: [
            "path": "file.txt",
            "old_text": "does\nnot\nexist",
            "new_text": "replacement"
        ])

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.lowercased().contains("not found"))
    }

    // MARK: - Unicode lookalike tolerance: models routinely "typographically
    // autocorrect" curly quotes, em/en dashes, and non-breaking spaces when
    // reproducing text from memory, even though the source file only ever
    // contains plain ASCII. Ported from qwen-code's UNICODE_EQUIVALENT_MAP.

    func testCurlyQuotesInOldTextMatchStraightQuotesInFile() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try write("let x = \"hello\";\n", named: "file.txt", in: workspace)

        let tool = EditFileTool(permissions: PermissionEngine(workspaceRoot: workspace.path))
        // old_text uses curly double quotes (\u{201C}/\u{201D}) instead of the
        // file's straight ASCII quotes.
        let result = try await tool.execute(arguments: [
            "path": "file.txt",
            "old_text": "let x = \u{201C}hello\u{201D};",
            "new_text": "let x = \"world\";"
        ])

        XCTAssertFalse(result.isError, "curly-quote old_text should still match straight-quote file content: \(result.content)")
        let written = try String(contentsOf: workspace.appendingPathComponent("file.txt"), encoding: .utf8)
        XCTAssertEqual(written, "let x = \"world\";\n")
    }

    func testEmDashInOldTextMatchesHyphenInFile() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try write("// a workaround - see ticket 42\n", named: "file.txt", in: workspace)

        let tool = EditFileTool(permissions: PermissionEngine(workspaceRoot: workspace.path))
        let result = try await tool.execute(arguments: [
            "path": "file.txt",
            "old_text": "// a workaround \u{2014} see ticket 42",
            "new_text": "// a workaround - see ticket 43"
        ])

        XCTAssertFalse(result.isError, "em-dash old_text should still match a plain-hyphen file: \(result.content)")
        let written = try String(contentsOf: workspace.appendingPathComponent("file.txt"), encoding: .utf8)
        XCTAssertEqual(written, "// a workaround - see ticket 43\n")
    }

    // MARK: - Line-based fuzzy tolerance: a multi-line old_text reconstructed
    // from memory routinely drifts on individual lines' trailing whitespace or
    // punctuation. Ported from qwen-code's findLineBasedMatch.

    func testTrailingWhitespaceDriftOnOneLineOfMultiLineOldTextStillMatches() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        // The file's middle line has trailing spaces the model's old_text omits.
        try write("line1\nfoo   \nbar\nline4\n", named: "file.txt", in: workspace)

        let tool = EditFileTool(permissions: PermissionEngine(workspaceRoot: workspace.path))
        let result = try await tool.execute(arguments: [
            "path": "file.txt",
            "old_text": "foo\nbar",
            "new_text": "baz\nbar"
        ])

        XCTAssertFalse(result.isError, "trailing-whitespace drift on one line should still match: \(result.content)")
        let written = try String(contentsOf: workspace.appendingPathComponent("file.txt"), encoding: .utf8)
        XCTAssertEqual(written, "line1\nbaz\nbar\nline4\n")
    }

    func testLineBasedFallbackNotTriggeredWhenExactMatchAlreadySucceeds() async throws {
        // Sanity check that the new fallback tiers don't change behavior for
        // the common, already-exact case.
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try write("foo\nbar\n", named: "file.txt", in: workspace)

        let tool = EditFileTool(permissions: PermissionEngine(workspaceRoot: workspace.path))
        let result = try await tool.execute(arguments: [
            "path": "file.txt",
            "old_text": "foo\nbar",
            "new_text": "baz\nqux"
        ])

        XCTAssertFalse(result.isError)
        let written = try String(contentsOf: workspace.appendingPathComponent("file.txt"), encoding: .utf8)
        XCTAssertEqual(written, "baz\nqux\n")
    }

    // MARK: - generateUnifiedDiff unit tests

    func testDiffHelperSingleLineChange() {
        let orig    = "a\nb\nc\n"
        let updated = "a\nB\nc\n"
        let diff = FileMutationSupport.generateUnifiedDiff(original: orig, updated: updated, path: "x.txt")

        XCTAssertTrue(diff.contains("-b"))
        XCTAssertTrue(diff.contains("+B"))
        XCTAssertTrue(diff.contains("@@"))
    }

    func testDiffHelperNoChanges() {
        let content = "same\n"
        let diff = FileMutationSupport.generateUnifiedDiff(original: content, updated: content, path: "x.txt")
        XCTAssertEqual(diff, "(no changes)")
    }

    func testDiffHelperContextLines() {
        let orig    = "1\n2\n3\n4\nOLD\n6\n7\n8\n9\n"
        let updated = "1\n2\n3\n4\nNEW\n6\n7\n8\n9\n"
        let diff = FileMutationSupport.generateUnifiedDiff(original: orig, updated: updated, path: "x.txt")

        // Should include 3 lines of context before and after the change
        XCTAssertTrue(diff.contains(" 2"), "context line 2")
        XCTAssertTrue(diff.contains(" 3"), "context line 3")
        XCTAssertTrue(diff.contains(" 4"), "context line 4 (leading context)")
        XCTAssertTrue(diff.contains(" 6"), "context line 6 (trailing context)")
        XCTAssertTrue(diff.contains(" 7"), "context line 7")
        XCTAssertTrue(diff.contains(" 8"), "context line 8")
        XCTAssertTrue(diff.contains("-OLD"))
        XCTAssertTrue(diff.contains("+NEW"))
    }
}
