// Sources/MLXCoder/Credentials.swift
// BYOK credential storage for online model providers.
//
// On-disk format mirrors pi's auth.json convention:
//   { "providers": { "<id>": { "apiKey": "..." } } }
// File mode is forced to 0600 on every write. Env vars are consulted as a
// fallback so users with OPENROUTER_API_KEY exported don't need to /login.

import Foundation

enum Credentials {
    static let directoryPath: String = {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.mlx-coder"
    }()

    static let filePath: String = directoryPath + "/auth.json"

    /// Env-var name consulted as a fallback when no key is stored on disk.
    static func envVarName(for provider: String) -> String {
        switch provider.lowercased() {
        case "openrouter": return "OPENROUTER_API_KEY"
        default:           return "\(provider.uppercased())_API_KEY"
        }
    }

    static func apiKey(for provider: String) -> String? {
        if let stored = load().providers[provider.lowercased()]?.apiKey, !stored.isEmpty {
            return stored
        }
        if let env = ProcessInfo.processInfo.environment[envVarName(for: provider)], !env.isEmpty {
            return env
        }
        return nil
    }

    static func isConfigured(_ provider: String) -> Bool {
        apiKey(for: provider) != nil
    }

    static func setAPIKey(_ key: String, for provider: String) throws {
        var auth = load()
        auth.providers[provider.lowercased()] = ProviderRecord(apiKey: key)
        try save(auth)
    }

    static func clear(provider: String) throws {
        var auth = load()
        auth.providers.removeValue(forKey: provider.lowercased())
        try save(auth)
    }

    // MARK: - Internals

    struct AuthFile: Codable {
        var providers: [String: ProviderRecord]
    }

    struct ProviderRecord: Codable {
        var apiKey: String
    }

    private static func load() -> AuthFile {
        guard FileManager.default.fileExists(atPath: filePath),
              let data = try? Data(contentsOf: URL(filePath: filePath)),
              let decoded = try? JSONDecoder().decode(AuthFile.self, from: data)
        else {
            return AuthFile(providers: [:])
        }
        return decoded
    }

    private static func save(_ auth: AuthFile) throws {
        try FileManager.default.createDirectory(
            atPath: directoryPath,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(auth)
        try data.write(to: URL(filePath: filePath), options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: filePath
        )
    }
}
