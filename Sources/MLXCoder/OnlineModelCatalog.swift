// Sources/MLXCoder/OnlineModelCatalog.swift
// Builds the online-provider rows shown in the /model picker alongside the
// local MLX model list.
//
// Each entry's `id` is the carrier string consumed by `AgentLoop.switchModel`
// and re-interpreted by `InferenceBackend(modelPath:)` — for OpenRouter the
// shape is `openrouter:<model-id>`. The label is what the user sees in /model.
//
// Two flavors of entries:
//   1. A headline status row — `OpenRouter • configured` / `OpenRouter • unconfigured`
//      pointing at a sensible default model. Always shown so users know the
//      provider exists.
//   2. One row per cached tool-capable model — `<id> [openrouter]`. Sourced
//      from `OpenRouterModelCache`, which is refreshed lazily at launch and
//      eagerly after `/login`.

import Foundation
import SwiftCoderTUI

enum OnlineModelCatalog {
    enum Filter: Sendable {
        case all
        case freeOnly
    }

    /// Default model used when the user picks the bare headline row without
    /// browsing the full list.
    static let defaultOpenRouterModel = "anthropic/claude-sonnet-4.5"

    /// Build the rows to append to the local model list.
    static func entries(filter: Filter = .all) -> [AppConfig.ModelConfig] {
        var result: [AppConfig.ModelConfig] = []
        let configured = Credentials.isConfigured("openrouter")

        // Headline row — always present, label reflects auth status.
        let headlineID = "openrouter:\(defaultOpenRouterModel)"
        let headlineLabel = configured
            ? "OpenRouter • configured"
            : "OpenRouter • unconfigured"
        result.append(AppConfig.ModelConfig(id: headlineID, label: headlineLabel))

        // Per-model rows. Only shown once a cache exists — if the user has
        // never run /login and never let a refresh complete, we keep the
        // picker tight to avoid a wall of unusable rows.
        let cached = OpenRouterModelCache.cachedModels().filter { model in
            switch filter {
            case .all:
                return true
            case .freeOnly:
                return model.isFree
            }
        }
        for model in cached {
            let freeBadge = model.isFree ? " [free]" : ""
            result.append(AppConfig.ModelConfig(
                id: "openrouter:\(model.id)",
                label: "\(model.id)\(freeBadge) [openrouter]"
            ))
        }

        return result
    }
}
