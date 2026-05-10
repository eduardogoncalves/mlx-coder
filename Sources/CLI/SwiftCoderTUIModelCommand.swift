import Foundation
import SwiftCoderTUI

enum TUIModelCommandIntent: Equatable {
    case openMenu
    case selectModel(index: Int)
    case invalidModelName(String)
}

enum TUIModelCommandParser {
    static func resolve(input: String, models: [AppConfig.ModelConfig]) -> TUIModelCommandIntent? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })

        guard let command = parts.first?.lowercased(), command == "/model" else {
            return nil
        }

        guard parts.count > 1 else { return .openMenu }
        let requested = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else { return .openMenu }

        if let numeric = Int(requested), (1...models.count).contains(numeric) {
            return .selectModel(index: numeric - 1)
        }

        guard let index = modelIndex(named: requested, in: models) else {
            return .invalidModelName(requested)
        }
        return .selectModel(index: index)
    }

    static func menuItems(
        models: [AppConfig.ModelConfig],
        currentModelLabel: String
    ) -> [(name: String, desc: String)] {
        models.enumerated().map { index, model in
            let isCurrent = model.label.caseInsensitiveCompare(currentModelLabel) == .orderedSame
            let details = model.id == model.label ? "" : " (id: \(model.id))"
            let desc = isCurrent ? "Current model" : "Switch to #\(index + 1) \(model.label)\(details)"
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
    let description: String? = "Switch model (/model, /model <name|id|#>)"

    func argumentCompletions(prefix: String) -> [AutocompleteItem] {
        let typed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = typed.lowercased()

        return models
            .enumerated()
            .filter { _, model in
                guard !normalized.isEmpty else { return true }
                return model.label.lowercased().hasPrefix(normalized)
                    || model.id.lowercased().hasPrefix(normalized)
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
    }
}
