// Sources/MLXCoder/ToolRegistration.swift
// Register all built-in tools with the registry.

import Foundation
import MLXLMCommon

/// Register all built-in tools with the registry.
func registerAllTools(
    registry: ToolRegistry,
    permissions: PermissionEngine,
    modelContainer: ModelContainer?,
    modelPath: String,
    useSandbox: Bool,
    config: GenerationEngine.Config,
    renderer: StreamRenderer,
    frontend: any AgentFrontend,
    mcpConfigs: [MCPClient.ServerConfig] = [],
    skillsRegistry: SkillsRegistry? = nil,
    toolOutputSpool: ToolOutputSpoolConfig = .enabledDefault,
    codeGraphIndexer: CodeGraphIndexer? = nil
) async {
    // Filesystem tools
    await registry.register(ReadFileTool(permissions: permissions))
    await registry.register(PlanFileTool(permissions: permissions))
    await registry.register(WriteFileTool(permissions: permissions))
    await registry.register(AppendFileTool(permissions: permissions))
    await registry.register(EditFileTool(permissions: permissions))
    await registry.register(PatchTool(permissions: permissions))
    await registry.register(ListDirTool(permissions: permissions))
    await registry.register(ReadManyTool(permissions: permissions))

    // Search tools
    await registry.register(GlobTool(permissions: permissions))
    await registry.register(GrepTool(permissions: permissions))
    await registry.register(CodeSearchTool(permissions: permissions))

    // Shell
    await registry.register(BashTool(permissions: permissions, useSandbox: useSandbox))

    // Agent tools
    await registry.register(TodoTool(workspaceRoot: permissions.workspaceRoot))
    await registry.register(TaskOutputTool(permissions: permissions))
    await registry.register(ReadToolOutputTool())
    // `parentAgentLoop` is nil here because the top-level AgentLoop doesn't exist
    // yet at this point in the startup sequence — remote role delegation (Phase 3)
    // still works immediately, but local role-model residency swapping (Phase 4)
    // only activates once the caller re-runs `agentLoop.registerToolsInternal()`
    // right after constructing the AgentLoop (see ChatCommand.swift/RunCommand.swift).
    await registry.register(TaskTool(
        modelContainer: modelContainer,
        permissions: permissions,
        generationConfig: config,
        modelPath: modelPath,
        useSandbox: useSandbox,
        parentRegistry: registry,
        frontend: frontend,
        roleModels: AgentRoleRegistry.current(workspaceRoot: permissions.workspaceRoot).roleModelMap,
        parentAgentLoop: nil,
        toolOutputSpool: toolOutputSpool
    ))
    if let modelContainer {
        await registry.register(ProjectExpertLoRATool(
            modelContainer: modelContainer,
            workspaceRoot: permissions.workspaceRoot,
            modelPath: modelPath,
            frontend: frontend
        ))
    }

    // Skills
    await registry.register(ReadSkillTool(
        skills: skillsRegistry ?? SkillsRegistry(workspaceRoot: permissions.workspaceRoot)
    ))

    // Web tools
    await registry.register(WebFetchTool(
        modelContainer: modelContainer,
        generationConfig: modelContainer == nil ? nil : config
    ))
    await registry.register(WebSearchTool())

    // LSP tools (.NET/C#)
    await registry.register(LSPDiagnosticsTool(permissions: permissions))
    await registry.register(LSPHoverTool(permissions: permissions))
    await registry.register(LSPReferencesTool(permissions: permissions))
    await registry.register(LSPDefinitionTool(permissions: permissions))
    await registry.register(LSPCompletionTool(permissions: permissions))
    await registry.register(LSPSignatureHelpTool(permissions: permissions))
    await registry.register(LSPDocumentSymbolsTool(permissions: permissions))
    await registry.register(LSPRenameTool(permissions: permissions))

    // Build checking tool
    await registry.register(BuildCheckTool(permissions: permissions))
    
    // Memory tools
    await registry.register(LogKnowledgeTool(workspaceRoot: permissions.workspaceRoot))
    await registry.register(SearchKnowledgeTool(workspaceRoot: permissions.workspaceRoot))

    // Code graph (optional — only registered when `codeGraph.enabled` in
    // config.json produced a live indexer; ships off by default so the tool
    // isn't advertised/prompt-token-costed until opted in).
    if let codeGraphIndexer {
        await registry.register(CodeGraphExploreTool(indexer: codeGraphIndexer))
    }

    // MCP tools (optional)
    for mcpConfig in mcpConfigs {
        do {
            let mcpTools = try await MCPClient.connect(to: mcpConfig)
            for tool in mcpTools {
                await registry.register(tool)
            }
            renderer.printStatus("Registered \(mcpTools.count) MCP tools from \(mcpConfig.name)")
        } catch {
            renderer.printError("Failed to register MCP tools for \(mcpConfig.name): \(error.localizedDescription)")
        }
    }
}
