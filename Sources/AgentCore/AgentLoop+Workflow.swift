// Sources/AgentCore/AgentLoop+Workflow.swift
// Entry point for running a deterministic `Workflow` from a live AgentLoop.

import Foundation

extension AgentLoop {
    /// Runs a deterministic `Workflow` to completion against this loop's live
    /// state, spawning one sub-agent per stage through the shared `TaskTool.run`
    /// code path. The `TaskTool` is built exactly as it is in
    /// `registerToolsInternal` (same model container, permissions, per-role
    /// model map, parent-loop reference for local-model swaps, and output spool),
    /// so a workflow stage behaves identically to a `task(...)` delegation — the
    /// only difference is that *which* stage runs next is decided here, in code,
    /// not by the model.
    func runWorkflow(
        _ workflow: Workflow,
        input: String,
        failurePolicy: WorkflowFailurePolicy = .stopOnFailure
    ) async -> WorkflowRunResult {
        let taskTool = TaskTool(
            modelContainer: modelContainer,
            permissions: permissions,
            generationConfig: currentGenerationConfig,
            modelPath: modelPath,
            useSandbox: useSandbox,
            parentRegistry: registry,
            frontend: frontend,
            roleModels: AgentRoleRegistry.current(workspaceRoot: permissions.workspaceRoot).roleModelMap,
            parentAgentLoop: self,
            toolOutputSpool: toolOutputSpoolConfig,
            codeGraphIndexer: codeGraphIndexer
        )

        let engine = WorkflowEngine(
            workflow: workflow,
            failurePolicy: failurePolicy,
            frontend: frontend
        )

        return await engine.run(input: input) { arguments in
            await taskTool.run(arguments)
        }
    }
}
