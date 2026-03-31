// Sources/MLXCoder/RuntimeConfig.swift
// Runtime configuration loading and merge helpers

import Foundation

struct RuntimeConfig: Sendable, Codable {
    struct MCPSettings: Sendable, Codable {
        let allowedServers: [String]?
        let blockedServers: [String]?

        init(allowedServers: [String]? = nil, blockedServers: [String]? = nil) {
            self.allowedServers = allowedServers
            self.blockedServers = blockedServers
        }
    }

    struct MCPServer: Sendable, Codable {
        let name: String
        let endpoint: String?
        let command: String?
        let arguments: [String]?
        let environment: [String: String]?
        let timeoutSeconds: Int?
        let enabled: Bool?
    }

    let mcpServers: [MCPServer]
    let mcpSettings: MCPSettings?
    let defaultApprovalMode: String?
    let defaultSandbox: Bool?
    let defaultDryRun: Bool?
    let defaultPolicyFile: String?
    let defaultAuditLogPath: String?

    init(
        mcpServers: [MCPServer] = [],
        mcpSettings: MCPSettings? = nil,
        defaultApprovalMode: String? = nil,
        defaultSandbox: Bool? = nil,
        defaultDryRun: Bool? = nil,
        defaultPolicyFile: String? = nil,
        defaultAuditLogPath: String? = nil
    ) {
        self.mcpServers = mcpServers
        self.mcpSettings = mcpSettings
        self.defaultApprovalMode = defaultApprovalMode
        self.defaultSandbox = defaultSandbox
        self.defaultDryRun = defaultDryRun
        self.defaultPolicyFile = defaultPolicyFile
        self.defaultAuditLogPath = defaultAuditLogPath
    }

    private enum CodingKeys: String, CodingKey {
        case mcpServers
        case mcpSettings
        case defaultApprovalMode
        case defaultSandbox
        case defaultDryRun
        case defaultPolicyFile
        case defaultAuditLogPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.mcpServers = try container.decodeIfPresent([MCPServer].self, forKey: .mcpServers) ?? []
        self.mcpSettings = try container.decodeIfPresent(MCPSettings.self, forKey: .mcpSettings)
        self.defaultApprovalMode = try container.decodeIfPresent(String.self, forKey: .defaultApprovalMode)
        self.defaultSandbox = try container.decodeIfPresent(Bool.self, forKey: .defaultSandbox)
        self.defaultDryRun = try container.decodeIfPresent(Bool.self, forKey: .defaultDryRun)
        self.defaultPolicyFile = try container.decodeIfPresent(String.self, forKey: .defaultPolicyFile)
        self.defaultAuditLogPath = try container.decodeIfPresent(String.self, forKey: .defaultAuditLogPath)
    }
}

enum RuntimeConfigLoader {
    static func loadMerged(
        workspaceRoot: String,
        userConfigPath: String? = nil,
        workspaceConfigPath: String? = nil
    ) -> RuntimeConfig {
        let userPath = userConfigPath ?? (FileManager.default.homeDirectoryForCurrentUser.path + "/.mlx-coder/config.json")
        let workspacePath = workspaceConfigPath ?? (workspaceRoot + "/.mlx-coder-config.json")

        let userConfig = load(path: userPath)
        let workspaceConfig = load(path: workspacePath)

        // Workspace config overrides user config by server name.
        var mergedByName: [String: RuntimeConfig.MCPServer] = [:]
        for server in userConfig.mcpServers {
            mergedByName[server.name] = server
        }
        for server in workspaceConfig.mcpServers {
            mergedByName[server.name] = server
        }

        let mergedServers = mergedByName.values.sorted { $0.name < $1.name }

        let mergedMCPSettings: RuntimeConfig.MCPSettings?
        if workspaceConfig.mcpSettings != nil || userConfig.mcpSettings != nil {
            mergedMCPSettings = RuntimeConfig.MCPSettings(
                allowedServers: workspaceConfig.mcpSettings?.allowedServers ?? userConfig.mcpSettings?.allowedServers,
                blockedServers: workspaceConfig.mcpSettings?.blockedServers ?? userConfig.mcpSettings?.blockedServers
            )
        } else {
            mergedMCPSettings = nil
        }

        return RuntimeConfig(
            mcpServers: mergedServers,
            mcpSettings: mergedMCPSettings,
            defaultApprovalMode: workspaceConfig.defaultApprovalMode ?? userConfig.defaultApprovalMode,
            defaultSandbox: workspaceConfig.defaultSandbox ?? userConfig.defaultSandbox,
            defaultDryRun: workspaceConfig.defaultDryRun ?? userConfig.defaultDryRun,
            defaultPolicyFile: workspaceConfig.defaultPolicyFile ?? userConfig.defaultPolicyFile,
            defaultAuditLogPath: workspaceConfig.defaultAuditLogPath ?? userConfig.defaultAuditLogPath
        )
    }

    private static func load(path: String) -> RuntimeConfig {
        guard FileManager.default.fileExists(atPath: path) else {
            return RuntimeConfig()
        }

        do {
            let data = try Data(contentsOf: URL(filePath: path))
            return try JSONDecoder().decode(RuntimeConfig.self, from: data)
        } catch {
            return RuntimeConfig()
        }
    }
}
