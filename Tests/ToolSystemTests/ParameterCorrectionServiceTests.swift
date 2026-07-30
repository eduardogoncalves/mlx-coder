import XCTest
@testable import MLXCoder

final class ParameterCorrectionServiceTests: XCTestCase {
    func testReadFileCorrectionKeepsAbsolutePath() async {
        let input: [String: Any] = [
            "path": "/Users/eduardogoncalves/skills/dotnet-architect/SKILL.md"
        ]

        let result = await ParameterCorrectionService.correct(
            toolName: "read_file",
            arguments: input,
            workspaceRoot: "/tmp/workspace"
        )

        XCTAssertEqual(result.correctedArguments["path"] as? String, "/Users/eduardogoncalves/skills/dotnet-architect/SKILL.md")
        XCTAssertFalse(result.corrections.contains { $0.contains("Converted absolute path to relative") })
    }

    // MARK: - Helpers

    private func makeTempWorkspace() throws -> String {
        let root = NSTemporaryDirectory() + "pcs-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ content: String, to relative: String, under root: String) throws {
        let path = (root as NSString).appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - P0: fuzzy edit_file correction must never collapse a multi-line
    // old_text onto a single file line (the .csproj-corruption regression).

    func testEditFuzzyDoesNotCollapseMultiLineOldTextOntoSingleLine() async throws {
        let root = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(atPath: root) }

        // Only the FIRST search line (`<ItemGroup>`) has a strong match in the
        // file; the other two are unrelated, so no same-line-count window clears
        // the similarity threshold. The old single-line fallback would have
        // matched the bare `<ItemGroup>` line and rewritten the 3-line old_text
        // down to it — then the multi-line new_text landed on one line and
        // mangled the file. The fix must instead leave old_text untouched.
        let fileContent = """
        <Project>
          <ItemGroup>
            <PackageReference Include="Microsoft.AspNetCore.OpenApi" Version="10.0.10" />
          </ItemGroup>
        </Project>
        """
        try write(fileContent, to: "App.csproj", under: root)

        let oldText = """
        <ItemGroup>
        this line is completely unrelated aaaa bbbb cccc dddd
        another totally different line xxxx yyyy zzzz wwww
        """
        let input: [String: Any] = [
            "path": "App.csproj",
            "old_text": oldText,
            "new_text": "<ItemGroup>\n  <PackageReference Include=\"X\" Version=\"1.0\" />\n</ItemGroup>",
        ]

        let result = await ParameterCorrectionService.correct(
            toolName: "edit_file",
            arguments: input,
            workspaceRoot: root
        )

        // No destructive fuzzy correction should have fired.
        XCTAssertFalse(result.corrections.contains { $0.contains("Auto-corrected old_text") },
                       "multi-line old_text must not be fuzzy-corrected onto a single line")
        // old_text stays exactly what the model sent (edit_file then fails
        // cleanly with 'old_text not found', prompting an exact retry).
        XCTAssertEqual(result.correctedArguments["old_text"] as? String, oldText)
    }

    func testEditFuzzyCorrectsSingleLineWhitespaceDrift() async throws {
        let root = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(atPath: root) }

        try write("struct A {\n    let count = 1\n}\n", to: "A.swift", under: root)

        // Extra internal spaces so it is not a literal substring of the file,
        // forcing the fuzzy single-line path.
        let input: [String: Any] = [
            "path": "A.swift",
            "old_text": "let  count  =  1",
            "new_text": "let count = 2",
        ]

        let result = await ParameterCorrectionService.correct(
            toolName: "edit_file",
            arguments: input,
            workspaceRoot: root
        )

        XCTAssertTrue(result.corrections.contains { $0.contains("Auto-corrected old_text") })
        XCTAssertEqual(result.correctedArguments["old_text"] as? String, "    let count = 1")
    }

    func testEditFuzzyRefusesAmbiguousSingleLineMatch() async throws {
        let root = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(atPath: root) }

        // Two distinct lines match the search about equally well — ambiguous, so
        // the correction must refuse rather than guess one.
        try write("value = alpha111\nvalue = alpha222\n", to: "Dup.txt", under: root)

        let input: [String: Any] = [
            "path": "Dup.txt",
            "old_text": "value = alpha333",
            "new_text": "value = beta",
        ]

        let result = await ParameterCorrectionService.correct(
            toolName: "edit_file",
            arguments: input,
            workspaceRoot: root
        )

        XCTAssertFalse(result.corrections.contains { $0.contains("Auto-corrected old_text") })
        XCTAssertEqual(result.correctedArguments["old_text"] as? String, "value = alpha333")
    }

    // MARK: - P3: redundant workspace-root prefix is stripped when (and only
    // when) that makes an otherwise-missing path resolve.

    func testReadFileStripsRedundantIsolationRootPrefix() async throws {
        let repoRoot = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(atPath: repoRoot) }
        let isolatedRoot = (repoRoot as NSString).appendingPathComponent("ChatStreamingAPI")
        try write("// program", to: "Program.cs", under: isolatedRoot)

        let input: [String: Any] = ["path": "ChatStreamingAPI/Program.cs"]

        let result = await ParameterCorrectionService.correct(
            toolName: "read_file",
            arguments: input,
            workspaceRoot: isolatedRoot
        )

        XCTAssertEqual(result.correctedArguments["path"] as? String, "Program.cs")
        XCTAssertTrue(result.corrections.contains { $0.contains("redundant workspace-root prefix") })
    }

    func testReadFileKeepsGenuineSameNamedSubdirectory() async throws {
        // A real subdirectory that legitimately repeats the root's name must be
        // left alone — the rewrite only fires when the original does not exist.
        let repoRoot = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(atPath: repoRoot) }
        let isolatedRoot = (repoRoot as NSString).appendingPathComponent("ChatStreamingAPI")
        try write("// nested", to: "ChatStreamingAPI/Program.cs", under: isolatedRoot)

        let input: [String: Any] = ["path": "ChatStreamingAPI/Program.cs"]

        let result = await ParameterCorrectionService.correct(
            toolName: "read_file",
            arguments: input,
            workspaceRoot: isolatedRoot
        )

        XCTAssertEqual(result.correctedArguments["path"] as? String, "ChatStreamingAPI/Program.cs")
        XCTAssertFalse(result.corrections.contains { $0.contains("redundant workspace-root prefix") })
    }
}
