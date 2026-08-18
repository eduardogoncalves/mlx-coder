// Sources/ToolSystem/CodeMode/ExecuteCodeTool.swift
// "Code Mode": lets the model write one JavaScript program that calls
// several other tools programmatically (loops, conditionals, data
// transformation between calls) instead of emitting them one at a time and
// waiting for a model round trip between each. Modeled on deepseek-harness's
// Code Mode / "programmatic tool calling".
//
// Execution happens out-of-process (see CodeModeSandboxProcess +
// Sources/CodeModeWorker) — this tool's job is just to describe the exposed
// `tools.*` surface to the model and translate the run's outcome into a
// ToolResult. Every sub-call the script makes is routed through the
// `dispatcher` closure supplied at construction, which the owning AgentLoop
// wires to the exact same permission/approval/watchdog/audit pipeline a
// direct model tool call gets (see AgentLoop.executeSubToolCall) — a
// script's `tools.write_file(...)` is not a way to skip that.
import Foundation

public struct ExecuteCodeTool: Tool {
    public struct ExposedTool: Sendable {
        public let name: String
        public let description: String
        public let parameters: JSONSchema

        public init(name: String, description: String, parameters: JSONSchema) {
            self.name = name
            self.description = description
            self.parameters = parameters
        }
    }

    public let name = "execute_code"
    public let description: String
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "code": PropertySchema(
                type: "string",
                description: "A JavaScript program, run as the body of an async function (top-level `await` and `return` are available). Call your other tools via the global `tools` object described in this tool's description."
            ),
        ],
        required: ["code"]
    )

    /// Every tool exposed to the script — never includes `execute_code`
    /// itself (defensive: a script cannot spawn a nested code-mode sandbox).
    private let exposedTools: [ExposedTool]
    private let permissions: PermissionEngine
    private let useSandbox: Bool
    private let timeoutSeconds: Double
    private let dispatcher: @Sendable (String, [String: Any]) async -> ToolResult

    public init(
        exposedTools: [ExposedTool],
        permissions: PermissionEngine,
        useSandbox: Bool,
        timeoutSeconds: Double = CodeModeSandboxProcess.defaultTimeoutSeconds,
        dispatcher: @escaping @Sendable (String, [String: Any]) async -> ToolResult
    ) {
        self.exposedTools = exposedTools.filter { $0.name != "execute_code" }
        self.permissions = permissions
        self.useSandbox = useSandbox
        self.timeoutSeconds = timeoutSeconds
        self.dispatcher = dispatcher
        self.description = ExecuteCodeTool.buildDescription(exposedTools: self.exposedTools)
    }

    static func buildDescription(exposedTools: [ExposedTool]) -> String {
        var lines = [
            "Run a JavaScript program that calls your other tools programmatically instead of one at a time — use this for multi-step work with loops, conditionals, or data transformation between calls (e.g. \"read every file matching X and report which ones fail to parse\"), to save the round trips a call-by-call sequence would cost.",
            "Every other tool you have is available as an async-callable function on a global `tools` object: `await tools.<name>({...})`, where the argument object matches that tool's normal parameters. Each call returns that tool's result as a plain string (the same text you'd see from calling it directly — `JSON.parse` it yourself if you expect structured data). A denied or failed call THROWS — wrap it in try/catch if you want to handle that instead of aborting the script.",
            "`console.log`/`warn`/`error` output is captured and returned alongside the result. End the script with `return <value>` (must be JSON-serializable) to produce its result; a script that never returns produces `null`.",
        ]
        if exposedTools.isEmpty {
            lines.append("No other tools are currently available to call from `tools`.")
        } else {
            lines.append("Available tools:")
            for tool in exposedTools.sorted(by: { $0.name < $1.name }) {
                let trimmedDescription = tool.description.count > 160
                    ? String(tool.description.prefix(160)) + "…"
                    : tool.description
                lines.append("- tools.\(tool.name)({...}) — \(trimmedDescription)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Tool names whose successful sub-calls mutate a file — used only to
    /// build the `modified_files:` line this tool's result embeds, mirroring
    /// TaskTool's own digest so AgentLoop.executeToolCall's existing
    /// `task`-digest bridging (git-orchestration/build-check hookup) picks
    /// up files a script wrote just as it already does for a delegated
    /// sub-agent's edits.
    private static let mutatingToolNames: Set<String> = ["write_file", "edit_file", "append_file", "patch"]

    /// Thread-safe accumulator for the paths mutating sub-calls touched.
    /// Sub-calls are effectively sequential (the script blocks on each one
    /// before making the next), but this stays `@unchecked Sendable`-safe
    /// regardless.
    private final class ModifiedFilesTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: Set<String> = []
        func record(_ path: String) {
            lock.lock(); defer { lock.unlock() }
            paths.insert(path)
        }
        func snapshot() -> [String] {
            lock.lock(); defer { lock.unlock() }
            return Array(paths)
        }
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let code = arguments["code"] as? String, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .error("Missing required argument: code")
        }

        let tracker = ModifiedFilesTracker()
        let dispatcher = self.dispatcher
        let trackingDispatcher: @Sendable (String, [String: Any]) async -> ToolResult = { toolName, toolArguments in
            let subResult = await dispatcher(toolName, toolArguments)
            if !subResult.isError, ExecuteCodeTool.mutatingToolNames.contains(toolName),
               let path = (toolArguments["path"] as? String) ?? (toolArguments["file_path"] as? String) {
                tracker.record(path)
            }
            return subResult
        }

        let result = await CodeModeSandboxProcess.run(
            code: code,
            exposedTools: exposedTools.map { ($0.name, $0.description, $0.parameters) },
            workspaceRoot: permissions.effectiveWorkspaceRoot,
            useSandbox: useSandbox,
            timeoutSeconds: timeoutSeconds,
            dispatch: trackingDispatcher
        )

        func modifiedFilesSuffix() -> String {
            let modifiedFiles = tracker.snapshot()
            guard !modifiedFiles.isEmpty else { return "" }
            return "\n" + TaskTool.modifiedFilesLinePrefix + modifiedFiles.sorted().joined(separator: ", ")
        }

        if let errorMessage = result.errorMessage {
            var content = "execute_code failed: \(errorMessage)"
            if !result.logs.isEmpty {
                content += "\n\n[console output before the failure]\n" + result.logs.joined(separator: "\n")
            }
            content += modifiedFilesSuffix()
            return .error(content)
        }

        if result.invalidOutput {
            return .error("execute_code: the script's return value could not be JSON-serialized (e.g. it contained a function or a circular reference) — return a plain JSON-serializable value instead." + modifiedFilesSuffix())
        }

        var content = "Result: \(result.valueJSON ?? "null")"
        if !result.logs.isEmpty {
            content += "\n\n[console output]\n" + result.logs.joined(separator: "\n")
        }
        content += modifiedFilesSuffix()
        return .success(content)
    }
}
