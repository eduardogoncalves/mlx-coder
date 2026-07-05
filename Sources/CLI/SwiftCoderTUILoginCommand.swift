// Sources/CLI/SwiftCoderTUILoginCommand.swift
// /login wizard and /logout command for managing remote providers in config.json.
//
// /login         — start a multi-step wizard: name → base URL → API key (optional)
// /logout        — open a menu of configured providers to remove
// /logout <id>   — remove a specific provider directly

import Foundation
import SwiftCoderTUI

/// Tracks the active step of the /login provider-entry wizard.
/// `.idle` means no wizard is running; any other case means the wizard owns
/// the input focus and free-typing goes to the current step.
enum LoginWizardStep: Equatable {
    case idle
    case awaitingName
    case awaitingURL(name: String)
    case awaitingAPIKey(name: String, url: String, existingKey: String?)
}

struct TUILoginSlashCommand: SlashCommand {
    let name: String = "login"
    let description: String? = "Add or update a remote provider in config.json (launches wizard)"

    func argumentCompletions(prefix: String) -> [AutocompleteItem] { [] }
}

struct TUILogoutSlashCommand: SlashCommand {
    let name: String = "logout"
    let description: String? = "Remove a configured remote provider from config.json"

    func argumentCompletions(prefix: String) -> [AutocompleteItem] {
        let typed = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return RemoteProviderRegistry.providers()
            .filter { typed.isEmpty || $0.id.hasPrefix(typed) || $0.name.lowercased().hasPrefix(typed) }
            .map { p in
                AutocompleteItem(
                    value: p.id,
                    label: "/logout \(p.id)",
                    description: "Remove \(p.name)"
                )
            }
    }
}

// MARK: - Wizard advance

/// Advance the login wizard one step using the submitted `value`.
/// Sets the new status notice and optionally pre-fills the input buffer for the
/// next step. Does NOT call `renderFooter()` — the caller is responsible.
///
/// Returns:
///   - `nextStep`: the wizard's new state
///   - `addedProviderID`: non-nil when the wizard just completed and a provider
///     was saved (used by the caller to trigger a catalog refresh)
@MainActor
func advanceLoginWizard(
    step: LoginWizardStep,
    value: String,
    renderer: Renderer
) async -> (nextStep: LoginWizardStep, addedProviderID: String?) {

    switch step {
    case .idle:
        return (.idle, nil)

    case .awaitingName:
        guard !value.isEmpty else {
            await renderer.printScrollLine("  \(DesignSystem.brightRed)Provider name cannot be empty.\(DesignSystem.reset)")
            await renderer.setStatusNotice("  Provider name: ")
            return (.awaitingName, nil)
        }
        let slug = RemoteProvider.slug(value)
        guard !slug.isEmpty else {
            await renderer.printScrollLine(
                "  \(DesignSystem.brightRed)'\(value)' produces an empty id — use letters, digits, or hyphens.\(DesignSystem.reset)"
            )
            await renderer.setStatusNotice("  Provider name: ")
            return (.awaitingName, nil)
        }
        let existing = RemoteProviderRegistry.provider(id: slug)
        if existing != nil {
            await renderer.printScrollLine("  Updating existing provider '\(value)'.")
        }
        await renderer.printScrollLine("  Name: \(value)")
        let prefillURL = existing?.baseURL ?? ""
        let urlNotice = prefillURL.isEmpty
            ? "  Base URL: "
            : "  Base URL [\(prefillURL)]: "
        await renderer.setStatusNotice(urlNotice)
        if !prefillURL.isEmpty {
            await renderer.setInputBuffer(prefillURL)
        }
        return (.awaitingURL(name: value), nil)

    case .awaitingURL(let name):
        guard !value.isEmpty, URL(string: value) != nil else {
            await renderer.printScrollLine(
                "  \(DesignSystem.brightRed)Enter a valid URL (e.g. https://openrouter.ai/api/v1).\(DesignSystem.reset)"
            )
            let hint = RemoteProviderRegistry.provider(id: RemoteProvider.slug(name))?.baseURL ?? ""
            await renderer.setStatusNotice(hint.isEmpty ? "  Base URL: " : "  Base URL [\(hint)]: ")
            return (.awaitingURL(name: name), nil)
        }
        await renderer.printScrollLine("  URL: \(value)")
        let existingKey = RemoteProviderRegistry.provider(id: RemoteProvider.slug(name))?.apiKey
        let hasKey = !(existingKey ?? "").isEmpty
        let keyNotice = hasKey
            ? "  API key [currently set — leave empty to keep, or type a new key]: "
            : "  API key (leave empty for keyless local servers): "
        await renderer.setStatusNotice(keyNotice)
        return (.awaitingAPIKey(name: name, url: value, existingKey: hasKey ? existingKey : nil), nil)

    case .awaitingAPIKey(let name, let url, let existingKey):
        // Empty submission means "keep the existing key" when one is set.
        let finalKey: String? = value.isEmpty ? existingKey : value
        let provider = RemoteProvider(name: name, baseURL: url, apiKey: finalKey)
        await renderer.setStatusNotice(nil)
        do {
            try RemoteProviderRegistry.addOrUpdate(provider)
            let keyStatus = provider.hasAPIKey ? "API key set" : "no API key (keyless)"
            await renderer.printScrollLine("  \(DesignSystem.brightCyan)✓ Provider '\(name)' saved (\(keyStatus)).\(DesignSystem.reset)")
            await renderer.printScrollLine("  Open /model to browse available models.")
        } catch {
            await renderer.printScrollLine(
                "  \(DesignSystem.brightRed)Error saving provider: \(error.localizedDescription)\(DesignSystem.reset)"
            )
            return (.idle, nil)
        }
        return (.idle, provider.id)
    }
}

