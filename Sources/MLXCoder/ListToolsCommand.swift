// Sources/MLXCoder/ListToolsCommand.swift
// List available tools without loading a model.

import ArgumentParser
import Foundation

struct ListToolsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-tools",
        abstract: "List available tools without loading a model"
    )

    @Option(name: .long, help: "Workspace root directory used for environment-sensitive tools")
    var workspace: String = "."

    @Flag(name: .long, help: "Emit machine-readable JSON output")
    var json: Bool = false

    @Flag(name: .long, help: "Treat MCP discovery errors as command failure")
    var strict: Bool = false

    @Option(name: .long, help: "Optional MCP server HTTP endpoint (JSON-RPC) for discovery")
    var mcpEndpoint: String?

    @Option(name: .long, help: "Logical MCP server name used in discovered tool prefixes")
    var mcpName: String = "remote"

    @Option(name: .long, help: "MCP request timeout in seconds")
    var mcpTimeout: Int = 30

    @Option(name: .long, help: "Comma-separated MCP server names to include (overrides config allow list)")
    var mcpInclude: String?

    @Option(name: .long, help: "Comma-separated MCP server names to exclude (applied after include)")
    var mcpExclude: String?

    @OptionGroup var testAbsorber: TestAbsorber

    mutating func run() async throws {
        guard !testAbsorber.isTestInvocation else { return }

        let workspacePath = NSString(string: workspace).expandingTildeInPath
        let rawWorkspace = workspacePath.hasPrefix("/")
            ? workspacePath
            : FileManager.default.currentDirectoryPath + "/" + workspacePath
        let absWorkspace = NSString(string: rawWorkspace).standardizingPath

        let runtimeConfig = RuntimeConfigLoader.loadMerged(workspaceRoot: absWorkspace)
        let detector = DotnetWorkspaceDetector()
        let isDotnetWorkspace = await detector.isDotnetWorkspace(absWorkspace)
        let cliMCPConfig: MCPClient.ServerConfig? = {
            guard let endpoint = mcpEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines), !endpoint.isEmpty else {
                return nil
            }
            return MCPClient.ServerConfig(
                name: mcpName,
                command: endpoint,
                endpointURL: endpoint,
                timeoutSeconds: max(1, mcpTimeout)
            )
        }()

        let result = await buildListToolsPayload(
            workspaceRoot: absWorkspace,
            isDotnetWorkspace: isDotnetWorkspace,
            runtimeConfig: runtimeConfig,
            cliMCPConfig: cliMCPConfig,
            mcpIncludeOverride: mcpInclude,
            mcpExcludeOverride: mcpExclude,
            discoverMCPTools: { config in
                try await MCPClient.connect(to: config)
            }
        )
        let payload = result.payload
        let mcpErrorMessages = result.mcpErrorMessages

        for message in mcpErrorMessages where !json {
            print("MCP discovery failed (\(message))")
        }

        if !mcpErrorMessages.isEmpty && !json {
            print("")
        }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)
            if let output = String(data: data, encoding: .utf8) {
                print(output)
            }
            if listToolsShouldFail(mcpErrorMessages: mcpErrorMessages, strict: strict) {
                throw ExitCode.failure
            }
            return
        }

        print("Workspace: \(payload.workspace)")
        print(".NET workspace: \(payload.dotnetWorkspace ? "yes" : "no")")
        print("Skills discovered: \(payload.skills.count)")
        print("")
        for tool in payload.tools {
            print("- \(tool.name) [\(tool.category)]")
            print("  \(tool.description)")
        }

        if !payload.skills.isEmpty {
            print("")
            print("Skills:")
            for skill in payload.skills {
                let tags = skill.tags.isEmpty ? "" : " [tags: \(skill.tags.joined(separator: ", "))]"
                print("- \(skill.name): \(skill.description) (\(skill.filePath))\(tags)")
            }
        }

        print("")
        print("Task capabilities:")
        print("- profiles: \(payload.taskCapabilities.profiles.joined(separator: ", "))")
        print("- isolation options: \(payload.taskCapabilities.isolationOptions.joined(separator: ", "))")

        if listToolsShouldFail(mcpErrorMessages: mcpErrorMessages, strict: strict) {
            throw ExitCode.failure
        }
    }
}

// MARK: - ListTools Types & Builders

struct ToolCatalogEntry: Codable, Sendable {
    let name: String
    let category: String
    let description: String
}

struct ListToolsPayload: Codable, Sendable {
    let workspace: String
    let dotnetWorkspace: Bool
    let tools: [ToolCatalogEntry]
    let skills: [SkillMetadata]
    let taskCapabilities: TaskCapabilities
    let mcpError: String?
}

struct TaskCapabilities: Codable, Sendable {
    let profiles: [String]
    let isolationOptions: [String]
}

func listToolsShouldFail(mcpErrorMessages: [String], strict: Bool) -> Bool {
    strict && !mcpErrorMessages.isEmpty
}

