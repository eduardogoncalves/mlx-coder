// Tests for the orchestrator-only manager tool visibility: the top-level
// AgentLoop always advertises only orchestration tools in its own prompt
// (task/todo/plan_file/log_knowledge/search_knowledge), while a
// TaskTool-constructed sub-agent shows exactly its own registered tool set.
// See AgentLoop+SystemPrompt.swift.

import XCTest
@testable import MLXCoder

final class ToolPromptFilterTests: XCTestCase {
    func testOrchestratorFilterOnlyExposesOrchestrationTools() {
        let filter = AgentLoop.orchestratorToolPromptFilter(mode: .agent)
        XCTAssertEqual(filter.selectedToolNames, ["task", "todo", "plan_file", "log_knowledge", "search_knowledge", "read_subagent_log"])
        XCTAssertEqual(filter.taskTypeHint, "orchestration")
        XCTAssertFalse(filter.includeMCPTools)
    }

    func testOrchestratorFilterCarriesModeHint() {
        XCTAssertEqual(AgentLoop.orchestratorToolPromptFilter(mode: .plan).modeHint, "plan")
        XCTAssertEqual(AgentLoop.orchestratorToolPromptFilter(mode: .agent).modeHint, "agent")
    }

    func testSubagentFilterShowsEverythingRegisteredRatherThanACuratedList() {
        let filter = AgentLoop.subagentToolPromptFilter(role: "executor")
        // nil selectedToolNames means "show everything in this registry" — correct
        // for a sub-agent, whose registry only ever contains its profile's tools.
        XCTAssertNil(filter.selectedToolNames)
        XCTAssertEqual(filter.taskTypeHint, "executor")
        XCTAssertTrue(filter.includeMCPTools)
    }

    /// The prompt-visible list and the hard execution-time guard in
    /// `executeToolCall`/`handleStreamedToolCall`/`commitTruncatedStreamedWrite`
    /// must agree on exactly which tools the orchestrator may call — otherwise a
    /// tool could be advertised but rejected, or hidden but silently allowed.
    func testOrchestratorAllowedToolNamesSetMatchesOrderedList() {
        XCTAssertEqual(
            AgentLoop.orchestratorAllowedToolNames,
            Set(AgentLoop.orchestratorAllowedToolNamesOrdered)
        )
        XCTAssertEqual(AgentLoop.orchestratorAllowedToolNamesOrdered, ["task", "todo", "plan_file", "log_knowledge", "search_knowledge", "read_subagent_log"])
    }
}
