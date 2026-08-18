// Sources/ToolSystem/CodeMode/CodeModeSandboxProcess.swift
// Parent-side driver for the `execute_code` ("Code Mode") worker process.
//
// Spawns the sibling `CodeModeWorker` binary (Seatbelt-wrapped, same as
// BashTool), hands it the script + the exposed tool schemas over stdin, and
// pumps the request/response protocol documented in
// Sources/CodeModeWorker/main.swift: every `tools.xyz(...)` call the script
// makes arrives here as a `{"type":"call",...}` line, gets dispatched
// through the SAME permission/approval/watchdog/audit pipeline a direct
// model tool call would use (via the `dispatch` closure the caller
// supplies), and the result is written back so the script can continue.
//
// Timeout is enforced here, not in the worker: a script whose synchronous
// body never returns (e.g. an infinite loop) blocks the worker's own
// `evaluateScript` call forever, so the only way to stop it is to kill the
// whole process tree from outside.

import Foundation

public struct CodeModeExecutionResult: Sendable {
    /// JSON-encoded return value (a JSON literal, e.g. `"null"`, `"42"`,
    /// `"{\"a\":1}"`), present only on a clean, non-timed-out completion.
    public let valueJSON: String?
    public let logs: [String]
    public let invalidOutput: Bool
    /// Set when the script threw, the worker failed to launch/handshake, the
    /// output exceeded the size cap, or (see `timedOut`) it was killed.
    public let errorMessage: String?
    public let timedOut: Bool
}

/// Reads newline-delimited lines from a file handle without relying on C
/// stdio buffering. Deliberately duplicated from CodeModeWorker's LineReader
/// (a separate SPM target that cannot share source with this one) — see
/// that file for why `.availableData`, not `readData(ofLength:)`, is used.
private final class SyncLineReader {
    private let handle: FileHandle
    private var buffer = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func nextLine() -> String? {
        while true {
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<newlineIndex]
                buffer.removeSubrange(...newlineIndex)
                return String(data: lineData, encoding: .utf8)
            }
            let chunk = handle.availableData
            if chunk.isEmpty {
                if buffer.isEmpty { return nil }
                let remainder = buffer
                buffer.removeAll()
                return String(data: remainder, encoding: .utf8)
            }
            buffer.append(chunk)
        }
    }
}

public enum CodeModeSandboxProcess {
    public static let defaultTimeoutSeconds: Double = 120
    /// Cap on the combined size of the returned value + captured logs
    /// handed back to the model — mirrors every other tool's output cap
    /// (see BashTool's `maxOutputLines`) so one script can't blow up the
    /// conversation context.
    public static let maxOutputCharacters = 20_000

    /// Env var override for the worker binary's location — used by tests,
    /// where `CommandLine.arguments[0]` is the XCTest runner, not MLXCoder's
    /// own binary, so the normal sibling-of-executable lookup can't find it.
    static let workerPathOverrideEnvVar = "MLXCODER_CODE_MODE_WORKER_PATH"

    static func workerExecutableURL() -> URL? {
        if let override = ProcessInfo.processInfo.environment[workerPathOverrideEnvVar],
           !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        guard let firstArgument = CommandLine.arguments.first else { return nil }
        let mainExecutable = URL(fileURLWithPath: firstArgument).standardizedFileURL
        let candidate = mainExecutable.deletingLastPathComponent().appendingPathComponent("CodeModeWorker")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else { return nil }
        return candidate
    }

    /// Runs `code` in the worker process, exposing `exposedTools` as
    /// `tools.<name>(...)` inside it. Every sub-call the script makes is
    /// routed through `dispatch`, which the caller wires to its own
    /// permission/approval/watchdog/audit pipeline (see
    /// `AgentLoop.executeSubToolCall`) — this function has no policy
    /// opinions of its own beyond the timeout and output cap.
    public static func run(
        code: String,
        exposedTools: [(name: String, description: String, parameters: JSONSchema)],
        workspaceRoot: String,
        useSandbox: Bool,
        timeoutSeconds: Double = defaultTimeoutSeconds,
        maxCalls: Int = 200,
        dispatch: @escaping @Sendable (String, [String: Any]) async -> ToolResult
    ) async -> CodeModeExecutionResult {
        guard let workerURL = workerExecutableURL() else {
            return CodeModeExecutionResult(
                valueJSON: nil, logs: [], invalidOutput: false,
                errorMessage: "execute_code: the CodeModeWorker helper binary was not found next to the running executable",
                timedOut: false
            )
        }

        let process = Process()
        if useSandbox, SandboxEngine.isWorkspaceRootSandboxSafe(workspaceRoot) {
            let sandboxEngine = SandboxEngine(networkPolicy: .deny)
            let escapedWorkerPath = workerURL.path.replacingOccurrences(of: "'", with: "'\\''")
            let wrapped = sandboxEngine.wrap(command: "'\(escapedWorkerPath)'", workspaceRoot: workspaceRoot)
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", wrapped]
        } else {
            process.executableURL = workerURL
        }
        process.currentDirectoryURL = URL(fileURLWithPath: workspaceRoot)
        process.environment = [:]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return CodeModeExecutionResult(
                valueJSON: nil, logs: [], invalidOutput: false,
                errorMessage: "execute_code: failed to launch worker: \(error.localizedDescription)",
                timedOut: false
            )
        }
        let childPID = process.processIdentifier

