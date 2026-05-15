// Sources/CLI/SwiftCoderTUIMemoryCommand.swift
// Memory command menu items and autocomplete provider.

import Foundation
import SwiftCoderTUI

enum TUIMemoryCommandParser {
    static let memorySubcommands: [(label: String, description: String)] = [
        ("save", "Save a session state checkpoint"),
        ("log", "Log typed knowledge (decision|gotcha|plan|pattern)"),
        ("search", "FTS5 keyword search"),
        ("list", "Browse recent entries"),
        ("undo", "Delete last entry"),
        ("status", "Entry counts and DB stats"),
        ("snippet", "Generate work summary"),
    ]

    static func menuItems() -> [(name: String, desc: String)] {
        memorySubcommands.map { (label, description) in
            (name: "/memory \(label)", desc: description)
        }
    }

    static func resolve(input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard let command = parts.first?.lowercased() else { return nil }

        guard command == "/memory" else { return nil }
        guard parts.count > 1 else { return nil }

        let requested = parts[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return requested.isEmpty ? nil : requested
    }
}

struct TUIMemorySlashCommand: SlashCommand {
    let name: String = "memory"
    let description: String? = "Memory subsystem (/memory, /memory <save|log|search|list|undo|status|snippet>)"

    func argumentCompletions(prefix: String) -> [AutocompleteItem] {
        let typed = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return TUIMemoryCommandParser.memorySubcommands
            .filter { typed.isEmpty || $0.label.hasPrefix(typed) }
            .map {
                AutocompleteItem(
                    value: $0.label,
                    label: "/memory \($0.label)",
                    description: $0.description
                )
            }
    }
}
