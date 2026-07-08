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
                // `cd -` is the only case where `tokens[1]` exists but does
                // not represent a statically resolvable path (it is the shell
                // special that switches to $OLDPWD). Bare `cd` (no argument)
                // is handled separately below. All other forms — including
                // `cd ~`, `cd ~/path`, absolute paths, and relative paths —
                // are resolved by `resolveTarget`; tilde-expansion is
                // performed inside `resolveTarget` via `expandingTildeInPath`,
                // so home-directory targets (typically outside the workspace)
                // will naturally fail the `pathIsInside` check and set
                // `trackedCWD` to nil without any special-casing here.
                if tokens.count >= 2, tokens[1] != "-" {
                    // Only advance CWD tracking when we know where we are.
                    // If trackedCWD is already nil (prior indeterminate cd),
                    // we cannot meaningfully resolve the new path, so leave it nil.
                    if let base = trackedCWD {
                        let newDir = resolveTarget(tokens[1], basePath: base)
                        // If the `cd` target is outside the workspace we stop
                        // tracking: we will not enforce `ln` semantics for a
                        // CWD we cannot reason about, and the post-execution
                        // sweep provides the second layer of defence.
                        trackedCWD = pathIsInside(newDir, root: normalizedRoot) ? newDir : nil
                    }
                } else {
                    // bare `cd` (returns to $HOME) or `cd -` (returns to
                    // $OLDPWD) — destination is undeterminable at parse time.
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

            let resolvedTarget = resolveTarget(target, basePath: cwd)
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
            // `.skipsHiddenFiles` is intentionally omitted so that hidden
            // dotfile symlinks (e.g. `.secret -> /etc/passwd`) are included in
            // the sweep — closing the gap where a command creates such a link
            // via an interpreter and bypasses the pre-execution `ln` parser.
            // To avoid the cost of descending into hidden VCS/build metadata
            // dirs exposed by this change, we prune them explicitly below.
            guard let enumerator = fm.enumerator(
                at: scanRoot,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
                options: [],
                errorHandler: { _, _ in true }
            ) else {
                continue
            }

            for case let url as URL in enumerator {
                let name = url.lastPathComponent

                // Evaluate symlink status FIRST so that a hidden file that
                // happens to be a symlink is caught before the descent-pruning
                // logic below has a chance to skip it.
                let values = try? url.resourceValues(
                    forKeys: [.isSymbolicLinkKey, .isDirectoryKey]
                )

                if values?.isSymbolicLink == true {
                    // Resolve the symlink one step (so we get the literal target).
                    guard let destination = try? fm.destinationOfSymbolicLink(
                        atPath: url.path
                    ) else { continue }

                    let resolved = resolveTarget(
                        destination,
                        basePath: url.deletingLastPathComponent().path
                    )

                    if !pathIsInside(resolved, root: normalizedRoot) {
                        try? fm.removeItem(at: url)
                    }
                    // Symlinks are leaves from the enumerator's perspective;
                    // no descent decision needed.
                    continue
                }

                // For non-symlink entries, prune descent into well-known large
                // build/dependency directories and VCS/build metadata dirs
                // (the latter are newly exposed because we dropped .skipsHiddenFiles).
                if values?.isDirectory == true,
                   knownSkippedDirectories.contains(name) {
                    enumerator.skipDescendants()
                }
            }
        }
    }

    /// Directories skipped during the post-execution symlink sweep.
    ///
    /// This set merges two concerns:
    /// - **Package-manager trees** (`node_modules`, `Pods`, …): managed by
    ///   external tools; unlikely to hold agent-created symlinks; can be huge.
    /// - **VCS / build metadata dirs** (`.git`, `.build`, `.swiftpm`, …):
    ///   previously hidden from the enumerator by `.skipsHiddenFiles`; now that
    ///   we removed that flag (to catch hidden dotfile symlinks), we prune them
    ///   explicitly to avoid expensive, unnecessary descent.
    private static let knownSkippedDirectories: Set<String> = [
        // Package-manager trees
        "node_modules", "Pods", "DerivedData", "dist", "vendor",
        // VCS / build metadata (dotdirs now visited without .skipsHiddenFiles)
        ".git", ".hg", ".svn", ".build", ".swiftpm",
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

                let resolved = resolveTarget(token, basePath: workspaceRoot)
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

    /// Resolve a shell-supplied target path relative to `basePath` (the
    /// directory the shell command executes from, e.g. the tracked CWD or
    /// the directory containing the symlink). Absolute paths and tilde-paths
    /// are left as-is; relative paths are anchored at `basePath`.
    private static func resolveTarget(
        _ target: String,
        basePath: String
    ) -> String {
        let expanded = NSString(string: target).expandingTildeInPath
        let combined = expanded.hasPrefix("/")
            ? expanded
            : basePath + "/" + expanded
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
