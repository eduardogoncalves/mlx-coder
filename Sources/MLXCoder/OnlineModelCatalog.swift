// Sources/MLXCoder/OnlineModelCatalog.swift
// Builds the remote-provider rows shown in the /model picker alongside the
// local MLX model list.
//
// Each entry's `id` is the carrier string consumed by `AgentLoop.switchModel`
// and re-interpreted by `InferenceBackend(modelPath:)` — the generic shape is
// `remote:<providerID>:<modelID>`. The label is what the user sees in /model.
//
// One row is emitted per cached tool-capable model per configured provider:
//   `remote:<provider>:<model.id>` → `<model.id>[ free] [<provider>]`.
// Sourced from `RemoteModelCache`, which is refreshed lazily at launch and
// eagerly after `/login`. Provider status/headline rows are intentionally not
// emitted here — the two-level `/model remote` menu surfaces provider status.

import Foundation
import SwiftCoderTUI

enum OnlineModelCatalog {
    enum Filter: Sendable {
        case all
        case freeOnly
    }

    /// Default OpenRouter model, kept for callsites that still reference it.
    static let defaultOpenRouterModel = "anthropic/claude-sonnet-4.5"

    /// Build the rows to append to the local model list — one per cached
    /// tool-capable model across every configured provider.
    static func entries(filter: Filter = .all) -> [AppConfig.ModelConfig] {
        var result: [AppConfig.ModelConfig] = []

        for provider in RemoteProviderRegistry.providers() {
            let cached = RemoteModelCache.cachedModels(providerID: provider.id).filter { model in
                switch filter {
                case .all:
                    return true
                case .freeOnly:
                    return model.isFree
                }
            }
            for model in cached {
                let freeBadge = model.isFree ? " free" : ""
                result.append(AppConfig.ModelConfig(
                    id: InferenceBackend.remote(providerID: provider.id, modelID: model.id).modelPath,
                    label: "\(model.id)\(freeBadge) [\(provider.id)]"
                ))
            }
        }

        return result
    }
}
