// Sources/ToolSystem/Filesystem/BuildOutputFilter.swift
// Shared filter for build output / dependency cache directories that the agent
// should not read by default.

import Foundation

/// Identifies paths that are inside well-known build-output or dependency-cache
/// directories (e.g. `bin`, `obj`, `node_modules`).
///
/// Tools use this to avoid polluting the model context with binary artifacts or
/// generated code. Callers can pass `include_build_dirs: true` to bypass the
/// filter when they genuinely need to inspect build artefacts.
public enum BuildOutputFilter {

    /// Directory names that are recognised as build-output or cache directories.
    /// Only the *name* of a path component is matched — not the full path —
    /// so `src/bin` and `./bin` are both filtered.
    public static let ignoredNames: Set<String> = [
        // .NET
        "bin", "obj", ".dotnet", ".nuget",
        // Per-user tool/data caches (dotnet, NuGet migrations, etc.)
        ".local",
        // Node.js / JavaScript / TypeScript
        "node_modules", ".npm",
        // Python
        "__pycache__", ".venv", "venv", "env", ".eggs",
        // Java / Kotlin – Maven + Gradle
        "target", ".gradle",
        // Swift Package Manager
        ".build", ".swiftpm",
        // Xcode
        "DerivedData", "xcuserdata",
        // iOS / macOS – CocoaPods
        "Pods",
        // Frontend frameworks
        ".next", ".nuxt", ".output",
        // Generic web bundler output (webpack/vite/rollup/esbuild/tsc, etc.)
        "dist", "build",
        // Test coverage / e2e report artefacts
        "coverage", ".nyc_output", "playwright-report", "test-results",
        // Ruby – Bundler
        ".bundle",
        // Misc package caches
        ".cache",
        // Version control internals — never project content, and .git in
        // particular is large/binary and pollutes recursive listings.
        ".git", ".hg", ".svn",
        // OS bookkeeping
        ".DS_Store",
        // mlx-coder's own sub-agent run archives/logs — internal bookkeeping,
        // not project content the model should be browsing or grepping.
        ".native-agent",
    ]

    /// mlx-coder's own workspace bookkeeping written alongside the project: the
    /// sub-agent log dir (`.native-agent`), the todo lists (`.mlx-coder-todo`,
    /// `.mlx-coder-todo-<session>`, legacy `.native-agent-todo.md`), the
    /// workspace config (`.mlx-coder-config.json`, legacy `.native-agent-config.json`),
    /// the tool policy document (`.mlx-coder-policy.json`), the search-ignore
    /// patterns file (`.mlx-coder-ignore`), and the project env file
    /// (`.mlx-coder.env`, which may hold secrets). This is harness state, not
    /// project content — hidden from listings/search/reads by default and
    /// revealed with `include_build_dirs: true`, exactly like build output.
    /// Names not covered by the dir-name-only `ignoredNames` above are matched
    /// here so `list_dir`/`read_file`/`read_many`/`grep`/`code_search`/`glob`
    /// all skip them, files included.
    public static let harnessArtifactNames: Set<String> = [
        ".native-agent",
        ".native-agent-todo.md",
        ".native-agent-config.json",
        ".mlx-coder-todo",
        ".mlx-coder.env",
        ".mlx-coder-config.json",
        ".mlx-coder-policy.json",
        ".mlx-coder-ignore",
    ]

    /// Prefix-matched harness artifacts (session-namespaced todo files such as
    /// `.mlx-coder-todo-abc123`), which have no fixed full name to list above.
    public static let harnessArtifactPrefixes: [String] = [".mlx-coder-todo-"]

    /// True when `name` is one of mlx-coder's own workspace artifacts.
    public static func isHarnessArtifact(name: String) -> Bool {
        harnessArtifactNames.contains(name)
            || harnessArtifactPrefixes.contains { name.hasPrefix($0) }
    }

    /// Returns `true` when *any* component of `path` matches an ignored name.
    public static func isBuildOutput(path: String) -> Bool {
        matchedComponent(in: path) != nil
    }

    /// Returns the first ignored/harness-internal component in `path`, or `nil`.
    public static func matchedComponent(in path: String) -> String? {
        let components = (path as NSString).pathComponents
        return components.first { ignoredNames.contains($0) || isHarnessArtifact(name: $0) }
    }
}
