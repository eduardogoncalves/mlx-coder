// Tests for the uniform "harness intervention" convention added to
// `AgentFrontend` (Sources/AgentFrontend/AgentFrontend.swift):
// `harnessIntervention(_:severity:)` and `harnessInterventionError(_:)`.
//
// These are the mlx-coder equivalent of little-coder's
// `_shared/intervention.ts::harnessIntervention` — the single, uniformly
// worded channel every genuine harness override/correction/block/redirect
// (auto-correction, context compaction, thinking-budget enforcement,
// malformed tool-call recovery, steering, write-guard blocks, repeated-
// failure aborts, ...) is routed through, so the user always sees one
// recognizable "harness intervention: " prefix no matter which subsystem
// fired it.
//
// This only covers the formatting contract of the helper itself — that it
// prepends the fixed prefix verbatim, preserves the caller's message and
// severity untouched, and routes to the right underlying `AgentEvent` case
// (`.status` for the soft variant, `.error` for the hard-abort variant). It
// does NOT cover any specific call site's wording (AgentLoop's generation
// loop needs a loaded model to exercise), nor rendering — the frontends'
// severity-based styling is exercised implicitly by every other event test
// and is out of scope here.

import XCTest
@testable import MLXCoder

/// Minimal `AgentFrontend` test double that records every emitted event
/// in order, so assertions can inspect exactly what a helper call produced.
/// Not thread-safe by design — these tests only ever call it from a single
/// synchronous XCTest method, mirroring the existing precedent of pure,
/// non-actor-isolated unit tests elsewhere in this directory
/// (ThinkingBudgetTests, ContextWatchdogTests).
private final class RecordingAgentFrontend: AgentFrontend, @unchecked Sendable {
    private(set) var events: [AgentEvent] = []

    func emit(_ event: AgentEvent) {
        events.append(event)
    }

    func request(_ request: AgentRequest) async -> AgentResponse {
        switch request {
        case .approval:     return .approval(.deny(suggestion: nil))
        case .optionSelect: return .optionSelect(nil)
        case .textInput:    return .textInput(nil)
        case .clarifyingQuestions: return .clarifyingQuestions(nil)
        }
    }
}

final class HarnessInterventionTests: XCTestCase {

    // MARK: - harnessIntervention(_:severity:)

    func testPrependsFixedPrefixVerbatim() {
        let frontend = RecordingAgentFrontend()
        frontend.harnessIntervention("forcing the model to start implementing.")

        guard case .status(let status)? = frontend.events.first else {
            return XCTFail("expected a single .status event")
        }
        XCTAssertEqual(status.text, "harness intervention: forcing the model to start implementing.")
    }

    func testDefaultSeverityIsInfo() {
        let frontend = RecordingAgentFrontend()
        frontend.harnessIntervention("auto-corrected the arguments.")

        guard case .status(let status)? = frontend.events.first else {
            return XCTFail("expected a single .status event")
        }
        XCTAssertEqual(status.severity, .info)
    }

    func testSeverityIsPassedThroughUnmodified() {
        let frontend = RecordingAgentFrontend()
        frontend.harnessIntervention("stopped deliberating.", severity: .warning)

        guard case .status(let status)? = frontend.events.first else {
            return XCTFail("expected a single .status event")
        }
        XCTAssertEqual(status.severity, .warning)
    }

    func testEmitsExactlyOneEventPerCall() {
        let frontend = RecordingAgentFrontend()
        frontend.harnessIntervention("one line, not several.")
        XCTAssertEqual(frontend.events.count, 1)
    }

    func testMessageContentIsPreservedExactlyAfterThePrefix() {
        let frontend = RecordingAgentFrontend()
        let message = "recovered 42 truncated bytes for foo.txt instead of discarding the partial write."
        frontend.harnessIntervention(message)

        guard case .status(let status)? = frontend.events.first else {
            return XCTFail("expected a single .status event")
        }
        XCTAssertTrue(status.text.hasPrefix("harness intervention: "))
        XCTAssertEqual(String(status.text.dropFirst("harness intervention: ".count)), message)
    }

    // MARK: - harnessInterventionError(_:)

    func testErrorVariantRoutesThroughTheErrorChannel() {
        let frontend = RecordingAgentFrontend()
        frontend.harnessInterventionError("stopping the turn — exceeded the tool budget.")

        guard case .error(let text)? = frontend.events.first else {
            return XCTFail("expected a single .error event")
        }
        XCTAssertEqual(text, "harness intervention: stopping the turn — exceeded the tool budget.")
    }

    func testErrorVariantDoesNotAlsoEmitAStatusEvent() {
        // The hard-abort variant should surface exactly once, through the
        // error channel only — not doubled onto the status channel too.
        let frontend = RecordingAgentFrontend()
        frontend.harnessInterventionError("stopping the turn.")

        XCTAssertEqual(frontend.events.count, 1)
        if case .status = frontend.events.first {
            XCTFail("harnessInterventionError should not also emit a .status event")
        }
    }

    // MARK: - Consistency between the two variants

    func testBothVariantsUseTheIdenticalPrefixString() {
        let frontend = RecordingAgentFrontend()
        frontend.harnessIntervention("a")
        frontend.harnessInterventionError("b")

        let texts: [String] = frontend.events.compactMap { event in
            switch event {
            case .status(let s): return s.text
            case .error(let e): return e
            default: return nil
            }
        }
        XCTAssertEqual(texts.count, 2)
        for text in texts {
            XCTAssertTrue(text.hasPrefix("harness intervention: "), "expected uniform prefix, got: \(text)")
        }
    }
}
