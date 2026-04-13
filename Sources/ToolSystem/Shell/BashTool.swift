// Sources/ToolSystem/Shell/BashTool.swift
// Sandboxed shell command execution

import Foundation

/// Executes shell commands with permission checks and output capture.
public struct BashTool: Tool {
    public let name = "bash"
    public let description = "Execute a shell command. Output is captured and returned. Commands must be allowed by the permission engine."
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "command": PropertySchema(type: "string", description: "The shell command to execute"),
            "timeout": PropertySchema(type: "integer", description: "Timeout in seconds (default: 30)"),
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

        let timeout = arguments["timeout"] as? Int ?? 30

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

        let process = Process()
        process.executableURL = URL(filePath: "/bin/zsh")
        process.arguments = ["-c", finalCommand]
        process.currentDirectoryURL = URL(filePath: permissions.effectiveWorkspaceRoot)

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
        process.environment = env

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

        // Build output
        var output = ""
        if !stdout.isEmpty {
            output += stdout
        }
        if !stderr.isEmpty {
            if !output.isEmpty { output += "\n" }
            output += "[stderr]\n\(stderr)"
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
