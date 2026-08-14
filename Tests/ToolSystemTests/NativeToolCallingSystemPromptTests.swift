import XCTest
@testable import MLXCoder

/// Remote/online backends receive tool schemas via the request's native `tools`
/// API field (see AgentLoop+RemoteGeneration.swift), so the system prompt
/// must not also inline the same JSON schemas as text, nor instruct the model
/// to emit text-based <tool_call> tags — both would double token cost and
/// contradict the provider's own native tool-calling mechanism.
final class NativeToolCallingSystemPromptTests: XCTestCase {
    private struct MockTool: Tool {
        let name: String
        let description: String
        let parameters: JSONSchema = JSONSchema(
            type: "object",
            properties: ["value": PropertySchema(type: "string", description: "Example value")],
            required: ["value"]
        )

        func execute(arguments: [String: Any]) async throws -> ToolResult {
            .success("ok")
        }
    }

    func testNativeToolCallingOmitsToolsJSONBlock() async {
        let registry = ToolRegistry()
        await registry.register(MockTool(name: "read_file", description: "Read a file"))

        let composition = await AgentLoop.buildSystemPromptComposition(
            registry: registry,
            usesNativeToolCalling: true
        )

        XCTAssertFalse(composition.prompt.contains("\"name\" : \"read_file\""))
        // An empty tools block means there's nothing to show — the section is
        // omitted entirely (no `<!-- SECTION:tools -->` pair at all),
        // rather than being rendered empty, so it has no token estimate.
        XCTAssertNil(composition.sectionTokenEstimates[.tools])
        XCTAssertFalse(composition.prompt.contains("SECTION:tools"))
    }

    func testNativeToolCallingOmitsTextWireFormatInstructions() async {
        let registry = ToolRegistry()
        let composition = await AgentLoop.buildSystemPromptComposition(
            registry: registry,
            dialect: .qwen,
            usesNativeToolCalling: true
        )

        XCTAssertFalse(composition.prompt.contains("<tool_call>"))
        XCTAssertFalse(composition.prompt.contains("respond with the tool call in this format"))
    }

    func testLocalBackendStillIncludesToolsJSONBlockAndInstructions() async {
        let registry = ToolRegistry()
        await registry.register(MockTool(name: "read_file", description: "Read a file"))

        let composition = await AgentLoop.buildSystemPromptComposition(
            registry: registry,
            dialect: .qwen,
            usesNativeToolCalling: false
        )

        XCTAssertTrue(composition.prompt.contains("\"name\" : \"read_file\""))
        XCTAssertTrue(composition.prompt.contains("respond with the tool call in this format"))
    }
}
