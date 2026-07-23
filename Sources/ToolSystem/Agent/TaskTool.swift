// Sources/ToolSystem/Agent/TaskTool.swift
// Delegate subtasks to sub-agents

import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Delegates a subtask to a sub-agent with its own context window.
public struct TaskTool: Tool {
    static let maxDescriptionCharacters = 4_000
    static let maxDelegatedTools = 32
    static let maxDigestSummaryCharacters = 700
    static let maxDigestSummaryLines = 8
    static let maxStatusLineCharacters = 160

    enum ToolListValidationError: Error, Equatable {
        case message(String)
    }

    enum DescriptionValidationError: Error, Equatable {
        case message(String)
    }

    enum ArgumentValidationError: Error, Equatable {
        case message(String)
    }

    struct IsolationPlan: Equatable {
        let root: String
        let isEphemeral: Bool
    }

    struct ValidatedArguments: Equatable {
        let description: String
        let tools: [String]
        let profileName: String
        let isolate: Bool
        let isolationDirectory: String?
        let cleanupIsolation: Bool
    }

    struct SubagentArchiveMetadata: Sendable, Codable {
        let id: String
        let createdAt: String
        let status: String
        let profile: String
        let taskDescription: String
        let messageCount: Int
        let toolResponseCount: Int
        let finalResponseLength: Int
    }

    enum SpecialistProfile: String, CaseIterable {
        case general
        case codebaseResearch = "codebase_research"
        case testEngineering = "test_engineering"
        case securityReview = "security_review"
        case docs
        case planner
        case executor
        case reviewer
        case filesystem
        case terminal
    }

    static var supportedProfileNames: [String] {
        SpecialistProfile.allCases.map(\.rawValue)
    }

    static func baseInstructions(for profileName: String) -> String? {
        guard let profile = SpecialistProfile(rawValue: profileName) else {
            return nil
        }

        // One identity statement per profile (not a generic "specialized
        // sub-agent" preamble followed by a second, role-specific one) — a
        // single, upfront role label is a stronger steering signal for small
        // models than an implicit "focus on X" clause tacked onto a generic
        // opener, and every profile paying for two identity sentences back
        // to back on every `task()` call added up across a whole run.
        let outputRules = "Process the task fully and output a concise final summary. Do not ask the user for permission to proceed."
        switch profile {
        case .general:
            return "You are a general-purpose sub-agent. \(outputRules)"
        case .codebaseResearch:
            return "You are the CODEBASE_RESEARCH agent. Focus on finding relevant files, symbols, and code-path evidence — prefer precise file/symbol references over broad summaries. \(outputRules)"
        case .testEngineering:
            return "You are the TEST_ENGINEERING agent. Focus on deterministic validation: run and interpret targeted tests, identify regressions, and propose minimal-risk fixes. \(outputRules)"
        case .securityReview:
            return "You are the SECURITY_REVIEW agent. Focus on security risks first: input validation, command/path injection, data leakage, authz boundaries, unsafe defaults. \(outputRules)"
        case .docs:
            return "You are the DOCS agent. Focus on clear user-facing documentation and migration notes aligned with actual behavior. \(outputRules)"
        case .planner:
            return "You are the PLANNER. Decompose the request, research the codebase (never edit or run destructive commands), and produce a concrete, actionable implementation plan via plan_file, citing specific file/symbol references. Do not implement the change yourself. \(outputRules)"
        case .executor:
            return "You are the EXECUTOR. Implement the requested change: read what you need, then write/edit/patch files and run shell commands as required, verifying your own work (build/tests) when tools allow it. \(outputRules)"
        case .reviewer:
            return "You are the REVIEWER. Inspect the current state of the code (never edit files); check correctness and project-convention compliance, and run build_check if available. Only report a finding if you're \u{2265}80% confident it's real after double-checking — skip stylistic nitpicks. Format each finding as `file:line — issue — suggested fix`, or state explicitly that the change looks correct if you find nothing. \(outputRules)"
        case .filesystem:
            return "You are the FILESYSTEM AGENT. Perform only the requested file reads/writes/edits precisely as described — do not run shell commands. \(outputRules)"
        case .terminal:
            return "You are the TERMINAL AGENT. Run only the requested shell command(s) and report their output — do not edit files. \(outputRules)"
        }
    }

