import XCTest
@testable import NativeAgent

private struct IntegrationMockTool: Tool {
    let name: String
    let description: String
    let parameters = JSONSchema(type: "object", properties: [:], required: [])

    func execute(arguments: [String : Any]) async throws -> ToolResult {
        .success("ok")
    }
}

private actor IntegrationSeenConfigs {
    private(set) var seenNames: [String] = []
    private(set) var seenEndpoints: [String: String] = [:]

    func record(_ config: MCPClient.ServerConfig) {
        seenNames.append(config.name)
        seenEndpoints[config.name] = config.endpointURL ?? config.command
    }

    func names() -> [String] {
        seenNames
    }

    func endpoint(for name: String) -> String? {
        seenEndpoints[name]
    }
}

final class ListToolsConfigIntegrationTests: XCTestCase {
    func testListToolsPayloadLoadsWorkspaceConfigAndSkipsDisabledServers() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("list-tools-config-int-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let workspaceConfigPath = tempDir.appendingPathComponent(".native-agent-config.json").path
        let configJSON = """
        {
          "mcpServers": [
            {"name":"enabled","endpoint":"http://enabled.example","timeoutSeconds":10,"enabled":true},
            {"name":"disabled","endpoint":"http://disabled.example","timeoutSeconds":10,"enabled":false}
          ]
        }
        """
        try configJSON.write(toFile: workspaceConfigPath, atomically: true, encoding: .utf8)

        let runtimeConfig = RuntimeConfigLoader.loadMerged(workspaceRoot: tempDir.path)
        let recorder = IntegrationSeenConfigs()

        let result = await buildListToolsPayload(
            workspaceRoot: tempDir.path,
            isDotnetWorkspace: false,
            runtimeConfig: runtimeConfig,
            cliMCPConfig: nil,
            discoverMCPTools: { config in
                await recorder.record(config)
                return [IntegrationMockTool(name: "mcp_\(config.name)_tool", description: "Tool from \(config.name)")]
            }
        )

        let seenNames = await recorder.names()

        XCTAssertNil(result.payload.mcpError)
        XCTAssertEqual(seenNames, ["enabled"])
        XCTAssertTrue(result.payload.tools.contains { $0.name == "mcp_enabled_tool" && $0.category == "mcp" })
        XCTAssertFalse(result.payload.tools.contains { $0.name.contains("disabled") })
    }

    func testListToolsPayloadCliOverrideWinsOverWorkspaceConfig() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("list-tools-config-override-int-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let workspaceConfigPath = tempDir.appendingPathComponent(".native-agent-config.json").path
        let configJSON = """
        {
          "mcpServers": [
            {"name":"docs","endpoint":"http://workspace.example","timeoutSeconds":10,"enabled":true}
          ]
        }
        """
        try configJSON.write(toFile: workspaceConfigPath, atomically: true, encoding: .utf8)

        let runtimeConfig = RuntimeConfigLoader.loadMerged(workspaceRoot: tempDir.path)
        let recorder = IntegrationSeenConfigs()

        let result = await buildListToolsPayload(
            workspaceRoot: tempDir.path,
            isDotnetWorkspace: false,
            runtimeConfig: runtimeConfig,
            cliMCPConfig: MCPClient.ServerConfig(
                name: "docs",
                command: "http://cli.example",
                endpointURL: "http://cli.example",
                timeoutSeconds: 15
            ),
            discoverMCPTools: { config in
                await recorder.record(config)
                return [IntegrationMockTool(name: "mcp_docs_tool", description: "docs")]
            }
        )

        let docsEndpoint = await recorder.endpoint(for: "docs")

        XCTAssertNil(result.payload.mcpError)
        XCTAssertEqual(docsEndpoint, "http://cli.example")
        XCTAssertTrue(result.payload.tools.contains { $0.name == "mcp_docs_tool" })
    }

