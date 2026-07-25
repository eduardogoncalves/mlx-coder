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

    /// Returns `true` when `workspaceRoot` is safe to embed in a Seatbelt profile
    /// string. Profiles are S-expressions; embedded `(`, `)`, `"`, `\`, `;` or
    /// newline characters in the workspace path can break out of the
    /// `(subpath "...")` literal and either neutralise the sandbox or inject
    /// new rules. Callers that receive `false` should reject the request
    /// rather than weakening the sandbox.
    ///
    /// The forbidden set also includes shell metacharacters (`'`, `` ` ``,
    /// `$`). `wrap(command:workspaceRoot:)` does single-quote-escape its
    /// inputs, but two consecutive injection points (the inner profile and
    /// the outer `/bin/zsh -c '…'`) plus the historical pattern of callers
    /// re-interpolating workspace paths into shell strings (see
    /// `BashTool.executeBackground`) means we apply defence in depth here.
    public static func isWorkspaceRootSandboxSafe(_ workspaceRoot: String) -> Bool {
        return !workspaceRoot.contains(where: { unsafeWorkspaceRootCharacters.contains($0) })
    }

    /// Shared forbidden-character set used by `isWorkspaceRootSandboxSafe`
    /// to validate workspace paths before they are embedded in a Seatbelt
    /// profile.
    ///
    /// Note: `BashTool.executeBackground` uses a deliberately *narrower*
    /// validator (`'`, newline, CR, NUL) because it only interpolates the
    /// path inside a single-quoted shell redirect, not inside an
    /// S-expression. The two validators are intentionally not unified so
    /// each context can stay as permissive as its quoting allows while
    /// blocking the characters that can actually break out.
    public static let unsafeWorkspaceRootCharacters: Set<Character> = [
        "\"", "\\", "(", ")", "\n", "\r", ";", "'", "`", "$"
    ]
    
    /// Generates a Seatbelt profile string.
    private func generateProfile(workspaceRoot: String) -> String {
        let canonicalWorkspaceRoot = canonicalWorkspacePath(workspaceRoot)
        let escapedWorkspaceRoot = escapeForProfileString(canonicalWorkspaceRoot)

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let escapedHome = escapeForProfileString(home)
        // Balanced developer baseline:
        // Explicit writable subpaths for common package managers/toolchains,
        // while keeping broad home-directory writes denied.
        let packageCachePaths: [String] = [
            // .NET / NuGet
            "\(home)/.local/share/NuGet",
            "\(home)/.nuget",
            "\(home)/.dotnet",
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

        // Read-allow exceptions inside the user's home directory. These are
        // re-permitted after the broad home-read deny below so common dev tools
        // (git, package managers, swiftpm) keep functioning while user data
        // (notes, documents, ssh keys, credentials) stays unreadable.
        let readableHomePaths: [String] = packageCachePaths + [
            // Git configuration
            "\(home)/.gitconfig",
            "\(home)/.gitignore_global",
            "\(home)/.config/git",
            // Shell / tool configuration commonly inspected by build scripts
            "\(home)/.zshenv",
            "\(home)/.profile",
            // Read-only metadata for already-writable caches isn't needed —
            // file-write* implies neither read nor list, so we explicitly
            // re-allow reads on the same subpaths via packageCachePaths above.
        ]
        let readableHomeRules = readableHomePaths
            .map { path -> String in
                let escaped = escapeForProfileString(path)
                // Use literal for files, subpath for directories. Seatbelt
                // accepts subpath for both (file paths just match themselves)
                // so subpath is safe and uniform.
                return "        (allow file-read* (subpath \"\(escaped)\"))"
            }
            .joined(separator: "\n")

        // Metadata-only reads on the workspace's ancestor directories. Tools
        // that resolve modules or find a project root walk up the directory
        // tree, `lstat`-ing each parent (npm's arborist is the canonical case:
        // it fails with `EPERM: lstat '/Users'` when a parent can't be
        // stat'd). The broad home/`/Users` denies above block that metadata
        // read. Re-allow `file-read-metadata` — but only via `(literal ...)`
        // on the exact ancestor paths, never `(subpath ...)`. `literal` matches
        // that directory alone, so a walk-up can `stat` it without gaining the
        // ability to read file contents or list siblings' data (that still
        // needs `file-read-data`, which stays denied).
        let ancestorMetadataRules = ancestorDirectories(of: canonicalWorkspaceRoot)
            .map { "        (allow file-read-metadata (literal \"\(escapeForProfileString($0))\"))" }
            .joined(separator: "\n")

        // Node config store used by the `env-paths`/`Conf` libraries: on macOS
        // the config dir resolves to ~/Library/Preferences/<name>-nodejs, and
        // env-paths honours no override env var there, so the BashTool
        // NPM_CONFIG_* redirects can't retarget it — the access has to be
        // granted in the profile. Rather than open the whole ~/Library/Preferences
        // tree (which would expose every app's preference plist to read and
        // tamper), scope it to the `-nodejs` suffix that env-paths always
        // appends. A `subpath` can't suffix-match, so use a `regex` anchored at
        // the Preferences dir and requiring the `-nodejs`-suffixed directory
        // name; real macOS prefs (com.apple.*, com.google.*, …) never match.
        // Both write and read are granted: Conf reads its existing config
        // before writing, and a denied (vs. missing) read throws.
        let prefsDir = escapeForProfileRegex("\(home)/Library/Preferences")
        let nodeConfigPattern = escapeForProfileString("^\(prefsDir)/[^/]+-nodejs(/|$)")
        let nodeConfigRules = [
            "        (allow file-write* (regex \"\(nodeConfigPattern)\"))",
            "        (allow file-read* (regex \"\(nodeConfigPattern)\"))",
        ].joined(separator: "\n")

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
            "        ;; Block reads of user data outside the workspace. This",
            "        ;; prevents commands like `cat ~/secret.md` or",
            "        ;; `cat /Users/other/...` from exfiltrating files outside",
            "        ;; the sandboxed workspace. System paths (/etc, /usr,",
            "        ;; /System, /Library, /tmp) remain readable so tools and",
            "        ;; libraries continue to function.",
            "        (deny file-read* (subpath \"\(escapedHome)\"))",
            "        (deny file-read* (subpath \"/Users\"))",
            "        ",
            "        ;; Layered secret-store denies. The home/Users denies above cover",
            "        ;; user data, but leave system credential/secret stores outside",
            "        ;; home readable under `(allow default)`. These paths hold password",
            "        ;; hashes and machine secrets that legitimate tools never read, so",
            "        ;; deny them explicitly on top of the home/Users denies. /etc, /usr,",
            "        ;; /System, /Library, /opt and temp dirs stay readable for tooling.",
            "        (deny file-read* (literal \"/etc/master.passwd\"))",
            "        (deny file-read* (literal \"/private/etc/master.passwd\"))",
            "        (deny file-read* (subpath \"/var/db/shadow\"))",
            "        (deny file-read* (subpath \"/private/var/db/shadow\"))",
            "        (deny file-read* (subpath \"/var/db\"))",
            "        (deny file-read* (subpath \"/private/var/db\"))",
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
            "        ;; Allow reads + writes within the workspace",
            "        (allow file-read* (subpath \"\(escapedWorkspaceRoot)\"))",
            "        (allow file-write* (subpath \"\(escapedWorkspaceRoot)\"))",
            "        ",
            "        ;; Package manager caches / data dirs (NuGet, npm, cargo, etc.)",
            packageCacheRules,
            "        ",
            "        ;; Re-allow reads for tool config and package caches inside HOME",
            "        ;; (overrides the broad home-read deny above).",
            readableHomeRules,
            "        ",
            "        ;; Node env-paths/Conf config dirs (~/Library/Preferences/*-nodejs)",
            "        ;; only — scoped by suffix so the rest of Preferences stays denied.",
            nodeConfigRules,
            "        ",
            "        ;; Metadata-only reads on the workspace's ancestor dirs so",
            "        ;; tools that walk up the tree (npm/node, git) can stat them.",
            ancestorMetadataRules,
            "        ",
            "        ;; Allow process execution and networking (permissive-open style)",
            "        (allow process*)",
            networkRule,
        ]
        return lines.joined(separator: "\n")
    }

    /// Returns every ancestor directory of `path`, from the top-level entry
    /// (`/Users`) down to the immediate parent, excluding `/` itself (always
    /// readable) and `path`. Used to grant metadata-only reads so directory
    /// tree walk-ups can `stat` each parent.
    func ancestorDirectories(of path: String) -> [String] {
        let components = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard components.count > 1 else { return [] }

        var ancestors: [String] = []
        var current = ""
        // Drop the last component (that's `path` itself, already fully allowed).
        for component in components.dropLast() {
            current += "/" + component
            ancestors.append(current)
        }
        return ancestors
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

    /// Escapes regex metacharacters in a literal path so it can be embedded in
    /// a Seatbelt `(regex "...")` pattern without the path's own characters
    /// (e.g. a `.` or `+` in a username) being interpreted as regex operators.
    /// The result is still passed through `escapeForProfileString` afterwards,
    /// which doubles any backslashes this adds for the S-expression string
    /// literal layer.
    private func escapeForProfileRegex(_ value: String) -> String {
        let specials: Set<Character> = [
            "\\", ".", "^", "$", "|", "?", "*", "+", "(", ")", "[", "]", "{", "}",
        ]
        var result = ""
        result.reserveCapacity(value.count)
        for character in value {
            if specials.contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
}