func buildListToolsPayload(
    workspaceRoot: String,
    isDotnetWorkspace: Bool,
    runtimeConfig: RuntimeConfig,
    cliMCPConfig: MCPClient.ServerConfig?,
    mcpIncludeOverride: String? = nil,
    mcpExcludeOverride: String? = nil,
    discoverMCPTools: @Sendable (MCPClient.ServerConfig) async throws -> [any Tool]
) async -> (payload: ListToolsPayload, mcpErrorMessages: [String]) {
    var tools = builtinToolCatalog(includeDotnetTools: isDotnetWorkspace)
    let skillsRegistry = SkillsRegistry(workspaceRoot: workspaceRoot)
    let skillMetadata = await skillsRegistry.listMetadata()
    let runtimeMCPConfigs = runtimeMCPServerConfigs(
        from: runtimeConfig,
        includeOverride: mcpIncludeOverride,
        excludeOverride: mcpExcludeOverride
    )
    let allMCPConfigs = mergedMCPConfigs(runtimeConfigs: runtimeMCPConfigs, cliConfig: cliMCPConfig)

    var mcpErrorMessages: [String] = []
    for mcpConfig in allMCPConfigs {
        do {
            let remoteTools = try await discoverMCPTools(mcpConfig)
            let mapped: [ToolCatalogEntry] = remoteTools.map {
                ToolCatalogEntry(name: $0.name, category: "mcp", description: $0.description)
            }
            tools.append(contentsOf: mapped)
        } catch {
            mcpErrorMessages.append("\(mcpConfig.name): \(error.localizedDescription)")
        }
    }

    let payload = ListToolsPayload(
        workspace: workspaceRoot,
        dotnetWorkspace: isDotnetWorkspace,
        tools: tools,
        skills: skillMetadata,
        taskCapabilities: TaskCapabilities(
            profiles: TaskTool.supportedProfileNames,
            isolationOptions: ["isolate", "isolation_directory", "cleanup_isolation"]
        ),
        mcpError: mcpErrorMessages.isEmpty ? nil : mcpErrorMessages.joined(separator: " | ")
    )

    return (payload, mcpErrorMessages)
}

private func builtinToolCatalog(includeDotnetTools: Bool) -> [ToolCatalogEntry] {
    var tools: [ToolCatalogEntry] = [
        ToolCatalogEntry(name: "read_file", category: "filesystem", description: "Read files with optional line ranges."),
        ToolCatalogEntry(name: "write_file", category: "filesystem", description: "Create or replace file contents."),
        ToolCatalogEntry(name: "append_file", category: "filesystem", description: "Append text to an existing file."),
        ToolCatalogEntry(name: "edit_file", category: "filesystem", description: "Apply exact search/replace edits in a file."),
        ToolCatalogEntry(name: "patch", category: "filesystem", description: "Apply unified diff patches."),
        ToolCatalogEntry(name: "list_dir", category: "filesystem", description: "List files and directories."),
        ToolCatalogEntry(name: "read_many", category: "filesystem", description: "Read multiple files in a single call."),
        ToolCatalogEntry(name: "glob", category: "search", description: "Find files by glob pattern."),
        ToolCatalogEntry(name: "grep", category: "search", description: "Search text across files."),
        ToolCatalogEntry(name: "code_search", category: "search", description: "Symbol-aware code search."),
        ToolCatalogEntry(name: "bash", category: "shell", description: "Execute shell commands with permission checks."),
        ToolCatalogEntry(name: "task", category: "agent", description: "Delegate a subtask to a sub-agent with specialist profiles and optional isolated execution."),
        ToolCatalogEntry(name: "todo", category: "agent", description: "Manage persistent todo items."),
        ToolCatalogEntry(name: "project_expert_lora", category: "agent", description: "Project LoRA expert tool (experimental)."),
        ToolCatalogEntry(name: "web_fetch", category: "web", description: "Fetch and summarize web content."),
        ToolCatalogEntry(name: "web_search", category: "web", description: "Search the web for recent information.")
    ]

    if includeDotnetTools {
        tools.append(contentsOf: [
            ToolCatalogEntry(name: "lsp_diagnostics", category: "lsp", description: "Get C# diagnostics from language server."),
            ToolCatalogEntry(name: "lsp_hover", category: "lsp", description: "Get C# symbol hover information."),
            ToolCatalogEntry(name: "lsp_references", category: "lsp", description: "Find C# symbol references."),
            ToolCatalogEntry(name: "lsp_definition", category: "lsp", description: "Find C# symbol definition locations."),
            ToolCatalogEntry(name: "lsp_completion", category: "lsp", description: "Get C# completion items at a position."),
            ToolCatalogEntry(name: "lsp_signature_help", category: "lsp", description: "Get C# signature help at a position."),
            ToolCatalogEntry(name: "lsp_document_symbols", category: "lsp", description: "List C# document symbols for a file."),
            ToolCatalogEntry(name: "lsp_rename", category: "lsp", description: "Plan C# symbol rename workspace edits, or apply them with apply=true.")
        ])
    }

    return tools
}
