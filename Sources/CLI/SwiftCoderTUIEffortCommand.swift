import Foundation
import SwiftCoderTUI

enum TUIEffortCommandIntent: Equatable {
    case openMenu(isLegacyAlias: Bool)
    case setLevel(AgentLoop.ThinkingLevel, isLegacyAlias: Bool)
    case invalidLevel(String, isLegacyAlias: Bool)
}

enum TUIEffortCommandParser {
    static let effortOptions: [(label: String, level: AgentLoop.ThinkingLevel)] = [
        ("off", .fast),
        ("minimal", .minimal),
        ("low", .low),
        ("medium", .medium),
        ("high", .high)
    ]

    static func resolve(input: String) -> TUIEffortCommandIntent? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard let command = parts.first?.lowercased() else { return nil }

        let isLegacyAlias: Bool
        switch command {
        case "/effort":
            isLegacyAlias = false
        case "/thinking":
            isLegacyAlias = true
        default:
            return nil
        }

        guard parts.count > 1 else { return .openMenu(isLegacyAlias: isLegacyAlias) }
        let requested = parts[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !requested.isEmpty else { return .openMenu(isLegacyAlias: isLegacyAlias) }

        guard let level = effortOptions.first(where: { $0.label == requested })?.level else {
            return .invalidLevel(requested, isLegacyAlias: isLegacyAlias)
        }

        return .setLevel(level, isLegacyAlias: isLegacyAlias)
    }

    static func menuItems(currentLevel: AgentLoop.ThinkingLevel) -> [(name: String, desc: String)] {
        effortOptions.map { option in
            let desc = option.level == currentLevel
                ? "Current effort"
                : "Set reasoning effort to \(option.label)"
            return (name: "/effort \(option.label)", desc: desc)
        }
    }
}

struct TUIEffortSlashCommand: SlashCommand {
    let name: String = "effort"
    let description: String? = "Set reasoning effort (/effort, /effort <off|minimal|low|medium|high>)"

    func argumentCompletions(prefix: String) -> [AutocompleteItem] {
        let typed = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return TUIEffortCommandParser.effortOptions
            .filter { typed.isEmpty || $0.label.hasPrefix(typed) }
            .map {
                AutocompleteItem(
                    value: $0.label,
                    label: "/effort \($0.label)",
                    description: "Set reasoning effort to \($0.label)"
                )
            }
    }
}
