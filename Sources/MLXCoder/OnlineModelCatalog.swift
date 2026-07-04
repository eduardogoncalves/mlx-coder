// Sources/MLXCoder/OnlineModelCatalog.swift
// Builds the remote-provider rows shown in the /model picker alongside the
// local MLX model list.
//
// Each entry's `id` is the carrier string consumed by `AgentLoop.switchModel`
// and re-interpreted by `InferenceBackend(modelPath:)` — the shape is
// `<providerID>:<modelID>`. The label shown in /model is the same carrier.
//
// One row is emitted per cached tool-capable model per configured provider:
//   `<provider>:<model.id>` → displayed verbatim (e.g. `openrouter:qwen/qwen3-235b`).
// Sourced from `RemoteModelCache`, which is refreshed lazily at launch and
// eagerly via `/model remote <provider> refresh`. Provider status/headline rows are intentionally not
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
                let carrier = InferenceBackend.remote(providerID: provider.id, modelID: model.id).modelPath
                result.append(AppConfig.ModelConfig(
                    id: carrier,
                    label: carrier
                ))
            }
        }

        return result
    }
}
