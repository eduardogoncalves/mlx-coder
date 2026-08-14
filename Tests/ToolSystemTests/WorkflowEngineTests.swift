// Tests for the deterministic WorkflowEngine: dependency ordering, digest
// threading between stages, per-stage gating (StepCondition), and the
// stop-on-failure policy. These use a stub `runStep` so no model is involved —
// the engine's own logic is exercised in isolation, with realistic digests
// produced via `TaskTool.makeSubagentDigest`.

import XCTest
@testable import MLXCoder

/// Records the description of every stage `runStep` was invoked with, in order.
private final class DescriptionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return _values }
    func append(_ value: String) { lock.lock(); _values.append(value); lock.unlock() }
}

private func digest(
    profile: String, summary: String, status: String = "success", taskDescription: String = "task",
    modifiedFiles: [String] = [], readFiles: [String] = []
) -> ToolResult {
    .success(TaskTool.makeSubagentDigest(
        status: status,
        profileName: profile,
        taskDescription: taskDescription,
        summary: summary,
        archivePath: nil,
        modifiedFiles: modifiedFiles,
        readFiles: readFiles
    ))
}

/// Test double that always answers approval requests with a fixed decision,
/// recording every posted status message so a confirmation gate's message
/// can be asserted on.
private final class StubApprovalFrontend: AgentFrontend, @unchecked Sendable {
    private let decision: ApprovalDecision
    private(set) var statusMessages: [String] = []
    init(decision: ApprovalDecision) { self.decision = decision }

    func emit(_ event: AgentEvent) {
        if case .status(let message) = event { statusMessages.append(message.text) }
    }

    func request(_ request: AgentRequest) async -> AgentResponse {
        switch request {
        case .approval:            return .approval(decision)
        case .optionSelect:        return .optionSelect(nil)
        case .textInput:           return .textInput(nil)
        case .clarifyingQuestions: return .clarifyingQuestions(nil)
        }
    }
}

final class WorkflowEngineTests: XCTestCase {

    func testRunsStepsInDependencyOrderAndThreadsDigests() async {
        let workflow = Workflow(name: "t", steps: [
            WorkflowStep(id: "b", name: "B", profile: .planner,
                         descriptionTemplate: "plan using {{a}}", dependsOn: ["a"]),
            WorkflowStep(id: "a", name: "A", profile: .codebaseResearch,
                         descriptionTemplate: "research: {{input}}"),
        ])
        let box = DescriptionBox()
        let engine = WorkflowEngine(workflow: workflow, frontend: NullAgentFrontend())

        let result = await engine.run(input: "build X") { args in
            box.append(args.description)
            return digest(profile: args.profileName, summary: "did \(args.profileName)")
        }

        XCTAssertTrue(result.succeeded)
        // 'a' must run before 'b' despite being declared second (dependsOn wins).
        XCTAssertEqual(result.results.map(\.stepID), ["a", "b"])
        XCTAssertEqual(box.values.count, 2)
        XCTAssertTrue(box.values[0].contains("build X"), "a should see the workflow input")
        XCTAssertTrue(box.values[1].contains("did codebase_research"),
                      "b should see a's digest threaded in; got: \(box.values[1])")
    }

