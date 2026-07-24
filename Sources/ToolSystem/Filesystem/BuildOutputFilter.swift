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
        "bin", "obj",
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
        // Test coverage artefacts
        "coverage", ".nyc_output",
        // Ruby – Bundler
        ".bundle",
        // Misc package caches
        ".cache",
        // mlx-coder's own sub-agent run archives/logs — internal bookkeeping,
        // not project content the model should be browsing or grepping.
        ".native-agent",
    ]

    /// Returns `true` when *any* component of `path` matches an ignored name.
    public static func isBuildOutput(path: String) -> Bool {
        let components = (path as NSString).pathComponents
        return components.contains { ignoredNames.contains($0) }
    }

    /// Returns the first matching ignored component in `path`, or `nil` if none.
    public static func matchedComponent(in path: String) -> String? {
        let components = (path as NSString).pathComponents
        return components.first { ignoredNames.contains($0) }
    }
}
