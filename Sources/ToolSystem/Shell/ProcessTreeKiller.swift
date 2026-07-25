// Sources/ToolSystem/Shell/ProcessTreeKiller.swift
// Kill a subprocess AND all its descendants.

import Foundation
import Darwin

/// Terminates a process and every descendant it spawned.
///
/// Foundation's `Process.terminate()` sends `SIGTERM` only to the single
/// tracked PID. For a shell pipeline like `zsh -c "curl ... | head"`, that
/// kills the `zsh` wrapper but leaves `curl`/`head` running as orphans —
/// `curl` in particular keeps holding a live network socket indefinitely. This
/// walks the actual process tree via libproc (`proc_listpids(PROC_PPID_ONLY)`)
/// and signals every descendant, which is safe on macOS without creating a new
/// process group (so there's no risk of `killpg` hitting our own group).
enum ProcessTreeKiller {
    /// Direct child PIDs of `ppid`, via libproc.
    static func childPIDs(of ppid: pid_t) -> [pid_t] {
        let flavor = UInt32(PROC_PPID_ONLY)
        let byteSize = proc_listpids(flavor, UInt32(ppid), nil, 0)
        guard byteSize > 0 else { return [] }
        let capacity = Int(byteSize) / MemoryLayout<pid_t>.stride
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let written = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listpids(flavor, UInt32(ppid), buffer.baseAddress, byteSize)
        }
        guard written > 0 else { return [] }
        let count = Int(written) / MemoryLayout<pid_t>.stride
        return pids.prefix(count).filter { $0 > 1 }
    }

    /// `root` plus all descendants, discovered depth-first. Bounded to avoid a
    /// pathological loop if the process table is enormous or cyclic.
    static func processTree(root: pid_t) -> [pid_t] {
        guard root > 1 else { return [] }
        var discovered: [pid_t] = []
        var stack: [pid_t] = [root]
        var seen = Set<pid_t>()
        var iterations = 0
        while let current = stack.popLast(), iterations < 10_000 {
            iterations += 1
            guard seen.insert(current).inserted else { continue }
            discovered.append(current)
            stack.append(contentsOf: childPIDs(of: current))
        }
        return discovered
    }

    /// Sends `signal` to `root` and every descendant. Descendants are signalled
    /// before their parents so a shell can't reap/re-parent a child out from
    /// under us before we reach it. No-ops on PIDs that already exited.
    static func killTree(root: pid_t, signal: Int32) {
        guard root > 1 else { return }
        for pid in processTree(root: root).reversed() {
            _ = kill(pid, signal)
        }
    }
}
