import XCTest
@testable import NativeAgent

final class RuntimeConfigTests: XCTestCase {
    func testWorkspaceConfigOverridesUserConfigByName() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let userPath = tempDir.appendingPathComponent("user.json").path
        let workspacePath = tempDir.appendingPathComponent("workspace.json").path

        let userJSON = """
        {
          "mcpServers": [
            {"name":"shared","endpoint":"http://user.example","timeoutSeconds":10},
            {"name":"userOnly","endpoint":"http://user-only.example","timeoutSeconds":5}
          ]
        }
        """

        let workspaceJSON = """
        {
          "mcpServers": [
            {"name":"shared","endpoint":"http://workspace.example","timeoutSeconds":20},
            {"name":"workspaceOnly","endpoint":"http://workspace-only.example","timeoutSeconds":15}
          ]
        }
        """

        try userJSON.write(toFile: userPath, atomically: true, encoding: .utf8)
        try workspaceJSON.write(toFile: workspacePath, atomically: true, encoding: .utf8)

        let merged = RuntimeConfigLoader.loadMerged(
            workspaceRoot: tempDir.path,
            userConfigPath: userPath,
            workspaceConfigPath: workspacePath
        )

        XCTAssertEqual(merged.mcpServers.count, 3)

        let shared = merged.mcpServers.first(where: { $0.name == "shared" })
        XCTAssertEqual(shared?.endpoint, "http://workspace.example")
        XCTAssertEqual(shared?.timeoutSeconds, 20)

        XCTAssertNotNil(merged.mcpServers.first(where: { $0.name == "userOnly" }))
        XCTAssertNotNil(merged.mcpServers.first(where: { $0.name == "workspaceOnly" }))
    }

    func testWorkspaceDefaultsOverrideUserDefaults() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-config-defaults-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let userPath = tempDir.appendingPathComponent("user-defaults.json").path
        let workspacePath = tempDir.appendingPathComponent("workspace-defaults.json").path

        let userJSON = """
        {
          "defaultApprovalMode": "yolo",
          "defaultSandbox": false,
          "defaultDryRun": true,
          "defaultPolicyFile": "user-policy.json",
          "defaultAuditLogPath": "user-audit.jsonl"
        }
        """

        let workspaceJSON = """
        {
          "defaultApprovalMode": "auto-edit",
          "defaultSandbox": true,
          "defaultPolicyFile": "workspace-policy.json"
        }
        """

        try userJSON.write(toFile: userPath, atomically: true, encoding: .utf8)
        try workspaceJSON.write(toFile: workspacePath, atomically: true, encoding: .utf8)

        let merged = RuntimeConfigLoader.loadMerged(
            workspaceRoot: tempDir.path,
            userConfigPath: userPath,
            workspaceConfigPath: workspacePath
        )

        XCTAssertEqual(merged.defaultApprovalMode, "auto-edit")
        XCTAssertEqual(merged.defaultSandbox, true)
        XCTAssertEqual(merged.defaultDryRun, true)
        XCTAssertEqual(merged.defaultPolicyFile, "workspace-policy.json")
        XCTAssertEqual(merged.defaultAuditLogPath, "user-audit.jsonl")
    }

    func testRuntimeConfigDecodesCommandBasedMCPServerWithoutEndpoint() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-config-command-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let workspacePath = tempDir.appendingPathComponent("workspace-command.json").path
        let workspaceJSON = """
        {
          "mcpServers": [
            {
              "name": "local-stdio",
              "command": "npx",
              "arguments": ["-y", "@modelcontextprotocol/server-filesystem", "."],
              "environment": {"NODE_ENV": "production"},
              "timeoutSeconds": 25,
              "enabled": true
            }
          ]
        }
        """

        try workspaceJSON.write(toFile: workspacePath, atomically: true, encoding: .utf8)

        let merged = RuntimeConfigLoader.loadMerged(
            workspaceRoot: tempDir.path,
            userConfigPath: tempDir.appendingPathComponent("missing-user.json").path,
            workspaceConfigPath: workspacePath
        )

        XCTAssertEqual(merged.mcpServers.count, 1)
        let server = merged.mcpServers[0]
        XCTAssertEqual(server.name, "local-stdio")
        XCTAssertNil(server.endpoint)
        XCTAssertEqual(server.command, "npx")
        XCTAssertEqual(server.arguments ?? [], ["-y", "@modelcontextprotocol/server-filesystem", "."])
        XCTAssertEqual(server.environment?["NODE_ENV"], "production")
    }

    func testWorkspaceMCPSettingsOverrideUserSettings() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-config-mcp-settings-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let userPath = tempDir.appendingPathComponent("user-mcp-settings.json").path
        let workspacePath = tempDir.appendingPathComponent("workspace-mcp-settings.json").path

        let userJSON = """
        {
          "mcpSettings": {
            "allowedServers": ["docs", "metrics"],
            "blockedServers": ["legacy"]
          }
        }
        """

        let workspaceJSON = """
        {
          "mcpSettings": {
            "allowedServers": ["docs"],
            "blockedServers": ["metrics"]
          }
        }
        """

        try userJSON.write(toFile: userPath, atomically: true, encoding: .utf8)
        try workspaceJSON.write(toFile: workspacePath, atomically: true, encoding: .utf8)

        let merged = RuntimeConfigLoader.loadMerged(
            workspaceRoot: tempDir.path,
            userConfigPath: userPath,
            workspaceConfigPath: workspacePath
        )

        XCTAssertEqual(merged.mcpSettings?.allowedServers ?? [], ["docs"])
        XCTAssertEqual(merged.mcpSettings?.blockedServers ?? [], ["metrics"])
    }
}
