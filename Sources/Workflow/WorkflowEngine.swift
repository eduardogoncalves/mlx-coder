// Sources/Workflow/WorkflowEngine.swift
// Executes a `Workflow` deterministically: dependency-ordered stages, each run
// as one sub-agent, with each stage's digest threaded into downstream stages.

import Foundation

/// Outcome of a single workflow stage.
struct WorkflowStepResult: Sendable, Equatable {
    let stepID: String
    let name: String
    /// `"success"` / `"partial"` (from the digest's own mechanical status —
    /// see `TaskTool.parseStatus`, which only reflects whether the sub-agent
    /// finished its turn without truncation, never whether the work it
    /// reports doing actually succeeded), `"failed"` (the sub-agent
    /// completed cleanly but its own reported verdict was negative — see
    /// `WorkflowStep.requiredSuccessMarker` — or it's an `.executor` stage
    /// that reported success while touching zero files, see `makeResult`),
    /// `"error"` (hard failure: the tool call itself errored), or
    /// `"skipped"` (gated out by its `StepCondition`).
    let status: String
    /// The sub-agent digest (or the error message on a hard failure). This is
    /// what gets threaded into downstream stage templates.
    let digest: String
    let modifiedFiles: [String]
    /// Files this stage actually loaded content for via `read_file`/`read_many`
    /// (excluding anything already in `modifiedFiles`) — see
    /// `AgentLoop.turnReadFiles` for why this is a narrower, higher-trust set
    /// than "every path any tool call touched": a research stage's `grep`/
    /// `glob`/`code_search` calls routinely scan many irrelevant files while
    /// converging on the right one, so surfacing those to a downstream stage
    /// would bury the files that actually mattered in search noise instead of
    /// letting it skip straight to `read_file` on a trusted, short list.
    let readFiles: [String]
    let skipped: Bool

    /// Files worth telling a downstream stage about without re-deriving them:
    /// everything this stage wrote plus everything it deliberately read.
    var relevantFiles: [String] {
        Array(Set(modifiedFiles).union(readFiles)).sorted()
    }

    /// `"error"` and `"failed"` both mean the step did not actually
    /// accomplish what it was asked, just for different reasons (the tool
    /// call broke vs. the sub-agent's own verdict was negative) — every
    /// failure-gating decision in `WorkflowEngine` treats them identically.
    var isFailure: Bool { status == "error" || status == "failed" }
}

/// Accumulated state across a workflow run: the initial input plus each
/// completed stage's result, keyed by step id. Threading upstream digests into
/// downstream stage descriptions happens through `resolve(_:)`.
struct WorkflowContext: Sendable {
    let input: String
    private(set) var results: [String: WorkflowStepResult] = [:]

    init(input: String) { self.input = input }

    mutating func record(_ result: WorkflowStepResult) {
        results[result.stepID] = result
    }

