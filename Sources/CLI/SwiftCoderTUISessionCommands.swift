// Sources/CLI/SwiftCoderTUISessionCommands.swift
// Autocomplete for `/resume`, whose destructive `remove` subcommand needs to
// be discoverable the same way `/memory remove` is.

import Foundation
import SwiftCoderTUI

struct TUIResumeSlashCommand: SlashCommand {
    let name: String = "resume"
    let description: String? = "Resume a saved session (opens a picker); /resume remove to delete one"

    func argumentCompletions(prefix: String) -> [AutocompleteItem] {
        let typed = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Empty prefix must yield no suggestions: unlike `/memory`, bare
        // `/resume` already does something (opens the resume picker), and the
        // editor accepts a pending suggestion before submitting on Enter — an
        // eagerly-offered "remove" here would hijack Enter on bare `/resume`
        // into silently running `/resume remove` instead.
        guard !typed.isEmpty, "remove".hasPrefix(typed) else { return [] }
        return [
            AutocompleteItem(value: "remove", label: "/resume remove", description: "Remove a saved session (interactive picker)"),
        ]
    }
}
