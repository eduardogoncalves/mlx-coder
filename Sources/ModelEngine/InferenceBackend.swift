// Sources/ModelEngine/InferenceBackend.swift
// Backend classification used by AgentLoop.generateResponse() to branch between
// local MLX inference and an online OpenAI-compatible provider.
//
// The carrier remains the existing `modelPath: String` so we don't have to
// rewire every callsite. Strings prefixed with `<provider>:` are treated as
// online identifiers; everything else is a local MLX model path / Hub id.

import Foundation

public enum InferenceBackend: Sendable, Equatable {
    case local(modelPath: String)
    case openRouter(modelID: String)

    public static let openRouterPrefix = "openrouter:"

    public init(modelPath: String) {
        if let modelID = Self.onlineModelID(modelPath, prefix: Self.openRouterPrefix) {
            self = .openRouter(modelID: modelID)
        } else {
            self = .local(modelPath: modelPath)
        }
    }

    /// Build the carrier string that round-trips through `InferenceBackend(modelPath:)`.
    public var modelPath: String {
        switch self {
        case .local(let path):     return path
        case .openRouter(let id):  return "\(Self.openRouterPrefix)\(id)"
        }
    }

    public var isLocal: Bool {
        if case .local = self { return true }
        return false
    }

    public var isOnline: Bool { !isLocal }

    /// Provider id, lowercase, suitable for `Credentials.apiKey(for:)`.
    public var providerID: String? {
        switch self {
        case .local:        return nil
        case .openRouter:   return "openrouter"
        }
    }

    private static func onlineModelID(_ raw: String, prefix: String) -> String? {
        guard raw.lowercased().hasPrefix(prefix) else { return nil }
        let id = String(raw.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }
}
