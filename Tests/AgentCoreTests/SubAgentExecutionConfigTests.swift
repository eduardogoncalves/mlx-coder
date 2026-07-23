// Regression test: a TaskTool-constructed sub-agent must not default to PLAN
// mode. AgentLoop.init has no `mode` parameter — the stored property's
// default is `.plan` — so without `configureForSubAgentExecution`, a
// sub-agent's first destructive tool call (write_file, bash, ...) hits the
// PLAN-mode "switch to AGENT mode?" prompt, whose framing makes no sense for
// a sub-agent (it's always agent-mode). The tool call still needs approval
// either way — a sub-agent inherits the parent orchestrator's own live
// approval state rather than always requiring or always skipping it.

import XCTest
@testable import MLXCoder

final class SubAgentExecutionConfigTests: XCTestCase {
    private func makeTemporaryWorkspace() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("subagent-exec-config-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private func makeSubAgent(workspace: String) -> AgentLoop {
        AgentLoop(
            modelContainer: nil,
            registry: ToolRegistry(),
            permissions: PermissionEngine(workspaceRoot: workspace),
            generationConfig: GenerationEngine.Config(),
            frontend: NullAgentFrontend(),
            systemPrompt: "test",
            modelPath: "mlx-community/test-model",
            workspace: workspace,
            role: "executor"
        )
    }

    func testFreshSubAgentDefaultsToPlanModeWithoutConfiguration() async throws {
        let workspace = makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(atPath: workspace) }

        let subAgent = makeSubAgent(workspace: workspace)
        let mode = await subAgent.mode
        XCTAssertEqual(mode, .plan, "sanity check: this is exactly the trap configureForSubAgentExecution must fix")
    }

    func testConfigureForSubAgentExecutionSwitchesToAgentMode() async throws {
        let workspace = makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(atPath: workspace) }

        let subAgent = makeSubAgent(workspace: workspace)
        await subAgent.configureForSubAgentExecution(taskType: .coding)

        let mode = await subAgent.mode
        let taskType = await subAgent.taskType
        XCTAssertEqual(mode, .agent, "PLAN mode's 'switch to AGENT mode?' framing makes no sense for a sub-agent")
        XCTAssertEqual(taskType, .coding)
    }

    /// Regression test: mutating tool calls inside a sub-agent still need
    /// approval, exactly like the orchestrator's own calls would — a
    /// sub-agent must NOT unconditionally auto-approve everything just
    /// because a human approved the `task(...)` delegation itself. Without
    /// an explicit parent approval state, the safe default is "still ask".
    func testConfigureForSubAgentExecutionDefaultsToRequiringApproval() async throws {
        let workspace = makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(atPath: workspace) }

        let subAgent = makeSubAgent(workspace: workspace)
        await subAgent.configureForSubAgentExecution(taskType: .coding)
        let autoApprove = await subAgent.autoApproveAllTools
        let approvedCommands = await subAgent.sessionApprovedToolCommands
        XCTAssertFalse(autoApprove)
        XCTAssertTrue(approvedCommands.isEmpty)
    }

    /// A sub-agent inherits the parent orchestrator's *live* approval state
    /// (autopilot mode, commands already allow-listed this session) rather
    /// than hardcoding either always-approve or always-ask — matching
    /// exactly what would happen if the orchestrator made the same call itself.
    func testConfigureForSubAgentExecutionInheritsParentApprovalState() async throws {
        let workspace = makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(atPath: workspace) }

        let subAgent = makeSubAgent(workspace: workspace)
        await subAgent.configureForSubAgentExecution(
            taskType: .coding,
            parentAutoApproveAllTools: true,
            parentSessionApprovedToolCommands: ["bash npm test"]
        )
        let autoApprove = await subAgent.autoApproveAllTools
        let approvedCommands = await subAgent.sessionApprovedToolCommands
        XCTAssertTrue(autoApprove)
        XCTAssertEqual(approvedCommands, ["bash npm test"])
    }

    /// Regression test: `taskType: .coding` also makes `processUserMessage`
    /// try to run its own interactive git worktree/branch setup on first use
    /// (`initializeGitOrchestration`) — every AgentLoop has a non-nil
    /// `interactiveInput`, so without this guard every sub-agent dispatch hit
    /// the same blocking "Coding mode git setup" picker a human session gets,
    /// corrupting the TUI layout mid-generation. A sub-agent must operate
    /// inside whatever workspace TaskTool already gave it — it doesn't own
    /// git lifecycle.
    func testConfigureForSubAgentExecutionSkipsGitOrchestrationInitialization() async throws {
        let workspace = makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(atPath: workspace) }

        let subAgent = makeSubAgent(workspace: workspace)
        await subAgent.configureForSubAgentExecution(taskType: .coding)
        let skipsGitInit = await subAgent.skipGitOrchestrationInitialization
        XCTAssertTrue(skipsGitInit, "sub-agents must never trigger their own git worktree/branch setup wizard")
    }

    /// Regression test: `setMode` (called internally) computes `pendingReload`
    /// by comparing `modelPath` against the still-nil `loaded*` tracking
    /// fields on a freshly-constructed instance — always true, even though
    /// TaskTool just handed the sub-agent an already-correctly-loaded (or
    /// intentionally nil, for online backends) container. Without this fix,
    /// every sub-agent's first turn wastefully reloads the model it was just
    /// given before doing anything else.
    func testConfigureForSubAgentExecutionDoesNotFlagAPendingReload() async throws {
        let workspace = makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(atPath: workspace) }

        let subAgent = makeSubAgent(workspace: workspace)
        await subAgent.configureForSubAgentExecution(taskType: .coding)
        let pendingReload = await subAgent.pendingReload
        let loadedModelPath = await subAgent.loadedModelPath
        XCTAssertFalse(pendingReload, "a sub-agent must not reload the model it was just constructed with")
        XCTAssertEqual(loadedModelPath, "mlx-community/test-model")
    }
}
