// Sources/Workflow/Workflow.swift
// Deterministic, code-level workflow orchestration.
//
// mlx-coder targets small local models, which are unreliable *orchestrators*:
// asked (via the ORCHESTRATOR system prompt) to delegate work in a
// research → plan → execute → review order, they routinely skip stages,
// mis-route by verb, or loop. A `Workflow` moves that pipeline structure out of
// the prompt and into code: the stage sequence and data flow are fixed here, and
// the model is only responsible for doing each individual stage's work — never
// for deciding what comes next. Each stage is one sub-agent run
// (`TaskTool.run`), reusing all of the existing delegation machinery (per-role
// model routing, local-model swap, archiving, digest shaping).

import Foundation

/// A single stage of a workflow: exactly one sub-agent run with a fixed profile.
///
/// The stage's task text comes from `descriptionTemplate`, with `{{input}}`
/// (the workflow's initial input) and `{{<stepID>}}` (an upstream stage's
/// digest) substituted in by `WorkflowContext.resolve(_:)` right before the
/// stage runs. That substitution is how a downstream stage sees what upstream
/// stages found — sub-agents are otherwise blind to each other.
struct WorkflowStep: Sendable, Equatable {
    /// Stable identifier. Used both for `dependsOn` wiring and as the token an
    /// upstream result is addressed by in templates (`{{research}}`).
    let id: String
    /// Human-facing stage name, shown in `.workflowStep` events.
    let name: String
    /// The specialist profile this stage runs as (drives identity + default
    /// tools + per-role model, exactly like a `task(profile:)` call).
    let profile: TaskTool.SpecialistProfile
    /// Task text; see `WorkflowContext.resolve(_:)` for the placeholders.
    let descriptionTemplate: String
    /// Explicit tool override. `nil` uses the profile's default preset
    /// (`TaskTool.defaultTools`).
    let tools: [String]?
    /// `"summary"` (default) or `"raw"` — same meaning as the `task` tool's
    /// `response_mode`.
    let responseMode: String
    /// Stages that must complete before this one (their digests become
    /// available to this stage's template). Also defines execution order.
    let dependsOn: [String]
    /// Gate deciding whether this stage runs at all, given accumulated context.
    let condition: StepCondition
    /// When non-nil, the engine posts this (template-resolved) text to the
    /// user and blocks on an approval prompt *before* running the stage. A
    /// decline stops the workflow here — this and every remaining stage are
    /// recorded as skipped, but the run is still reported as succeeded (the
    /// user got exactly the outcome they asked for, not a failure). This is
    /// how `/discovery` differs from `/feature`: same pipeline, with a human
    /// checkpoint inserted before the mutating stages run.
    let confirmationPrompt: String?
    /// When non-nil, the step's digest must contain this text (case-
    /// insensitive) for the step to count as successful. Exists because
    /// `TaskTool`'s own `status:` line only reflects whether the sub-agent
    /// finished its turn cleanly — never whether the work it reports doing
    /// actually succeeded (a `test_engineering` stage that watches tests
    /// fail and faithfully says so still gets `status: success`). Use it on
    /// any stage whose entire job is to render a pass/fail verdict, paired
    /// with a `descriptionTemplate` that requires the sub-agent to end with
    /// that exact marker — see `Workflow.fix`'s `verify` stage.
    let requiredSuccessMarker: String?

    init(
        id: String,
        name: String,
        profile: TaskTool.SpecialistProfile,
        descriptionTemplate: String,
        tools: [String]? = nil,
        responseMode: String = "summary",
        dependsOn: [String] = [],
        condition: StepCondition = .always,
        confirmationPrompt: String? = nil,
        requiredSuccessMarker: String? = nil
    ) {
        self.id = id
        self.name = name
        self.profile = profile
        self.descriptionTemplate = descriptionTemplate
        self.tools = tools
        self.responseMode = responseMode
        self.dependsOn = dependsOn
        self.condition = condition
        self.confirmationPrompt = confirmationPrompt
        self.requiredSuccessMarker = requiredSuccessMarker
    }
}

