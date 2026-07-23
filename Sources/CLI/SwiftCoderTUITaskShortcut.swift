// Sources/CLI/SwiftCoderTUITaskShortcut.swift
// Parses `/planner <message>`-style shortcuts that dispatch a named internal
// agent directly, bypassing the orchestrator's own reasoning — see
// AgentLoop.dispatchTaskShortcut.

import Foundation
import SwiftCoderTUI

enum TUITaskShortcutParser {
    /// Matches `/<profile> <message>` where `<profile>` is one of
    /// `TaskTool.supportedProfileNames` (e.g. `/planner`, `/executor`,
    /// `/reviewer`, `/filesystem`, `/terminal`, ...). Returns `nil` for any
    /// input that isn't a recognized profile shortcut, so the session's
    /// existing slash-command chain keeps handling everything else (and an
    /// unrelated command like `/plan` never fuzzy-matches `planner`).
    static func parse(_ input: String) -> (profile: String, message: String)? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }

        let head = trimmed.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard let commandToken = head.first else { return nil }

        let rawProfile = String(commandToken.dropFirst())
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        guard TaskTool.supportedProfileNames.contains(rawProfile) else { return nil }

        guard head.count > 1 else { return nil }
        let message = String(head[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return nil }

        return (profile: rawProfile, message: message)
    }
}
