// Sources/CLI/SwiftCoderTUILoginCommand.swift
// `/login` slash command for storing online-provider API keys (BYOK).
//
// Forms:
//   /login                       — open the provider picker
//   /login openrouter            — print guidance ("paste your key after the provider name")
//   /login openrouter sk-or-...  — save the key for `openrouter` and confirm
//   /logout openrouter           — clear the stored key
//
// Keys are stored via `Credentials` at ~/.mlx-coder/auth.json (mode 0600). The
// env var `OPENROUTER_API_KEY` is also honored as a fallback.

import Foundation
import SwiftCoderTUI

enum TUILoginCommandIntent: Equatable {
    case openMenu
    case showHelp(provider: String)
    case saveKey(provider: String, key: String)
    case clearKey(provider: String)
    case unknownProvider(String)
}

enum TUILoginCommandParser {
    static let knownProviders: [(id: String, label: String)] = [
        ("openrouter", "OpenRouter")
    ]

    /// Returns the intent for both `/login` and `/logout` inputs. Returns nil
    /// for inputs that aren't login commands.
    static func resolve(input: String) -> TUILoginCommandIntent? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let firstSpace = trimmed.firstIndex(of: " ")
        let head = firstSpace.map { String(trimmed[..<$0]).lowercased() } ?? trimmed.lowercased()
        let rest = firstSpace.map { String(trimmed[trimmed.index(after: $0)...]).trimmingCharacters(in: .whitespaces) } ?? ""

        switch head {
        case "/login":
            if rest.isEmpty { return .openMenu }
            let parts = rest.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            let provider = String(parts[0]).lowercased()
            guard isKnownProvider(provider) else { return .unknownProvider(provider) }
            if parts.count > 1 {
                let key = String(parts[1]).trimmingCharacters(in: .whitespaces)
                return key.isEmpty ? .showHelp(provider: provider) : .saveKey(provider: provider, key: key)
            }
            return .showHelp(provider: provider)
        case "/logout":
            if rest.isEmpty { return .openMenu }
            let provider = rest.lowercased()
            guard isKnownProvider(provider) else { return .unknownProvider(provider) }
            return .clearKey(provider: provider)
        default:
            return nil
        }
    }

    static func menuItems() -> [(name: String, desc: String)] {
        knownProviders.map { provider in
            let configured = Credentials.isConfigured(provider.id)
            let status = configured ? "configured" : "unconfigured"
            let action = configured ? "Re-enter API key" : "Set API key"
            return (
                name: "/login \(provider.id)",
                desc: "\(action) for \(provider.label) (\(status))"
            )
        }
    }

    static func isKnownProvider(_ id: String) -> Bool {
        knownProviders.contains { $0.id == id }
    }

    static func displayName(_ id: String) -> String {
        knownProviders.first(where: { $0.id == id })?.label ?? id
    }
}

struct TUILoginSlashCommand: SlashCommand {
    let name: String = "login"
    let description: String? = "Set an API key for an online provider (/login, /login <provider> <key>)"

    func argumentCompletions(prefix: String) -> [AutocompleteItem] {
        let typed = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return TUILoginCommandParser.knownProviders
            .filter { typed.isEmpty || $0.id.hasPrefix(typed) }
            .map {
                let configured = Credentials.isConfigured($0.id)
                let status = configured ? "configured" : "unconfigured"
                return AutocompleteItem(
                    value: $0.id,
                    label: "/login \($0.id)",
                    description: "\($0.label) (\(status))"
                )
            }
    }
}

struct TUILogoutSlashCommand: SlashCommand {
    let name: String = "logout"
    let description: String? = "Clear an online provider's stored API key (/logout <provider>)"

    func argumentCompletions(prefix: String) -> [AutocompleteItem] {
        let typed = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return TUILoginCommandParser.knownProviders
            .filter { Credentials.isConfigured($0.id) }
            .filter { typed.isEmpty || $0.id.hasPrefix(typed) }
            .map {
                AutocompleteItem(
                    value: $0.id,
                    label: "/logout \($0.id)",
                    description: "Forget \($0.label) API key"
                )
            }
    }
}
