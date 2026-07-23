// Verifies the actual claim behind the orchestrator redesign: the top-level
// system prompt's <tools> block only ever contains orchestration tools
// (task/todo/plan_file/log_knowledge/search_knowledge), regardless of how
// many tools are registered for `task` to hand out to sub-agents — and a
// sub-agent's own prompt only contains the tools its profile was actually
// given, not the full registry.

import XCTest
@testable import MLXCoder

final class OrchestratorPromptSizeTests: XCTestCase {
    private func makeTemporaryWorkspace() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orch-prompt-size-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    /// Registers a representative slice of what a real session ends up with
    /// in AgentLoop.registerToolsInternal — enough to prove filtering works,
    /// not an exhaustive mirror of every built-in tool.
    private func makeFullSessionRegistry(workspace: String) async -> ToolRegistry {
        let permissions = PermissionEngine(workspaceRoot: workspace)
        let registry = ToolRegistry()
        await registry.register(ReadFileTool(permissions: permissions))
        await registry.register(WriteFileTool(permissions: permissions))
        await registry.register(EditFileTool(permissions: permissions))
        await registry.register(PatchTool(permissions: permissions))
        await registry.register(ListDirTool(permissions: permissions))
        await registry.register(GrepTool(permissions: permissions))
        await registry.register(GlobTool(permissions: permissions))
        await registry.register(BashTool(permissions: permissions))
        await registry.register(TodoTool(workspaceRoot: workspace))
        await registry.register(PlanFileTool(permissions: permissions))
        await registry.register(LogKnowledgeTool(workspaceRoot: workspace))
        await registry.register(SearchKnowledgeTool(workspaceRoot: workspace))
        await registry.register(WebSearchTool())
        await registry.register(TaskTool(
            modelContainer: nil,
            permissions: permissions,
            generationConfig: GenerationEngine.Config(),
            modelPath: "mlx-community/test-model",
            useSandbox: false,
            parentRegistry: registry,
            frontend: NullAgentFrontend()
        ))
        return registry
    }

    func testOrchestratorToolsBlockOnlyContainsOrchestrationToolsRegardlessOfRegistrySize() async throws {
        let workspace = makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(atPath: workspace) }

        let registry = await makeFullSessionRegistry(workspace: workspace)
        let registeredCount = await registry.count
        XCTAssertGreaterThanOrEqual(registeredCount, 13, "sanity check: registry should hold every tool listed above")

        let orchestratorComposition = await AgentLoop.buildSystemPromptComposition(
            registry: registry,
            mode: .agent,
            workspaceRoot: workspace,
            toolPromptFilterOverride: AgentLoop.orchestratorToolPromptFilter(mode: .agent)
        )

        // Only the 5 orchestration tool names may appear as `"name" : "..."`
        // entries in the rendered <tools> block.
        for hiddenTool in ["read_file", "write_file", "edit_file", "patch", "list_dir", "grep", "glob", "bash", "web_search"] {
            XCTAssertFalse(
                orchestratorComposition.prompt.contains("\"name\" : \"\(hiddenTool)\""),
                "orchestrator prompt should not advertise '\(hiddenTool)'"
            )
        }
        for visibleTool in ["task", "todo", "plan_file", "log_knowledge", "search_knowledge"] {
            XCTAssertTrue(
                orchestratorComposition.prompt.contains("\"name\" : \"\(visibleTool)\""),
                "orchestrator prompt should advertise '\(visibleTool)'"
            )
        }

        // Compare against the same registry with no filter at all (the old,
        // pre-orchestrator behavior) to prove this is a real reduction, not
        // just a different arrangement of the same content.
        let unfilteredComposition = await AgentLoop.buildSystemPromptComposition(
            registry: registry,
            mode: .agent,
            workspaceRoot: workspace,
            toolPromptFilterOverride: .unfiltered
        )

        let orchestratorToolsTokens = orchestratorComposition.sectionTokenEstimates[.tools] ?? 0
        let unfilteredToolsTokens = unfilteredComposition.sectionTokenEstimates[.tools] ?? 0
        XCTAssertLessThan(
            orchestratorToolsTokens * 2, unfilteredToolsTokens,
            "orchestrator tools block (\(orchestratorToolsTokens) tokens) should be well under half of the unfiltered block (\(unfilteredToolsTokens) tokens)"
        )

        // The orchestrator's dedicated instructions (explaining the manager
        // pattern — see `orchestratorInstructions` in
        // AgentLoop+SystemPrompt.swift) must not make the "core" section
        // *bigger* than the generic direct-tool-use instructions it replaces;
        // otherwise trimming the tools block would just be offset elsewhere.
        let plainComposition = await AgentLoop.buildSystemPromptComposition(
            registry: registry,
            mode: .agent,
            workspaceRoot: workspace
        )
        let orchestratorCoreTokens = orchestratorComposition.sectionTokenEstimates[.core] ?? 0
        let plainCoreTokens = plainComposition.sectionTokenEstimates[.core] ?? 0
        XCTAssertLessThanOrEqual(
            orchestratorCoreTokens, plainCoreTokens,
            "orchestrator instructions (\(orchestratorCoreTokens) tokens) should not be larger than the generic instructions they replace (\(plainCoreTokens) tokens)"
        )

        // Must explicitly forbid doing planning/implementation work in its
        // own response text (not just structurally block tool calls) — a
        // model can still narrate a full plan, diff, or shell command in
        // plain prose even with no tools to back it up.
        XCTAssertTrue(orchestratorComposition.prompt.contains("Do NOT do the work yourself in your response text"))
        XCTAssertFalse(
            orchestratorComposition.prompt.contains("if the approach isn't already obvious"),
            "must not give the model an escape hatch to skip delegating research/planning"
        )

