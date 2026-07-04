// Sources/ModelEngine/InferenceBackend.swift
// Backend classification used by AgentLoop.generateResponse() to branch between
// local MLX inference and a remote OpenAI-compatible provider.
//
// The carrier remains the existing `modelPath: String` so we don't have to
// rewire every callsite. Remote identifiers use `remote:<providerID>:<modelID>`
// (legacy `openrouter:<modelID>` is still accepted); everything else is a local
// MLX model path / Hub id.

import Foundation

public enum InferenceBackend: Sendable, Equatable {
    case local(modelPath: String)
    case remote(providerID: String, modelID: String)

    public static let openRouterPrefix = "openrouter:"
    public static let remotePrefix = "remote:"

    public init(modelPath: String) {
        let lower = modelPath.lowercased()

        // 1. Generic remote form: remote:<providerID>:<modelID>
        if lower.hasPrefix(Self.remotePrefix) {
            let remainder = String(modelPath.dropFirst(Self.remotePrefix.count))
            if let colon = remainder.firstIndex(of: ":") {
                let providerID = String(remainder[remainder.startIndex..<colon])
                let modelID = String(remainder[remainder.index(after: colon)...])
                if !providerID.isEmpty && !modelID.isEmpty {
                    self = .remote(providerID: providerID, modelID: modelID)
                    return
                }
            }
            // Malformed — fall through to local.
        }

        // 2. Back-compat: legacy openrouter:<modelID> form.
        if lower.hasPrefix(Self.openRouterPrefix) {
            let modelID = String(modelPath.dropFirst(Self.openRouterPrefix.count))
            if !modelID.isEmpty {
                self = .remote(providerID: "openrouter", modelID: modelID)
                return
            }
        }

        // 3. Local MLX model path / Hub id.
        self = .local(modelPath: modelPath)
    }

    /// Build the carrier string that round-trips through `InferenceBackend(modelPath:)`.
    public var modelPath: String {
        switch self {
        case .local(let path):
            return path
        case .remote(let providerID, let modelID):
            return "\(Self.remotePrefix)\(providerID):\(modelID)"
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
        case .local:                 return nil
        case .remote(let id, _):     return id
        }
    }

    /// The remote model id for `.remote`, nil otherwise.
    public var remoteModelID: String? {
        switch self {
        case .local:                    return nil
        case .remote(_, let modelID):   return modelID
        }
    }
}
