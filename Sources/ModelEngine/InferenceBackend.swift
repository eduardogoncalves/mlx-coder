// Sources/ModelEngine/InferenceBackend.swift
// Backend classification used by AgentLoop.generateResponse() to branch between
// local MLX inference and a remote OpenAI-compatible provider.
//
// The carrier remains the existing `modelPath: String` so we don't have to
// rewire every callsite. Remote identifiers use `<providerID>:<modelID>` (e.g.
// `openrouter:qwen/qwen3-235b`); everything else is a local MLX model path / Hub id.
//
// A `<providerID>:<modelID>` is recognized as remote only when the segment
// before the first colon is a bare token (letters, digits, `_`, `-`) with no
// path separators — so local Hub ids (`owner/repo`) and filesystem paths, which
// don't carry a leading `token:`, always resolve to `.local`.

import Foundation

public enum InferenceBackend: Sendable, Equatable {
    case local(modelPath: String)
    case remote(providerID: String, modelID: String)

    public init(modelPath: String) {
        // Provider carrier: <providerID>:<modelID>.
        if let backend = Self.parseProviderCarrier(modelPath) {
            self = backend
            return
        }

        // Local MLX model path / Hub id.
        self = .local(modelPath: modelPath)
    }

    /// Parse `<providerID>:<modelID>` into a `.remote` backend, or nil when the
    /// string isn't a provider carrier (no colon, empty halves, or a provider
    /// segment containing path separators / other punctuation).
    private static func parseProviderCarrier(_ string: String) -> InferenceBackend? {
        guard let colon = string.firstIndex(of: ":") else { return nil }
        let providerID = String(string[string.startIndex..<colon])
        let modelID = String(string[string.index(after: colon)...])
        guard !providerID.isEmpty, !modelID.isEmpty else { return nil }
        guard providerID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            return nil
        }
        return .remote(providerID: providerID, modelID: modelID)
    }

    /// Build the carrier string that round-trips through `InferenceBackend(modelPath:)`.
    public var modelPath: String {
        switch self {
        case .local(let path):
            return path
        case .remote(let providerID, let modelID):
            return "\(providerID):\(modelID)"
        }
    }

    public var isLocal: Bool {
        if case .local = self { return true }
        return false
    }

    public var isOnline: Bool { !isLocal }

    /// Provider id, lowercase, suitable for `RemoteProviderRegistry.provider(id:)`.
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
