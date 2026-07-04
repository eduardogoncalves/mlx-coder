// Sources/MLXCoder/RemoteProvider.swift
// Provider-agnostic description of a remote, OpenAI-API-compatible inference
// endpoint (OpenRouter, LM Studio, vLLM, mlx-lm.server, etc.).
//
// Built-in providers ship with the app; users can add or override providers in
// ~/.mlx-coder/config.json with shape:
//   { "remoteProviders": [ { "id", "name", "baseURL", "requiresAuth", "apiKeyEnv" } ] }
// File permissions mirror Credentials.swift (dir 0700, file 0600, atomic write).

import Foundation

struct RemoteProvider: Codable, Sendable, Equatable {
    var id: String            // unique, lowercase, e.g. "openrouter", "lmstudio"
    var name: String          // display, e.g. "OpenRouter", "LM Studio"
    var baseURL: String       // OpenAI-compatible base, e.g. "https://openrouter.ai/api/v1"
    var requiresAuth: Bool    // true => an API key is required
    var apiKeyEnv: String?    // optional override env var name; default computed

    /// The base URL as a `URL`, or nil if malformed.
    var baseURLValue: URL? { URL(string: baseURL) }

    /// Env-var name consulted for this provider's API key.
    var envVarName: String {
        apiKeyEnv ?? "\(id.uppercased().replacingOccurrences(of: "-", with: "_"))_API_KEY"
    }
}

enum RemoteProviderRegistry {
    static let directoryPath: String = {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.mlx-coder"
    }()

    static let filePath: String = directoryPath + "/config.json"

    static var builtIns: [RemoteProvider] {
        [
            RemoteProvider(
                id: "openrouter",
                name: "OpenRouter",
                baseURL: "https://openrouter.ai/api/v1",
                requiresAuth: true,
                apiKeyEnv: nil
            ),
            RemoteProvider(
                id: "lmstudio",
                name: "LM Studio",
                baseURL: "http://localhost:1234/v1",
                requiresAuth: false,
                apiKeyEnv: nil
            ),
            RemoteProvider(
                id: "vllm",
                name: "vLLM",
                baseURL: "http://localhost:8000/v1",
                requiresAuth: false,
                apiKeyEnv: nil
            ),
            RemoteProvider(
                id: "mlx-lm",
                name: "mlx-lm.server",
                baseURL: "http://localhost:8080/v1",
                requiresAuth: false,
                apiKeyEnv: nil
            )
        ]
    }

    /// Built-ins merged with user-defined providers. User entries with the same
    /// `id` override the built-in; new ids are appended after the built-ins.
    static func providers() -> [RemoteProvider] {
        let user = loadUser()
        var result: [RemoteProvider] = []
        var seen = Set<String>()

        for builtIn in builtIns {
            if let override = user.first(where: { $0.id.lowercased() == builtIn.id.lowercased() }) {
                result.append(override)
            } else {
                result.append(builtIn)
            }
            seen.insert(builtIn.id.lowercased())
        }

        for provider in user where !seen.contains(provider.id.lowercased()) {
            result.append(provider)
            seen.insert(provider.id.lowercased())
        }

        return result
    }

    /// Look up a provider by id (case-insensitive).
    static func provider(id: String) -> RemoteProvider? {
        let needle = id.lowercased()
        return providers().first { $0.id.lowercased() == needle }
    }

    /// Upsert a user-defined/overridden provider into the config file.
    static func addOrUpdate(_ provider: RemoteProvider) throws {
        var user = loadUser()
        if let index = user.firstIndex(where: { $0.id.lowercased() == provider.id.lowercased() }) {
            user[index] = provider
        } else {
            user.append(provider)
        }
        try saveUser(user)
    }

    /// Remove a user-defined/overridden provider by id. Built-ins can't truly be
    /// removed — this only drops any user override for that id.
    static func remove(id: String) throws {
        var user = loadUser()
        user.removeAll { $0.id.lowercased() == id.lowercased() }
        try saveUser(user)
    }

    // MARK: - Internals

    struct ConfigFile: Codable {
        var remoteProviders: [RemoteProvider]
    }

    private static func loadUser() -> [RemoteProvider] {
        guard FileManager.default.fileExists(atPath: filePath),
              let data = try? Data(contentsOf: URL(filePath: filePath)),
              let decoded = try? JSONDecoder().decode(ConfigFile.self, from: data)
        else {
            return []
        }
        return decoded.remoteProviders
    }

    private static func saveUser(_ providers: [RemoteProvider]) throws {
        try FileManager.default.createDirectory(
            atPath: directoryPath,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(ConfigFile(remoteProviders: providers))
        try data.write(to: URL(filePath: filePath), options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: filePath
        )
    }
}
