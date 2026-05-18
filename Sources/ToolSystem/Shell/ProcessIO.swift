// Sources/ToolSystem/Shell/ProcessIO.swift
// Shared subprocess I/O helpers used by `BashTool`, `GitService`,
// `UpdateCommand`, and the read-only `GrepTool` / `GlobTool` /
// `CodeSearchTool` / `BuildToolErrorDetector` callers.
//
// The kernel pipe buffer on macOS is small (16–64 KiB). A child process that
// writes more than that before exiting will block in `write(2)`, which then
// stalls `Process.waitUntilExit()` forever because the parent only drains the
// pipe after the child exits. The helpers below drain stdout/stderr
// concurrently via `readabilityHandler`s, so children of any output size make
// progress.

import Foundation

/// Thread-safe accumulator for stdout/stderr bytes captured by readability
/// handlers. Used by every subprocess call site in mlx-coder that needs to
/// read a child's full output without risking the pipe-buffer deadlock.
///
/// `@unchecked Sendable` is intentional: the only mutable state is two `Data`
/// buffers guarded by `NSLock`, which is a Sendable-compatible primitive on
/// every supported platform.
final class PipeOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func appendStdout(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        stdout.append(data)
    }

    func appendStderr(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        stderr.append(data)
    }

    func stdoutSnapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        return stdout
    }

    func stderrSnapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        return stderr
    }
}

/// Synchronous subprocess I/O helpers. All helpers assume the caller has
/// already configured `process.executableURL` / `arguments` / etc., and that
/// the caller will invoke `process.run()` itself or rely on the runner
/// helpers below.
///
/// `BashTool.executeSync` inlines an equivalent collector + drain because it
/// also wires `withTaskCancellationHandler` and a timeout `Task` around
/// `waitUntilExit`; the helpers here cover the simpler synchronous case.
enum ProcessIO {

    /// Installs readability handlers on `stdoutPipe` and `stderrPipe`, blocks
    /// the calling thread until `process` exits, then drains any remaining
    /// bytes. Safe for arbitrarily large child output.
    ///
    /// The caller must have already started `process` via `process.run()`.
    static func drainAndWait(
        process: Process,
        stdoutPipe: Pipe,
        stderrPipe: Pipe
    ) -> (stdout: String, stderr: String) {
        let (outData, errData) = drainAndWaitData(
            process: process,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe
        )
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        return (out, err)
    }

    /// Same as `drainAndWait` but returns the raw `Data`. Useful when the
    /// caller wants to defer UTF-8 decoding (e.g. to preserve binary output
    /// or use a different encoding).
    static func drainAndWaitData(
        process: Process,
        stdoutPipe: Pipe,
        stderrPipe: Pipe
    ) -> (stdout: Data, stderr: Data) {
        let collector = PipeOutputCollector()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            collector.appendStdout(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            collector.appendStderr(data)
        }

        process.waitUntilExit()

        // Tear down readability handlers and drain any final bytes. After
        // `waitUntilExit` returns the child has closed its write ends; the
        // remaining reads are non-blocking.
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let tailOut = stdoutPipe.fileHandleForReading.availableData
        let tailErr = stderrPipe.fileHandleForReading.availableData
        if !tailOut.isEmpty { collector.appendStdout(tailOut) }
        if !tailErr.isEmpty { collector.appendStderr(tailErr) }

        return (collector.stdoutSnapshot(), collector.stderrSnapshot())
    }

    /// Runs `process` to completion and returns its captured output. Sets up
    /// the pipes and installs readability handlers so the child can produce
    /// output of any size without deadlocking.
    ///
    /// `stderrPipe` is configured but its contents are returned alongside
    /// stdout so the caller can attach diagnostics on failure.
    static func runCapturing(_ process: Process) throws -> (stdout: String, stderr: String) {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        return drainAndWait(process: process, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
    }
}
