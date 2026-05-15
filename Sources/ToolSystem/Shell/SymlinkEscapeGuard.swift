// Sources/ToolSystem/Shell/SymlinkEscapeGuard.swift
// Sandbox hardening: prevent shell commands from creating symlinks
// inside the workspace that point to files outside of it.

import Foundation

/// Static helpers used by `BashTool` to block the symlink-then-read sandbox
/// escape pattern (e.g. `ln -s ../secrets.txt link && cat link`).
public enum SymlinkEscapeGuard {

    // MARK: - Pre-execution check

    /// Inspect a shell command and, if it contains an `ln`/`ln -s` invocation,
    /// verify that the target path resolves inside `workspaceRoot`. Returns a
    /// human-readable error string when an escape attempt is detected, or `nil`
    /// when the command is allowed.
    ///
    /// Notes:
    /// - We only care about *symlinks* here. Hard links (without `-s`) cannot
    ///   span filesystems and the resulting path stays inside the workspace,
    ///   so file-read tools that resolve symlinks still validate correctly.
    /// - Multiple `ln` invocations chained with `;`, `&&`, `||`, `|`, or
    ///   newlines are each inspected in isolation.
    public static func checkLnCommand(
        _ command: String,
        workspaceRoot: String
    ) -> String? {
        let segments = splitIntoSegments(command)
        let normalizedRoot = canonicalize(workspaceRoot)

        for segment in segments {
            let tokens = tokenize(segment)
            guard tokens.first == "ln" else { continue }

            // Parse `ln` flags + positional arguments. We only block when the
            // user explicitly requested a symlink with -s/--symbolic.
            var symbolic = false
            var positional: [String] = []
            var index = 1
            while index < tokens.count {
                let token = tokens[index]
                if token == "--" {
                    positional.append(contentsOf: tokens[(index + 1)...])
                    break
                }
                if token == "--symbolic" {
                    symbolic = true
                } else if token.hasPrefix("--") {
                    // Long option we don't care about (e.g. --force, --backup).
                } else if token.hasPrefix("-") && token.count > 1 {
                    // Short option cluster like -sfn. Detect the 's' flag.
                    if token.dropFirst().contains("s") {
                        symbolic = true
                    }
                } else {
                    positional.append(token)
                }
                index += 1
            }

            guard symbolic else { continue }
            guard let target = positional.first else { continue }

            let resolvedTarget = resolveTarget(target, workspaceRoot: normalizedRoot)
            if !pathIsInside(resolvedTarget, root: normalizedRoot) {
                return """
                    Refused to create symlink: target '\(target)' resolves to \
                    '\(resolvedTarget)', which is outside the workspace root \
                    '\(normalizedRoot)'. Symlinks pointing outside the workspace \
                    are blocked to prevent sandbox escape.
                    """
            }
        }

        return nil
    }

    // MARK: - Post-execution sweep

    /// Walk the workspace and remove any symlinks whose resolved target is
    /// outside `workspaceRoot`. This is best-effort defense in depth for cases
    /// where the symlink was created by a tool we can't statically inspect.
    public static func removeEscapingSymlinks(in workspaceRoot: String) {
        let fm = FileManager.default
        let normalizedRoot = canonicalize(workspaceRoot)

        guard let enumerator = fm.enumerator(
            at: URL(filePath: normalizedRoot),
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            return
        }

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values?.isSymbolicLink == true else { continue }

            // Resolve the symlink one step (so we get the literal target).
            guard let destination = try? fm.destinationOfSymbolicLink(
                atPath: url.path
            ) else { continue }

            let resolved = resolveTarget(
                destination,
                workspaceRoot: url.deletingLastPathComponent().path
            )

            if !pathIsInside(resolved, root: normalizedRoot) {
                try? fm.removeItem(at: url)
            }
        }
    }

    // MARK: - Helpers

    /// Split a shell command on top-level operators that introduce a new
    /// command (`;`, `&&`, `||`, `|`, newline). We don't try to be a full
    /// shell parser; quoting/escaping is handled best-effort.
    private static func splitIntoSegments(_ command: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var escapeNext = false

        let chars = Array(command)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if escapeNext {
                current.append(c)
                escapeNext = false
                i += 1
                continue
            }
            if c == "\\" && !inSingle {
                current.append(c)
                escapeNext = true
                i += 1
                continue
            }
            if c == "'" && !inDouble {
                inSingle.toggle()
                current.append(c)
                i += 1
                continue
            }
            if c == "\"" && !inSingle {
                inDouble.toggle()
                current.append(c)
                i += 1
                continue
            }
            if !inSingle && !inDouble {
                if c == ";" || c == "\n" || c == "|" {
                    // Handle && and ||
                    if (c == "|") && i + 1 < chars.count && chars[i + 1] == "|" {
                        segments.append(current)
                        current = ""
                        i += 2
                        continue
                    }
                    segments.append(current)
                    current = ""
                    i += 1
                    continue
                }
                if c == "&" && i + 1 < chars.count && chars[i + 1] == "&" {
                    segments.append(current)
                    current = ""
                    i += 2
                    continue
                }
            }
            current.append(c)
            i += 1
        }
        if !current.isEmpty {
            segments.append(current)
        }
        return segments
    }

    /// Tokenize a shell segment into argv-like tokens. Handles single/double
    /// quotes and backslash escapes; sufficient for the `ln` invocations we
    /// need to inspect.
    private static func tokenize(_ segment: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var escapeNext = false
        var hasContent = false

        for c in segment {
            if escapeNext {
                current.append(c)
                hasContent = true
                escapeNext = false
                continue
            }
            if c == "\\" && !inSingle {
                escapeNext = true
                continue
            }
            if c == "'" && !inDouble {
                inSingle.toggle()
                hasContent = true
                continue
            }
            if c == "\"" && !inSingle {
                inDouble.toggle()
                hasContent = true
                continue
            }
            if c.isWhitespace && !inSingle && !inDouble {
                if hasContent {
                    tokens.append(current)
                    current = ""
                    hasContent = false
                }
                continue
            }
            current.append(c)
            hasContent = true
        }
        if hasContent {
            tokens.append(current)
        }
        return tokens
    }

    /// Resolve a shell-supplied target path. Symlink target paths are
    /// interpreted relative to the directory containing the link, which for
    /// the pre-execution check we approximate using the workspace root (the
    /// command's CWD).
    private static func resolveTarget(
        _ target: String,
        workspaceRoot: String
    ) -> String {
        let expanded = NSString(string: target).expandingTildeInPath
        let combined = expanded.hasPrefix("/")
            ? expanded
            : workspaceRoot + "/" + expanded
        return URL(filePath: combined).standardized.path()
    }

    private static func canonicalize(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        return URL(filePath: expanded)
            .standardized
            .resolvingSymlinksInPath()
            .path()
    }

    private static func pathIsInside(_ path: String, root: String) -> Bool {
        let resolvedPath = URL(filePath: path)
            .standardized
            .resolvingSymlinksInPath()
            .path()
        let resolvedRoot = root
        if resolvedPath == resolvedRoot { return true }
        return resolvedPath.hasPrefix(resolvedRoot + "/")
    }
}
