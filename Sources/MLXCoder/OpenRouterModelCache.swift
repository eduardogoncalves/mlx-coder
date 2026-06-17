// Sources/MLXCoder/OpenRouterModelCache.swift
// Persists OpenRouter's `/models` response under ~/.mlx-coder so the picker has
// entries on launch without hitting the network. Refreshed lazily when stale
// and eagerly after `/login openrouter <key>`.

import Foundation

enum OpenRouterModelCache {
    static let filePath: String = {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.mlx-coder/openrouter-models.json"
    }()

    /// Cache entries older than this are still served, but the caller is encouraged
    /// to kick off a background refresh.
    static let staleAfter: TimeInterval = 24 * 60 * 60

    struct CacheFile: Codable {
        let fetchedAt: Date
        let models: [OpenRouterClient.ModelInfo]
    }

    static func load() -> CacheFile? {
        guard let data = try? Data(contentsOf: URL(filePath: filePath)) else { return nil }
        return try? JSONDecoder.iso8601().decode(CacheFile.self, from: data)
    }

    static func cachedModels() -> [OpenRouterClient.ModelInfo] {
        load()?.models ?? []
    }

    static func isStale() -> Bool {
        guard let cache = load() else { return true }
        return Date().timeIntervalSince(cache.fetchedAt) > staleAfter
    }

    static func save(_ models: [OpenRouterClient.ModelInfo]) throws {
        let dir = (filePath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let payload = CacheFile(fetchedAt: Date(), models: models)
        let data = try JSONEncoder.iso8601().encode(payload)
        try data.write(to: URL(filePath: filePath), options: .atomic)
    }

    /// Fetch live and persist. Returns the new list. Throws on network error.
    @discardableResult
    static func refresh() async throws -> [OpenRouterClient.ModelInfo] {
        // The /models endpoint is public — no API key needed — so we can
        // populate the cache before the user runs /login.
        let client = OpenRouterClient(apiKey: Credentials.apiKey(for: "openrouter") ?? "")
        let models = try await client.listToolCapableModels()
        try save(models)
        return models
    }
}

private extension JSONDecoder {
    static func iso8601() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

private extension JSONEncoder {
    static func iso8601() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }
}
