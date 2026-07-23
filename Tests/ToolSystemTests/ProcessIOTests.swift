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
}
