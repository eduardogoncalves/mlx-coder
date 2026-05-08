// Sources/ToolSystem/Shell/SandboxEngine.swift
// macOS Seatbelt sandboxing for shell commands

import Foundation

/// Utility to wrap shell commands in a macOS Seatbelt sandbox using `sandbox-exec`.
public struct SandboxEngine: Sendable {

    /// Controls whether outbound network connections are permitted inside the sandbox.
    public enum NetworkPolicy: Sendable {
        /// Allow all outbound network connections (default; preserves legacy behaviour).
        case allow
        /// Deny all network connections inside the sandbox.
        case deny
    }

    private let networkPolicy: NetworkPolicy

    public init(networkPolicy: NetworkPolicy = .allow) {
        self.networkPolicy = networkPolicy
    }
    
    /// Wraps a command string with `sandbox-exec` and a dynamically generated permissive profile.
    /// 
    /// - Parameters:
    ///   - command: The shell command to wrap.
    ///   - workspaceRoot: The root directory to allow write access to.
    /// - Returns: A sandboxed command string.
    public func wrap(command: String, workspaceRoot: String) -> String {
        let profile = generateProfile(workspaceRoot: workspaceRoot)
        
        // Escape the profile and command to be safe for inclusion in a shell command
        // Wrap both in single quotes and escape any single quotes inside.
        let escapedProfile = profile.replacingOccurrences(of: "'", with: "'\\''")
        let escapedCommand = command.replacingOccurrences(of: "'", with: "'\\''")
        
        // Return the wrapped command. Use an explicit shell entrypoint so commands with
        // arguments/operators are executed correctly under sandbox-exec.
        return "sandbox-exec -p '\(escapedProfile)' /bin/zsh -c '\(escapedCommand)'"
    }
    
    /// Generates a Seatbelt profile string.
    private func generateProfile(workspaceRoot: String) -> String {
        let canonicalWorkspaceRoot = canonicalWorkspacePath(workspaceRoot)
        let escapedWorkspaceRoot = escapeForProfileString(canonicalWorkspaceRoot)

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Balanced developer baseline:
        // Explicit writable subpaths for common package managers/toolchains,
        // while keeping broad home-directory writes denied.
        let packageCachePaths: [String] = [
            // .NET / NuGet
            "\(home)/.local/share/NuGet",
            "\(home)/.nuget",
            // Node.js ecosystem
            "\(home)/.npm",
            "\(home)/.pnpm-store",
            "\(home)/.yarn",
            // Rust
            "\(home)/.cargo",
            // Java / Kotlin (Maven + Gradle)
            "\(home)/.m2",
            "\(home)/.gradle",
            // Go modules / installed binaries
            "\(home)/go/pkg/mod",
            "\(home)/go/bin",
            // Swift package metadata/cache
            "\(home)/.swiftpm",
            // Python tooling caches
            "\(home)/.cache/pip",
            "\(home)/.cache/uv",
            // General caches (kept for compatibility with existing behavior)
            "\(home)/.cache",
            "\(home)/Library/Caches",
        ]
        let packageCacheRules = packageCachePaths
            .map { "        (allow file-write* (subpath \"\(escapeForProfileString($0))\"))" }
            .joined(separator: "\n")

        let networkRule: String
        switch networkPolicy {
        case .allow:
            networkRule = "        (allow network*)"
        case .deny:
            networkRule = "        ;; Network connections denied by policy\n        (deny network*)"
        }

        let lines: [String] = [
            "        (version 1)",
            "        (allow default)",
            "        ",
            "        ;; Block all writes by default",
            "        (deny file-write*)",
            "        ",
            "        ;; Allow null/tty devices — git and many tools open /dev/null O_RDWR",
            "        (allow file-write* (literal \"/dev/null\"))",
            "        (allow file-read* (literal \"/dev/null\"))",
            "        (allow file-write* (literal \"/dev/tty\"))",
            "        (allow file-read* (literal \"/dev/tty\"))",
            "        ",
            "        ;; Allow writes to system temp and common paths",
            "        (allow file-write* (subpath \"/tmp\"))",
            "        (allow file-write* (subpath \"/private/tmp\"))",
            "        (allow file-write* (subpath \"/var/folders\"))",
            "        (allow file-write* (subpath \"/private/var/folders\"))",
            "        ",
            "        ;; Allow writes within the workspace",
            "        (allow file-write* (subpath \"\(escapedWorkspaceRoot)\"))",
            "        ",
            "        ;; Package manager caches / data dirs (NuGet, npm, cargo, etc.)",
            packageCacheRules,
            "        ",
            "        ;; Allow process execution and networking (permissive-open style)",
            "        (allow process*)",
            networkRule,
        ]
        return lines.joined(separator: "\n")
    }

    private func canonicalWorkspacePath(_ workspaceRoot: String) -> String {
        URL(filePath: workspaceRoot)
            .standardized
            .resolvingSymlinksInPath()
            .path()
    }

    private func escapeForProfileString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
