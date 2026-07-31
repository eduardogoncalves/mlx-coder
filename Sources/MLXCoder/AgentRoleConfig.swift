// Sources/MLXCoder/AgentRoleConfig.swift
// Per-role model assignments (planner / executor / reviewer) for the
// orchestrator's internal agents. Values are the same "carrier" strings used
// everywhere else in the codebase: a local path/hub id, or
// `<providerID>:<modelID>` for a remote provider
// (see InferenceBackend.remote(providerID:modelID:).modelPath).
//
// Stored under the "agentRoles" key in the same ~/.mlx-coder/config.json file
// RemoteProviderRegistry (providers) and RuntimeConfig (mcpServers, defaults)
// already share — each decoder only reads its own key and ignores the rest,
// so this is additive.

import Foundation

struct AgentRolesConfig: Codable, Sendable, Equatable {
    var planner: String?
    var executor: String?
    var reviewer: String?
    /// Codebase-traversal sub-agent (`codebase_research` profile). When unset it
    /// falls back to `planner`'s model — see `TaskTool.roleModel(forProfile:in:)`.
    var codebaseResearch: String?
    /// Test-runner sub-agent (`test_engineering` profile). When unset it falls
    /// back to `executor`'s model — see `TaskTool.roleModel(forProfile:in:)`.
    var testEngineering: String?

    init(
        planner: String? = nil,
        executor: String? = nil,
        reviewer: String? = nil,
        codebaseResearch: String? = nil,
        testEngineering: String? = nil
    ) {
        self.planner = planner
        self.executor = executor
        self.reviewer = reviewer
        self.codebaseResearch = codebaseResearch
        self.testEngineering = testEngineering
    }

    /// Normalize a role token for lookup: lowercase, drop `_`/`-`, so
    /// "codebase_research", "codebaseResearch", and "codebaseresearch" all match.
    private static func normalizeRole(_ role: String) -> String {
        role.lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    /// Look up a role by name (case- and separator-insensitive, e.g. "planner",
    /// "codebase_research", "testEngineering"). Unknown role names return nil.
    subscript(role: String) -> String? {
        get {
            switch AgentRolesConfig.normalizeRole(role) {
            case "planner": return planner
            case "executor": return executor
            case "reviewer": return reviewer
            case "codebaseresearch": return codebaseResearch
            case "testengineering": return testEngineering
            default: return nil
            }
        }
        set {
            switch AgentRolesConfig.normalizeRole(role) {
            case "planner": planner = newValue
            case "executor": executor = newValue
            case "reviewer": reviewer = newValue
            case "codebaseresearch": codebaseResearch = newValue
            case "testengineering": testEngineering = newValue
            default: break
            }
        }
    }

    /// All known role names, in a stable display order. The two extra roles
    /// (`codebaseResearch`, `testEngineering`) let a codebase-research or
    /// test-engineering sub-agent run on its own model instead of inheriting the
    /// coarse planner/executor bucket.
    static let roleNames = ["planner", "codebaseResearch", "executor", "testEngineering", "reviewer"]

    /// Non-nil (role, model) pairs, in `roleNames` order.
    var assignments: [(role: String, model: String)] {
        AgentRolesConfig.roleNames.compactMap { role in
            self[role].map { (role: role, model: $0) }
        }
    }

    /// Non-nil assignments as a `[role: model]` dictionary, for `TaskTool`'s
    /// `roleModels` parameter.
    var roleModelMap: [String: String] {
        Dictionary(uniqueKeysWithValues: assignments)
    }
}

enum AgentRoleRegistry {
    /// Shared with RemoteProviderRegistry — same file, different top-level key.
    static var filePath: String { RemoteProviderRegistry.filePath }

    private struct ConfigFile: Codable {
        var agentRoles: AgentRolesConfig?
    }

    /// The role→model assignments merged from `~/.mlx-coder/config.json` and an
    /// optional workspace override file, workspace winning per-role when both set.
    /// Missing/invalid files decode as "no assignments" rather than throwing.
    static func current(
        workspaceRoot: String,
        userConfigPath: String? = nil,
        workspaceConfigPath: String? = nil
    ) -> AgentRolesConfig {
        let userPath = userConfigPath ?? filePath
        let workspacePath = workspaceConfigPath ?? firstExistingPath([
            workspaceRoot + "/.mlx-coder-config.json",
            workspaceRoot + "/.native-agent-config.json"
        ])

        let userConfig = load(path: userPath)
        let workspaceConfig = load(path: workspacePath ?? "")

        var merged = userConfig
        for role in AgentRolesConfig.roleNames {
            if let override = workspaceConfig[role] {
                merged[role] = override
            }
        }
        return merged
    }

    /// Assign a model carrier string to a role in the user config
    /// (`~/.mlx-coder/config.json`). Creates the file if needed.
    static func set(role: String, model: String) throws {
        RemoteProviderRegistry.ensureConfigFileExists()
        var config = load(path: filePath)
        config[role] = model
        try save(config, to: filePath)
    }

    /// Remove a role's assignment from the user config. No-op if unset.
    static func clear(role: String) throws {
        var config = load(path: filePath)
        config[role] = nil
        try save(config, to: filePath)
    }

    // MARK: - Internals

    private static func load(path: String) -> AgentRolesConfig {
        guard FileManager.default.fileExists(atPath: path),
              let raw = try? String(contentsOf: URL(filePath: path), encoding: .utf8),
              let data = RemoteProviderRegistry.stripJSONComments(raw).data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ConfigFile.self, from: data)
        else {
            return AgentRolesConfig()
        }
        return decoded.agentRoles ?? AgentRolesConfig()
    }

    /// Rewrites the shared config file, preserving the `providers` array already
    /// managed by `RemoteProviderRegistry` (that decoder/encoder pair is kept in
    /// sync separately; here we merge in the raw JSON so neither section clobbers
    /// the other on a plain-JSON rewrite).
    private static func save(_ roles: AgentRolesConfig, to path: String) throws {
        try FileManager.default.createDirectory(
            atPath: RemoteProviderRegistry.directoryPath,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: path),
           let raw = try? String(contentsOf: URL(filePath: path), encoding: .utf8),
           let data = RemoteProviderRegistry.stripJSONComments(raw).data(using: .utf8),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let rolesData = try encoder.encode(roles)
        let rolesDict = try JSONSerialization.jsonObject(with: rolesData) as? [String: Any] ?? [:]
        // Drop null entries so an all-nil AgentRolesConfig removes the key entirely.
        let nonNilRoles = rolesDict.filter { !($0.value is NSNull) }
        if nonNilRoles.isEmpty {
            root.removeValue(forKey: "agentRoles")
        } else {
            root["agentRoles"] = nonNilRoles
        }

        let outputData = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try outputData.write(to: URL(filePath: path), options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: path
        )
    }

    private static func firstExistingPath(_ candidates: [String]) -> String? {
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
        return nil
    }
}