/// Gate controlling whether a `WorkflowStep` runs. Modeled as data (not a
/// closure) so a `Workflow` stays `Sendable` and can cross the `AgentLoop`
/// actor boundary without concurrency ceremony.
enum StepCondition: Sendable, Equatable {
    /// Always run.
    case always
    /// Run unless the named upstream step hard-failed (its digest `status:` is
    /// `error`, or the run returned an error `ToolResult`). A `partial`
    /// (e.g. truncated) upstream still lets this stage run.
    case unlessFailed(String)
    /// Skip this stage when the named upstream step's digest contains `marker`
    /// (case-insensitive) — e.g. skip the executor when research reported
    /// "not found".
    case skipIfContains(step: String, marker: String)
}

/// A named, deterministic pipeline of `WorkflowStep`s forming a DAG (via each
/// step's `dependsOn`). Executed by `WorkflowEngine`.
struct Workflow: Sendable, Equatable {
    let name: String
    let steps: [WorkflowStep]

    init(name: String, steps: [WorkflowStep]) {
        self.name = name
        self.steps = steps
    }

    /// Look up a step by id.
    func step(_ id: String) -> WorkflowStep? { steps.first { $0.id == id } }
}

// MARK: - Built-in workflows

extension Workflow {
    /// The shared research → plan → execute → review pipeline behind both
    /// `/feature` and `/discovery`, encoding as *code* the same order the
    /// ORCHESTRATOR system prompt only *asks* the model to follow. Each
    /// stage's task embeds the prior stage's digest so the sub-agents (blind
    /// to one another) stay coherent.
    ///
    /// `gateBeforeExecute` is the only difference between the two commands:
    /// when `true`, the pipeline stops after `plan` and shows the user the
    /// plan before asking whether to proceed — that's `/discovery`. When
    /// `false` it runs straight through — that's `/feature`.
    private static func featurePipelineSteps(gateBeforeExecute: Bool) -> [WorkflowStep] {
        [
            WorkflowStep(
                id: "research",
                name: "Codebase research",
                profile: .codebaseResearch,
                descriptionTemplate: """
                Locate everything in this codebase relevant to the following request, and \
                prove it with concrete `file:line` references and short quoted snippets.

                REQUEST:
                {{input}}

                Report the exact files, symbols, and call sites a change would touch, the \
                existing patterns/conventions to follow, and anything that would block the \
                change. If something the request assumes does not exist, say so plainly.
                """
            ),
            WorkflowStep(
                id: "plan",
                name: "Implementation plan",
                profile: .planner,
                descriptionTemplate: """
                Produce a concrete, actionable implementation plan for the request below and \
                persist it with `plan_file`. Name the exact files/symbols to change (with \
                `file:line`), the chosen approach, and a step-by-step build order.

                REQUEST:
                {{input}}

                Codebase research already gathered (treat as ground truth; do not re-discover \
                what is already proven here):
                {{research}}

                Files research already read or otherwise established as relevant — read these \
                directly for exact current content instead of re-running glob/grep/code_search \
                to relocate them:
                {{all_files}}
                """,
                dependsOn: ["research"]
            ),
            WorkflowStep(
                id: "execute",
                name: "Implementation",
                profile: .executor,
                descriptionTemplate: """
                Implement the request below end-to-end, following the plan exactly. Match the \
                existing code's conventions. After editing, verify your own work (build or \
                targeted tests) when the tools allow, and fix what you broke. Change ONLY what \
                the request requires.

                REQUEST:
                {{input}}

                PLAN to follow (may be a truncated summary — if so, call `plan_file` \
                with action 'read' for the full, authoritative text; it is NOT in \
                `.native-agent/`):
                {{plan}}

                Files research and/or planning already read or otherwise established as \
                relevant — read these directly for exact current content instead of re-running \
                glob/grep/code_search to relocate them:
                {{all_files}}
                """,
                dependsOn: ["plan"],
                condition: .unlessFailed("plan"),
                confirmationPrompt: gateBeforeExecute ? """
                    Discovery complete — research and plan are ready for review.

                    PLAN:
                    {{plan}}

                    Proceed with implementation?
                    """ : nil
            ),
            WorkflowStep(
                id: "review",
                name: "Quality review",
                profile: .reviewer,
                descriptionTemplate: """
                Review the CURRENT state of the code for the change described below. Check \
                correctness (logic errors, edge cases, resource leaks) and project-convention \
                compliance. Run `build_check` if available. Do NOT edit anything. Report each \
                finding as `file:line — issue — suggested fix`, or say explicitly that the \
                change looks correct.

                CHANGE that was implemented:
                {{input}}

                What the implementation step reported:
                {{execute}}
                """,
                dependsOn: ["execute"],
                condition: .unlessFailed("execute")
            ),
        ]
    }

