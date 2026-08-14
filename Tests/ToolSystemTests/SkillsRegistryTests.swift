import XCTest
@testable import MLXCoder

final class SkillsRegistryTests: XCTestCase {
    func testDiscoversSkillsMetadataAndLoadsBodyLazily() async throws {
        let workspace = makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(atPath: workspace) }

        let skillDir = workspace + "/.github/skills/reviewer"
        try FileManager.default.createDirectory(atPath: skillDir, withIntermediateDirectories: true)
        let skillFile = skillDir + "/SKILL.md"
        let skillBody = """
        ---
        name: reviewer
        description: Review and risk triage
        tags: [review, safety]
        ---

        # Reviewer
        """
        try skillBody.write(toFile: skillFile, atomically: true, encoding: .utf8)

        let registry = SkillsRegistry(workspaceRoot: workspace, includeHomeSkills: false)
        let metadata = await registry.listMetadata()

        XCTAssertEqual(metadata.count, 1)
        XCTAssertEqual(metadata[0].name, "reviewer")
        XCTAssertEqual(metadata[0].description, "Review and risk triage")
        XCTAssertEqual(metadata[0].tags, ["review", "safety"])

        let loadedBody = try await registry.loadBody(name: "reviewer")
        XCTAssertNotNil(loadedBody)
        XCTAssertTrue(loadedBody?.contains("# Reviewer") == true)
    }

    private func makeTemporaryWorkspace() -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path()
    }

    // MARK: - relevantSkills (per-turn keyword filter)

    private let dotnetSkill = SkillMetadata(
        name: "dotnet-lsp", description: "Configure the .NET language server for C# projects",
        filePath: ".claude/skills/dotnet-lsp/SKILL.md", tags: ["dotnet", "csharp", "lsp"]
    )
    private let reviewerSkill = SkillMetadata(
        name: "reviewer", description: "Review and risk triage",
        filePath: ".github/skills/reviewer/SKILL.md", tags: ["review", "safety"]
    )

    func testRelevantSkillsMatchesOnTag() {
        let matches = SkillsRegistry.relevantSkills([dotnetSkill, reviewerSkill], to: "help me set up the dotnet language server")
        XCTAssertEqual(matches.map(\.name), ["dotnet-lsp"])
    }

    func testRelevantSkillsMatchesOnDescriptionWord() {
        let matches = SkillsRegistry.relevantSkills([dotnetSkill, reviewerSkill], to: "can you triage this for safety issues")
        XCTAssertEqual(matches.map(\.name), ["reviewer"])
    }

    func testRelevantSkillsReturnsEmptyWhenNothingMatches() {
        let matches = SkillsRegistry.relevantSkills([dotnetSkill, reviewerSkill], to: "what's the weather like today")
        XCTAssertTrue(matches.isEmpty)
    }

    func testRelevantSkillsRanksTagMatchAboveDescriptionOnlyMatch() {
        // "review" appears in reviewerSkill's tags (weight 3) and nowhere in
        // dotnetSkill; "csharp" appears in dotnetSkill's tags too, so both
        // score, but reviewer's tag hit should still surface it first.
        let matches = SkillsRegistry.relevantSkills([dotnetSkill, reviewerSkill], to: "review this csharp change")
        XCTAssertEqual(matches.first?.name, "reviewer")
    }

    func testRelevantSkillsRespectsLimit() {
        let many = (0..<5).map {
            SkillMetadata(name: "skill-\($0)", description: "handles widget work", filePath: "skills/skill-\($0)/SKILL.md", tags: ["widget"])
        }
        let matches = SkillsRegistry.relevantSkills(many, to: "widget widget widget", limit: 2)
        XCTAssertEqual(matches.count, 2)
    }
}
