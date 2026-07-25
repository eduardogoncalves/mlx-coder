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
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Runs a block exactly once, thread-safely — used to guard a
/// `CheckedContinuation` that may be resumed from either a process termination
/// handler or an already-exited fast path (a double resume traps).
final class OneShotResume: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func run(_ block: () -> Void) {
        lock.lock()
        let first = !fired
        fired = true
        lock.unlock()
        if first { block() }
    }
}

/// Lightweight timestamped diagnostics for subprocess timing/timeouts/kills.
/// Gated behind `MLXCODER_DEBUG_TOOL_TIMING` ("1"/"true", case-insensitive —
/// matches the truthy convention used by `MLXCODER_STRICT_ORCHESTRATION`) so
/// it stays completely silent by default. There is no logging framework
/// elsewhere in this codebase, so this writes directly to
/// `FileHandle.standardError`.
enum ToolTimingLog {
    static let isEnabled: Bool = {
        guard let raw = ProcessInfo.processInfo.environment["MLXCODER_DEBUG_TOOL_TIMING"] else {
            return false
        }
        return ["1", "true"].contains(raw.lowercased())
    }()

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        // A fresh formatter per call avoids sharing a mutable
        // `ISO8601DateFormatter` (not `Sendable`) across concurrent callers;
        // this path only runs when the opt-in debug env var is set, so the
        // extra allocation is not a concern.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = "[mlx-coder timing] \(formatter.string(from: Date())) \(message())\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

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

