import Foundation
import SwiftCoderTUI

enum TUIModelCommandIntent: Equatable {
    case openRootMenu
    case openLocalMenu
    case selectLocal(id: String)
    case openRemoteProvidersMenu
    case openRemoteModelsMenu(provider: String)
    case refreshRemote(provider: String)
    case selectRemote(provider: String, modelID: String)
    case selectExisting(index: Int)      // back-compat: /model <label|#>
    case openFilteredMenu(query: String) // /model <substring> matching >1 model
    case invalidModelName(String)
}

enum TUIModelCommandParser {
    /// Parse a `/model …` input into an intent. Returns nil for non-`/model`
    /// input and for the global filter verbs (`free`/`all`/`reset`) so the
    /// session's existing filter block keeps handling them.
    static func resolve(input: String, models: [AppConfig.ModelConfig]) -> TUIModelCommandIntent? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = trimmed.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })

        guard let command = head.first?.lowercased(), command == "/model" else {
            return nil
        }

        guard head.count > 1 else { return .openRootMenu }
        let rest = head[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return .openRootMenu }

        // Split the remainder into whitespace-separated tokens.
        let tokens = rest.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let firstLower = tokens.first?.lowercased() ?? ""

        // Global filter verbs are handled by the session's filter block.
        if tokens.count == 1, firstLower == "free" || firstLower == "all" || firstLower == "reset" {
            return nil
        }

        // Local drill-down.
        if firstLower == "local" {
            if tokens.count == 1 { return .openLocalMenu }
            // Everything after "local" is the id, verbatim & trimmed.
            let id = rest
                .dropFirst(tokens[0].count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return id.isEmpty ? .openLocalMenu : .selectLocal(id: id)
        }

        // Remote drill-down.
        if firstLower == "remote" {
            switch tokens.count {
            case 1:
                return .openRemoteProvidersMenu
            case 2:
                return .openRemoteModelsMenu(provider: tokens[1])
            case 3:
                if tokens[2].lowercased() == "refresh" {
                    return .refreshRemote(provider: tokens[1])
                }
                return .selectRemote(provider: tokens[1], modelID: tokens[2])
            default:
                return .invalidModelName(rest)
            }
        }

        // Back-compat: numeric index or exact label/id.
        if let numeric = Int(rest), (1...models.count).contains(numeric) {
            return .selectExisting(index: numeric - 1)
        }
        if let index = modelIndex(named: rest, in: models) {
            return .selectExisting(index: index)
        }
        // Partial (case-insensitive substring) match against labels/ids:
        // `/model coder` → one match switches, several open a filtered menu.
        let matches = substringMatchIndices(query: rest, in: models)
        if matches.count == 1 {
            return .selectExisting(index: matches[0])
        }
        if matches.count > 1 {
            return .openFilteredMenu(query: rest)
        }
        return .invalidModelName(rest)
    }

    /// Indices of models whose label or id contains `query` (case-insensitive).
    static func substringMatchIndices(query: String, in models: [AppConfig.ModelConfig]) -> [Int] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return [] }
        return models.enumerated().compactMap { index, model in
            (model.label.lowercased().contains(needle) || model.id.lowercased().contains(needle)) ? index : nil
        }
    }

    // MARK: - Menu builders

    static func rootMenuItems() -> [(name: String, desc: String)] {
        [
            (name: "/model local", desc: "Browse local MLX models in ~/models/"),
            (name: "/model remote", desc: "Browse remote provider models")
        ]
    }

    static func localMenuItems(
        models: [AppConfig.ModelConfig],
        currentModelLabel: String
    ) -> [(name: String, desc: String)] {
        let localIDs = models
            .filter { InferenceBackend(modelPath: $0.id).isLocal }
            .map(\.id)
        // De-dupe while preserving order.
        var seen = Set<String>()
        let ids = localIDs.filter { seen.insert($0).inserted }

        return ids.map { id in
            let isCurrent = id.caseInsensitiveCompare(currentModelLabel) == .orderedSame
            let desc = isCurrent ? "Current model" : "Switch to \(id)"
            return (name: "/model local \(id)", desc: desc)
        }
    }

    static func remoteProvidersMenuItems() -> [(name: String, desc: String)] {
        RemoteProviderRegistry.providers().map { provider in
            let count = RemoteModelCache.cachedModels(providerID: provider.id).count
            let auth = provider.hasAPIKey ? "API key set" : "no API key"
            return (
                name: "/model remote \(provider.id)",
                desc: "\(provider.name) — \(auth) — \(count) models cached"
            )
        }
    }

    static func remoteModelsMenuItems(
        provider: String,
        currentModelLabel: String
    ) -> [(name: String, desc: String)] {
        let providerName = RemoteProviderRegistry.provider(id: provider)?.name ?? provider
        var items: [(name: String, desc: String)] = [
            (name: "/model remote \(provider) refresh", desc: "Refresh model list from \(providerName)")
        ]

        let cached = RemoteModelCache.cachedModels(providerID: provider)
            .filter { $0.supportsTools }
        for model in cached {
            let carrier = InferenceBackend.remote(providerID: provider, modelID: model.id).modelPath
            let isCurrent = carrier.caseInsensitiveCompare(currentModelLabel) == .orderedSame
                || model.id.caseInsensitiveCompare(currentModelLabel) == .orderedSame
            var badges = ""
            if model.isFree { badges += " [free]" }
            if let ctx = model.contextLength { badges += " (\(ctx) ctx)" }
            let desc = isCurrent ? "Current model\(badges)" : "Switch to \(model.id)\(badges)"
            items.append((name: "/model remote \(provider) \(model.id)", desc: desc))
        }

        return items
    }

    /// Palette rows for the models matching a `/model <substring>` query.
    static func filteredMenuItems(
        query: String,
        models: [AppConfig.ModelConfig],
        currentModelLabel: String
    ) -> [(name: String, desc: String)] {
        substringMatchIndices(query: query, in: models).map { index in
            let model = models[index]
            let isCurrent = model.label.caseInsensitiveCompare(currentModelLabel) == .orderedSame
            let desc = isCurrent ? "Current model" : "Switch to #\(index + 1) \(model.id)"
            return (name: "/model \(model.label)", desc: desc)
        }
    }

    private static func modelIndex(named requested: String, in models: [AppConfig.ModelConfig]) -> Int? {
        models.firstIndex {
            $0.label.caseInsensitiveCompare(requested) == .orderedSame ||
            $0.id.caseInsensitiveCompare(requested) == .orderedSame
        }
    }
}

struct TUIModelSlashCommand: SlashCommand {
    let models: [AppConfig.ModelConfig]

    let name: String = "model"
    let description: String? = "Switch model (/model → local / remote)"

    func argumentCompletions(prefix: String) -> [AutocompleteItem] {
        let typed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = typed.lowercased()

        let navItems: [AutocompleteItem] = [
            AutocompleteItem(
                value: "local",
                label: "/model local",
                description: "Browse local MLX models"
            ),
            AutocompleteItem(
                value: "remote",
                label: "/model remote",
                description: "Browse remote provider models"
            )
        ].filter { normalized.isEmpty || $0.value.hasPrefix(normalized) }

        let modelItems = models
            .enumerated()
            .filter { _, model in
                guard !normalized.isEmpty else { return true }
                return model.label.lowercased().contains(normalized)
                    || model.id.lowercased().contains(normalized)
            }
            .map { index, model in
                let desc = model.id == model.label
                    ? "Switch to #\(index + 1) \(model.label)"
                    : "#\(index + 1), id: \(model.id)"
                return AutocompleteItem(
                    value: model.label,
                    label: "/model \(model.label)",
                    description: desc
                )
            }

        return navItems + modelItems
    }
}
