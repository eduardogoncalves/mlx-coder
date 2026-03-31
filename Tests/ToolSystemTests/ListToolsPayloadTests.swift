import XCTest
@testable import NativeAgent

private struct MockTool: Tool {
    let name: String
    let description: String
    let parameters = JSONSchema(type: "object", properties: [:], required: [])

    func execute(arguments: [String : Any]) async throws -> ToolResult {
        .success("ok")
    }
}

private actor SeenConfigs {
    private(set) var endpointsByName: [String: String] = [:]

    func record(_ config: MCPClient.ServerConfig) {
        endpointsByName[config.name] = config.endpointURL ?? config.command
    }

    func endpoint(for name: String) -> String? {
        endpointsByName[name]
    }

    func count() -> Int {
        endpointsByName.count
    }
}

private struct MCPDiscoveryError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

final class ListToolsPayloadTests: XCTestCase {
    func testListToolsShouldFailOnlyWhenStrictAndErrorsPresent() {
        XCTAssertFalse(listToolsShouldFail(mcpErrorMessages: [], strict: false))
        XCTAssertFalse(listToolsShouldFail(mcpErrorMessages: [], strict: true))
        XCTAssertFalse(listToolsShouldFail(mcpErrorMessages: ["mcp error"], strict: false))
        XCTAssertTrue(listToolsShouldFail(mcpErrorMessages: ["mcp error"], strict: true))
    }

    func testBuildListToolsPayloadUsesCLIConfigOverrideByName() async {
        let runtimeConfig = RuntimeConfig(
            mcpServers: [
                .init(name: "docs", endpoint: "http://runtime.example", command: nil, arguments: nil, environment: nil, timeoutSeconds: 10, enabled: true),
                .init(name: "disabled", endpoint: "http://disabled.example", command: nil, arguments: nil, environment: nil, timeoutSeconds: 10, enabled: false)
            ]
        )

        let recorder = SeenConfigs()
        let cliConfig = MCPClient.ServerConfig(
            name: "docs",
            command: "http://cli.example",
            endpointURL: "http://cli.example",
            timeoutSeconds: 20
        )

        let result = await buildListToolsPayload(
            workspaceRoot: "/tmp/workspace",
            isDotnetWorkspace: false,
            runtimeConfig: runtimeConfig,
            cliMCPConfig: cliConfig,
            discoverMCPTools: { config in
                await recorder.record(config)
                return [
                    MockTool(name: "mcp_docs_ping", description: "Ping endpoint")
                ]
            }
        )

        let seenCount = await recorder.count()
        let docsEndpoint = await recorder.endpoint(for: "docs")

        XCTAssertNil(result.payload.mcpError)
        XCTAssertEqual(seenCount, 1)
        XCTAssertEqual(docsEndpoint, "http://cli.example")
        XCTAssertTrue(result.payload.tools.contains { $0.name == "mcp_docs_ping" && $0.category == "mcp" })
    }

    func testBuildListToolsPayloadAggregatesMCPDiscoveryErrors() async {
        let runtimeConfig = RuntimeConfig(
            mcpServers: [
                .init(name: "alpha", endpoint: "http://alpha.example", command: nil, arguments: nil, environment: nil, timeoutSeconds: 10, enabled: true),
                .init(name: "beta", endpoint: "http://beta.example", command: nil, arguments: nil, environment: nil, timeoutSeconds: 10, enabled: true)
            ]
        )

        let result = await buildListToolsPayload(
            workspaceRoot: "/tmp/workspace",
            isDotnetWorkspace: false,
            runtimeConfig: runtimeConfig,
            cliMCPConfig: nil,
            discoverMCPTools: { config in
                throw MCPDiscoveryError(message: "unreachable-\(config.name)")
            }
        )

        XCTAssertNotNil(result.payload.mcpError)
        XCTAssertEqual(result.mcpErrorMessages.count, 2)
        XCTAssertTrue(result.mcpErrorMessages[0].contains("alpha: unreachable-alpha"))
        XCTAssertTrue(result.mcpErrorMessages[1].contains("beta: unreachable-beta"))

        // Ensure no MCP tools were appended on failures.
        XCTAssertFalse(result.payload.tools.contains { $0.category == "mcp" })
    }

    func testBuildListToolsPayloadSupportsRuntimeStdioMCPServer() async {
        let runtimeConfig = RuntimeConfig(
            mcpServers: [
                .init(
                    name: "local-stdio",
                    endpoint: nil,
                    command: "/usr/bin/env",
                    arguments: ["echo", "noop"],
                    environment: ["MCP_MODE": "test"],
                    timeoutSeconds: 5,
                    enabled: true
                )
            ]
        )

        let recorder = SeenConfigs()
        let result = await buildListToolsPayload(
            workspaceRoot: "/tmp/workspace",
            isDotnetWorkspace: false,
            runtimeConfig: runtimeConfig,
            cliMCPConfig: nil,
            discoverMCPTools: { config in
                await recorder.record(config)
                return [MockTool(name: "mcp_local_stdio_ping", description: "Ping stdio")]
            }
        )

        let endpoint = await recorder.endpoint(for: "local-stdio")
        XCTAssertNil(result.payload.mcpError)
        XCTAssertEqual(endpoint, "/usr/bin/env")
        XCTAssertTrue(result.payload.tools.contains { $0.name == "mcp_local_stdio_ping" && $0.category == "mcp" })
    }

    func testBuildListToolsPayloadIncludesDiscoveredSkillsMetadata() async throws {
        let workspace = makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(atPath: workspace) }

        let skillDir = workspace + "/.github/skills/security"
        try FileManager.default.createDirectory(atPath: skillDir, withIntermediateDirectories: true)
        try """
        ---
        name: security
        description: Security review helper
        tags: [security, review]
        ---
        """.write(toFile: skillDir + "/SKILL.md", atomically: true, encoding: .utf8)

        let result = await buildListToolsPayload(
            workspaceRoot: workspace,
            isDotnetWorkspace: false,
            runtimeConfig: RuntimeConfig(),
            cliMCPConfig: nil,
            discoverMCPTools: { _ in [] }
        )

        XCTAssertEqual(result.payload.skills.count, 1)
        XCTAssertEqual(result.payload.skills[0].name, "security")
        XCTAssertEqual(result.payload.skills[0].tags, ["security", "review"])
    }

    func testTaskToolDescriptionMentionsProfilesAndIsolation() async {
        let result = await buildListToolsPayload(
            workspaceRoot: "/tmp/workspace",
            isDotnetWorkspace: false,
            runtimeConfig: RuntimeConfig(),
            cliMCPConfig: nil,
            discoverMCPTools: { _ in [] }
        )

        let taskEntry = result.payload.tools.first { $0.name == "task" }
        XCTAssertNotNil(taskEntry)
        XCTAssertTrue(taskEntry?.description.contains("profiles") == true)
        XCTAssertTrue(taskEntry?.description.contains("isolated") == true)

        XCTAssertTrue(result.payload.taskCapabilities.profiles.contains("general"))
        XCTAssertTrue(result.payload.taskCapabilities.profiles.contains("security_review"))
        XCTAssertEqual(
            result.payload.taskCapabilities.isolationOptions,
            ["isolate", "isolation_directory", "cleanup_isolation"]
        )
    }

    private func makeTemporaryWorkspace() -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path()
    }
}
