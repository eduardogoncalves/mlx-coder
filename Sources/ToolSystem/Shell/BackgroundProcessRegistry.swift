// Sources/ToolSystem/Shell/BackgroundProcessRegistry.swift
// Tracks detached background jobs so they can be torn down with their owner.

import Foundation
import Darwin

/// Records the PIDs of detached background jobs started via `bash`
/// `mode: "background"` (`nohup … &`) so they can be killed when the agent that
/// started them finishes.
///
/// A sub-agent that launches a server this way would otherwise leave it running
/// forever: the `nohup` deliberately outlives the shell, and once the sub-agent
/// returns nothing holds a handle to it. Scoping a registry to the sub-agent's
/// run and terminating it on completion keeps those processes from leaking past
/// the turn that created them.
///
/// Thread-safe (`@unchecked Sendable` guarded by a lock): a `bash` launch on one
/// task and end-of-run cleanup can race.
public final class BackgroundProcessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var pids: [pid_t] = []

    public init() {}

    /// Records a launched background job's root PID (the `nohup` subshell). Its
    /// whole tree is torn down together, so descendants need not be recorded.
    public func register(_ pid: pid_t) {
        guard pid > 1 else { return }
        lock.withLock { pids.append(pid) }
    }

    /// Snapshot of currently-tracked PIDs (diagnostics / tests).
    public func trackedPIDs() -> [pid_t] {
        lock.withLock { pids }
    }

    /// SIGTERMs every tracked process tree, waits a short grace, then SIGKILLs
    /// any survivor — the same escalate-after-grace policy `BashTool` uses for
    /// its sync-mode timeout. Clears the list and returns the PIDs it signalled,
    /// so a second call after the processes are gone is a no-op.
    @discardableResult
    public func terminateAll(graceSeconds: Double = 2.0) async -> [pid_t] {
        let victims: [pid_t] = lock.withLock {
            let snapshot = pids
            pids = []
            return snapshot
        }

        guard !victims.isEmpty else { return [] }
        for pid in victims {
            ProcessTreeKiller.killTree(root: pid, signal: SIGTERM)
        }
        try? await Task.sleep(for: .seconds(graceSeconds))
        for pid in victims {
            ProcessTreeKiller.killTree(root: pid, signal: SIGKILL)
        }
        return victims
    }
}
