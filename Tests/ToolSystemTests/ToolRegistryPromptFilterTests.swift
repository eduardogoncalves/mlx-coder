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

    func testGenerateToolsBlockCodingFilterPrioritizesCodingTools() async throws {
        let registry = ToolRegistry()
        await registry.register(MockTool(name: "read_file", description: "Read file"))
        await registry.register(MockTool(name: "bash", description: "Run shell"))
        await registry.register(MockTool(name: "lsp_definition", description: "LSP defs"))
        await registry.register(MockTool(name: "web_search", description: "Web search"))

        let filter = ToolPromptFilter(modeHint: "agent", taskTypeHint: "coding", maxTools: 3, maxMCPTools: 0)
        let block = try await registry.generateToolsBlock(filter: filter)
        let names = try extractToolNames(fromToolsBlock: block)

        XCTAssertEqual(Set(names), Set(["read_file", "bash", "lsp_definition"]))
        XCTAssertFalse(names.contains("web_search"))
    }

    func testGenerateToolsBlockRespectsMCPToolCap() async throws {
        let registry = ToolRegistry()
        await registry.register(MockTool(name: "read_file", description: "Read file"))
        await registry.register(MockTool(name: "mcp_docs_search", description: "Search docs"))
        await registry.register(MockTool(name: "mcp_docs_fetch", description: "Fetch docs"))
        await registry.register(MockTool(name: "mcp_git_open_pr", description: "Open PR"))

        let filter = ToolPromptFilter(modeHint: "agent", taskTypeHint: "general", maxTools: 10, maxMCPTools: 1)
        let block = try await registry.generateToolsBlock(filter: filter)
        let names = try extractToolNames(fromToolsBlock: block)

        let mcpNames = names.filter { $0.hasPrefix("mcp_") }
        XCTAssertEqual(mcpNames.count, 1)
    }

    func testGenerateToolsBlockFilterReducesTokenFootprint() async throws {
        let registry = ToolRegistry()

        let names = [
            "read_file", "list_dir", "glob", "grep", "code_search", "read_many",
            "write_file", "edit_file", "append_file", "patch", "bash", "todo", "task",
            "lsp_diagnostics", "lsp_definition", "lsp_references", "lsp_hover", "lsp_completion",
            "web_fetch", "web_search", "build_check", "mcp_docs_search", "mcp_docs_fetch"
        ]

        for name in names {
            await registry.register(MockTool(name: name, description: "Tool \(name)"))
        }

        let fullBlock = try await registry.generateToolsBlock()
        let filteredBlock = try await registry.generateToolsBlock(
            filter: ToolPromptFilter(modeHint: "plan", taskTypeHint: "general", maxTools: 14, maxMCPTools: 1)
        )

        let fullTokens = fullBlock.count / 4
        let filteredTokens = filteredBlock.count / 4

        XCTAssertLessThan(filteredTokens, fullTokens)
        XCTAssertGreaterThan(fullTokens - filteredTokens, 50)
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
