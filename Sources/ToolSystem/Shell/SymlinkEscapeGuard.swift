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

        // Track the effective CWD across chained segments so that a command
        // like `cd subdir && ln -s ../etc link` correctly evaluates `../etc`
        // relative to `workspaceRoot/subdir` rather than `workspaceRoot`.
        // `nil` means we saw a `cd` whose destination we couldn't statically
        // determine (e.g. bare `cd`, `cd -`, or a path outside the workspace);
        // in that case we skip the `ln` check and rely on the post-exec sweep.
        var trackedCWD: String? = normalizedRoot

        for segment in segments {
            let tokens = tokenize(segment)
            guard let first = tokens.first else { continue }

            if first == "cd" {
                if tokens.count >= 2, tokens[1] != "-" {
                    // Only advance CWD tracking when we know where we are.
                    // If trackedCWD is already nil (prior indeterminate cd),
                    // we cannot meaningfully resolve the new path, so leave it nil.
                    if let base = trackedCWD {
                        let newDir = resolveTarget(tokens[1], workspaceRoot: base)
                        trackedCWD = pathIsInside(newDir, root: normalizedRoot) ? newDir : nil
                    }
                } else {
                    // bare `cd` or `cd -` — can't determine destination statically
                    trackedCWD = nil
                }
                continue
            }

            guard first == "ln", let cwd = trackedCWD else { continue }

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

            let resolvedTarget = resolveTarget(target, workspaceRoot: cwd)
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
    ///
    /// When `command` is provided the sweep is limited to workspace directories
    /// explicitly mentioned in that command, avoiding a full recursive walk on
    /// every shell call. If no in-workspace directories can be extracted from
    /// the command, the entire workspace is enumerated but known large
    /// build/dependency trees (e.g. `node_modules`, `Pods`) are skipped.
    public static func removeEscapingSymlinks(
        in workspaceRoot: String,
        command: String? = nil
    ) {
        let fm = FileManager.default
        let normalizedRoot = canonicalize(workspaceRoot)

        // Determine which directories to scan. Narrowing the sweep to paths the
        // command explicitly touched prevents walking large trees like
        // `node_modules` or `Pods` on every shell invocation.
        let scanRoots: [URL]
        if let command,
           let touched = directoriesFromCommand(command, workspaceRoot: normalizedRoot),
           !touched.isEmpty {
            scanRoots = touched.map { URL(filePath: $0) }
        } else {
            scanRoots = [URL(filePath: normalizedRoot)]
        }

        for scanRoot in scanRoots {
            guard let enumerator = fm.enumerator(
                at: scanRoot,
                includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) else {
                continue
            }

            for case let url as URL in enumerator {
                // Skip well-known large build/dependency directories to avoid
                // per-command overhead on big workspaces. Symlinks inside these
                // trees are managed by the package manager, not the agent.
                if knownHeavyDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }

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
    }

    /// Well-known directories that are managed by external package managers and
    /// are unlikely to contain agent-created symlinks. Skipping them avoids
    /// significant per-command overhead on large workspaces.
    private static let knownHeavyDirectories: Set<String> = [
        "node_modules", "Pods", "DerivedData", "dist", "vendor"
    ]

    /// Extract unique workspace-relative directory paths explicitly referenced
    /// in `command`. Returns `nil` when no in-workspace paths can be
    /// identified, signalling the caller to fall back to a full workspace scan.
    private static func directoriesFromCommand(
        _ command: String,
        workspaceRoot: String
    ) -> [String]? {
        let fm = FileManager.default
        var seen: Set<String> = []
        var dirs: [String] = []

        for segment in splitIntoSegments(command) {
            for token in tokenize(segment) {
                // Skip option flags and bare words without path separators or
                // tilde expansion — they are unlikely to be file-system paths.
                guard !token.hasPrefix("-"),
                      token.contains("/") || token.hasPrefix("~")
                else { continue }

                let resolved = resolveTarget(token, workspaceRoot: workspaceRoot)
                guard pathIsInside(resolved, root: workspaceRoot) else { continue }

                var isDir: ObjCBool = false
                let exists = fm.fileExists(atPath: resolved, isDirectory: &isDir)
                let dir = (exists && isDir.boolValue)
                    ? resolved
                    : (resolved as NSString).deletingLastPathComponent
                guard dir.hasPrefix(workspaceRoot), seen.insert(dir).inserted else { continue }
                dirs.append(dir)
            }
        }

        return dirs.isEmpty ? nil : dirs
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