    func testStopsOnFailure() async {
        let workflow = Workflow(name: "t", steps: [
            WorkflowStep(id: "a", name: "A", profile: .planner,
                         descriptionTemplate: "{{input}}"),
            WorkflowStep(id: "b", name: "B", profile: .executor,
                         descriptionTemplate: "{{a}}", dependsOn: ["a"]),
        ])
        let box = DescriptionBox()
        let engine = WorkflowEngine(workflow: workflow, failurePolicy: .stopOnFailure,
                                    frontend: NullAgentFrontend())

        let result = await engine.run(input: "x") { args in
            if args.profileName == "planner" { return .error("boom") }
            box.append(args.description)
            return digest(profile: args.profileName, summary: "ok")
        }

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.results.map(\.stepID), ["a"], "b must not run after a hard-fails")
        XCTAssertEqual(result.results.first?.status, "error")
        XCTAssertTrue(box.values.isEmpty)
    }

    func testSkipConditionSkipsStageButDoesNotFailRun() async {
        let workflow = Workflow(name: "t", steps: [
            WorkflowStep(id: "a", name: "A", profile: .codebaseResearch,
                         descriptionTemplate: "{{input}}"),
            WorkflowStep(id: "b", name: "B", profile: .executor,
                         descriptionTemplate: "{{a}}", dependsOn: ["a"],
                         condition: .skipIfContains(step: "a", marker: "NOT FOUND")),
        ])
        let engine = WorkflowEngine(workflow: workflow, frontend: NullAgentFrontend())

        let result = await engine.run(input: "x") { args in
            digest(profile: args.profileName, summary: "the symbol was NOT FOUND anywhere")
        }

        XCTAssertEqual(result.results.count, 2)
        let b = result.results.first { $0.stepID == "b" }
        XCTAssertEqual(b?.status, "skipped")
        XCTAssertTrue(b?.skipped ?? false)
        XCTAssertTrue(result.succeeded, "a skip is not a failure")
    }

    func testUnlessFailedSkipsDownstreamOnHardFailureWithContinuePolicy() async {
        let workflow = Workflow(name: "t", steps: [
            WorkflowStep(id: "a", name: "A", profile: .planner,
                         descriptionTemplate: "{{input}}"),
            WorkflowStep(id: "b", name: "B", profile: .executor,
                         descriptionTemplate: "{{a}}", dependsOn: ["a"],
                         condition: .unlessFailed("a")),
        ])
        let engine = WorkflowEngine(workflow: workflow, failurePolicy: .continueOnFailure,
                                    frontend: NullAgentFrontend())

        let result = await engine.run(input: "x") { args in
            if args.profileName == "planner" { return .error("boom") }
            return digest(profile: args.profileName, summary: "ok")
        }

        // continueOnFailure keeps going, but b's `unlessFailed("a")` gate skips it.
        XCTAssertEqual(result.results.map(\.stepID), ["a", "b"])
        XCTAssertEqual(result.results.first { $0.stepID == "b" }?.status, "skipped")
        XCTAssertFalse(result.succeeded, "an errored stage still marks the run unsuccessful")
    }

    func testParseStatusFromDigest() {
        let d = TaskTool.makeSubagentDigest(
            status: "partial", profileName: "planner",
            taskDescription: "t", summary: "s", archivePath: nil
        )
        XCTAssertEqual(TaskTool.parseStatus(fromDigest: d), "partial")
        XCTAssertNil(TaskTool.parseStatus(fromDigest: "no status line here"))
    }

    func testBuiltinLookupIsCaseAndSeparatorInsensitive() {
        XCTAssertEqual(Workflow.builtin(named: "feature")?.name, "feature")
        XCTAssertEqual(Workflow.builtin(named: "Discovery")?.name, "discovery")
        XCTAssertEqual(Workflow.builtin(named: "FIX")?.name, "fix")
        XCTAssertNil(Workflow.builtin(named: "does-not-exist"))
    }

    // MARK: - confirmationPrompt gate (discovery-style human checkpoint)

    func testConfirmationGateProceedsWhenApproved() async {
        let workflow = Workflow(name: "t", steps: [
            WorkflowStep(id: "a", name: "A", profile: .planner, descriptionTemplate: "{{input}}"),
            WorkflowStep(id: "b", name: "B", profile: .executor,
                         descriptionTemplate: "{{a}}", dependsOn: ["a"],
                         confirmationPrompt: "plan from a: {{a}}"),
        ])
        let frontend = StubApprovalFrontend(decision: .allowOnce)
        let engine = WorkflowEngine(workflow: workflow, frontend: frontend)
        let box = DescriptionBox()

        let result = await engine.run(input: "x") { args in
            box.append(args.description)
            // b runs as .executor — give it a modified file so the
            // "executor claimed success but touched nothing" guard in
            // makeResult doesn't downgrade this to "failed" (that guard is
            // exercised on its own in testExecutorStepWithNoModifiedFilesIsDowngradedToFailed).
            return digest(profile: args.profileName, summary: "ok", modifiedFiles: ["src/Changed.swift"])
        }

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.results.map(\.stepID), ["a", "b"])
        XCTAssertEqual(result.results.last?.status, "success")
        XCTAssertEqual(box.values.count, 2, "b must have actually run")
        XCTAssertTrue(frontend.statusMessages.contains { $0.contains("plan from a") },
                      "the gate must post the resolved prompt so the user can read it before deciding")
    }

    func testConfirmationGateStopsWithoutRunningWhenDeclined() async {
        let workflow = Workflow(name: "t", steps: [
            WorkflowStep(id: "a", name: "A", profile: .planner, descriptionTemplate: "{{input}}"),
            WorkflowStep(id: "b", name: "B", profile: .executor,
                         descriptionTemplate: "{{a}}", dependsOn: ["a"],
                         confirmationPrompt: "plan from a: {{a}}"),
            WorkflowStep(id: "c", name: "C", profile: .reviewer,
                         descriptionTemplate: "{{b}}", dependsOn: ["b"]),
        ])
        let frontend = StubApprovalFrontend(decision: .deny(suggestion: nil))
        let engine = WorkflowEngine(workflow: workflow, frontend: frontend)
        let box = DescriptionBox()

        let result = await engine.run(input: "x") { args in
            box.append(args.description)
            return digest(profile: args.profileName, summary: "ok")
        }

        XCTAssertTrue(result.succeeded, "declining the gate is an expected outcome, not a failure")
        XCTAssertEqual(box.values.count, 1, "only a (ungated) should have run — b and c must not")
        XCTAssertEqual(result.results.map(\.stepID), ["a", "b", "c"])
        XCTAssertEqual(result.results.first { $0.stepID == "b" }?.status, "skipped")
        XCTAssertEqual(result.results.first { $0.stepID == "c" }?.status, "skipped")
    }

    // MARK: - requiredSuccessMarker (a sub-agent's own reported verdict, not just "did it crash")

    func testRequiredSuccessMarkerAbsentMarksStepFailedEvenThoughTaskToolReportedSuccess() async {
        let workflow = Workflow(name: "t", steps: [
            WorkflowStep(id: "verify", name: "Verify", profile: .testEngineering,
                         descriptionTemplate: "{{input}}",
                         requiredSuccessMarker: "VERIFICATION: PASS"),
        ])
        let engine = WorkflowEngine(workflow: workflow, frontend: NullAgentFrontend())

        let result = await engine.run(input: "x") { args in
            // TaskTool's own mechanical status is "success" — the sub-agent
            // completed cleanly — but its reported verdict is a failure.
            digest(profile: args.profileName, summary: "Ran the tests. 3 failed.\nVERIFICATION: FAIL")
        }

        XCTAssertEqual(result.results.first?.status, "failed")
        XCTAssertFalse(result.succeeded, "a sub-agent-reported FAIL must not let the workflow report as completed")
    }

    func testRequiredSuccessMarkerAbsentEntirelyAlsoMarksStepFailed() async {
        let workflow = Workflow(name: "t", steps: [
            WorkflowStep(id: "verify", name: "Verify", profile: .testEngineering,
                         descriptionTemplate: "{{input}}",
                         requiredSuccessMarker: "VERIFICATION: PASS"),
        ])
        let engine = WorkflowEngine(workflow: workflow, frontend: NullAgentFrontend())

        let result = await engine.run(input: "x") { args in
            // Small models are unreliable at literal sentinel compliance —
            // a summary that just omits the marker must fail closed too.
            digest(profile: args.profileName, summary: "I looked at the code, seems fine.")
        }

        XCTAssertEqual(result.results.first?.status, "failed")
        XCTAssertFalse(result.succeeded)
    }

    func testRequiredSuccessMarkerIgnoresMatchInTaskEchoNotSummary() async {
        // The digest's truncated `task:` echo repeats the start of the task
        // description — if that description happens to contain the marker
        // text (as `/fix`'s own verify-step instructions do), a whole-digest
        // scan would always see it. Only the summary's last line counts.
        let workflow = Workflow(name: "t", steps: [
            WorkflowStep(id: "verify", name: "Verify", profile: .testEngineering,
                         descriptionTemplate: "{{input}}",
                         requiredSuccessMarker: "VERIFICATION: PASS"),
        ])
        let engine = WorkflowEngine(workflow: workflow, frontend: NullAgentFrontend())

        let result = await engine.run(input: "x") { args in
            digest(
                profile: args.profileName,
                summary: "Ran the tests. 3 failed.\nVERIFICATION: FAIL",
                taskDescription: "End with the line VERIFICATION: PASS if it works, or VERIFICATION: FAIL otherwise."
            )
        }

        XCTAssertEqual(result.results.first?.status, "failed",
                       "the marker text living in the task-description echo must not count as a pass")
    }

    func testRequiredSuccessMarkerIgnoresMentionEarlierInSummaryProse() async {
        // A sub-agent that quotes/mentions the marker in passing, but whose
        // actual final verdict line differs, must not be read as a pass.
        let workflow = Workflow(name: "t", steps: [
            WorkflowStep(id: "verify", name: "Verify", profile: .testEngineering,
                         descriptionTemplate: "{{input}}",
                         requiredSuccessMarker: "VERIFICATION: PASS"),
        ])
        let engine = WorkflowEngine(workflow: workflow, frontend: NullAgentFrontend())

        let result = await engine.run(input: "x") { args in
            digest(
                profile: args.profileName,
                summary: "I was told to report VERIFICATION: PASS or FAIL. 2 of 5 tests still fail.\nVERIFICATION: FAIL",
                taskDescription: "task"
            )
        }

        XCTAssertEqual(result.results.first?.status, "failed",
                       "an earlier mention of the marker string must not override the actual last-line verdict")
    }

    func testRequiredSuccessMarkerPresentKeepsStepSuccessful() async {
        let workflow = Workflow(name: "t", steps: [
            WorkflowStep(id: "verify", name: "Verify", profile: .testEngineering,
                         descriptionTemplate: "{{input}}",
                         requiredSuccessMarker: "VERIFICATION: PASS"),
        ])
        let engine = WorkflowEngine(workflow: workflow, frontend: NullAgentFrontend())

        let result = await engine.run(input: "x") { args in
            digest(profile: args.profileName, summary: "All tests pass.\nVERIFICATION: PASS")
        }

        XCTAssertEqual(result.results.first?.status, "success")
        XCTAssertTrue(result.succeeded)
    }

    // MARK: - executor stages that claim success without touching a file
    // (see makeResult's zero-modifiedFiles guard). This is the same class of
    // gap `requiredSuccessMarker` closes for verdict stages — TaskTool's own
    // status: line only reflects "did the sub-agent's turn crash", never
    // "did it actually do anything" — applied to mutation stages, where the
    // sub-agent's own prose claiming a fix is not evidence a fix happened.

    func testExecutorStepWithNoModifiedFilesIsDowngradedToFailed() async {
        let workflow = Workflow(name: "t", steps: [
            WorkflowStep(id: "fix", name: "Fix", profile: .executor, descriptionTemplate: "{{input}}"),
        ])
        let engine = WorkflowEngine(workflow: workflow, frontend: NullAgentFrontend())

        let result = await engine.run(input: "x") { args in
            // A plausible-sounding narrative claiming a fix was made, but no
            // modifiedFiles — exactly what a sub-agent that made zero tool
            // calls (yet still answered the "write a final summary" nudge
            // with confident prose) produces.
            digest(profile: args.profileName, summary: "I reviewed the code and fixed the root cause.")
        }

        XCTAssertEqual(result.results.first?.status, "failed")
        XCTAssertFalse(result.succeeded)
    }

    func testExecutorStepWithModifiedFilesStaysSuccessful() async {
        let workflow = Workflow(name: "t", steps: [
            WorkflowStep(id: "fix", name: "Fix", profile: .executor, descriptionTemplate: "{{input}}"),
        ])
        let engine = WorkflowEngine(workflow: workflow, frontend: NullAgentFrontend())

        let result = await engine.run(input: "x") { args in
            digest(profile: args.profileName, summary: "Fixed it.", modifiedFiles: ["src/Foo.swift"])
        }

        XCTAssertEqual(result.results.first?.status, "success")
        XCTAssertTrue(result.succeeded)
    }

    func testNonExecutorStepWithNoModifiedFilesIsUnaffected() async {
        // The guard is scoped to .executor — a research stage never touches
        // files by design, so it must not be penalized for having none.
        let workflow = Workflow(name: "t", steps: [
            WorkflowStep(id: "research", name: "Research", profile: .codebaseResearch, descriptionTemplate: "{{input}}"),
        ])
        let engine = WorkflowEngine(workflow: workflow, frontend: NullAgentFrontend())

        let result = await engine.run(input: "x") { args in
            digest(profile: args.profileName, summary: "Found it.")
        }

        XCTAssertEqual(result.results.first?.status, "success")
        XCTAssertTrue(result.succeeded)
    }

    func testUnlessFailedAlsoGatesOnRequiredMarkerFailure() async {
        let workflow = Workflow(name: "t", steps: [
            WorkflowStep(id: "verify", name: "Verify", profile: .testEngineering,
                         descriptionTemplate: "{{input}}",
                         requiredSuccessMarker: "VERIFICATION: PASS"),
            WorkflowStep(id: "report", name: "Report", profile: .docs,
                         descriptionTemplate: "{{verify}}", dependsOn: ["verify"],
                         condition: .unlessFailed("verify")),
        ])
        // continueOnFailure so "report" actually gets a chance to run and its
        // own `.unlessFailed("verify")` gate — not the engine's stop-on-error
        // loop — is what's under test here.
        let engine = WorkflowEngine(workflow: workflow, failurePolicy: .continueOnFailure, frontend: NullAgentFrontend())

        let result = await engine.run(input: "x") { args in
            digest(profile: args.profileName, summary: "VERIFICATION: FAIL")
        }

        XCTAssertEqual(result.results.first { $0.stepID == "report" }?.status, "skipped",
                       "a marker-based failure must gate downstream stages exactly like a technical error")
        XCTAssertFalse(result.succeeded)
    }

    // MARK: - {{all_files}}: deterministic file handoff, so a downstream stage
    // doesn't have to re-glob/re-grep to relocate what an upstream stage
    // already found (see AgentLoop.turnReadFiles / WorkflowStepResult.relevantFiles).

    func testAllFilesResolvesToUnionOfReadAndModifiedFilesAcrossUpstreamStages() async {
        let workflow = Workflow(name: "t", steps: [
            WorkflowStep(id: "a", name: "A", profile: .codebaseResearch, descriptionTemplate: "{{input}}"),
            WorkflowStep(id: "b", name: "B", profile: .executor,
                         descriptionTemplate: "files so far:\n{{all_files}}", dependsOn: ["a"]),
        ])
        let box = DescriptionBox()
        let engine = WorkflowEngine(workflow: workflow, frontend: NullAgentFrontend())

        let result = await engine.run(input: "x") { args in
            if args.profileName == "codebase_research" {
                return digest(profile: args.profileName, summary: "found it",
                               readFiles: ["src/Foo.swift", "src/Bar.swift"])
            }
            box.append(args.description)
            return digest(profile: args.profileName, summary: "ok", modifiedFiles: ["src/Foo.swift"])
        }

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(box.values.count, 1)
        XCTAssertTrue(box.values[0].contains("- src/Bar.swift"))
        XCTAssertTrue(box.values[0].contains("- src/Foo.swift"))
    }

    func testAllFilesIsCumulativeAcrossMultiHopChainEvenWhenMiddleStageReadsNothing() async {
        // research -> plan -> execute: plan never itself calls read_file, but
        // execute must still see the files research found two hops back.
        let workflow = Workflow(name: "t", steps: [
            WorkflowStep(id: "research", name: "Research", profile: .codebaseResearch, descriptionTemplate: "{{input}}"),
            WorkflowStep(id: "plan", name: "Plan", profile: .planner,
                         descriptionTemplate: "{{research}}", dependsOn: ["research"]),
            WorkflowStep(id: "execute", name: "Execute", profile: .executor,
                         descriptionTemplate: "files so far:\n{{all_files}}", dependsOn: ["plan"]),
        ])
        let box = DescriptionBox()
        let engine = WorkflowEngine(workflow: workflow, frontend: NullAgentFrontend())

        let result = await engine.run(input: "x") { args in
            switch args.profileName {
            case "codebase_research":
                return digest(profile: args.profileName, summary: "found it", readFiles: ["src/Target.swift"])
            case "planner":
                // Plan step reads nothing itself — just reasons over the digest.
                return digest(profile: args.profileName, summary: "plan ready")
            default:
                box.append(args.description)
                // "execute" runs as .executor — give it a modified file so the
                // "executor claimed success but touched nothing" guard in
                // makeResult doesn't downgrade this stage.
                return digest(profile: args.profileName, summary: "ok", modifiedFiles: ["src/Target.swift"])
            }
        }

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(box.values.first?.contains("- src/Target.swift") == true,
                      "execute must see research's files even though plan (its direct dependency) read nothing itself")
    }

    func testAllFilesPlaceholderWhenNothingReadOrModifiedYet() async {
        let workflow = Workflow(name: "t", steps: [
            WorkflowStep(id: "a", name: "A", profile: .planner, descriptionTemplate: "files:\n{{all_files}}"),
        ])
        let engine = WorkflowEngine(workflow: workflow, frontend: NullAgentFrontend())

        var seenDescription = ""
        _ = await engine.run(input: "x") { args in
            seenDescription = args.description
            return digest(profile: args.profileName, summary: "ok")
        }

        XCTAssertTrue(seenDescription.contains("(no files identified yet)"))
    }

    func testAllFilesDoesNotDoubleCountFileBothReadAndModifiedByTheSameStage() async {
        let workflow = Workflow(name: "t", steps: [
            WorkflowStep(id: "a", name: "A", profile: .executor, descriptionTemplate: "{{input}}"),
            WorkflowStep(id: "b", name: "B", profile: .reviewer,
                         descriptionTemplate: "{{all_files}}", dependsOn: ["a"]),
        ])
        let box = DescriptionBox()
        let engine = WorkflowEngine(workflow: workflow, frontend: NullAgentFrontend())

        _ = await engine.run(input: "x") { args in
            if args.profileName == "executor" {
                return digest(profile: args.profileName, summary: "ok",
                               modifiedFiles: ["src/Foo.swift"], readFiles: ["src/Foo.swift"])
            }
            box.append(args.description)
            return digest(profile: args.profileName, summary: "ok")
        }

        let occurrences = box.values[0].components(separatedBy: "src/Foo.swift").count - 1
        XCTAssertEqual(occurrences, 1, "a file both read and modified by the same stage must appear once, not twice")
    }

    // MARK: - partial upstream results must not be threaded downstream as unqualified "ground truth"

    func testPartialUpstreamResultIsFlaggedRatherThanTreatedAsGroundTruth() async {
        let workflow = Workflow(name: "t", steps: [
            WorkflowStep(id: "a", name: "A", profile: .codebaseResearch, descriptionTemplate: "{{input}}"),
            WorkflowStep(id: "b", name: "B", profile: .planner,
                         descriptionTemplate: "research: {{a}}", dependsOn: ["a"]),
        ])
        let box = DescriptionBox()
        let engine = WorkflowEngine(workflow: workflow, frontend: NullAgentFrontend())

        let result = await engine.run(input: "x") { args in
            if args.profileName == "codebase_research" {
                return digest(profile: args.profileName, summary: "partial findings", status: "partial")
            }
            box.append(args.description)
            return digest(profile: args.profileName, summary: "ok")
        }

        XCTAssertEqual(result.results.first?.status, "partial")
        XCTAssertTrue(result.succeeded, "partial still lets the pipeline continue — it's a caveat, not a hard failure")
        XCTAssertTrue(box.values.first?.contains("WARNING") == true,
                      "b must see an explicit truncation warning instead of silently trusting a's result")
        XCTAssertTrue(box.values.first?.contains("partial findings") == true,
                      "the partial content itself must still be threaded through, just flagged")
    }
}
