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
}
