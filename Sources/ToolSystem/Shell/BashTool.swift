// Sources/ToolSystem/Shell/BashTool.swift
// Sandboxed shell command execution with synchronous and background modes

import Foundation

/// Executes shell commands with permission checks and output capture.
///
/// Supports two execution modes:
/// - `sync` (default): Waits for the command to complete and returns all output.
/// - `background`: Starts the command, waits `initial_wait` seconds for early output
///   (startup messages, immediate errors), then returns without waiting for completion.
///   Use this for long-running servers (e.g. `uvicorn`, `npm run dev`).
public struct BashTool: Tool {
    public let name = "bash"
    public let description = """
        Execute a shell command. Output is captured and returned. Commands must be allowed by the permission engine. \
        Use mode "background" with initial_wait for long-running processes like servers.
        """
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "command": PropertySchema(type: "string", description: "The shell command to execute"),
            "timeout": PropertySchema(type: "integer", description: "Timeout in seconds for sync mode (default: 30)"),
            "mode": PropertySchema(type: "string", description: "Execution mode: \"sync\" (default) waits for completion, \"background\" starts the process and returns after initial_wait", enumValues: ["sync", "background"]),
            "initial_wait": PropertySchema(type: "integer", description: "Seconds to wait for early output in background mode (default: 3). Use higher values for processes that take longer to start."),
        ],
        required: ["command"]
    )

    private let permissions: PermissionEngine
    private let maxOutputLines: Int
    private let useSandbox: Bool
    private let sandboxEngine = SandboxEngine()

    public init(permissions: PermissionEngine, maxOutputLines: Int = 500, useSandbox: Bool = false) {
        self.permissions = permissions
        self.maxOutputLines = maxOutputLines
        self.useSandbox = useSandbox
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let command = arguments["command"] as? String else {
            return .error("Missing required argument: command")
        }

        let mode = (arguments["mode"] as? String) ?? "sync"
        let timeout = arguments["timeout"] as? Int ?? 30
        let initialWait = arguments["initial_wait"] as? Int ?? 3

        // Check command against permission rules
        guard permissions.isCommandAllowed(command) else {
            return .error("Command denied by permission rules: \(command)")
        }

        let finalCommand: String
        if useSandbox {
            finalCommand = sandboxEngine.wrap(command: command, workspaceRoot: permissions.effectiveWorkspaceRoot)
        } else {
            finalCommand = command
        }

        if mode == "background" {
            return try await executeBackground(command: finalCommand, initialWait: initialWait)
        } else {
            return try await executeSync(command: finalCommand, timeout: timeout)
        }
    }

    // MARK: - Synchronous Execution

    private func executeSync(command: String, timeout: Int) async throws -> ToolResult {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(filePath: permissions.effectiveWorkspaceRoot)
        process.environment = safeEnvironment()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Set up timeout
        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(timeout))
            if process.isRunning {
                process.terminate()
            }
        }

        try process.run()
        process.waitUntilExit()
        timeoutTask.cancel()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        let exitCode = process.terminationStatus

        return formatOutput(stdout: stdout, stderr: stderr, exitCode: exitCode)
    }

    // MARK: - Background Execution

    private func executeBackground(command: String, initialWait: Int) async throws -> ToolResult {
        // Wrap the command so that the main shell exits after launching the background job.
        // The inner nohup + redirect ensures the child process survives and doesn't block
        // on pipe I/O. We capture early output via a temp file.
        let outputFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-coder-bg-\(UUID().uuidString).log")

        // Use nohup + redirect to detach the process from the shell's pipes.
        // Capture output to a temp file for the initial_wait period.
        let wrappedCommand = """
            nohup /bin/zsh -c '\(command.replacingOccurrences(of: "'", with: "'\\''"))' \
            > '\(outputFile.path)' 2>&1 &
            BG_PID=$!
            echo "[background] Started process with PID $BG_PID"
            """

        let process = Process()
        process.executableURL = URL(filePath: "/bin/zsh")
        process.arguments = ["-c", wrappedCommand]
        process.currentDirectoryURL = URL(filePath: permissions.effectiveWorkspaceRoot)
        process.environment = safeEnvironment()

        let launchPipe = Pipe()
        process.standardOutput = launchPipe
        process.standardError = launchPipe

        try process.run()
        process.waitUntilExit()

        let launchData = launchPipe.fileHandleForReading.readDataToEndOfFile()
        let launchOutput = String(data: launchData, encoding: .utf8) ?? ""

        // Wait for initial output from the background process
        try await Task.sleep(for: .seconds(initialWait))

        // Read whatever the background process has written so far
        var earlyOutput = ""
        if FileManager.default.fileExists(atPath: outputFile.path) {
            earlyOutput = (try? String(contentsOf: outputFile, encoding: .utf8)) ?? ""
        }

        var output = launchOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !earlyOutput.isEmpty {
            output += "\n[early output after \(initialWait)s]\n\(earlyOutput)"
        }

        // Check if the process crashed immediately by looking for common error patterns
        let hasError = earlyOutput.lowercased().contains("error") ||
                       earlyOutput.lowercased().contains("traceback") ||
                       earlyOutput.lowercased().contains("exception")

        if hasError {
            return formatOutput(stdout: output, stderr: "", exitCode: 1, backgroundNote: "Process may have failed during startup. Check the output above.")
        }

        return formatOutput(stdout: output, stderr: "", exitCode: 0, backgroundNote: "Process is running in the background. Output is being logged to \(outputFile.path)")
    }

    // MARK: - Helpers

    private func safeEnvironment() -> [String: String] {
        // Set up environment with whitelisted variables only
        // Security: Don't inherit parent environment which may contain dangerous variables like
        // LD_LIBRARY_PATH, DYLD_INSERT_LIBRARIES, IFS, PS4, etc. that can lead to code injection.
        var env: [String: String] = [:]
        let safeEnvVars = ["PATH", "HOME", "USER", "LANG", "LC_ALL", "TERM"]
        for key in safeEnvVars {
            if let value = ProcessInfo.processInfo.environment[key] {
                env[key] = value
            }
        }
        // Ensure secure PATH and include Apple Silicon Homebrew locations.
        env["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        return env
    }

    private func formatOutput(stdout: String, stderr: String, exitCode: Int32, backgroundNote: String? = nil) -> ToolResult {
        var output = ""
        if !stdout.isEmpty {
            output += stdout
        }
        if !stderr.isEmpty {
            if !output.isEmpty { output += "\n" }
            output += "[stderr]\n\(stderr)"
        }
        if let note = backgroundNote {
            if !output.isEmpty { output += "\n" }
            output += "[note] \(note)"
        }

        // Apply output cap
        let lines = output.components(separatedBy: "\n")
        let truncationMarker: String?
        let content: String

        if lines.count > maxOutputLines {
            let truncated = lines.prefix(maxOutputLines)
            let omitted = lines.count - maxOutputLines
            content = truncated.joined(separator: "\n")
            truncationMarker = "[... \(omitted) lines omitted ...]"
        } else {
            content = output
            truncationMarker = nil
        }

        if exitCode != 0 {
            return ToolResult(
                content: "Exit code: \(exitCode)\n\(content)",
                truncationMarker: truncationMarker,
                isError: true
            )
        }

        return ToolResult(content: content, truncationMarker: truncationMarker)
    }
}
