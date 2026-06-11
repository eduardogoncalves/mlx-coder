import XCTest
@testable import MLXCoder

final class ReadSkillToolTests: XCTestCase {
    func testReadsFullSkillByName() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try writeSkill(
            in: workspace,
            directory: "dotnet-cli",
            name: "dotnet-cli",
            bodyLines: ["# Dotnet CLI", "Use `dotnet build` to compile."]
        )

        let tool = ReadSkillTool(skills: SkillsRegistry(workspaceRoot: workspace.path, includeHomeSkills: false))
        let result = try await tool.execute(arguments: ["name": "dotnet-cli"])

        XCTAssertFalse(result.isError)
        XCTAssertNil(result.truncationMarker)
        XCTAssertTrue(result.content.contains("Skill 'dotnet-cli'"))
        XCTAssertTrue(result.content.contains("Use `dotnet build` to compile."))
    }

    func testPaginatesLongSkillWithContinuationHint() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let bodyLines = (1...30).map { "Instruction line \($0)" }
        try writeSkill(in: workspace, directory: "long-skill", name: "long-skill", bodyLines: bodyLines)

        let registry = SkillsRegistry(workspaceRoot: workspace.path, includeHomeSkills: false)
        let tool = ReadSkillTool(skills: registry, maxOutputLines: 10)

        let firstPage = try await tool.execute(arguments: ["name": "long-skill"])
        XCTAssertFalse(firstPage.isError)
        XCTAssertTrue(firstPage.content.contains("lines 1-10 of"))
        let marker = try XCTUnwrap(firstPage.truncationMarker)
        XCTAssertTrue(marker.contains("\"start_line\": 11"))
        XCTAssertTrue(marker.contains("read_skill"))

        let secondPage = try await tool.execute(arguments: ["name": "long-skill", "start_line": 11])
        XCTAssertFalse(secondPage.isError)
        XCTAssertTrue(secondPage.content.contains("lines 11-20 of"))
        XCTAssertTrue(try XCTUnwrap(secondPage.truncationMarker).contains("\"start_line\": 21"))

        // The file is 34 lines (4 frontmatter + 30 instructions), so the last page starts at 31.
        let lastPage = try await tool.execute(arguments: ["name": "long-skill", "start_line": "31"])
        XCTAssertFalse(lastPage.isError)
        XCTAssertNil(lastPage.truncationMarker)
        XCTAssertTrue(lastPage.content.contains("lines 31-34 of 34"))
        XCTAssertTrue(lastPage.content.contains("Instruction line 30"))
    }

    func testUnknownSkillListsAvailableNames() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try writeSkill(in: workspace, directory: "reviewer", name: "reviewer", bodyLines: ["# Reviewer"])

        let tool = ReadSkillTool(skills: SkillsRegistry(workspaceRoot: workspace.path, includeHomeSkills: false))
        let result = try await tool.execute(arguments: ["name": "does-not-exist"])

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("Unknown skill 'does-not-exist'"))
        XCTAssertTrue(result.content.contains("reviewer"))
    }

    func testResolvesNameCaseInsensitively() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try writeSkill(in: workspace, directory: "dotnet-cli", name: "dotnet-cli", bodyLines: ["# Dotnet CLI"])

        let tool = ReadSkillTool(skills: SkillsRegistry(workspaceRoot: workspace.path, includeHomeSkills: false))
        let result = try await tool.execute(arguments: ["name": "Dotnet-CLI"])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Skill 'dotnet-cli'"))
    }

    private func writeSkill(in workspace: URL, directory: String, name: String, bodyLines: [String]) throws {
        let skillDir = workspace.appendingPathComponent("skills/\(directory)", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        let body = """
        ---
        name: \(name)
        description: Test skill \(name)
        ---

        """ + bodyLines.joined(separator: "\n") + "\n"
        try body.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    private func makeTempWorkspace() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mlx-coder-read-skill-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
