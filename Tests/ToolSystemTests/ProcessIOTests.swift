// Regression test for a hang class where a command's *direct* child exits
// promptly, but a detached grandchild it spawned (classically: an MSBuild
// "node reuse" worker left behind by `dotnet build`/`dotnet restore`, or an
// npm/yarn background daemon) keeps a duplicate of the stdout/stderr pipe's
// write end open. A plain blocking read for the "final tail" of output after
// `waitUntilExit()` — e.g. `FileHandle.availableData` — then never returns,
// because the pipe never sees EOF, even though the command we cared about
// already finished. `ProcessIO.nonBlockingDrain` must not be susceptible to
// this.

import XCTest
@testable import MLXCoder

final class ProcessIOTests: XCTestCase {
    func testDrainAndWaitDataDoesNotHangWhenGrandchildHoldsPipeOpen() throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/zsh")
        // The outer shell prints "hello" and exits immediately, but first
        // backgrounds a detached subshell that sleeps — inheriting stdout —
        // simulating an orphaned grandchild that outlives the command we
        // actually waited on.
        process.arguments = ["-c", "echo hello; (sleep 3 &) ; exit 0"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let start = Date()
        let (stdout, _) = ProcessIO.drainAndWait(process: process, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
        // Must return well before the orphaned grandchild's 3s sleep ends —
        // a blocking `.availableData` tail read would wait the full 3s (or
        // longer, since the write end never closes at all).
        XCTAssertLessThan(elapsed, 1.5, "drainAndWaitData blocked on the orphaned grandchild's still-open pipe")
    }

    func testNonBlockingDrainReturnsEmptyWhenNoDataAvailable() throws {
        let pipe = Pipe()
        // Nothing has been written and the write end is still open (owned by
        // this test) — a blocking read would hang; the non-blocking drain
        // must return immediately with no data.
        let data = ProcessIO.nonBlockingDrain(pipe.fileHandleForReading)
        XCTAssertTrue(data.isEmpty)
    }

    func testNonBlockingDrainReadsAvailableBytes() throws {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write("partial".data(using: .utf8)!)
        let data = ProcessIO.nonBlockingDrain(pipe.fileHandleForReading)
        XCTAssertEqual(String(data: data, encoding: .utf8), "partial")
    }

    // MARK: - drainAndWaitDataAsync (off-pool wait + timeout + hard kill)

    /// Regression test for the production hang this fix addresses: a
    /// synchronous `Process.waitUntilExit()` called from an async/actor
    /// context (e.g. `GitService.runGitCommand`) with no deadline blocks a
    /// cooperative-pool thread forever when the child stalls (classically: a
    /// `git push`/`pull` against a black-holed remote). `drainAndWaitDataAsync`
    /// must (a) not require the caller to block synchronously and (b) bound
    /// the wait via `timeout`, killing the child (SIGTERM escalating to
    /// SIGKILL) on expiry rather than waiting for it to exit on its own.
    ///
    /// The child here sleeps for 30s — if the timeout/kill path didn't work,
    /// this test would take ~30s (and this suite would visibly hang).
    func testDrainAndWaitDataAsyncTimesOutAndKillsSlowChild() async throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/zsh")
        process.arguments = ["-c", "sleep 30"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let childPID = process.processIdentifier

        let start = Date()
        let (_, _, timedOut) = await ProcessIO.drainAndWaitDataAsync(
            process: process,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            timeout: 1.0
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(timedOut, "drainAndWaitDataAsync should report timedOut for a child that outlives the timeout")
        // Bounded by timeout (1s) + SIGKILL grace (2s, see `terminateEscalating`)
        // + slack for process teardown/scheduling — nowhere near the child's
        // 30s sleep.
        XCTAssertLessThan(elapsed, 6.0, "drainAndWaitDataAsync did not return promptly after its timeout fired")

        // The child must actually be dead, not orphaned — give the SIGKILL
        // escalation (fires ~2s after SIGTERM) a moment to land if it hasn't
        // already, then confirm the PID is gone.
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(kill(childPID, 0), -1, "child process should have been killed, not left running")
    }

    /// Sanity check that a child finishing well within the timeout is not
    /// affected by the timeout machinery (no spurious kill, correct output).
    func testDrainAndWaitDataAsyncReturnsPromptlyWhenChildFinishesBeforeTimeout() async throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/zsh")
        process.arguments = ["-c", "echo fast-exit"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let (stdout, _, timedOut) = await ProcessIO.drainAndWaitDataAsync(
            process: process,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            timeout: 10.0
        )

        XCTAssertFalse(timedOut)
        XCTAssertEqual(String(data: stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), "fast-exit")
    }
}