    /// Substitutes template placeholders: `{{input}}` → the workflow input;
    /// `{{<stepID>}}` → that upstream stage's digest (or a skip marker);
    /// `{{all_files}}` → a deterministic, newline-joined list of every file
    /// any stage completed *so far* wrote or deliberately read
    /// (`WorkflowStepResult.relevantFiles`, unioned across every recorded
    /// stage — not just this template's direct dependency, so a 3-hop chain
    /// like `research → plan → execute` still gives `execute` the files
    /// `research` found even if `plan` itself never re-read them), or a
    /// placeholder line if nothing has been read/written yet. A downstream
    /// stage's template can point straight at this instead of parsing file
    /// paths back out of upstream digest prose, and unlike a digest, this
    /// list can never drift from what tool calls actually touched (it's
    /// derived from tracked tool arguments, not summarized by a sub-agent).
    /// An unresolved `{{id}}` (stage not yet run) is left untouched, which
    /// cannot happen for a well-formed DAG since dependencies always run first.
    ///
    /// A `"partial"` upstream digest (truncated, or otherwise incomplete —
    /// see `TaskTool.parseStatus`) is prefixed with an explicit warning
    /// rather than substituted verbatim: several step templates tell the
    /// downstream sub-agent to "treat [it] as ground truth", which is exactly
    /// wrong when the truncation may have cut off the one fact that mattered.
    /// The sub-agent still gets the (partial) content — just not silent
    /// unearned confidence in its completeness. `{{all_files}}` is exempt
    /// from that caveat: it only ever reflects tool calls that actually
    /// completed, truncation or not.
    func resolve(_ template: String) -> String {
        var out = template.replacingOccurrences(of: "{{input}}", with: input)
        var allFiles: Set<String> = []
        for (id, result) in results {
            let value: String
            if result.skipped {
                value = "(this stage was skipped)"
            } else if result.status == "partial" {
                value = "[WARNING: this stage's result was reported PARTIAL/TRUNCATED — it may be missing information. Do not treat it as complete or authoritative; independently verify anything critical before relying on it.]\n\n" + result.digest
            } else {
                value = result.digest
            }
            out = out.replacingOccurrences(of: "{{\(id)}}", with: value)
            allFiles.formUnion(result.relevantFiles)
        }
        let filesList = allFiles.isEmpty
            ? "(no files identified yet)"
            : allFiles.sorted().map { "- \($0)" }.joined(separator: "\n")
        out = out.replacingOccurrences(of: "{{all_files}}", with: filesList)
        return out
    }
}

/// What to do when a stage hard-fails.
enum WorkflowFailurePolicy: Sendable {
    /// Stop the pipeline the moment a stage returns an error `ToolResult`.
    case stopOnFailure
    /// Keep going; downstream stages still run (subject to their own gates).
    case continueOnFailure
}

/// Aggregate result of running a whole workflow.
struct WorkflowRunResult: Sendable {
    let workflow: String
    let succeeded: Bool
    /// Stage results in execution order (including skipped stages).
    let results: [WorkflowStepResult]

    /// All files any stage reported modifying, de-duplicated and sorted.
    var modifiedFiles: [String] {
        Array(Set(results.flatMap(\.modifiedFiles))).sorted()
    }