// MARK: - /login and /logout entry point

/// Handle `/login` (start wizard) and `/logout` (remove a provider).
///
/// Returns the new `LoginWizardStep` — `.awaitingName` when the wizard was
/// started, `.idle` otherwise.
@MainActor
func handleLoginCommand(input: String, renderer: Renderer) async -> LoginWizardStep {

    if input.hasPrefix("/logout") {
        let arg = String(input.dropFirst("/logout".count)).trimmingCharacters(in: .whitespaces)
        let configured = RemoteProviderRegistry.providers()

        if arg.isEmpty {
            guard !configured.isEmpty else {
                await renderer.printScrollLine("  No providers configured. Use /login to add one.")
                await renderer.renderFooter()
                return .idle
            }
            let items = configured.map { p in
                (name: "/logout \(p.id)", desc: "Remove \(p.name)")
            }
            await renderer.openCommandPalette(commands: items)
            await renderer.renderFooter()
        } else {
            let needle = RemoteProvider.slug(arg)
            guard configured.contains(where: { $0.id == needle }) else {
                let known = configured.isEmpty
                    ? "(none configured)"
                    : configured.map(\.id).joined(separator: ", ")
                await renderer.printScrollLine("  Unknown provider '\(arg)'. Configured: \(known).")
                await renderer.renderFooter()
                return .idle
            }
            do {
                try RemoteProviderRegistry.remove(id: needle)
                await renderer.printScrollLine("  \(DesignSystem.brightCyan)✓ Provider '\(arg)' removed from config.json.\(DesignSystem.reset)")
            } catch {
                await renderer.printScrollLine(
                    "  \(DesignSystem.brightRed)Error removing provider: \(error.localizedDescription)\(DesignSystem.reset)"
                )
            }
            await renderer.renderFooter()
        }
        return .idle
    }

    // /login — start the wizard.
    await renderer.setStatusNotice("  Provider name (press Esc to cancel): ")
    await renderer.setInputBuffer("")
    await renderer.renderFooter()
    return .awaitingName
}