        // Regression: models were emitting `"tool_name"` instead of `"name"`
        // for the `task` call. The instructions must show the exact wire
        // format literally, not just describe it in prose.
        XCTAssertTrue(
            orchestratorComposition.prompt.contains(#"{"name": "task", "arguments": {"profile": "executor""#),
            "orchestrator instructions must include a literal example of the task call's wire format"
        )
        XCTAssertTrue(
            orchestratorComposition.prompt.contains("never \"tool_name\" or \"tool_call\""),
            "must explicitly rule out the field names models were mistakenly using"
        )

        // Regression: the final reminder used to say "no filesystem tools"
        // right after the PATHS note was already omitted for having none —
        // reads fine standalone, but contradicted a stray leftover mention
        // elsewhere. Assert the corrected, self-consistent phrasing survives.
        XCTAssertTrue(
            orchestratorComposition.prompt.contains("You have no filesystem tools of your own."),
            "final reminder must consistently state the orchestrator has no filesystem tools"
        )
    }

    func testSubAgentPromptOnlyContainsItsOwnProfileToolsNotTheFullRegistry() async throws {
        let workspace = makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(atPath: workspace) }
        let permissions = PermissionEngine(workspaceRoot: workspace)

        // A narrow "filesystem" sub-agent registry, as TaskTool would build it —
        // only the tools its profile preset (or an explicit `tools` list) named.
        let subRegistry = ToolRegistry()
        await subRegistry.register(ReadFileTool(permissions: permissions))
        await subRegistry.register(WriteFileTool(permissions: permissions))
        await subRegistry.register(EditFileTool(permissions: permissions))

        let subAgentComposition = await AgentLoop.buildSystemPromptComposition(
            registry: subRegistry,
            mode: .agent,
            workspaceRoot: workspace,
            toolPromptFilterOverride: AgentLoop.subagentToolPromptFilter(role: "filesystem")
        )

        for visibleTool in ["read_file", "write_file", "edit_file"] {
            XCTAssertTrue(subAgentComposition.prompt.contains("\"name\" : \"\(visibleTool)\""))
        }
        // Tools that were never registered into this sub-agent's own registry
        // (bash, task, web_search, ...) must not appear, even though they
        // exist elsewhere in a real session's parent registry.
        for hiddenTool in ["bash", "task", "web_search", "grep", "glob"] {
            XCTAssertFalse(subAgentComposition.prompt.contains("\"name\" : \"\(hiddenTool)\""))
        }
    }

    // MARK: - runtime section: dynamic PATHS note + orchestrator-only bookend reminder

    func testOrchestratorRuntimeSectionOmitsPathsNoteAndKeepsFinalReminder() async throws {
        let workspace = makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(atPath: workspace) }

        // The orchestrator's registry still holds filesystem tools (`task`
        // hands them to sub-agents), but it can't call them directly, so the
        // PATHS note (which names path-taking tools) must not mention any.
        let registry = await makeFullSessionRegistry(workspace: workspace)

        let composition = await AgentLoop.buildSystemPromptComposition(
            registry: registry,
            mode: .agent,
            workspaceRoot: workspace,
            toolPromptFilterOverride: AgentLoop.orchestratorToolPromptFilter(mode: .agent)
        )

        XCTAssertFalse(composition.prompt.contains("PATHS: All `path` arguments"))
        // The orchestrator persists across many turns, so it keeps the
        // bookend reminder that fights long-context drift.
        XCTAssertTrue(composition.prompt.contains("FINAL REMINDER — WORKSPACE ROOT"))
    }

    func testSubAgentRuntimeSectionListsOnlyItsOwnPathTakingToolsAndOmitsFinalReminder() async throws {
        let workspace = makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(atPath: workspace) }
        let permissions = PermissionEngine(workspaceRoot: workspace)

        // A "terminal" sub-agent: bash only, no path-taking filesystem tools.
        let terminalRegistry = ToolRegistry()
        await terminalRegistry.register(BashTool(permissions: permissions))
        let terminalComposition = await AgentLoop.buildSystemPromptComposition(
            registry: terminalRegistry,
            mode: .agent,
            workspaceRoot: workspace,
            toolPromptFilterOverride: AgentLoop.subagentToolPromptFilter(role: "terminal")
        )
        XCTAssertFalse(terminalComposition.prompt.contains("PATHS: All `path` arguments"))
        XCTAssertFalse(terminalComposition.prompt.contains("FINAL REMINDER — WORKSPACE ROOT"))

        // A "filesystem" sub-agent: only mentions the tools it actually has,
        // not the full 8-tool list every profile used to see unconditionally.
        let filesystemRegistry = ToolRegistry()
        await filesystemRegistry.register(ReadFileTool(permissions: permissions))
        await filesystemRegistry.register(WriteFileTool(permissions: permissions))
        let filesystemComposition = await AgentLoop.buildSystemPromptComposition(
            registry: filesystemRegistry,
            mode: .agent,
            workspaceRoot: workspace,
            toolPromptFilterOverride: AgentLoop.subagentToolPromptFilter(role: "filesystem")
        )
        XCTAssertTrue(filesystemComposition.prompt.contains("PATHS: All `path` arguments to filesystem tools (read_file, write_file)"))
        XCTAssertFalse(filesystemComposition.prompt.contains("grep"), "should not mention tools this profile was never given")
        XCTAssertFalse(filesystemComposition.prompt.contains("FINAL REMINDER — WORKSPACE ROOT"))
    }
}
