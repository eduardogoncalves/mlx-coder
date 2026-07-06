import XCTest
@testable import MLXCoder

private struct RuntimeMockTool: Tool {
    let name: String
    let description: String
    let parameters: JSONSchema = JSONSchema(
        type: "object",
        properties: [
            "value": PropertySchema(type: "string", description: "Example value")
        ],
        required: ["value"]
    )

    func execute(arguments: [String: Any]) async throws -> ToolResult {
        .success("ok")
    }
}

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

    func testPlanningModeInjectsPlanningToolsOnly() async {
        let registry = ToolRegistry()

        for name in [
            "read_file", "read_many", "list_dir", "glob", "grep",
            "write_file", "edit_file", "bash", "todo",
            "plan_file", "patch", "task"
        ] {
            await registry.register(RuntimeMockTool(name: name, description: "Tool \(name)"))
        }

        let composition = await AgentLoop.buildSystemPromptComposition(
            registry: registry,
            mode: .plan,
            taskType: .coding
        )

        XCTAssertTrue(composition.prompt.contains("\"name\" : \"plan_file\""))
        XCTAssertFalse(composition.prompt.contains("\"name\" : \"patch\""))
        XCTAssertFalse(composition.prompt.contains("\"name\" : \"task\""))
    }
}