    /// Research → plan → execute → review, run straight through with no
    /// human checkpoint. Bound to `/feature`.
    static let feature = Workflow(name: "feature", steps: featurePipelineSteps(gateBeforeExecute: false))

    /// Research → plan, then a mandatory approval gate showing the plan
    /// before execute/review run. Bound to `/discovery`. Declining the gate
    /// ends the run right there (research + plan only) without touching the
    /// filesystem.
    static let discovery = Workflow(name: "discovery", steps: featurePipelineSteps(gateBeforeExecute: true))

    /// Leaner diagnose → fix → verify pipeline for bug fixes. Bound to
    /// `/fix`. Skips the separate planning stage `/feature` uses — a bug fix
    /// is scoped by the bug itself, not by a plan document — and verifies
    /// with the TEST_ENGINEERING profile (run the narrowest tests / repro
    /// steps and report pass/fail) rather than a static review pass.
    static let fix = Workflow(
        name: "fix",
        steps: [
            WorkflowStep(
                id: "diagnose",
                name: "Diagnosis",
                profile: .codebaseResearch,
                descriptionTemplate: """
                Find the ROOT CAUSE of the bug described below — not just where it manifests. \
                Prove it with concrete `file:line` references and short quoted snippets.

                BUG REPORT:
                {{input}}

                Report the exact file/function/line where the defect lives, the code path \
                that triggers it, and why it's wrong. If the report describes a symptom that \
                doesn't match anything in the code, say so plainly instead of guessing.
                """
            ),
            WorkflowStep(
                id: "fix",
                name: "Fix",
                profile: .executor,
                descriptionTemplate: """
                Fix the bug described below. Change ONLY what's needed to correct the root \
                cause — do not refactor unrelated code. Match existing conventions. After \
                editing, verify your own work (build or targeted tests) when the tools allow, \
                and fix what you broke.

                BUG REPORT:
                {{input}}

                Diagnosis (root cause; treat as ground truth):
                {{diagnose}}

                Files the diagnosis already read or otherwise established as relevant — call \
                read_file directly on these to get their exact current content before editing; \
                do NOT re-run glob/grep/code_search to relocate them, that work is already done:
                {{all_files}}
                """,
                dependsOn: ["diagnose"],
                condition: .unlessFailed("diagnose")
            ),
            WorkflowStep(
                id: "verify",
                name: "Verification",
                profile: .testEngineering,
                descriptionTemplate: """
                Verify the fix below actually resolves the bug. Run the narrowest tests that \
                cover it (or the exact repro steps from the bug report if no test exists), and \
                report the exact command and pass/fail outcome. If it still fails, quote the \
                failure and say so plainly — do not mark it fixed unless you've confirmed it.

                ORIGINAL BUG:
                {{input}}

                FIX that was implemented:
                {{fix}}

                End your summary with exactly one line, verbatim: `VERIFICATION: PASS` if you \
                ran the check and it confirms the bug is fixed, or `VERIFICATION: FAIL` \
                otherwise — including if you could not run or complete verification. This \
                exact line is REQUIRED: it is parsed by tooling, and a summary without it is \
                treated as a failed verification.
                """,
                dependsOn: ["fix"],
                condition: .unlessFailed("fix"),
                requiredSuccessMarker: "VERIFICATION: PASS"
            ),
        ]
    )

    /// Built-in workflows addressable by name (for CLI / slash-command lookup).
    static let builtins: [Workflow] = [feature, discovery, fix]

    /// Case-insensitive lookup of a built-in workflow by name (accepts `_`/`-`
    /// interchangeably, e.g. "feature-development" / "feature_development").
    static func builtin(named name: String) -> Workflow? {
        func norm(_ s: String) -> String {
            s.lowercased().replacingOccurrences(of: "_", with: "-")
        }
        let target = norm(name)
        return builtins.first { norm($0.name) == target }
    }
}
