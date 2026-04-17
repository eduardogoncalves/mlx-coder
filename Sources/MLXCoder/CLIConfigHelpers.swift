// Sources/MLXCoder/CLIConfigHelpers.swift
// Permission, policy, ignore patterns, MCP config, approval mode, and skill discovery helpers.

import Foundation

func parseApprovalMode(_ value: String) -> PermissionEngine.ApprovalMode {
    switch value.lowercased() {
    case PermissionEngine.ApprovalMode.autoEdit.rawValue:
        return .autoEdit
    case PermissionEngine.ApprovalMode.yolo.rawValue:
        return .yolo
    default:
        return .default
    }
}

func loadPermissionPolicy(explicitPath: String?, workspaceRoot: String, renderer: StreamRenderer) -> PermissionEngine.PolicyDocument? {
    let policyPath: String

    if let explicitPath, !explicitPath.isEmpty {
        let expanded = NSString(string: explicitPath).expandingTildeInPath
        policyPath = expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
    } else {
        policyPath = workspaceRoot + "/.mlx-coder-policy.json"
    }

    guard FileManager.default.fileExists(atPath: policyPath) else {
        return nil
    }

    do {
        let data = try Data(contentsOf: URL(filePath: policyPath))
        let decoder = JSONDecoder()
        let document = try decoder.decode(PermissionEngine.PolicyDocument.self, from: data)
        renderer.printStatus("Loaded permission policy: \(policyPath)")
        return document
    } catch {
        renderer.printError("Failed to load policy file '\(policyPath)': \(error.localizedDescription)")
        return nil
    }
}

func loadIgnorePatterns(workspaceRoot: String) -> [String] {
    let ignorePath = workspaceRoot + "/.mlx-coder-ignore"
    guard let text = try? String(contentsOfFile: ignorePath, encoding: .utf8) else {
        return []
    }

    return text
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .filter { !$0.hasPrefix("#") }
}

func discoverSkillFiles(workspaceRoot: String) -> [String] {
    let fileManager = FileManager.default
    let roots = [
        workspaceRoot + "/.github/skills",
        workspaceRoot + "/skills"
    ]

    var discovered: [String] = []
    for root in roots {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
            continue
        }

        guard let enumerator = fileManager.enumerator(atPath: root) else {
            continue
        }

        for case let relative as String in enumerator {
            if relative == "SKILL.md" || relative.hasSuffix("/SKILL.md") {
                discovered.append(root + "/" + relative)
            }
        }
    }

    return discovered.sorted()
}

func makeMCPServerConfig(from args: ModelArguments) -> MCPClient.ServerConfig? {
    guard let endpoint = args.mcpEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines), !endpoint.isEmpty else {
        return nil
    }

    return MCPClient.ServerConfig(
        name: args.mcpName,
        command: endpoint,
        endpointURL: endpoint,
        timeoutSeconds: max(1, args.mcpTimeout)
    )
}

func runtimeMCPServerConfigs(
    from runtimeConfig: RuntimeConfig,
    includeOverride: String? = nil,
    excludeOverride: String? = nil
) -> [MCPClient.ServerConfig] {
    let allowedServers: Set<String>
    if let includeOverride {
        allowedServers = parseMCPServerNameSet(csv: includeOverride)
    } else {
        allowedServers = Set(
            (runtimeConfig.mcpSettings?.allowedServers ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
    }

    let blockedServers: Set<String>
    if let excludeOverride {
        blockedServers = parseMCPServerNameSet(csv: excludeOverride)
    } else {
        blockedServers = Set(
            (runtimeConfig.mcpSettings?.blockedServers ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
    }

    return runtimeConfig.mcpServers.compactMap { server in
        if server.enabled == false {
            return nil
        }

        let serverName = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = serverName.lowercased()

        if !allowedServers.isEmpty, !allowedServers.contains(normalizedName) {
            return nil
        }

        if blockedServers.contains(normalizedName) {
            return nil
        }

        let command = server.command ?? server.endpoint ?? ""
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return MCPClient.ServerConfig(
            name: serverName,
            command: command,
            arguments: server.arguments ?? [],
            environment: server.environment ?? [:],
            endpointURL: server.endpoint,
            timeoutSeconds: max(1, server.timeoutSeconds ?? 30)
        )
    }
}

func parseMCPServerNameSet(csv: String) -> Set<String> {
    Set(
        csv
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    )
}

func resolvedApprovalMode(from cliValue: String, runtimeConfig: RuntimeConfig) -> PermissionEngine.ApprovalMode {
    if cliValue.lowercased() != PermissionEngine.ApprovalMode.default.rawValue {
        return parseApprovalMode(cliValue)
    }

    if let configured = runtimeConfig.defaultApprovalMode {
        return parseApprovalMode(configured)
    }

    return .default
}

func resolvedSandbox(cliSandbox: Bool, runtimeConfig: RuntimeConfig) -> Bool {
    if cliSandbox == false {
        return false
    }
    return runtimeConfig.defaultSandbox ?? cliSandbox
}

func resolvedDryRun(cliDryRun: Bool, runtimeConfig: RuntimeConfig) -> Bool {
    if cliDryRun == true {
        return true
    }
    return runtimeConfig.defaultDryRun ?? cliDryRun
}

func mergedMCPConfigs(runtimeConfigs: [MCPClient.ServerConfig], cliConfig: MCPClient.ServerConfig?) -> [MCPClient.ServerConfig] {
    var merged = runtimeConfigs
    if let cliConfig {
        merged.append(cliConfig)
    }

    // Deduplicate by server name while preserving the latest entry.
    var byName: [String: MCPClient.ServerConfig] = [:]
    for config in merged {
        byName[config.name] = config
    }
    return byName.values.sorted { $0.name < $1.name }
}

func isCommandAvailable(_ command: String) -> Bool {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return false
    }

    if trimmed.contains("/") {
        return access(trimmed, X_OK) == 0
    }

    let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let directories = envPath
        .components(separatedBy: ":")
        .filter { !$0.isEmpty }

    for directory in directories {
        let candidate = (directory as NSString).appendingPathComponent(trimmed)
        if access(candidate, X_OK) == 0 {
            return true
        }
    }

    return false
}