    /// Default tool preset for a profile, used when the caller omits `tools`
    /// (or passes an empty list). An explicit `tools` argument always overrides
    /// this preset.
    static func defaultTools(for profileName: String) -> [String] {
        guard let profile = SpecialistProfile(rawValue: profileName) else {
            return []
        }
        switch profile {
        case .general:
            return ["read_file", "read_many", "list_dir", "glob", "grep", "code_search", "write_file", "edit_file", "bash", "todo"]
        case .codebaseResearch:
            return ["read_file", "read_many", "list_dir", "glob", "grep", "code_search", "search_knowledge"]
        case .testEngineering:
            return ["read_file", "read_many", "list_dir", "glob", "grep", "bash", "build_check"]
        case .securityReview:
            return ["read_file", "read_many", "list_dir", "glob", "grep", "code_search"]
        case .docs:
            return ["read_file", "read_many", "list_dir", "glob", "grep", "write_file", "edit_file"]
        case .planner:
            return ["read_file", "read_many", "list_dir", "glob", "grep", "code_search", "web_search", "web_fetch", "search_knowledge", "plan_file"]
        case .executor:
            return ["read_file", "read_many", "list_dir", "glob", "grep", "write_file", "edit_file", "append_file", "patch", "bash", "code_search", "lsp_diagnostics"]
        case .reviewer:
            return ["read_file", "read_many", "list_dir", "glob", "grep", "code_search", "lsp_diagnostics", "lsp_references", "build_check"]
        case .filesystem:
            return ["read_file", "read_many", "write_file", "edit_file", "append_file", "patch", "list_dir", "glob", "grep"]
        case .terminal:
            return ["bash", "build_check"]
        }
    }

    /// Maps any profile to the role (`planner`/`executor`/`reviewer`) whose
    /// configured model it should inherit when it has no override of its own.
    /// `AgentRoleRegistry` only lets users configure those three roles — this
    /// spreads that configuration across every specialist profile by nature
    /// (research-flavored profiles inherit `planner`'s model, mutation-capable
    /// ones inherit `executor`'s, read-only verification ones inherit
    /// `reviewer`'s), so choosing e.g. `codebase_research` over `planner`
    /// still uses the model the user actually configured for research work.
    static func roleModelKey(forProfile profileName: String) -> String {
        guard let profile = SpecialistProfile(rawValue: profileName) else {
            return profileName
        }
        switch profile {
        case .planner, .codebaseResearch:
            return "planner"
        case .executor, .general, .filesystem, .terminal, .testEngineering, .docs:
            return "executor"
        case .reviewer, .securityReview:
            return "reviewer"
        }
    }

    static func normalizeProfileName(_ value: String?) -> String {
        guard let value else { return SpecialistProfile.general.rawValue }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        return normalized.isEmpty ? SpecialistProfile.general.rawValue : normalized
    }

    /// Tools that write to the filesystem or run arbitrary commands — used to
    /// decide whether a `task(...)` call needs the same approval a direct
    /// mutating tool call would need. Deliberately excludes `plan_file`:
    /// writing PLAN.MD (directly, or via a delegated `planner`) is already
    /// treated as a safe, expected planning action, not a destructive one —
    /// see the `plan_file` special-casing in `AgentLoop.isDestructiveToolCall`.
    static let mutatingToolNames: Set<String> = ["write_file", "edit_file", "append_file", "patch", "bash"]

    /// Whether a `task(...)` call, given its arguments, could perform a
    /// mutating action. The orchestrator must be free to delegate research
    /// (`planner`, `reviewer`, `codebase_research`, ...) without an approval
    /// prompt — even in PLAN mode, since that's the only way it can research
    /// anything — but delegating to a profile that can write files or run
    /// shell commands still needs to go through the normal permission system,
    /// exactly like a direct `write_file`/`bash` call would.
    static func isMutatingTaskCall(arguments: [String: Any]) -> Bool {
        let profileName = normalizeProfileName(arguments["profile"] as? String)
        let explicitTools = (arguments["tools"] as? [String])?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        let effectiveTools = (explicitTools?.isEmpty == false) ? explicitTools! : defaultTools(for: profileName)
        return effectiveTools.contains { mutatingToolNames.contains($0) }
    }

