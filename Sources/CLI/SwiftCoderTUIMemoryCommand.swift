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

    // Second-level argument/option suggestions
    static let subcommandOptions: [String: [(value: String, description: String)]] = [
        "save": [
            ("\"<checkpoint summary>\"", "A brief description of what you're saving"),
        ],
        "log": [
            ("\"<message>\"", "Knowledge to log"),
            ("--type decision", "A key decision made"),
            ("--type gotcha", "A pitfall or lesson learned"),
            ("--type plan", "An upcoming task or goal"),
            ("--type pattern", "A reusable technique or pattern"),
        ],
        "search": [
            ("\"<query>\"", "Keywords to search for (uses FTS5)"),
        ],
        "list": [
            ("[--type decision]", "Show only decision entries"),
            ("[--type gotcha]", "Show only gotcha/lesson entries"),
            ("[--type plan]", "Show only plan entries"),
            ("[--type pattern]", "Show only pattern entries"),
        ],
        "snippet": [
            ("[--today]", "Generate summary for today"),
            ("[--week]", "Generate summary for this week"),
        ],
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
        let typed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = typed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)

        // First part is the subcommand
        let subcommand = parts.first.map(String.init)?.lowercased() ?? ""
        
        // If we only have a subcommand or are still typing it, show subcommand completions
        if parts.count <= 1 {
            return TUIMemoryCommandParser.memorySubcommands
                .filter { subcommand.isEmpty || $0.label.hasPrefix(subcommand) }
                .map {
                    AutocompleteItem(
                        value: $0.label,
                        label: "/memory \($0.label)",
                        description: $0.description
                    )
                }
        }
        
        // We have a subcommand + additional input, show options for that subcommand
        let remainingTyped = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        
        guard let options = TUIMemoryCommandParser.subcommandOptions[subcommand] else {
            // Subcommand has no options
            return []
        }
        
        // Filter options that match what's been typed so far
        return options
            .filter { remainingTyped.isEmpty || $0.value.lowercased().hasPrefix(remainingTyped.lowercased()) }
            .map {
                AutocompleteItem(
                    value: $0.value,
                    label: "\($0.value)",
                    description: $0.description
                )
            }
    }
}

