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
}
