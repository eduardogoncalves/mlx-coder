// Tests for per-role model assignments (planner/executor/reviewer): merge
// precedence between the user config and a workspace override, and the
// AgentRolesConfig subscript/assignments helpers.
//
// Note: mirrors RuntimeConfigTests's pattern of pointing loadMerged at
// explicit temp file paths, so these tests never touch the real
// ~/.mlx-coder/config.json.

import XCTest
@testable import MLXCoder

final class AgentRoleConfigTests: XCTestCase {
    func testWorkspaceOverridesUserPerRole() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-role-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let userPath = tempDir.appendingPathComponent("user.json").path
        let workspacePath = tempDir.appendingPathComponent("workspace.json").path

        let userJSON = """
        {
          "agentRoles": {
            "planner": "openrouter:qwen/qwen3-235b-a22b",
            "executor": "mlx-community/Qwen3.5-9B-4bit",
            "reviewer": "openrouter:anthropic/claude-3.5-sonnet"
          }
        }
        """
        let workspaceJSON = """
        {
          "agentRoles": {
            "executor": "mlx-community/OtherModel-4bit"
          }
        }
        """

        try userJSON.write(toFile: userPath, atomically: true, encoding: .utf8)
        try workspaceJSON.write(toFile: workspacePath, atomically: true, encoding: .utf8)

        let merged = AgentRoleRegistry.current(
            workspaceRoot: tempDir.path,
            userConfigPath: userPath,
            workspaceConfigPath: workspacePath
        )

        XCTAssertEqual(merged.planner, "openrouter:qwen/qwen3-235b-a22b")
        XCTAssertEqual(merged.executor, "mlx-community/OtherModel-4bit")
        XCTAssertEqual(merged.reviewer, "openrouter:anthropic/claude-3.5-sonnet")
    }

    func testMissingFilesYieldNoAssignments() {
        let merged = AgentRoleRegistry.current(
            workspaceRoot: "/nonexistent-workspace-\(UUID().uuidString)",
            userConfigPath: "/nonexistent-user-\(UUID().uuidString).json",
            workspaceConfigPath: "/nonexistent-workspace-config-\(UUID().uuidString).json"
        )
        XCTAssertNil(merged.planner)
        XCTAssertNil(merged.executor)
        XCTAssertNil(merged.reviewer)
        XCTAssertTrue(merged.assignments.isEmpty)
    }

    func testSubscriptGetSet() {
        var config = AgentRolesConfig()
        config["planner"] = "local/model-a"
        config["EXECUTOR"] = "local/model-b"
        XCTAssertEqual(config.planner, "local/model-a")
        XCTAssertEqual(config.executor, "local/model-b")
        XCTAssertEqual(config["planner"], "local/model-a")
        XCTAssertNil(config["unknown_role"])
    }

    func testAssignmentsPreservesRoleOrderAndSkipsUnset() {
        let config = AgentRolesConfig(executor: "local/model-b", reviewer: "local/model-c")
        let assignments = config.assignments
        XCTAssertEqual(assignments.map(\.role), ["executor", "reviewer"])
        XCTAssertEqual(config.roleModelMap, ["executor": "local/model-b", "reviewer": "local/model-c"])
    }
}