    /// Compact, user-facing recap of the run.
    var summary: String {
        var lines = ["Workflow '\(workflow)' \(succeeded ? "completed" : "stopped"):"]
        for r in results {
            let mark: String
            switch r.status {
            case "success": mark = "✓"
            case "skipped": mark = "⤼"
            case "error", "failed": mark = "✗"
            default:        mark = "◐"
            }
            lines.append("  \(mark) \(r.name) — \(r.status)")
        }
        let mods = modifiedFiles
        if !mods.isEmpty {
            lines.append("Files modified: \(mods.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }
}

/// Runs a `Workflow` by invoking a sub-agent per stage. The engine owns *only*
/// ordering, gating, and data-threading; the actual sub-agent spawn is supplied
/// as `runStep` (in practice `TaskTool.run`), so the engine shares the exact
/// delegation code path — per-role model routing, local-model swap, archiving,
/// digest shaping — and stays trivially testable with a stub `runStep`.
///
/// Stages run **sequentially** in dependency order. Only one local MLX model may
/// be resident at a time, so genuine parallelism would contend for it; the value
/// here is deterministic *routing*, not concurrency.
struct WorkflowEngine {
    let workflow: Workflow
    let failurePolicy: WorkflowFailurePolicy
    let frontend: any AgentFrontend

    init(
        workflow: Workflow,
        failurePolicy: WorkflowFailurePolicy = .stopOnFailure,
        frontend: any AgentFrontend
    ) {
        self.workflow = workflow
        self.failurePolicy = failurePolicy
        self.frontend = frontend
    }

    func run(
        input: String,
        runStep: (TaskTool.ValidatedArguments) async -> ToolResult
    ) async -> WorkflowRunResult {
        guard let ordered = topologicalOrder() else {
            frontend.emit(.error("Workflow '\(workflow.name)' has an invalid dependency graph (cycle or unknown dependency); nothing ran."))
            frontend.emit(.workflowStep(.completed(workflow: workflow.name, succeeded: false, stepsRun: 0)))
            return WorkflowRunResult(workflow: workflow.name, succeeded: false, results: [])
        }

        var context = WorkflowContext(input: input)
        var executionOrder: [WorkflowStepResult] = []
        var stepsRun = 0
        var stopped = false
        let total = workflow.steps.count

        stageLoop: for (index, step) in ordered.enumerated() {
            let gate = evaluate(step.condition, in: context)
            guard gate.run else {
                let result = WorkflowStepResult(
                    stepID: step.id, name: step.name, status: "skipped",
                    digest: "", modifiedFiles: [], readFiles: [], skipped: true
                )
                context.record(result)
                executionOrder.append(result)
                frontend.emit(.workflowStep(.skipped(workflow: workflow.name, step: step.name, reason: gate.reason)))
                continue
            }

            if let template = step.confirmationPrompt {
                let proceed = await requestConfirmation(step: step, message: context.resolve(template))
                if !proceed {
                    for remaining in ordered[index...] {
                        let result = WorkflowStepResult(
                            stepID: remaining.id, name: remaining.name, status: "skipped",
                            digest: "", modifiedFiles: [], readFiles: [], skipped: true
                        )
                        context.record(result)
                        executionOrder.append(result)
                        frontend.emit(.workflowStep(.skipped(
                            workflow: workflow.name, step: remaining.name, reason: "user declined to proceed"
                        )))
                    }
                    break stageLoop
                }
            }

            stepsRun += 1
            frontend.emit(.workflowStep(.started(
                workflow: workflow.name, step: step.name,
                index: stepsRun, total: total, profile: step.profile.rawValue
            )))

            let arguments = TaskTool.ValidatedArguments(
                description: context.resolve(step.descriptionTemplate),
                tools: step.tools ?? TaskTool.defaultTools(for: step.profile.rawValue),
                profileName: step.profile.rawValue,
                isolate: false,
                isolationDirectory: nil,
                responseMode: step.responseMode,
                expectedPatterns: [],
                mustNotTruncate: false,
                resumeHistoryPath: nil
            )
            let toolResult = await runStep(arguments)
            let result = makeResult(for: step, from: toolResult)
            context.record(result)
            executionOrder.append(result)
            frontend.emit(.workflowStep(.finished(workflow: workflow.name, step: step.name, status: result.status)))

            if result.isFailure, failurePolicy == .stopOnFailure {
                stopped = true
                break
            }
        }

        let succeeded = !stopped && !executionOrder.contains(where: \.isFailure)
        frontend.emit(.workflowStep(.completed(workflow: workflow.name, succeeded: succeeded, stepsRun: stepsRun)))
        return WorkflowRunResult(workflow: workflow.name, succeeded: succeeded, results: executionOrder)
    }

    // MARK: - Internals

    /// Posts `message` to the user (so they can actually read the plan, not
    /// just a one-line prompt) then blocks on an approval decision for
    /// `step`. Any "allow" variant proceeds; `.deny` (including a cancelled
    /// request) declines.
    private func requestConfirmation(step: WorkflowStep, message: String) async -> Bool {
        frontend.emitStatus(message)
        let response = await frontend.request(.approval(ApprovalRequest(
            toolName: "workflow",
            display: "Proceed with '\(step.name)'? (see plan above)",
            cacheKey: "workflow.\(workflow.name).\(step.id)",
            isPlanModeBlock: false
        )))
        guard case .approval(let decision) = response else { return false }
        switch decision {
        case .allowOnce, .allowAlwaysForCommand, .allowAllAutopilot, .switchToAgentAndAllow:
            return true
        case .deny:
            return false
        }
    }

    /// `TaskTool.parseStatus` only tells us whether the sub-agent finished
    /// its turn cleanly — a `test_engineering` stage that runs the tests,
    /// watches them fail, and faithfully reports "3 tests FAILED" still gets
    /// `status: success` from that mechanical check, because nothing broke
    /// technically. A step whose entire job is to render a verdict (like
    /// `/fix`'s verify stage) sets `requiredSuccessMarker` so the engine
    /// checks the sub-agent's OWN verdict instead of just "did it crash":
    /// the marker's absence — including a reported FAIL, or a sub-agent that
    /// skipped the required sentinel entirely — downgrades the step to
    /// `"failed"`, which fails the whole run exactly like a technical error.
    ///
    /// Checked against ONLY the last line of the digest's `summary:` body
    /// (`TaskTool.lastSummaryLine`), never the whole digest text — searching
    /// the whole digest would also match the marker inside the truncated
    /// `task:` echo (which, for a step whose own instructions ask for that
    /// marker, would then always read as "passed") or a passing mention
    /// buried earlier in the sub-agent's prose.
    private func makeResult(for step: WorkflowStep, from toolResult: ToolResult) -> WorkflowStepResult {
        if toolResult.isError {
            return WorkflowStepResult(
                stepID: step.id, name: step.name, status: "error",
                digest: toolResult.content, modifiedFiles: [], readFiles: [], skipped: false
            )
        }
        var status = TaskTool.parseStatus(fromDigest: toolResult.content) ?? "success"
        if let marker = step.requiredSuccessMarker {
            let verdictLine = TaskTool.lastSummaryLine(fromDigest: toolResult.content) ?? ""
            if verdictLine.range(of: marker, options: .caseInsensitive) == nil {
                status = "failed"
            }
        }
        let modified = TaskTool.parseModifiedFiles(fromDigest: toolResult.content)
        let read = TaskTool.parseReadFiles(fromDigest: toolResult.content)
        // An `.executor` stage's entire job is to change files — its own
        // prose claiming "I fixed X" is not evidence of that, only
        // `modifiedFiles` (tracked mechanically from actual tool calls, see
        // `AgentLoop.turnModifiedFiles`) is. A sub-agent that made zero tool
        // calls (e.g. stalled on a confusing upstream digest, or answered
        // its own empty-response nudge with a plausible-sounding narrative
        // instead of doing the work) still reports `status: success` from
        // `TaskTool.parseStatus` because nothing technically crashed — this
        // is the same trust gap `requiredSuccessMarker` closes for verdict
        // stages, applied to mutation stages instead. Observed for real in a
        // `/fix` run where the executor stage made 0 tool calls yet
        // described a fix in detail; nothing downstream caught it until the
        // unrelated verify-marker check happened to fail two stages later.
        if step.profile == .executor, status == "success", modified.isEmpty {
            status = "failed"
        }
        return WorkflowStepResult(
            stepID: step.id, name: step.name, status: status,
            digest: toolResult.content, modifiedFiles: modified, readFiles: read, skipped: false
        )
    }

    private func evaluate(_ condition: StepCondition, in context: WorkflowContext) -> (run: Bool, reason: String) {
        switch condition {
        case .always:
            return (true, "")
        case .unlessFailed(let dependency):
            if context.results[dependency]?.isFailure == true {
                return (false, "upstream stage '\(dependency)' failed")
            }
            return (true, "")
        case .skipIfContains(let dependency, let marker):
            let body = context.results[dependency]?.digest ?? ""
            if body.range(of: marker, options: .caseInsensitive) != nil {
                return (false, "upstream stage '\(dependency)' reported '\(marker)'")
            }
            return (true, "")
        }
    }

    /// Stable topological sort honoring `dependsOn`, preserving declared order
    /// among ready steps. Returns `nil` on a cycle or an unknown dependency.
    private func topologicalOrder() -> [WorkflowStep]? {
        var completed = Set<String>()
        var ordered: [WorkflowStep] = []
        var remaining = workflow.steps

        while !remaining.isEmpty {
            guard let index = remaining.firstIndex(where: { step in
                step.dependsOn.allSatisfy { completed.contains($0) }
            }) else {
                return nil
            }
            let step = remaining.remove(at: index)
            ordered.append(step)
            completed.insert(step.id)
        }
        return ordered
    }
}
