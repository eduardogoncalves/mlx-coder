// Sources/ToolSystem/Permissions/PermissionEngine.swift
// Path validation and permission rules for tool operations

import Foundation
#if os(macOS)
import Darwin
#else
import Glibc
#endif

/// Validates filesystem paths and shell commands against security rules.
/// All resolved paths must start with `workspaceRoot`. Reject otherwise.
public struct PermissionEngine: Sendable {

    /// Static policy document used for tool/path allow/deny rules.
    public struct PolicyDocument: Sendable, Codable {
        public let rules: [PolicyRule]

        public init(rules: [PolicyRule]) {
            self.rules = rules
        }
    }

    /// Single allow/deny rule.
    public struct PolicyRule: Sendable, Codable {
        public enum Effect: String, Sendable, Codable {
            case allow
            case deny
        }

        public let effect: Effect
        public let tools: [String]
        public let paths: [String]?
        public let reason: String?

        public init(effect: Effect, tools: [String], paths: [String]? = nil, reason: String? = nil) {
            self.effect = effect
            self.tools = tools
            self.paths = paths
            self.reason = reason
        }
    }

    public enum PolicyDecision: Sendable, Equatable {
        case allowed
        case denied(reason: String)
    }

    /// Approval strategy for destructive tools.
    public enum ApprovalMode: String, Sendable, CaseIterable {
        case `default` = "default"
        case autoEdit = "auto-edit"
        case yolo = "yolo"
    }

    /// The root directory for all filesystem operations.
    public let workspaceRoot: String

    /// Glob patterns for allowed shell commands.
    public let allowedCommands: [String]

    /// Glob patterns for denied shell commands.
    public let deniedCommands: [String]

    /// Approval behavior for destructive tool execution.
    public let approvalMode: ApprovalMode

    /// Optional per-tool/per-path policy document.
    public let policy: PolicyDocument?

    /// Workspace-relative path ignore patterns.
    public let ignoredPathPatterns: [String]

    public init(
        workspaceRoot: String,
        allowedCommands: [String] = ["*"],
        deniedCommands: [String] = ["rm -rf /", "sudo *", "shutdown *", "reboot *"],
        approvalMode: ApprovalMode = .default,
        policy: PolicyDocument? = nil,
        ignoredPathPatterns: [String] = []
    ) {
        let expanded = NSString(string: workspaceRoot).expandingTildeInPath
        self.workspaceRoot = URL(filePath: expanded).standardized.path()
        self.allowedCommands = allowedCommands
        self.deniedCommands = deniedCommands
        self.approvalMode = approvalMode
        self.policy = policy
        self.ignoredPathPatterns = ignoredPathPatterns
    }

    /// Get the effective workspace (worktree if set, otherwise original)
    public var effectiveWorkspaceRoot: String {
        return workspaceRoot
    }

    /// Resolve a path to an absolute, normalized, symlink-resolved location.
    private func resolveAbsolutePath(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        let effectiveRoot = normalizeRootPath(effectiveWorkspaceRoot)
        let resolved = expanded.hasPrefix("/") ? expanded : effectiveRoot + "/" + expanded
        let normalizedPath = URL(filePath: resolved).standardized.path()
        return URL(filePath: normalizedPath).resolvingSymlinksInPath().path()
    }

