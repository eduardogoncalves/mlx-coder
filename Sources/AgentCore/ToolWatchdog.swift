// Sources/AgentCore/ToolWatchdog.swift
// Loop-level wall-clock backstop around tool execution.

import Foundation

/// Thrown when a tool execution exceeds the loop-level watchdog deadline.
///
/// This is the agent loop's last-resort guard: individual tools may (and
/// should) bound their own work, but a tool that hangs — e.g. a `bash` call
/// stuck on a stalled network request — must never be able to freeze the whole
/// turn. The watchdog races the tool against a wall-clock deadline; on expiry
/// it cancels the tool task (cooperative cancellation, which a well-behaved
/// tool like `BashTool` turns into `process` termination) and surfaces this
/// error so the loop can record a failed tool result and keep going.
public struct ToolWatchdogTimeout: Error, Sendable {
    public let toolName: String
    public let seconds: Double
}

/// Configuration + diagnostics for the tool watchdog, read from the environment.
enum ToolWatchdogConfig {
    /// Hard ceiling for any single tool call. Deliberately generous so a
    /// legitimate long build (run via `bash` with a large `timeout`) isn't
    /// killed, but finite so a hung tool can never freeze the turn forever.
    /// Override with `MLXCODER_TOOL_WATCHDOG_SECONDS`.
    static var seconds: Double {
        if let raw = ProcessInfo.processInfo.environment["MLXCODER_TOOL_WATCHDOG_SECONDS"],
           let value = Double(raw), value > 0 {
            return value
        }
        return 1800
    }

    /// When `MLXCODER_DEBUG_TOOL_TIMING` is truthy, emit timestamped
    /// dispatch/return lines to stderr so a "stuck" turn can be pinpointed live.
    static var debugTiming: Bool {
        let raw = (ProcessInfo.processInfo.environment["MLXCODER_DEBUG_TOOL_TIMING"] ?? "").lowercased()
        return raw == "1" || raw == "true" || raw == "yes"
    }

    static func log(_ message: @autoclosure () -> String) {
        guard debugTiming else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("[mlx-coder timing \(stamp)] \(message())\n".utf8))
    }
}

/// Runs `operation` with a hard wall-clock deadline of `seconds`.
///
/// Returns the tool result if it finishes in time; otherwise cancels the
/// operation and throws `ToolWatchdogTimeout`. Structured concurrency means the
/// operation must be cancellable for the group to unwind promptly — every
/// subprocess-backed tool in this codebase wires `withTaskCancellationHandler`
/// (or an off-pool bounded wait) so cancellation actually tears the child down.
func runWithToolWatchdog(
    seconds: Double,
    toolName: String,
    operation: @escaping @Sendable () async throws -> ToolResult
) async throws -> ToolResult {
    try await withThrowingTaskGroup(of: ToolResult.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw ToolWatchdogTimeout(toolName: toolName, seconds: seconds)
        }
        defer { group.cancelAll() }
        // First task to finish wins. If it's the sleeper, it throws the
        // timeout; `defer` then cancels the still-running operation task.
        guard let result = try await group.next() else {
            throw ToolWatchdogTimeout(toolName: toolName, seconds: seconds)
        }
        return result
    }
}
