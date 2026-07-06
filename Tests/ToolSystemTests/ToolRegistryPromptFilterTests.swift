import XCTest
@testable import MLXCoder

private struct MockTool: Tool {
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

final class ToolRegistryPromptFilterTests: XCTestCase {
    func testGenerateToolsBlockUnfilteredIncludesAllTools() async throws {
        let registry = ToolRegistry()
        await registry.register(MockTool(name: "read_file", description: "Read file"))
        await registry.register(MockTool(name: "bash", description: "Run shell"))
        await registry.register(MockTool(name: "mcp_docs_search", description: "Search docs"))

        let block = try await registry.generateToolsBlock()
        let names = try extractToolNames(fromToolsBlock: block)

        XCTAssertEqual(names, ["bash", "mcp_docs_search", "read_file"])
    }

    func testToolSelectionForCodeEditIncludesBaseAndEphemeralGroups() {
        XCTAssertEqual(
            ToolInjectionSelection.toolNames(forTaskType: "code_edit"),
            [
                "read_file", "read_many", "read_skill", "search_knowledge", "log_knowledge",
                "list_dir", "glob", "grep",
                "write_file", "edit_file", "bash", "todo",
                "web_fetch", "web_search",
                "lsp_diagnostics", "lsp_definition", "lsp_references",
                "lsp_rename", "lsp_hover", "lsp_completion",
                "lsp_signature_help", "code_search",
                "patch", "append_file"
            ]
        )
    }

    func testToolSelectionForPlanningIncludesBaseAndPlanFile() {
        XCTAssertEqual(
            ToolInjectionSelection.toolNames(forTaskType: "planning"),
            [
                "read_file", "read_many", "read_skill", "search_knowledge", "log_knowledge",
                "list_dir", "glob", "grep",
                "write_file", "edit_file", "bash", "todo",
                "web_fetch", "web_search",
                "plan_file"
            ]
        )
    }

    func testToolSelectionForUnknownTaskFallsBackToBaseOnly() {
        XCTAssertEqual(
            ToolInjectionSelection.toolNames(forTaskType: "something_else"),
            ToolInjectionSelection.baseTools
        )
    }

    func testGetToolsForTaskReturnsOnlyRegisteredMatchingTools() async {
        let registry = ToolRegistry()
        await registry.register(MockTool(name: "read_file", description: "Read file"))
        await registry.register(MockTool(name: "bash", description: "Run shell"))
        await registry.register(MockTool(name: "plan_file", description: "Persist PLAN.MD"))
        await registry.register(MockTool(name: "web_search", description: "Search web"))

        let tools = await registry.getToolsForTask(taskType: "planning")
        let names = tools.map(\.name).sorted()

        XCTAssertEqual(names, ["bash", "plan_file", "read_file", "web_search"])
    }

    func testGenerateToolsBlockWithSelectedToolNamesOnlyInjectsRelevantTools() async throws {
        let registry = ToolRegistry()

        for name in [
            "read_file", "read_many", "list_dir", "glob", "grep",
            "write_file", "edit_file", "bash", "todo",
            "plan_file", "web_search", "mcp_docs_search"
        ] {
            await registry.register(MockTool(name: name, description: "Tool \(name)"))
        }

        let block = try await registry.generateToolsBlock(
            filter: ToolPromptFilter(
                modeHint: "plan",
                taskTypeHint: "planning",
                includeMCPTools: false,
                selectedToolNames: ToolInjectionSelection.toolNames(forTaskType: "planning")
            )
        )
        let names = try extractToolNames(fromToolsBlock: block)

        XCTAssertEqual(
            names,
            [
                "bash", "edit_file", "glob", "grep", "list_dir",
                "plan_file", "read_file", "read_many", "todo",
                "web_search", "write_file"
            ]
        )
        XCTAssertFalse(names.contains("mcp_docs_search"))
    }

    private func extractToolNames(fromToolsBlock block: String) throws -> [String] {
        let openTag = ToolCallPattern.toolsOpen
        let closeTag = ToolCallPattern.toolsClose

        guard let openRange = block.range(of: openTag),
              let closeRange = block.range(of: closeTag),
              openRange.upperBound <= closeRange.lowerBound else {
            throw NSError(domain: "ToolRegistryPromptFilterTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid tools block format"])
        }

        let jsonText = String(block[openRange.upperBound..<closeRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonText.data(using: .utf8),
              let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw NSError(domain: "ToolRegistryPromptFilterTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid tools block JSON"])
        }

        return array.compactMap { item in
            guard let function = item["function"] as? [String: Any] else {
                return nil
            }
            return function["name"] as? String
        }.sorted()
    }
}