    static func resolveIsolationPlan(workspaceRoot: String, requestedSubdirectory: String?) throws -> IsolationPlan {
        let boundary = PermissionEngine(workspaceRoot: workspaceRoot)
        if let requestedSubdirectory {
            let trimmed = requestedSubdirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return IsolationPlan(root: try boundary.validatePath(trimmed), isEphemeral: false)
            }
        }
        return IsolationPlan(
            root: try boundary.validatePath(".native-agent/subagent-runs/\(UUID().uuidString)"),
            isEphemeral: true
        )
    }

    static func validateIsolationOptions(
        isolate: Bool,
        requestedSubdirectory: String?,
        cleanupIsolation: Bool
    ) -> String? {
        let trimmedSubdirectory = requestedSubdirectory?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let trimmedSubdirectory, !trimmedSubdirectory.isEmpty, !isolate {
            return "isolation_directory requires isolate=true."
        }

        if cleanupIsolation && !isolate {
            return "cleanup_isolation=true requires isolate=true."
        }

        if cleanupIsolation, let trimmedSubdirectory, !trimmedSubdirectory.isEmpty {
            return "cleanup_isolation=true is only allowed for auto-created isolated directories. Omit isolation_directory or disable cleanup_isolation."
        }

        return nil
    }

    static func sanitizeRequestedTools(_ tools: [String]) -> Result<[String], ToolListValidationError> {
        let trimmed = tools
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard trimmed.count <= maxDelegatedTools else {
            return .failure(.message("Task tool supports at most \(maxDelegatedTools) delegated tools."))
        }

        if trimmed.contains(where: { $0.lowercased() == "task" }) {
            return .failure(.message("Task tool cannot include 'task' in delegated sub-agent tools (max depth 1)."))
        }

        var seen: Set<String> = []
        var deduplicated: [String] = []
        for tool in trimmed {
            let key = tool.lowercased()
            if seen.insert(key).inserted {
                deduplicated.append(tool)
            }
        }

        return .success(deduplicated)
    }

    static func sanitizeDescription(_ description: String) -> Result<String, DescriptionValidationError> {
        let normalized = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return .failure(.message("Task tool requires a non-empty 'description'."))
        }
        guard normalized.count <= maxDescriptionCharacters else {
            return .failure(.message("Task description exceeds maximum length of \(maxDescriptionCharacters) characters."))
        }
        return .success(normalized)
    }

    static func extractDescription(from arguments: [String: Any]) -> Result<String, ArgumentValidationError> {
        guard let rawDescription = arguments["description"] else {
            return .failure(.message("Missing required argument: description"))
        }
        guard let description = rawDescription as? String else {
            return .failure(.message("Invalid argument type: description must be a string"))
        }
        return .success(description)
    }

    static func extractRequestedTools(from arguments: [String: Any]) -> Result<[String], ArgumentValidationError> {
        guard let rawTools = arguments["tools"] else {
            return .success([])
        }
        guard let tools = rawTools as? [String] else {
            return .failure(.message("Invalid argument type: tools must be an array of strings"))
        }
        return .success(tools)
    }

    static func extractProfileName(from arguments: [String: Any]) -> Result<String, ArgumentValidationError> {
        guard let rawProfile = arguments["profile"] else {
            return .success(normalizeProfileName(nil))
        }
        guard let profile = rawProfile as? String else {
            return .failure(.message("Invalid argument type: profile must be a string"))
        }
        return .success(normalizeProfileName(profile))
    }

    static func extractIsolate(from arguments: [String: Any]) -> Result<Bool, ArgumentValidationError> {
        guard let rawIsolate = arguments["isolate"] else {
            return .success(false)
        }
        guard let isolate = rawIsolate as? Bool else {
            return .failure(.message("Invalid argument type: isolate must be a boolean"))
        }
        return .success(isolate)
    }

    static func extractIsolationDirectory(from arguments: [String: Any]) -> Result<String?, ArgumentValidationError> {
        guard let rawDirectory = arguments["isolation_directory"] else {
            return .success(nil)
        }
        guard let directory = rawDirectory as? String else {
            return .failure(.message("Invalid argument type: isolation_directory must be a string"))
        }
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.message("Invalid argument value: isolation_directory must be non-empty when provided"))
        }
        return .success(trimmed)
    }

    static func extractCleanupIsolation(from arguments: [String: Any]) -> Result<Bool, ArgumentValidationError> {
        guard let rawCleanup = arguments["cleanup_isolation"] else {
            return .success(false)
        }
        guard let cleanupIsolation = rawCleanup as? Bool else {
            return .failure(.message("Invalid argument type: cleanup_isolation must be a boolean"))
        }
        return .success(cleanupIsolation)
    }

    static func validateAndNormalizeArguments(_ arguments: [String: Any]) -> Result<ValidatedArguments, ArgumentValidationError> {
        let description: String
        switch extractDescription(from: arguments) {
        case .success(let value):
            description = value
        case .failure(let error):
            return .failure(error)
        }

        let sanitizedDescription: String
        switch sanitizeDescription(description) {
        case .success(let value):
            sanitizedDescription = value
        case .failure(.message(let message)):
            return .failure(.message(message))
        }

        let requestedTools: [String]
        switch extractRequestedTools(from: arguments) {
        case .success(let value):
            requestedTools = value
        case .failure(let error):
            return .failure(error)
        }

        var sanitizedTools: [String]
        switch sanitizeRequestedTools(requestedTools) {
        case .success(let value):
            sanitizedTools = value
        case .failure(.message(let message)):
            return .failure(.message(message))
        }

        let profileName: String
        switch extractProfileName(from: arguments) {
        case .success(let value):
            profileName = value
        case .failure(let error):
            return .failure(error)
        }

        // No explicit tools given — fall back to the profile's default preset.
        if sanitizedTools.isEmpty {
            sanitizedTools = defaultTools(for: profileName)
        }

        guard !sanitizedTools.isEmpty else {
            return .failure(.message("Task tool requires at least one tool in 'tools' (profile '\(profileName)' has no default preset)."))
        }

        let isolate: Bool
        switch extractIsolate(from: arguments) {
        case .success(let value):
            isolate = value
        case .failure(let error):
            return .failure(error)
        }

        let requestedIsolationDirectory: String?
        switch extractIsolationDirectory(from: arguments) {
        case .success(let value):
            requestedIsolationDirectory = value
        case .failure(let error):
            return .failure(error)
        }

        let cleanupIsolation: Bool
        switch extractCleanupIsolation(from: arguments) {
        case .success(let value):
            cleanupIsolation = value
        case .failure(let error):
            return .failure(error)
        }

        if let optionError = validateIsolationOptions(
            isolate: isolate,
            requestedSubdirectory: requestedIsolationDirectory,
            cleanupIsolation: cleanupIsolation
        ) {
            return .failure(.message(optionError))
        }

        return .success(
            ValidatedArguments(
                description: sanitizedDescription,
                tools: sanitizedTools,
                profileName: profileName,
                isolate: isolate,
                isolationDirectory: requestedIsolationDirectory,
                cleanupIsolation: cleanupIsolation
            )
        )
    }

    static func subagentRunID(profileName: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"

        let timestamp = formatter.string(from: Date())
        let normalizedProfile = profileName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9_]+", with: "-", options: .regularExpression)
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        return "\(timestamp)-\(normalizedProfile)-\(suffix)"
    }

    /// Collapses a (possibly long, multi-line) description down to a single
    /// short line, for status/spinner text — those render paths assume a
    /// bounded, single-line string. A raw multi-line, multi-hundred-character
    /// task description (e.g. a full numbered-list spec) pushed through
    /// `emitStatus`/the spinner label can overwhelm the TUI's line-wrapping
    /// and cursor-position math, corrupting the whole layout below it.
    static func statusLineSummary(_ text: String, maxCharacters: Int = maxStatusLineCharacters) -> String {
        let firstLine = text
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? text
        let normalized = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasMore = normalized.count > maxCharacters || text.contains(where: \.isNewline)

        guard normalized.count > maxCharacters else {
            return hasMore ? normalized + "…" : normalized
        }
        return String(normalized.prefix(maxCharacters)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// Builds a last-resort digest summary from raw tool output when a
    /// sub-agent's final turn carries no assistant text (e.g. it stopped
    /// right after a tool call without writing a wrap-up). Without this,
    /// `compactDigestSummary` falls through to "No summary available." and
    /// discards everything the tool actually returned — including cases
    /// like "read this file and report back" where the tool result *is*
    /// the answer the orchestrator asked for. The orchestrator has no
    /// direct file/tool access of its own, so this is the only path that
    /// information can reach it through.
    static func fallbackToolActivitySummary(
        from messages: [Message],
        maxTools: Int = 3,
        maxCharactersPerTool: Int = 220
    ) -> String? {
        let toolMessages = messages.filter { $0.role == .tool }
        guard !toolMessages.isEmpty else { return nil }

        let recent = toolMessages.suffix(maxTools)
        let lines = recent.map { message -> String in
            let name = message.toolCallId ?? "tool"
            let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let truncated = trimmed.count > maxCharactersPerTool
                ? String(trimmed.prefix(maxCharactersPerTool)) + "..."
                : trimmed
            return "- \(name): \(truncated)"
        }

        return "Sub-agent did not write a final summary. Raw output from its last \(recent.count) tool call(s):\n"
            + lines.joined(separator: "\n")
    }

    static func compactDigestSummary(
        from text: String,
        maxLines: Int = maxDigestSummaryLines,
        maxCharacters: Int = maxDigestSummaryCharacters
    ) -> String {
        let normalizedLines = text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !normalizedLines.isEmpty else {
            return "No summary available."
        }

        let limited = normalizedLines.prefix(max(1, maxLines)).joined(separator: "\n")
        if limited.count <= maxCharacters {
            return limited
        }

        return String(limited.prefix(maxCharacters)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    /// Prefix identifying the modified-files line in a digest, parsed back out
    /// by `AgentLoop.executeToolCall` so a parent orchestrator can bridge a
    /// sub-agent's edits into its own build-check/git flow.
    static let modifiedFilesLinePrefix = "modified_files: "

    static func makeSubagentDigest(
        status: String,
        profileName: String,
        taskDescription: String,
        summary: String,
        archivePath: String?,
        modifiedFiles: [String] = []
    ) -> String {
        var lines: [String] = [
            "[Sub-agent digest]",
            "status: \(status)",
            "profile: \(profileName)",
            "task: \(taskDescription)",
            "summary:",
            summary,
        ]

        if let archivePath, !archivePath.isEmpty {
            lines.append("archive: \(archivePath)")
        }

        if !modifiedFiles.isEmpty {
            lines.append("\(modifiedFilesLinePrefix)\(modifiedFiles.sorted().joined(separator: ", "))")
        }

        return lines.joined(separator: "\n")
    }

    /// Parses the `modified_files:` line out of a digest (if present).
    static func parseModifiedFiles(fromDigest digest: String) -> [String] {
        for line in digest.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineString = String(line)
            guard lineString.hasPrefix(modifiedFilesLinePrefix) else { continue }
            let list = lineString.dropFirst(modifiedFilesLinePrefix.count)
            return list
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return []
    }

    public let name = "task"
    public let description = "Delegate a subtask to an internal sub-agent. See the 'profile' parameter's allowed values for available specialist profiles; each has a default tool scope you can override with 'tools'. Sub-agents have isolated context and cannot spawn further sub-agents (max depth 1)."
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "description": PropertySchema(type: "string", description: "Description of the task for the sub-agent"),
            "tools": PropertySchema(
                type: "array",
                description: "Optional list of tool names the sub-agent should have access to. Omit to use the profile's default tool preset.",
                items: PropertySchema(type: "string")
            ),
            "profile": PropertySchema(
                type: "string",
                description: "Optional specialist profile for sub-agent behavior",
                enumValues: TaskTool.supportedProfileNames
            ),
            "isolate": PropertySchema(
                type: "boolean",
                description: "When true, run sub-agent tools inside an isolated workspace directory"
            ),
            "isolation_directory": PropertySchema(
                type: "string",
                description: "Optional workspace-relative directory to use when isolate=true"
            ),
            "cleanup_isolation": PropertySchema(
                type: "boolean",
                description: "When isolate=true, remove auto-created isolated directory after task completion"
            ),
        ],
        required: ["description"]
    )

    private let modelContainer: ModelContainer?
    private let permissions: PermissionEngine
    private let generationConfig: GenerationEngine.Config
    private let modelPath: String
    private let useSandbox: Bool
    private let parentRegistry: ToolRegistry
    private let frontend: any AgentFrontend
    /// Per-profile model overrides (e.g. planner/executor/reviewer), keyed by
    /// profile name, resolved from `AgentRoleRegistry`. Values are carrier
    /// strings (local path/hub id, or `<providerID>:<modelID>`).
    private let roleModels: [String: String]
    /// The parent AgentLoop, used to release/reacquire its local model when a
    /// role's model is a *different* local model (only one local model may be
    /// resident at a time).
    private let parentAgentLoop: AgentLoop?

    public init(
        modelContainer: ModelContainer?,
        permissions: PermissionEngine,
        generationConfig: GenerationEngine.Config,
        modelPath: String,
        useSandbox: Bool,
        parentRegistry: ToolRegistry,
        frontend: any AgentFrontend,
        roleModels: [String: String] = [:],
        parentAgentLoop: AgentLoop? = nil
    ) {
        self.modelContainer = modelContainer
        self.permissions = permissions
        self.generationConfig = generationConfig
        self.modelPath = modelPath
        self.useSandbox = useSandbox
        self.parentRegistry = parentRegistry
        self.frontend = frontend
        self.roleModels = roleModels
        self.parentAgentLoop = parentAgentLoop
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        let validatedArguments: TaskTool.ValidatedArguments
        switch TaskTool.validateAndNormalizeArguments(arguments) {
        case .success(let value):
            validatedArguments = value
        case .failure(.message(let message)):
            return .error(message)
        }

        let sanitizedDescription = validatedArguments.description
        let sanitizedTools = validatedArguments.tools
        let profileName = validatedArguments.profileName
        let isolate = validatedArguments.isolate
        let requestedIsolationDirectory = validatedArguments.isolationDirectory
        let cleanupIsolation = validatedArguments.cleanupIsolation

        guard let baseInstructions = TaskTool.baseInstructions(for: profileName) else {
            return .error("Invalid profile '\(profileName)'. Supported profiles: \(TaskTool.supportedProfileNames.joined(separator: ", ")).")
        }

        let subPermissions: PermissionEngine
        var isolatedRoot: String?
        var isolationIsEphemeral = false
        if isolate {
            do {
                let plan = try TaskTool.resolveIsolationPlan(
                    workspaceRoot: permissions.workspaceRoot,
                    requestedSubdirectory: requestedIsolationDirectory
                )

                let root = plan.root
                try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
                subPermissions = PermissionEngine(
                    workspaceRoot: root,
                    allowedCommands: permissions.allowedCommands,
                    deniedCommands: permissions.deniedCommands,
                    approvalMode: permissions.approvalMode,
                    policy: permissions.policy,
                    ignoredPathPatterns: permissions.ignoredPathPatterns
                )
                isolatedRoot = root
                isolationIsEphemeral = plan.isEphemeral
            } catch {
                return .error("Failed to prepare isolated directory for task sub-agent: \(error.localizedDescription)")
            }
        } else {
            subPermissions = permissions
        }

        // Resolve which model this sub-agent should use. A role-model override
        // (planner/executor/reviewer, configured via AgentRoleRegistry) takes
        // precedence over the parent's own model. Resolved before tool
        // registration so container-dependent tools (project_expert_lora,
        // web_fetch) bind to the role's own container, not a stale parent one.
        var resolvedModelContainer = modelContainer
        var resolvedModelPath = modelPath
        var releasedParentLocalModel = false

        let roleModelKey = TaskTool.roleModelKey(forProfile: profileName)
        if let roleModelPath = roleModels[roleModelKey], roleModelPath != modelPath {
            let roleBackend = InferenceBackend(modelPath: roleModelPath)
            resolvedModelPath = roleModelPath
            if roleBackend.isOnline {
                resolvedModelContainer = nil
            } else if let parentAgentLoop {
                // Local role model different from the parent's — only one local
                // model may be resident at a time, so release the parent's first.
                await parentAgentLoop.releaseLocalModelForSubagent()
                releasedParentLocalModel = true
                do {
                    resolvedModelContainer = try await ModelLoader.load(
                        from: roleModelPath,
                        memoryLimit: nil,
                        cacheLimit: nil
                    )
                } catch {
                    try? await parentAgentLoop.reacquireLocalModelAfterSubagent()
                    return .error("Failed to load role model '\(roleModelPath)' for profile '\(profileName)': \(error.localizedDescription)")
                }
            }
            // else: no parentAgentLoop reference (e.g. isolated test construction) —
            // fall back to the parent's own model/container rather than risk two
            // local models resident at once.
        }

        // Create a new registry for the sub-agent
        let subRegistry = ToolRegistry()
        for toolName in sanitizedTools {
            let registered = await registerRequestedTool(
                named: toolName,
                into: subRegistry,
                permissions: subPermissions,
                isolationEnabled: isolate,
                modelContainer: resolvedModelContainer,
                modelPath: resolvedModelPath
            )
            if registered {
                continue
            } else {
                if releasedParentLocalModel {
                    resolvedModelContainer = nil
                    MLX.Memory.clearCache()
                    try? await parentAgentLoop?.reacquireLocalModelAfterSubagent()
                }
                return .error("Requested tool not found or cannot be used by sub-agent: \(toolName)")
            }
        }

        // Build a specialized system prompt for the sub-agent. Uses
        // subagentToolPromptFilter so the prompt shows exactly the tools this
        // profile was registered with (subRegistry), not a curated subset.
        let systemPrompt = await AgentLoop.buildSystemPrompt(
            registry: subRegistry,
            maxTokens: generationConfig.maxTokens,
            mode: .agent, // Sub-agents are usually agents
            thinkingLevel: .high, // Default to high for sub-agents
            taskType: .general,
            baseInstructions: baseInstructions,
            dialect: ToolCallDialect.detect(modelPath: resolvedModelPath),
            usesNativeToolCalling: InferenceBackend(modelPath: resolvedModelPath).isOnline,
            toolPromptFilterOverride: AgentLoop.subagentToolPromptFilter(role: profileName)
        )

        // Instantiate a fresh AgentLoop with isolated history
        let subAgent = AgentLoop(
            modelContainer: resolvedModelContainer,
            registry: subRegistry,
            permissions: subPermissions,
            generationConfig: generationConfig,
            frontend: frontend,
            systemPrompt: systemPrompt,
            modelPath: resolvedModelPath,
            workspace: subPermissions.effectiveWorkspaceRoot,
            useSandbox: useSandbox,
            role: profileName
        )

        // Puts the sub-agent in AGENT mode (not the PLAN-mode default, whose
        // "switch to AGENT mode?" framing makes no sense here) while
        // inheriting the parent orchestrator's own live approval posture —
        // mutating tool calls inside the sub-agent still need permission,
        // exactly like the orchestrator's own calls would. See
        // configureForSubAgentExecution.
        let parentAutoApprove = await parentAgentLoop?.autoApproveAllTools ?? false
        let parentApprovedCommands = await parentAgentLoop?.sessionApprovedToolCommands ?? []
        await subAgent.configureForSubAgentExecution(
            taskType: .coding,
            parentAutoApproveAllTools: parentAutoApprove,
            parentSessionApprovedToolCommands: parentApprovedCommands
        )

        // Notify user via renderer about sub-agent start. Status/spinner text
        // must stay a single short line — see statusLineSummary.
        let descriptionSummary = TaskTool.statusLineSummary(sanitizedDescription)
        if let isolatedRoot {
            frontend.emitStatus("Starting sub-agent (profile=\(profileName), model=\(resolvedModelPath), isolated_root=\(isolatedRoot)) for task: \(descriptionSummary)")
        } else {
            frontend.emitStatus("Starting sub-agent (profile=\(profileName), model=\(resolvedModelPath)) for task: \(descriptionSummary)")
        }

        // Let the frontend label its spinner with the active internal agent +
        // model (sub-agents share the parent's frontend/event pipeline, so
        // without this the "Generating…" spinner gives no indication that a
        // different agent/model just took over). Sub-agents cannot spawn
        // further sub-agents, so this never nests.
        frontend.emit(.subAgentActivity(.started(profile: profileName, modelPath: resolvedModelPath)))
        defer { frontend.emit(.subAgentActivity(.ended)) }

        do {
            try await subAgent.processUserMessage("Sub-agent Task: \(sanitizedDescription)")

            var subMessages = await subAgent.history.messages
            var finalAssistantResponse = subMessages.last(where: { $0.role == .assistant })?.content
            var trimmedFinalResponse = finalAssistantResponse?.trimmingCharacters(in: .whitespacesAndNewlines)

            // A sub-agent's last turn can be tool-calls-only (no wrap-up text) —
            // e.g. it stops right after a successful `read_file`/`web_search`
            // without narrating the result. The orchestrator has no other way to
            // see what happened (it can't call tools directly), so force one more
            // turn asking explicitly for a plain-text report instead of silently
            // losing everything the sub-agent did.
            if trimmedFinalResponse?.isEmpty ?? true {
                frontend.emitStatus("Sub-agent produced no final summary; requesting one explicitly.", severity: .warning)
                try? await subAgent.processUserMessage(
                    "You stopped without writing a final summary. Do not call any more tools — respond now with a short plain-text report (2-6 sentences) of what you did and what you found or produced."
                )
                subMessages = await subAgent.history.messages
                finalAssistantResponse = subMessages.last(where: { $0.role == .assistant })?.content
                trimmedFinalResponse = finalAssistantResponse?.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let status = (trimmedFinalResponse?.isEmpty ?? true) ? "partial" : "success"

            let runID = TaskTool.subagentRunID(profileName: profileName)
            let archivePath = try? archiveSubagentRun(
                runID: runID,
                profileName: profileName,
                taskDescription: sanitizedDescription,
                status: status,
                finalAssistantResponse: finalAssistantResponse,
                messages: subMessages
            )

            if isolate, cleanupIsolation, isolationIsEphemeral, let isolatedRoot {
                try? FileManager.default.removeItem(atPath: isolatedRoot)
            }

            // If even the forced follow-up didn't produce text (model ignored the
            // instruction, or the follow-up call itself errored), fall back to the
            // raw tool output rather than reporting an empty digest.
            let summarySource: String
            if let trimmedFinalResponse, !trimmedFinalResponse.isEmpty {
                summarySource = trimmedFinalResponse
            } else if let fallback = TaskTool.fallbackToolActivitySummary(from: subMessages) {
                summarySource = fallback
            } else {
                summarySource = "Sub-agent finished but returned no response."
            }

            let digestSummary = TaskTool.compactDigestSummary(
                from: summarySource,
                maxLines: TaskTool.maxDigestSummaryLines,
                maxCharacters: TaskTool.maxDigestSummaryCharacters
            )

            // Only bridge modified-file paths up when the sub-agent shared the
            // parent's own workspace (not an isolated sandbox root) — otherwise
            // the paths aren't meaningful relative to the parent's workspace.
            let subAgentModifiedFiles = isolate ? [] : Array(await subAgent.turnModifiedFiles)

            let digest = TaskTool.makeSubagentDigest(
                status: status,
                profileName: profileName,
                taskDescription: sanitizedDescription,
                summary: digestSummary,
                archivePath: archivePath,
                modifiedFiles: subAgentModifiedFiles
            )

            if releasedParentLocalModel {
                resolvedModelContainer = nil
                MLX.Memory.clearCache()
                try? await parentAgentLoop?.reacquireLocalModelAfterSubagent()
            }

            return .success(digest)
        } catch {
            if isolate, cleanupIsolation, isolationIsEphemeral, let isolatedRoot {
                try? FileManager.default.removeItem(atPath: isolatedRoot)
            }

            if releasedParentLocalModel {
                resolvedModelContainer = nil
                MLX.Memory.clearCache()
                try? await parentAgentLoop?.reacquireLocalModelAfterSubagent()
            }

            return .error("Sub-agent failed: \(error.localizedDescription)")
        }
    }

    private func archiveSubagentRun(
        runID: String,
        profileName: String,
        taskDescription: String,
        status: String,
        finalAssistantResponse: String?,
        messages: [Message]
    ) throws -> String {
        let rootRelative = ".native-agent/subagent-logs"
        let runRelative = "\(rootRelative)/\(runID)"

        let rootAbsolute = try permissions.validatePath(rootRelative)
        let runAbsolute = try permissions.validatePath(runRelative)

        try FileManager.default.createDirectory(atPath: rootAbsolute, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: runAbsolute, withIntermediateDirectories: true)

        let metadataPath = runAbsolute + "/metadata.json"
        let historyPath = runAbsolute + "/history.json"

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]

        let metadata = SubagentArchiveMetadata(
            id: runID,
            createdAt: isoFormatter.string(from: Date()),
            status: status,
            profile: profileName,
            taskDescription: taskDescription,
            messageCount: messages.count,
            toolResponseCount: messages.filter { $0.role == .tool }.count,
            finalResponseLength: finalAssistantResponse?.count ?? 0
        )

        let metadataData = try encoder.encode(metadata)
        let historyData = try encoder.encode(messages)

        try metadataData.write(to: URL(filePath: metadataPath), options: .atomic)
        try historyData.write(to: URL(filePath: historyPath), options: .atomic)

        return runRelative
    }

    private func registerRequestedTool(
        named toolName: String,
        into registry: ToolRegistry,
        permissions: PermissionEngine,
        isolationEnabled: Bool,
        modelContainer: ModelContainer?,
        modelPath: String
    ) async -> Bool {
        let normalizedToolName = toolName.lowercased()

        switch normalizedToolName {
        case "read_file":
            await registry.register(ReadFileTool(permissions: permissions))
        case "plan_file":
            await registry.register(PlanFileTool(permissions: permissions))
        case "write_file":
            await registry.register(WriteFileTool(permissions: permissions))
        case "append_file":
            await registry.register(AppendFileTool(permissions: permissions))
        case "edit_file":
            await registry.register(EditFileTool(permissions: permissions))
        case "patch":
            await registry.register(PatchTool(permissions: permissions))
        case "list_dir":
            await registry.register(ListDirTool(permissions: permissions))
        case "read_many":
            await registry.register(ReadManyTool(permissions: permissions))
        case "glob":
            await registry.register(GlobTool(permissions: permissions))
        case "grep":
            await registry.register(GrepTool(permissions: permissions))
        case "code_search":
            await registry.register(CodeSearchTool(permissions: permissions))
        case "bash":
            await registry.register(BashTool(permissions: permissions, useSandbox: useSandbox))
        case "build_check":
            await registry.register(BuildCheckTool(permissions: permissions))
        case "todo":
            await registry.register(TodoTool(workspaceRoot: permissions.workspaceRoot))
        case "read_skill":
            await registry.register(ReadSkillTool(skills: SkillsRegistry(workspaceRoot: permissions.workspaceRoot)))
        case "project_expert_lora":
            if let modelContainer {
                await registry.register(ProjectExpertLoRATool(modelContainer: modelContainer, workspaceRoot: permissions.workspaceRoot, modelPath: modelPath, frontend: frontend))
            } else {
                return false
            }
        case "web_fetch":
            await registry.register(WebFetchTool(modelContainer: modelContainer, generationConfig: generationConfig))
        case "web_search":
            await registry.register(WebSearchTool())
        case "lsp_diagnostics":
            await registry.register(LSPDiagnosticsTool(permissions: permissions))
        case "lsp_hover":
            await registry.register(LSPHoverTool(permissions: permissions))
        case "lsp_references":
            await registry.register(LSPReferencesTool(permissions: permissions))
        case "lsp_definition":
            await registry.register(LSPDefinitionTool(permissions: permissions))
        case "lsp_completion":
            await registry.register(LSPCompletionTool(permissions: permissions))
        case "lsp_signature_help":
            await registry.register(LSPSignatureHelpTool(permissions: permissions))
        case "lsp_document_symbols":
            await registry.register(LSPDocumentSymbolsTool(permissions: permissions))
        case "lsp_rename":
            await registry.register(LSPRenameTool(permissions: permissions))
        default:
            // In non-isolated mode, allow passthrough for dynamically discovered tools (e.g. MCP).
            // In isolated mode, reject unknown tools to avoid escaping the isolated permissions boundary.
            let exactTool = await parentRegistry.tool(named: toolName)
            let normalizedTool = exactTool == nil ? await parentRegistry.tool(named: normalizedToolName) : nil
            if !isolationEnabled, let tool = exactTool ?? normalizedTool {
                await registry.register(tool)
            } else {
                return false
            }
        }

        return true
    }
}