    /// Reads whatever bytes are currently available on `handle`'s file
    /// descriptor without blocking, then restores its original blocking mode.
    ///
    /// After `process.waitUntilExit()` returns, the process we were tracking
    /// has exited — but a *detached grandchild* it spawned before exiting
    /// (classically: MSBuild/VBCSCompiler "node reuse" worker processes left
    /// behind by `dotnet build`/`dotnet restore`, or an npm/yarn background
    /// daemon) can still hold a duplicate of the pipe's write end open. In
    /// that case the pipe never signals EOF, and a plain blocking read like
    /// `FileHandle.availableData` — despite the common assumption that "the
    /// child has closed its write end by now" — waits forever even though
    /// the command we actually cared about already finished. Toggling
    /// `O_NONBLOCK` for this one read sidesteps that regardless of why the
    /// pipe is still held open.
    static func nonBlockingDrain(_ handle: FileHandle) -> Data {
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags != -1 else { return Data() }
        guard fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1 else { return Data() }
        defer { _ = fcntl(fd, F_SETFL, flags) }

        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { ptr -> Int in
                read(fd, ptr.baseAddress, ptr.count)
            }
            if bytesRead > 0 {
                result.append(contentsOf: buffer[0..<bytesRead])
                continue
            }
            // 0 = EOF; -1 = no data available right now (EAGAIN/EWOULDBLOCK)
            // or another error. Either way, there is nothing more to read
            // without blocking, so stop.
            break
        }
        return result
    }

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
        installReadabilityHandlers(collector: collector, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)

        process.waitUntilExit()

        // Tear down readability handlers and drain any final bytes. Uses a
        // non-blocking read (see `nonBlockingDrain`) rather than
        // `.availableData` — a detached grandchild of the process we waited
        // on can still hold the pipe's write end open, so a blocking read
        // here is not actually guaranteed to return.
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let tailOut = nonBlockingDrain(stdoutPipe.fileHandleForReading)
        let tailErr = nonBlockingDrain(stderrPipe.fileHandleForReading)
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

    // MARK: - Off-pool async waiting (for async/actor call sites)

    /// Installs the same readability handlers as `drainAndWaitData`. Split
    /// out so both the synchronous and async drain variants share one
    /// implementation.
    private static func installReadabilityHandlers(
        collector: PipeOutputCollector,
        stdoutPipe: Pipe,
        stderrPipe: Pipe
    ) {
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
    }

    /// Best-effort: makes `process`'s child its own process-group leader via
    /// a parent-side `setpgid(pid, pid)` call immediately after `run()`.
    ///
    /// This lets a timeout kill take out helper children the process spawns
    /// before exiting (classically: git's http/askpass transport helpers)
    /// via `killpg`, not just the tracked PID, which `process.terminate()`
    /// alone cannot reach. There is an inherent, unavoidable race with the
    /// child performing its own `exec` — `Process`/`posix_spawn` do not
    /// expose a child-side `POSIX_SPAWN_SETPGROUP` file action via Foundation
    /// on Darwin — but calling `setpgid` this soon after `run()` returns
    /// wins that race in practice. Callers must not rely on this for
    /// correctness; `terminateEscalating` always also signals the tracked
    /// PID directly as a fallback.
    @discardableResult
    static func makeProcessGroupLeader(_ process: Process) -> Bool {
        let pid = process.processIdentifier
        guard pid > 0 else { return false }
        return setpgid(pid, pid) == 0
    }

    /// Sends SIGTERM to `process`, then escalates to SIGKILL after `grace`
    /// seconds if it is still running. When `killProcessGroup` is true, also
    /// signals the process group (see `makeProcessGroupLeader`) so helper
    /// children die too. Always also signals the tracked PID directly — a
    /// harmless no-op if the group signal already covered it, and the only
    /// thing that works if `makeProcessGroupLeader` lost its race.
    static func terminateEscalating(
        process: Process,
        killProcessGroup: Bool,
        grace: TimeInterval = 2.0
    ) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }

        let signal: @Sendable (Int32, String) -> Void = { sig, label in
            if killProcessGroup {
                _ = killpg(pid, sig)
            }
            _ = kill(pid, sig)
            ToolTimingLog.log("sent \(label) to pid \(pid)\(killProcessGroup ? " (and its process group)" : "")")
        }

        signal(SIGTERM, "SIGTERM")
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + grace) {
            if process.isRunning {
                signal(SIGKILL, "SIGKILL")
            }
        }
    }

    /// Waits for `process` to exit off the calling thread. Swift's
    /// cooperative concurrency thread pool has a small, fixed number of
    /// worker threads; calling `Process.waitUntilExit()` directly from an
    /// `async`/actor context parks one of those threads for as long as the
    /// child runs; a stalled child (e.g. `git push` against a black-holed
    /// remote) then starves the pool, and every *other* component relying on
    /// `Task.sleep`-based timeouts stops making progress too. Waiting on a
    /// background `DispatchQueue` instead keeps the calling thread free.
    ///
    /// Cooperative cancellation of the calling `Task` best-effort
    /// `terminate()`s the process so the background wait can complete.
    static func offPoolWait(process: Process) async {
        await waitForExit(process: process) { process.terminate() }
    }

    /// Suspends until `process` exits, without parking any thread in a blocking
    /// `waitUntilExit()`. Foundation's `terminationHandler` is invoked exactly
    /// once, on Foundation's own queue, when the child exits — whereas calling
    /// `waitUntilExit()` off the thread that ran the process races Foundation's
    /// internal SIGCHLD reaper: under load the reaper can consume the child
    /// first and `waitUntilExit()` then never returns, parking that thread
    /// forever. Enough of those and the shared thread pool is exhausted and the
    /// whole process wedges (the observed hang). `onCancel` runs if the calling
    /// task is cancelled, so a caller can tear the child (tree) down.
    static func waitForExit(process: Process, onCancel: @escaping @Sendable () -> Void) async {
        let once = OneShotResume()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                process.terminationHandler = { _ in once.run { cont.resume() } }
                // Cover the race where the child exited before the handler was
                // installed (Foundation won't call it then).
                if !process.isRunning {
                    once.run { cont.resume() }
                }
            }
        } onCancel: {
            onCancel()
        }
    }

    /// Async, off-pool equivalent of `drainAndWaitData`. Installs the same
    /// readability handlers, then waits for `process` to exit via
    /// `offPoolWait` (never blocking a cooperative-pool thread) instead of
    /// calling `waitUntilExit()` directly.
    ///
    /// If `timeout` is provided and elapses before the process exits, the
    /// process (and, if `killProcessGroup` is true, its process group) is
    /// killed via `terminateEscalating` (SIGTERM, then SIGKILL after a short
    /// grace period) and the returned `timedOut` flag is `true`. The
    /// captured output up to that point is still returned.
    ///
    /// The caller must have already started `process` via `process.run()`.
    static func drainAndWaitDataAsync(
        process: Process,
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        timeout: TimeInterval? = nil,
        killProcessGroup: Bool = false
    ) async -> (stdout: Data, stderr: Data, timedOut: Bool) {
        let collector = PipeOutputCollector()
        installReadabilityHandlers(collector: collector, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)

        let timedOut: Bool
        if let timeout {
            timedOut = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    await offPoolWait(process: process)
                    return false
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(timeout))
                    guard !Task.isCancelled else { return false }
                    ToolTimingLog.log("timeout (\(timeout)s) fired for pid \(process.processIdentifier) — killing")
                    terminateEscalating(process: process, killProcessGroup: killProcessGroup)
                    return true
                }
                // Whichever finishes first decides the outcome. If the exit
                // waiter wins, cancelling the sleep task lets it return
                // promptly. If the timeout wins, cancelling the exit waiter
                // is a no-op signal (it has no cancellation check of its
                // own) — it naturally completes once `terminateEscalating`
                // above causes the process to actually die, which is
                // bounded by `grace`.
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
        } else {
            await offPoolWait(process: process)
            timedOut = false
        }

        // Tear down readability handlers and drain any final bytes. See
        // `drainAndWaitData` for why a non-blocking read is required here.
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let tailOut = nonBlockingDrain(stdoutPipe.fileHandleForReading)
        let tailErr = nonBlockingDrain(stderrPipe.fileHandleForReading)
        if !tailOut.isEmpty { collector.appendStdout(tailOut) }
        if !tailErr.isEmpty { collector.appendStderr(tailErr) }

        return (collector.stdoutSnapshot(), collector.stderrSnapshot(), timedOut)
    }

    /// String-decoding convenience over `drainAndWaitDataAsync`, mirroring
    /// the `drainAndWaitData`/`drainAndWait` relationship above.
    static func drainAndWaitAsync(
        process: Process,
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        timeout: TimeInterval? = nil,
        killProcessGroup: Bool = false
    ) async -> (stdout: String, stderr: String, timedOut: Bool) {
        let (outData, errData, timedOut) = await drainAndWaitDataAsync(
            process: process,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            timeout: timeout,
            killProcessGroup: killProcessGroup
        )
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        return (out, err, timedOut)
    }
}
