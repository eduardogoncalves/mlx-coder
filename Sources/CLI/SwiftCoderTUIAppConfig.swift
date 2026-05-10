// Sources/CLI/SwiftCoderTUIAppConfig.swift
// AppConfig builder for the SwiftCoderTUI front-end. Centralises the static
// metadata (name, version, models, modes, slash-commands) the TUI shell
// needs. Adapter wiring lives in `SwiftCoderTUIFrontend`.

import Foundation
import SwiftCoderTUI

public enum SwiftCoderTUIAppConfigBuilder {

    private static func tbDebugEnabledFromEnvironment() -> Bool {
        guard let raw = ProcessInfo.processInfo.environment["MLX_CODER_TUI_TB_DEBUG"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else {
            return false
        }
        return ["1", "true", "yes", "on"].contains(raw)
    }

    /// Build an AppConfig for mlx-coder. `version` should be the value
    /// from `MLXCoderCLI.configuration.version`.
    public static func build(
        version: String,
        models: [AppConfig.ModelConfig],
        defaultModelIndex: Int
    ) -> AppConfig {
        AppConfig(
            appName: "mlx-coder",
            version: version,
            welcomeMessage: "type a prompt and press Enter · type ? for keyboard shortcuts",
            models: models.isEmpty
                ? [AppConfig.ModelConfig(id: "unknown", label: "unknown")]
                : models,
            modes: [
                // coding (purple)
                AppConfig.ModeConfig(id: "coding-off", label: "off",
                                     barColor: "\u{001B}[35m", badgeColor: "\u{001B}[32m"),
                AppConfig.ModeConfig(id: "coding-minimal", label: "minimal",
                                     barColor: "\u{001B}[35m", badgeColor: "\u{001B}[96m"),
                AppConfig.ModeConfig(id: "coding-low", label: "low",
                                     barColor: "\u{001B}[35m", badgeColor: "\u{001B}[96m"),
                AppConfig.ModeConfig(id: "coding-medium", label: "medium",
                                     barColor: "\u{001B}[35m", badgeColor: "\u{001B}[93m"),
                AppConfig.ModeConfig(id: "coding-high", label: "high",
                                     barColor: "\u{001B}[35m", badgeColor: "\u{001B}[95m"),
                // plan (cyan)
                AppConfig.ModeConfig(id: "plan-off", label: "off",
                                     barColor: "\u{001B}[96m", badgeColor: "\u{001B}[32m"),
                AppConfig.ModeConfig(id: "plan-minimal", label: "minimal",
                                     barColor: "\u{001B}[96m", badgeColor: "\u{001B}[96m"),
                AppConfig.ModeConfig(id: "plan-low", label: "low",
                                     barColor: "\u{001B}[96m", badgeColor: "\u{001B}[96m"),
                AppConfig.ModeConfig(id: "plan-medium", label: "medium",
                                     barColor: "\u{001B}[96m", badgeColor: "\u{001B}[93m"),
                AppConfig.ModeConfig(id: "plan-high", label: "high",
                                     barColor: "\u{001B}[96m", badgeColor: "\u{001B}[95m"),
                // autopilot (green)
                AppConfig.ModeConfig(id: "autopilot-off", label: "off",
                                     barColor: "\u{001B}[32m", badgeColor: "\u{001B}[32m"),
                AppConfig.ModeConfig(id: "autopilot-minimal", label: "minimal",
                                     barColor: "\u{001B}[32m", badgeColor: "\u{001B}[96m"),
                AppConfig.ModeConfig(id: "autopilot-low", label: "low",
                                     barColor: "\u{001B}[32m", badgeColor: "\u{001B}[96m"),
                AppConfig.ModeConfig(id: "autopilot-medium", label: "medium",
                                     barColor: "\u{001B}[32m", badgeColor: "\u{001B}[93m"),
                AppConfig.ModeConfig(id: "autopilot-high", label: "high",
                                     barColor: "\u{001B}[32m", badgeColor: "\u{001B}[95m"),
            ],
            commands: [
                AppConfig.CommandConfig(name: "/caffeinate", description: "Prevent system sleep (on/off/busy/<duration>)"),
                AppConfig.CommandConfig(name: "/clear",   description: "Clear the conversation"),
                AppConfig.CommandConfig(name: "/context", description: "Show context-window usage"),
                AppConfig.CommandConfig(name: "/skills",  description: "List available skills"),
                AppConfig.CommandConfig(name: "/hooks",   description: "Manage hooks"),
                AppConfig.CommandConfig(name: "/transforms", description: "Manage prompt transforms"),
                AppConfig.CommandConfig(name: "/save-history", description: "Save chat history"),
                AppConfig.CommandConfig(name: "/save-history-json", description: "Save chat history as JSON"),
                AppConfig.CommandConfig(name: "/load-history-json", description: "Load chat history from JSON"),
                AppConfig.CommandConfig(name: "/undo",    description: "Undo the last turn"),
                AppConfig.CommandConfig(name: "/revert",  description: "Revert to a previous turn"),
                AppConfig.CommandConfig(name: "/plan",    description: "Toggle planning mode"),
                AppConfig.CommandConfig(name: "/autopilot", description: "Toggle autopilot mode"),
                AppConfig.CommandConfig(name: "/agent",   description: "Run in agent mode"),
                AppConfig.CommandConfig(name: "/steer",   description: "Set steering instructions"),
                AppConfig.CommandConfig(name: "/followup", description: "Set follow-up prompts"),
                AppConfig.CommandConfig(name: "/merge-approval", description: "Configure merge approvals"),
                AppConfig.CommandConfig(name: "/gittree", description: "Inspect git tree/worktree"),
                AppConfig.CommandConfig(name: "/memory",  description: "Memory subsystem (save/list/search/...)"),
                AppConfig.CommandConfig(name: "/help",    description: "Show help and shortcuts"),
                AppConfig.CommandConfig(name: "/model",   description: "Switch the active model"),
                AppConfig.CommandConfig(name: "/effort",  description: "Set reasoning effort (off/minimal/low/medium/high)"),
                AppConfig.CommandConfig(name: "/retry",   description: "Re-run the last prompt"),
                AppConfig.CommandConfig(name: "/status",  description: "Show session status"),
                AppConfig.CommandConfig(name: "/quit",    description: "Quit the application"),
            ],
            defaultModelIndex: defaultModelIndex,
            defaultModeIndex: 2,
            topBarDebugEnabled: tbDebugEnabledFromEnvironment()
        )
    }
}