        let toolSchemas: [[String: Any]] = exposedTools.map { tool in
            let schemaDict: [String: Any]
            if let schemaData = try? JSONEncoder().encode(tool.parameters),
               let decoded = try? JSONSerialization.jsonObject(with: schemaData) as? [String: Any] {
                schemaDict = decoded
            } else {
                schemaDict = [:]
            }
            return ["name": tool.name, "description": tool.description, "parameters": schemaDict]
        }
        let handshake: [String: Any] = ["code": code, "tools": toolSchemas, "maxCalls": maxCalls]

        guard let handshakeData = try? JSONSerialization.data(withJSONObject: handshake) else {
            ProcessTreeKiller.killTree(root: childPID, signal: SIGKILL)
            return CodeModeExecutionResult(
                valueJSON: nil, logs: [], invalidOutput: false,
                errorMessage: "execute_code: failed to encode handshake",
                timedOut: false
            )
        }
        var handshakeLine = handshakeData
        handshakeLine.append(0x0A)
        stdinPipe.fileHandleForWriting.write(handshakeLine)

        final class ResultBox: @unchecked Sendable {
            var finalMessage: [String: Any]?
        }
        let box = ResultBox()
        let doneSemaphore = DispatchSemaphore(value: 0)

        // Pumps the synchronous request/response protocol on a dedicated
        // background thread (not a Swift concurrency pool thread — each
        // sub-call blocks here until `dispatch` resolves, which would
        // otherwise starve the cooperative pool for the whole script run).
        let pumpThread = Thread {
            let reader = SyncLineReader(handle: stdoutPipe.fileHandleForReading)
            while true {
                guard let line = reader.nextLine(),
                      let lineData = line.data(using: .utf8),
                      let message = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let type = message["type"] as? String
                else { break }

                if type == "call" {
                    let callID = (message["id"] as? String) ?? ""
                    let toolName = (message["tool"] as? String) ?? ""
                    // [String: Any] is not Sendable; explicit unsafe snapshot
                    // before crossing into the Task below.
                    nonisolated(unsafe) let arguments = (message["arguments"] as? [String: Any]) ?? [:]

                    let dispatchSemaphore = DispatchSemaphore(value: 0)
                    nonisolated(unsafe) var dispatchedResult = ToolResult.error("execute_code: internal dispatch error")
                    Task {
                        dispatchedResult = await dispatch(toolName, arguments)
                        dispatchSemaphore.signal()
                    }
                    dispatchSemaphore.wait()

                    let reply: [String: Any] = [
                        "type": "result", "id": callID,
                        "content": dispatchedResult.content, "isError": dispatchedResult.isError,
                    ]
                    if let replyData = try? JSONSerialization.data(withJSONObject: reply) {
                        var replyLine = replyData
                        replyLine.append(0x0A)
                        stdinPipe.fileHandleForWriting.write(replyLine)
                    }
                } else if type == "done" {
                    box.finalMessage = message
                    break
                }
                // Any other/unrecognized line type is ignored rather than
                // treated as fatal — forward compatible with a worker that
                // emits a future message kind this parent doesn't know yet.
            }
            doneSemaphore.signal()
        }
        pumpThread.start()

        let timedOut = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let waitResult = doneSemaphore.wait(timeout: .now() + timeoutSeconds)
                continuation.resume(returning: waitResult == .timedOut)
            }
        }

        if timedOut {
            ProcessTreeKiller.killTree(root: childPID, signal: SIGTERM)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) {
                ProcessTreeKiller.killTree(root: childPID, signal: SIGKILL)
            }
            return CodeModeExecutionResult(
                valueJSON: nil, logs: [], invalidOutput: false,
                errorMessage: "execute_code: script exceeded the \(Int(timeoutSeconds))s timeout and was cancelled",
                timedOut: true
            )
        }

        try? stdinPipe.fileHandleForWriting.close()
        ProcessTreeKiller.killTree(root: childPID, signal: SIGTERM)

        guard let finalMessage = box.finalMessage else {
            return CodeModeExecutionResult(
                valueJSON: nil, logs: [], invalidOutput: false,
                errorMessage: "execute_code: worker exited without a result (crashed or was killed)",
                timedOut: false
            )
        }

        let logs = (finalMessage["logs"] as? [String]) ?? []
        let invalidOutput = (finalMessage["invalidOutput"] as? Bool) ?? false
        let errorMessage = (finalMessage["error"] as? [String: Any])?["message"] as? String
        let valueJSON = (finalMessage["valueJSON"] as? String) ?? "null"

        let combinedSize = valueJSON.count + logs.reduce(0) { $0 + $1.count }
        guard combinedSize <= maxOutputCharacters else {
            return CodeModeExecutionResult(
                valueJSON: nil, logs: [], invalidOutput: false,
                errorMessage: "execute_code: output exceeded \(maxOutputCharacters) characters (return value + console logs combined) — have the script summarize or page its own output instead of returning everything at once",
                timedOut: false
            )
        }

        return CodeModeExecutionResult(
            valueJSON: errorMessage == nil ? valueJSON : nil,
            logs: logs,
            invalidOutput: invalidOutput,
            errorMessage: errorMessage,
            timedOut: false
        )
    }
}