        func testListToolsPayloadAppliesMCPAllowAndBlockLists() async throws {
                let tempDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent("list-tools-config-allow-block-int-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: tempDir) }

                let workspaceConfigPath = tempDir.appendingPathComponent(".native-agent-config.json").path
                let configJSON = """
                {
                    "mcpServers": [
                        {"name":"docs","endpoint":"http://docs.example","timeoutSeconds":10,"enabled":true},
                        {"name":"git","endpoint":"http://git.example","timeoutSeconds":10,"enabled":true},
                        {"name":"metrics","endpoint":"http://metrics.example","timeoutSeconds":10,"enabled":true}
                    ],
                    "mcpSettings": {
                        "allowedServers": ["docs", "git", "metrics"],
                        "blockedServers": ["git"]
                    }
                }
                """
                try configJSON.write(toFile: workspaceConfigPath, atomically: true, encoding: .utf8)

                let runtimeConfig = RuntimeConfigLoader.loadMerged(workspaceRoot: tempDir.path)
                let recorder = IntegrationSeenConfigs()

                let result = await buildListToolsPayload(
                        workspaceRoot: tempDir.path,
                        isDotnetWorkspace: false,
                        runtimeConfig: runtimeConfig,
                        cliMCPConfig: nil,
                        discoverMCPTools: { config in
                                await recorder.record(config)
                                return [IntegrationMockTool(name: "mcp_\(config.name)_tool", description: "Tool from \(config.name)")]
                        }
                )

                let seenNames = await recorder.names()

                XCTAssertNil(result.payload.mcpError)
                XCTAssertEqual(seenNames, ["docs", "metrics"])
                XCTAssertTrue(result.payload.tools.contains { $0.name == "mcp_docs_tool" })
                XCTAssertTrue(result.payload.tools.contains { $0.name == "mcp_metrics_tool" })
                XCTAssertFalse(result.payload.tools.contains { $0.name == "mcp_git_tool" })
        }

        func testListToolsPayloadCliIncludeExcludeOverridesRuntimeSettings() async throws {
                let tempDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent("list-tools-config-cli-include-exclude-int-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: tempDir) }

                let workspaceConfigPath = tempDir.appendingPathComponent(".native-agent-config.json").path
                let configJSON = """
                {
                    "mcpServers": [
                        {"name":"docs","endpoint":"http://docs.example","timeoutSeconds":10,"enabled":true},
                        {"name":"git","endpoint":"http://git.example","timeoutSeconds":10,"enabled":true},
                        {"name":"metrics","endpoint":"http://metrics.example","timeoutSeconds":10,"enabled":true}
                    ],
                    "mcpSettings": {
                        "allowedServers": ["docs"],
                        "blockedServers": ["metrics"]
                    }
                }
                """
                try configJSON.write(toFile: workspaceConfigPath, atomically: true, encoding: .utf8)

                let runtimeConfig = RuntimeConfigLoader.loadMerged(workspaceRoot: tempDir.path)
                let recorder = IntegrationSeenConfigs()

                let result = await buildListToolsPayload(
                        workspaceRoot: tempDir.path,
                        isDotnetWorkspace: false,
                        runtimeConfig: runtimeConfig,
                        cliMCPConfig: nil,
                        mcpIncludeOverride: "docs,metrics",
                        mcpExcludeOverride: "docs",
                        discoverMCPTools: { config in
                                await recorder.record(config)
                                return [IntegrationMockTool(name: "mcp_\(config.name)_tool", description: "Tool from \(config.name)")]
                        }
                )

                let seenNames = await recorder.names()

                XCTAssertNil(result.payload.mcpError)
                XCTAssertEqual(seenNames, ["metrics"])
                XCTAssertTrue(result.payload.tools.contains { $0.name == "mcp_metrics_tool" })
                XCTAssertFalse(result.payload.tools.contains { $0.name == "mcp_docs_tool" })
                XCTAssertFalse(result.payload.tools.contains { $0.name == "mcp_git_tool" })
        }
}
