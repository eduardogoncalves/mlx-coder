// Sources/CLI/DebugEventFrontend.swift
// Debug frontend for validating event timing and content.
//
// Activated with `--ui debug`. Writes every AgentEvent to stdout with a
// microsecond timestamp and to /tmp/mlx-coder-events.log so you can
// `tail -f` it in a parallel terminal.
//
// Usage:
//   mlx-coder chat --ui debug
//   # In another terminal:
//   tail -f /tmp/mlx-coder-events.log

import Foundation

public final class DebugEventFrontend: AgentFrontend, @unchecked Sendable {

    private let logURL = URL(fileURLWithPath: "/tmp/mlx-coder-events.log")
    private let fileHandle: FileHandle?
    private let startTime: Date

    public init() {
        self.startTime = Date()
        // Truncate/create the log file at startup.
        FileManager.default.createFile(atPath: "/tmp/mlx-coder-events.log", contents: nil)
        self.fileHandle = try? FileHandle(forWritingTo: logURL)
        fileHandle?.seekToEndOfFile()
        log("=== DebugEventFrontend started at \(Date()) ===")
        print("[debug] Logging events to /tmp/mlx-coder-events.log")
        print("[debug] Run in another terminal: tail -f /tmp/mlx-coder-events.log")
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

        case .thinkingStarted:
            log("[\(ts)] thinkingStarted")

        case .thinkingChunk(let text):
            let escaped = text.replacingOccurrences(of: "\n", with: "\\n")
            log("[\(ts)] thinkingChunk: \"\(escaped)\"")

        case .thinkingEnded:
            log("[\(ts)] thinkingEnded")

        case .toolCallStarted(let snap):
            log("[\(ts)] toolCallStarted: \(snap.name)")

        case .toolCallResult(let snap):
            log("[\(ts)] toolCallResult: \(snap.toolName) error=\(snap.isError)")

        case .generationActivity(let phase):
            switch phase {
            case .started(let msg): log("[\(ts)] generationActivity.started: \(msg)")
            case .phase(let msg):   log("[\(ts)] generationActivity.phase: \(msg)")
            case .ended:            log("[\(ts)] generationActivity.ended")
            }

        case .status(let msg):
            log("[\(ts)] status(\(msg.severity)): \(msg.text)")

        case .error(let err):
            log("[\(ts)] error: \(err)")

        case .stats(let s):
            log("[\(ts)] stats: \(s.generationTokens) tokens @ \(String(format: "%.1f", s.tokensPerSecond)) tok/s")

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