    private func normalizeRootPath(_ root: String) -> String {
        guard root.count > 1 else { return root }
        var normalized = root
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    private func isPathWithinRoot(_ path: String, root: String) -> Bool {
        let normalizedRoot = normalizeRootPath(root)
        return path == normalizedRoot || path.hasPrefix(normalizedRoot + "/")
    }

    /// Validate that a path is within the workspace root.
    public func validatePath(_ path: String) throws -> String {
        let effectiveRoot = normalizeRootPath(effectiveWorkspaceRoot)
        let finalPath = resolveAbsolutePath(path)

        guard isPathWithinRoot(finalPath, root: effectiveRoot) else {
            throw PermissionError.pathOutsideWorkspace(
                path: finalPath,
                workspaceRoot: effectiveRoot
            )
        }

        return finalPath
    }

    /// Validate read-only access for a path.
    ///
    /// Reads are allowed inside the workspace and under `~/skills`.
    public func validateReadPath(_ path: String) throws -> String {
        let finalPath = resolveAbsolutePath(path)
        let effectiveRoot = normalizeRootPath(effectiveWorkspaceRoot)
        if isPathWithinRoot(finalPath, root: effectiveRoot) {
            return finalPath
        }

        let homeSkills = URL(filePath: FileManager.default.homeDirectoryForCurrentUser.path)
            .appending(path: "skills")
            .standardized
            .resolvingSymlinksInPath()
            .path()
        if isPathWithinRoot(finalPath, root: homeSkills) {
            return finalPath
        }

        throw PermissionError.pathOutsideAllowedReadRoots(
            path: finalPath,
            workspaceRoot: effectiveRoot,
            extraRoot: homeSkills
        )
    }

    /// Check if a shell command is allowed.
    public func isCommandAllowed(_ command: String) -> Bool {
        for pattern in deniedCommands {
            if matchesGlob(command, pattern: pattern) {
                return false
            }
        }

        for pattern in allowedCommands {
            if matchesGlob(command, pattern: pattern) {
                return true
            }
        }

        return false
    }

    /// Evaluate configured tool/path policy rules.
    public func evaluateToolPolicy(toolName: String, targetPath: String?) -> PolicyDecision {
        guard let policy else {
            return .allowed
        }

        let normalizedPath: String?
        if let targetPath {
            let expanded = NSString(string: targetPath).expandingTildeInPath
            let effectiveRoot = effectiveWorkspaceRoot
            let candidate = expanded.hasPrefix("/") ? expanded : effectiveRoot + "/" + expanded
            normalizedPath = URL(filePath: candidate).standardized.path()
        } else {
            normalizedPath = nil
        }

        for rule in policy.rules {
            guard rule.tools.contains(where: { matchesGlob(toolName, pattern: $0) }) else {
                continue
            }

            let pathMatched: Bool
            if let paths = rule.paths, !paths.isEmpty {
                guard let normalizedPath else {
                    continue
                }
                pathMatched = paths.contains(where: { matchesGlob(normalizedPath, pattern: $0) })
            } else {
                pathMatched = true
            }

            guard pathMatched else {
                continue
            }

            switch rule.effect {
            case .deny:
                let baseReason = rule.reason ?? "Denied by policy rule for tool '\(toolName)'"
                return .denied(reason: baseReason)
            case .allow:
                continue
            }
        }

        return .allowed
    }

    /// Returns true if a path should be ignored by search-style tools.
    public func isPathIgnored(_ path: String) -> Bool {
        guard !ignoredPathPatterns.isEmpty else {
            return false
        }

        let relativePath: String
        let effectiveRoot = normalizeRootPath(effectiveWorkspaceRoot)
        if path == effectiveRoot {
            relativePath = "."
        } else if path.hasPrefix(effectiveRoot + "/") {
            relativePath = String(path.dropFirst(effectiveRoot.count + 1))
        } else {
            relativePath = path
        }

        for pattern in ignoredPathPatterns {
            if matchesGlob(relativePath, pattern: pattern) || matchesGlob(path, pattern: pattern) {
                return true
            }
        }

        return false
    }

    private func matchesGlob(_ string: String, pattern: String) -> Bool {
        return fnmatch(pattern, string, 0) == 0
    }
}

// MARK: - Errors

public enum PermissionError: LocalizedError {
    case pathOutsideWorkspace(path: String, workspaceRoot: String)
    case pathOutsideAllowedReadRoots(path: String, workspaceRoot: String, extraRoot: String)
    case commandDenied(command: String)

    public var errorDescription: String? {
        switch self {
        case .pathOutsideWorkspace(let path, let root):
            return "Path '\(path)' is outside workspace root '\(root)'"
        case .pathOutsideAllowedReadRoots(let path, let root, let extraRoot):
            return "Path '\(path)' is outside allowed read roots '\(root)' and '\(extraRoot)'"
        case .commandDenied(let command):
            return "Command denied by permission rules: \(command)"
        }
    }
}
