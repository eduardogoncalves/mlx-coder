import XCTest
@testable import MLXCoder

final class SystemPromptRuntimeTests: XCTestCase {
    func testRuntimeSectionIncludesCurrentWorkdir() async {
        let registry = ToolRegistry()
        let composition = await AgentLoop.buildSystemPromptComposition(registry: registry)

        let cwd = FileManager.default.currentDirectoryPath
        XCTAssertTrue(composition.prompt.contains("PROMPT_SECTION:runtime"))
        XCTAssertTrue(composition.prompt.contains("Current workdir (workspace): \(cwd)"))
    }

    func testRuntimeSectionUsesExplicitWorkspaceRootWhenProvided() async {
        let registry = ToolRegistry()
        let composition = await AgentLoop.buildSystemPromptComposition(
            registry: registry,
            workspaceRoot: "/tmp/custom-workspace"
        )

        XCTAssertTrue(composition.prompt.contains("Current workdir (workspace): /tmp/custom-workspace"))
    }
}
