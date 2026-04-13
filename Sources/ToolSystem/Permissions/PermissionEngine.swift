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
    
    /// Global effective workspace override - use setGlobalEffectiveWorkspace/clearGlobalEffectiveWorkspace
    /// Marked as unsafe because this is intentionally shared mutable state for worktree support
    private static nonisolated(unsafe) var _globalEffectiveWorkspace: String? = nil
    
    /// Set the global effective workspace (e.g., worktree path) - affects all PermissionEngine instances
    public static nonisolated func setGlobalEffectiveWorkspace(_ path: String?) {
        guard let path else {
            _globalEffectiveWorkspace = nil
            return
        }

        let expanded = NSString(string: path).expandingTildeInPath
        let absolutePath: String
        if expanded.hasPrefix("/") {
            absolutePath = expanded
        } else {
            absolutePath = URL(filePath: FileManager.default.currentDirectoryPath)
                .appending(path: expanded)
                .standardized.path()
        }

        _globalEffectiveWorkspace = URL(filePath: absolutePath).standardized.path()
    }
    
    /// Get the global effective workspace
    public static nonisolated func getGlobalEffectiveWorkspace() -> String? {
        _globalEffectiveWorkspace
    }
    
    /// Clear the global effective workspace
    public static nonisolated func clearGlobalEffectiveWorkspace() {
        _globalEffectiveWorkspace = nil
    }

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
        // Check global override first (set by git orchestration)
        if let global = PermissionEngine.getGlobalEffectiveWorkspace() {
            return global
        }
        return workspaceRoot
    }

    /// Validate that a path is within the workspace root.
    public func validatePath(_ path: String) throws -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        let resolved: String
        let effectiveRoot = effectiveWorkspaceRoot

        if expanded.hasPrefix("/") {
            resolved = expanded
        } else {
            resolved = effectiveRoot + "/" + expanded
        }

        let url = URL(filePath: resolved).standardized
        let normalizedPath = url.path()
        
        let resolvedURL = URL(filePath: normalizedPath).resolvingSymlinksInPath()
        let finalPath = resolvedURL.path()

        guard finalPath.hasPrefix(effectiveRoot) else {
            throw PermissionError.pathOutsideWorkspace(
                path: finalPath,
                workspaceRoot: effectiveRoot
            )
        }

        return finalPath
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
        let effectiveRoot = effectiveWorkspaceRoot
        if path.hasPrefix(effectiveRoot + "/") {
            relativePath = String(path.dropFirst(effectiveRoot.count + 1))
        } else if path == effectiveRoot {
            relativePath = "."
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
    case commandDenied(command: String)

    public var errorDescription: String? {
        switch self {
        case .pathOutsideWorkspace(let path, let root):
            return "Path '\(path)' is outside workspace root '\(root)'"
        case .commandDenied(let command):
            return "Command denied by permission rules: \(command)"
        }
    }
}
