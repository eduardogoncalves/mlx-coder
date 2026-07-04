// Sources/MLXCoder/OpenRouterModelCache.swift
// Persists a remote provider's `/models` response under ~/.mlx-coder so the
// picker has entries on launch without hitting the network. Refreshed lazily
// when stale and eagerly on demand via `/model remote <provider> refresh`.
//
// The cache is keyed per provider under ~/.mlx-coder/remote-models/<id>.json.
// `OpenRouterModelCache` is kept as a thin back-compat wrapper over
// `RemoteModelCache` (providerID "openrouter") for existing callsites.

import Foundation

enum RemoteModelCache {
    static func filePath(providerID: String) -> String {
        FileManager.default.homeDirectoryForCurrentUser.path
            + "/.mlx-coder/remote-models/\(providerID).json"
    }

    /// Cache entries older than this are still served, but the caller is encouraged
    /// to kick off a background refresh.
    static let staleAfter: TimeInterval = 24 * 60 * 60

    struct CacheFile: Codable {
        let fetchedAt: Date
        let models: [OpenRouterClient.ModelInfo]
    }

    static func load(providerID: String) -> CacheFile? {
        guard let data = try? Data(contentsOf: URL(filePath: filePath(providerID: providerID))) else { return nil }
        return try? JSONDecoder.iso8601().decode(CacheFile.self, from: data)
    }

    static func cachedModels(providerID: String) -> [OpenRouterClient.ModelInfo] {
        load(providerID: providerID)?.models ?? []
    }

    static func isStale(providerID: String) -> Bool {
        guard let cache = load(providerID: providerID) else { return true }
        return Date().timeIntervalSince(cache.fetchedAt) > staleAfter
    }

    static func save(_ models: [OpenRouterClient.ModelInfo], providerID: String) throws {
        let path = filePath(providerID: providerID)
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let payload = CacheFile(fetchedAt: Date(), models: models)
        let data = try JSONEncoder.iso8601().encode(payload)
        try data.write(to: URL(filePath: path), options: .atomic)
    }

    /// Fetch live and persist. Returns the new list. Throws on network error or
    /// if the provider is unknown.
    @discardableResult
    static func refresh(providerID: String) async throws -> [OpenRouterClient.ModelInfo] {
        guard let provider = RemoteProviderRegistry.provider(id: providerID) else {
            throw NSError(
                domain: "RemoteModelCache",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unknown remote provider '\(providerID)'. Configure it in ~/.mlx-coder/config.json."]
            )
        }
        // The /models endpoint is typically public, but we still pass the
        // configured key when present so authenticated gateways work too.
        let base = provider.baseURLValue ?? URL(string: "https://openrouter.ai/api/v1")!
        let key = RemoteProviderRegistry.apiKey(for: providerID) ?? ""
        let client = OpenRouterClient(apiKey: key, baseURL: base)
        let models = try await client.listToolCapableModels()
        try save(models, providerID: providerID)
        return models
    }
}

/// Back-compat wrapper for existing callsites that still assume OpenRouter.
/// The /model menu UI task will migrate these to `RemoteModelCache` directly.
enum OpenRouterModelCache {
    static func cachedModels() -> [OpenRouterClient.ModelInfo] {
        RemoteModelCache.cachedModels(providerID: "openrouter")
    }

    static func isStale() -> Bool {
        RemoteModelCache.isStale(providerID: "openrouter")
    }

    @discardableResult
    static func refresh() async throws -> [OpenRouterClient.ModelInfo] {
        try await RemoteModelCache.refresh(providerID: "openrouter")
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
