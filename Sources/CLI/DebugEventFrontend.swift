// Sources/CLI/DebugEventFrontend.swift
// Debug frontend for validating event timing and content.
//
// Activated with `--ui debug`. Writes every AgentEvent to stdout with a
// microsecond timestamp, and to a per-user, per-process log file under the
// user's temporary directory (printed at startup). You can `tail -f` that
// file in a parallel terminal.
//
// Usage:
//   mlx-coder chat --ui debug
//   # In another terminal, tail the path printed at startup, e.g.:
//   tail -f "$TMPDIR/mlx-coder-debug/events-<pid>.log"

import Foundation

public final class DebugEventFrontend: AgentFrontend, @unchecked Sendable {

    private let logURL: URL
    private let fileHandle: FileHandle?
    private let startTime: Date

    /// Per-user, per-process log path under the user's temporary directory.
    /// Using the user-specific temp dir (and a unique filename) prevents
    /// symlink-overwrite attacks that were possible against the previous
    /// hard-coded `/tmp/mlx-coder-events.log` on multi-user systems.
    private static func makeLogURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-coder-debug", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir.appendingPathComponent("events-\(ProcessInfo.processInfo.processIdentifier).log")
    }

    public init() {
        self.startTime = Date()
        let url = Self.makeLogURL()
        self.logURL = url
        // Atomically create with 0600 perms inside the just-created 0700
        // directory so the file is scoped to the current user and other local
        // users cannot pre-create it as a symlink to overwrite arbitrary files.
        FileManager.default.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        )
        self.fileHandle = try? FileHandle(forWritingTo: url)
        fileHandle?.seekToEndOfFile()
        log("=== DebugEventFrontend started at \(Date()) ===")
        print("[debug] Logging events to \(url.path)")
        print("[debug] Run in another terminal: tail -f \(url.path)")
    }

    deinit {
        log("=== DebugEventFrontend stopped ===")
        fileHandle?.closeFile()
    }

    // MARK: - AgentFrontend

    public func emit(_ event: AgentEvent) {
        let ts = String(format: "+%.3fs", Date().timeIntervalSince(startTime))
        switch event {
        case .assistantTextChunk(let text):
            let escaped = text.replacingOccurrences(of: "\n", with: "\\n")
            log("[\(ts)] assistantTextChunk: \"\(escaped)\"")

        case .thinkingActivity(let lifecycle):
            switch lifecycle {
            case .started: log("[\(ts)] thinkingActivity.started")
            case .ended:   log("[\(ts)] thinkingActivity.ended")
            }

        case .thinkingChunk(let text):
            let escaped = text.replacingOccurrences(of: "\n", with: "\\n")
            log("[\(ts)] thinkingChunk: \"\(escaped)\"")

        case .tokenProcessingActivity(let lifecycle):
            switch lifecycle {
            case .started: log("[\(ts)] tokenProcessingActivity.started")
            case .ended:   log("[\(ts)] tokenProcessingActivity.ended")
            }

        case .toolCallStarted(let snap):
            log("[\(ts)] toolCallStarted: \(snap.name)")

        case .toolCallResult(let snap):
            log("[\(ts)] toolCallResult: \(snap.toolName) error=\(snap.isError)")

        case .generationActivity(let lifecycle):
            switch lifecycle {
            case .started: log("[\(ts)] generationActivity.started")
            case .ended:   log("[\(ts)] generationActivity.ended")
            }

        case .status(let msg):
            log("[\(ts)] status(\(msg.severity)): \(msg.text)")

        case .error(let err):
            log("[\(ts)] error: \(err)")

        case .stats(let s):
            log("[\(ts)] stats: \(s.generationTokens) tokens @ \(String(format: "%.1f", s.tokensPerSecond)) tok/s")

        case .subAgentActivity(let activity):
            switch activity {
            case .started(let profile, let modelPath): log("[\(ts)] subAgentActivity.started profile=\(profile) model=\(modelPath)")
            case .ended: log("[\(ts)] subAgentActivity.ended")
            }

        default:
            log("[\(ts)] event: \(event)")
        }
    }

    public func request(_ req: AgentRequest) async -> AgentResponse {
        let ts = String(format: "+%.3fs", Date().timeIntervalSince(startTime))
        switch req {
        case .approval(let r):
            log("[\(ts)] request.approval: \(r.toolName)")
            print("[debug] Approval request for \(r.toolName) — auto-approving")
            return .approval(.allowOnce)
        case .optionSelect(let r):
            log("[\(ts)] request.optionSelect: \(r.prompt)")
            return .optionSelect(nil)
        case .textInput(let r):
            log("[\(ts)] request.textInput: \(r.prompt)")
            return .textInput(nil)
        }
    }

    // MARK: - Private

    private func log(_ line: String) {
        let output = line + "\n"
        print(output, terminator: "")
        fflush(stdout)
        if let data = output.data(using: .utf8) {
            fileHandle?.write(data)
        }
    }
}
