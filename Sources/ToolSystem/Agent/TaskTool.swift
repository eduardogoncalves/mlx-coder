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
    }

    static var supportedProfileNames: [String] {
        SpecialistProfile.allCases.map(\.rawValue)
    }

    static func baseInstructions(for profileName: String) -> String? {
        guard let profile = SpecialistProfile(rawValue: profileName) else {
            return nil
        }

        let common = "You are a specialized sub-agent. Your task is to complete the objective using your available tools. Process the task fully and output your final result as a concise summary. Do not ask the user for permission to proceed."
        switch profile {
        case .general:
            return common
        case .codebaseResearch:
            return common + " Focus on finding relevant files, symbols, and code-path evidence. Prefer precise file/symbol references over broad summaries."
        case .testEngineering:
            return common + " Focus on deterministic validation: run and interpret targeted tests, identify regressions, and propose minimal-risk fixes."
        case .securityReview:
            return common + " Focus on security risks first: input validation, command/path injection, data leakage, authz boundaries, and unsafe defaults."
        case .docs:
            return common + " Focus on clear user-facing documentation and migration notes aligned with actual behavior."
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

        guard !trimmed.isEmpty else {
            return .failure(.message("Task tool requires at least one tool in 'tools'."))
        }

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

        let sanitizedTools: [String]
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

    static func makeSubagentDigest(
        status: String,
        profileName: String,
        taskDescription: String,
        summary: String,
        archivePath: String?
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

        return lines.joined(separator: "\n")
    }

    public let name = "task"
    public let description = "Delegate a subtask to a sub-agent. Supports specialist profiles (general, codebase_research, test_engineering, security_review, docs). Sub-agents have isolated context and cannot spawn further sub-agents (max depth 1)."
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "description": PropertySchema(type: "string", description: "Description of the task for the sub-agent"),
            "tools": PropertySchema(
                type: "array",
                description: "List of tool names the sub-agent should have access to",
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
        required: ["description", "tools"]
    )

    private let modelContainer: ModelContainer
    private let permissions: PermissionEngine
    private let generationConfig: GenerationEngine.Config
    private let modelPath: String
    private let useSandbox: Bool
    private let parentRegistry: ToolRegistry
    private let renderer: StreamRenderer

    public init(
        modelContainer: ModelContainer,
        permissions: PermissionEngine,
        generationConfig: GenerationEngine.Config,
        modelPath: String,
        useSandbox: Bool,
        parentRegistry: ToolRegistry,
        renderer: StreamRenderer
    ) {
        self.modelContainer = modelContainer
        self.permissions = permissions
        self.generationConfig = generationConfig
        self.modelPath = modelPath
        self.useSandbox = useSandbox
        self.parentRegistry = parentRegistry
        self.renderer = renderer
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

        // Create a new registry for the sub-agent
        let subRegistry = ToolRegistry()
        for toolName in sanitizedTools {
            if await registerRequestedTool(named: toolName, into: subRegistry, permissions: subPermissions, isolationEnabled: isolate) {
                continue
            } else {
                return .error("Requested tool not found or cannot be used by sub-agent: \(toolName)")
            }
        }

        // Build a specialized system prompt for the sub-agent
        let systemPrompt = await AgentLoop.buildSystemPrompt(
            registry: subRegistry,
            maxTokens: generationConfig.maxTokens,
            mode: .agent, // Sub-agents are usually agents
            thinkingLevel: .high, // Default to high for sub-agents
            taskType: .general,
            baseInstructions: baseInstructions
        )

        // Instantiate a fresh AgentLoop with isolated history
        let subAgent = AgentLoop(
            modelContainer: modelContainer,
            registry: subRegistry,
            permissions: subPermissions,
            generationConfig: generationConfig,
            renderer: renderer,
            systemPrompt: systemPrompt,
            modelPath: modelPath,
            useSandbox: useSandbox
        )

        // Notify user via renderer about sub-agent start
        if let isolatedRoot {
            renderer.printStatus("Starting sub-agent (profile=\(profileName), isolated_root=\(isolatedRoot)) for task: \(sanitizedDescription)")
        } else {
            renderer.printStatus("Starting sub-agent (profile=\(profileName)) for task: \(sanitizedDescription)")
        }
        
        do {
            try await subAgent.processUserMessage("Sub-agent Task: \(sanitizedDescription)")

            let subMessages = await subAgent.history.messages
            let finalAssistantResponse = subMessages.last(where: { $0.role == .assistant })?.content
            let status = finalAssistantResponse == nil ? "partial" : "success"

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

            let digestSummary = TaskTool.compactDigestSummary(
                from: finalAssistantResponse ?? "Sub-agent finished but returned no response.",
                maxLines: TaskTool.maxDigestSummaryLines,
                maxCharacters: TaskTool.maxDigestSummaryCharacters
            )

            let digest = TaskTool.makeSubagentDigest(
                status: status,
                profileName: profileName,
                taskDescription: sanitizedDescription,
                summary: digestSummary,
                archivePath: archivePath
            )
            return .success(digest)
        } catch {
            if isolate, cleanupIsolation, isolationIsEphemeral, let isolatedRoot {
                try? FileManager.default.removeItem(atPath: isolatedRoot)
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
        isolationEnabled: Bool
    ) async -> Bool {
        let normalizedToolName = toolName.lowercased()

        switch normalizedToolName {
        case "read_file":
            await registry.register(ReadFileTool(permissions: permissions))
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
        case "todo":
            await registry.register(TodoTool(workspaceRoot: permissions.workspaceRoot))
        case "project_expert_lora":
            await registry.register(ProjectExpertLoRATool(modelContainer: modelContainer, workspaceRoot: permissions.workspaceRoot, modelPath: modelPath))
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
