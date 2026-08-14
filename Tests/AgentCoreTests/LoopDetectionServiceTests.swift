// Tests for LoopDetectionService.failedCallSignature, which decides whether
// two failed tool calls count as "the same failure" for the identical-failure
// steer/abort thresholds in AgentLoop.registerFailedCall.

import XCTest
@testable import MLXCoder

final class LoopDetectionServiceTests: XCTestCase {

    // MARK: - edit_file: signature keyed on path, not old_text/new_text

    func testEditFileSignatureIgnoresOldTextAndNewText() {
        // A model re-guessing old_text after a failed match changes
        // old_text/new_text on nearly every retry. If the signature included
        // those fields (like every other tool's does), two failed edit_file
        // calls against the same file would almost never look identical, and
        // the model could thrash against one file indefinitely without ever
        // tripping the steer/abort thresholds — which is exactly what let a
        // real session run 80+ failed edit_file attempts against one file
        // before a human had to abort it. The signature must depend on the
        // path alone so any run of edit_file failures against the same file
        // is recognized as the same failure.
        let first = LoopDetectionService.failedCallSignature(
            callName: "edit_file",
            arguments: ["path": "src/Foo.cs", "old_text": "guess one\nabc", "new_text": "replacement one"]
        )
        let second = LoopDetectionService.failedCallSignature(
            callName: "edit_file",
            arguments: ["path": "src/Foo.cs", "old_text": "guess two\ndef", "new_text": "replacement two"]
        )
        XCTAssertEqual(first, second, "failed edit_file calls against the same path must share a signature regardless of old_text/new_text")
    }

    func testEditFileSignatureDiffersAcrossFiles() {
        let fooSignature = LoopDetectionService.failedCallSignature(
            callName: "edit_file",
            arguments: ["path": "src/Foo.cs", "old_text": "x", "new_text": "y"]
        )
        let barSignature = LoopDetectionService.failedCallSignature(
            callName: "edit_file",
            arguments: ["path": "src/Bar.cs", "old_text": "x", "new_text": "y"]
        )
        XCTAssertNotEqual(fooSignature, barSignature, "failures against different files are genuinely different failures")
    }

    // MARK: - Other tools: unaffected, still keyed on the full arguments

    func testNonEditFileToolSignatureStillIncludesFullArguments() {
        let first = LoopDetectionService.failedCallSignature(
            callName: "bash",
            arguments: ["command": "echo one"]
        )
        let second = LoopDetectionService.failedCallSignature(
            callName: "bash",
            arguments: ["command": "echo two"]
        )
        XCTAssertNotEqual(first, second, "non-edit_file tools should keep their existing exact-arguments signature")
    }

    // MARK: - evaluateFailedCallLoop end-to-end: streak now accumulates across varying old_text

    func testFailedCallLoopBreaksAfterVaryingEditFileFailuresAgainstSamePath() {
        var signature: String?
        var streak = 0
        var lastState: (nextSignature: String, nextStreak: Int, shouldSteer: Bool, shouldBreak: Bool)?

        let guesses = ["alpha", "beta", "gamma"] // a different old_text guess every attempt
        for guess in guesses {
            let state = LoopDetectionService.evaluateFailedCallLoop(
                callName: "edit_file",
                arguments: ["path": "src/Foo.cs", "old_text": guess, "new_text": "fix"],
                previousSignature: signature,
                previousStreak: streak
            )
            signature = state.nextSignature
            streak = state.nextStreak
            lastState = state
        }

        XCTAssertEqual(streak, 3, "three failed attempts against the same path, despite different old_text, should form one streak")
        XCTAssertTrue(lastState?.shouldBreak ?? false, "the default break limit (3) should trip even though every old_text guess differed")
    }
}
