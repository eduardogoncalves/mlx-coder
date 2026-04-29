// Sources/CLI/SwiftCoderTUIAppConfig.swift
// AppConfig builder for the SwiftCoderTUI front-end. Centralises the static
// metadata (name, version, models, modes, slash-commands) the TUI shell
// needs. Adapter wiring lives in `SwiftCoderTUIFrontend`.

import Foundation
import SwiftCoderTUI

public enum SwiftCoderTUIAppConfigBuilder {

    /// Build an AppConfig for mlx-coder. `version` should be the value
    /// from `MLXCoderCLI.configuration.version`.
    public static func build(version: String, defaultModelLabel: String) -> AppConfig {
        AppConfig(
            appName: "mlx-coder",
            version: version,
            welcomeMessage: "type a prompt and press Enter · type ? for keyboard shortcuts",
            models: [
                AppConfig.ModelConfig(id: defaultModelLabel, label: defaultModelLabel)
            ],
            modes: [
                AppConfig.ModeConfig(id: "fast", label: "fast",
                                     barColor: "\u{001B}[34m", badgeColor: "\u{001B}[34m"),
                AppConfig.ModeConfig(id: "low", label: "low",
                                     barColor: "\u{001B}[96m", badgeColor: "\u{001B}[96m"),
                AppConfig.ModeConfig(id: "medium", label: "medium",
                                     barColor: "\u{001B}[33m", badgeColor: "\u{001B}[93m"),
                AppConfig.ModeConfig(id: "high", label: "high",
                                     barColor: "\u{001B}[35m", badgeColor: "\u{001B}[95m"),
            ],
            commands: [
                AppConfig.CommandConfig(name: "/clear",   description: "Clear the conversation"),
                AppConfig.CommandConfig(name: "/help",    description: "Show help and shortcuts"),
                AppConfig.CommandConfig(name: "/model",   description: "Switch the active model"),
                AppConfig.CommandConfig(name: "/mode",    description: "Cycle thinking mode"),
                AppConfig.CommandConfig(name: "/memory",  description: "Memory subsystem (save/list/search/...)"),
                AppConfig.CommandConfig(name: "/retry",   description: "Re-run the last prompt"),
                AppConfig.CommandConfig(name: "/status",  description: "Show session status"),
                AppConfig.CommandConfig(name: "/context", description: "Show context-window usage"),
                AppConfig.CommandConfig(name: "/undo",    description: "Undo the last turn"),
                AppConfig.CommandConfig(name: "/quit",    description: "Quit the application"),
                AppConfig.CommandConfig(name: "!",        description: "Run a shell command (e.g. ! ls -la)"),
                AppConfig.CommandConfig(name: "!!",       description: "Repeat the last shell command"),
            ],
            defaultModelIndex: 0,
            defaultModeIndex: 1
        )
    }
}
