// Sources/ToolSystem/Shell/WorkspaceEnvironment.swift
// Project-level environment variables loaded from <workspace>/.mlx-coder.env

import Foundation

/// Loads project-scoped environment variables from a dotenv-style file at the
/// workspace root (`.mlx-coder.env`). These are merged into every `bash` tool
/// subprocess and exported to the agent process at startup, so commands that
/// need project-specific configuration (e.g. `DOTNET_CLI_HOME` for sandboxed
/// `dotnet` invocations) pick them up automatically.
public enum WorkspaceEnvironment {

    public static let fileName = ".mlx-coder.env"

    /// Variables that a workspace file is never allowed to set. A cloned
    /// repository must not be able to inject loader/shell-behavior variables
    /// into every command the agent runs.
    static let blockedExactKeys: Set<String> = [
        "IFS", "PS4", "ENV", "BASH_ENV", "ZDOTDIR", "SHELLOPTS", "PROMPT_COMMAND",
    ]
    static let blockedKeyPrefixes: [String] = ["DYLD_", "LD_"]

    /// Load and sanitize the workspace env file. Returns an empty dictionary
    /// when the file does not exist or cannot be read.
    public static func load(workspaceRoot: String) -> [String: String] {
        let path = workspaceRoot + "/" + fileName
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return [:]
        }
        return sanitized(parse(contents))
    }

    /// Parse dotenv-style content: `KEY=VALUE` lines, `#` comments, optional
    /// `export ` prefix, and optional single/double quotes around the value.
    /// No interpolation is performed.
    static func parse(_ contents: String) -> [String: String] {
        var result: [String: String] = [:]

        for rawLine in contents.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            if line.hasPrefix("export ") {
                line = String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
            }

            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            guard isValidKey(key) else { continue }

            var value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, let last = value.last,
               first == last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }

            result[key] = value
        }

        return result
    }

    /// Drop variables that could alter loader or shell behavior.
    static func sanitized(_ env: [String: String]) -> [String: String] {
        env.filter { key, _ in
            guard !blockedExactKeys.contains(key) else { return false }
            return !blockedKeyPrefixes.contains(where: { key.hasPrefix($0) })
        }
    }

    /// Merge workspace variables into a base process environment. PATH is
    /// never replaced: workspace PATH entries are appended after the secure
    /// base PATH so system binaries always resolve first.
    public static func merge(into base: [String: String], workspace: [String: String]) -> [String: String] {
        var env = base
        for (key, value) in workspace {
            if key == "PATH" {
                if let basePath = env["PATH"], !basePath.isEmpty {
                    env["PATH"] = value.isEmpty ? basePath : basePath + ":" + value
                } else {
                    env["PATH"] = value
                }
            } else {
                env[key] = value
            }
        }
        return env
    }

    /// Export the workspace variables into the agent process itself so child
    /// processes spawned by other tools (LSP servers, git helpers, …) inherit
    /// them. PATH is intentionally skipped — the agent's own PATH is never
    /// modified by workspace config.
    @discardableResult
    public static func applyToCurrentProcess(workspaceRoot: String) -> [String: String] {
        let env = load(workspaceRoot: workspaceRoot)
        for (key, value) in env where key != "PATH" {
            setenv(key, value, 1)
        }
        return env
    }

    private static func isValidKey(_ key: String) -> Bool {
        guard let first = key.first, first.isLetter || first == "_" else { return false }
        return key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
