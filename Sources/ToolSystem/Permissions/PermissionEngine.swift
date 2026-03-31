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
        /// Prompt for destructive operations.
        case `default` = "default"
        /// Auto-approve common file edit tools; still prompt for shell/task.
        case autoEdit = "auto-edit"
        /// Auto-approve all destructive operations.
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
        // Resolve workspace root to absolute path
        let expanded = NSString(string: workspaceRoot).expandingTildeInPath
        self.workspaceRoot = URL(filePath: expanded).standardized.path()
        self.allowedCommands = allowedCommands
        self.deniedCommands = deniedCommands
        self.approvalMode = approvalMode
        self.policy = policy
        self.ignoredPathPatterns = ignoredPathPatterns
    }

    /// Validate that a path is within the workspace root.
    ///
    /// - Parameter path: The path to validate (will be resolved to absolute, symlinks resolved)
    /// - Returns: The resolved absolute path
    /// - Throws: `PermissionError.pathOutsideWorkspace` if the path escapes
    public func validatePath(_ path: String) throws -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        let resolved: String

        if expanded.hasPrefix("/") {
            resolved = expanded
        } else {
            resolved = workspaceRoot + "/" + expanded
        }

        // Resolve symlinks and normalize the path
        // This is critical for security: we must resolve symlinks to prevent TOCTOU attacks
        // where symlinks are created after validation but before the actual operation.
        let url = URL(filePath: resolved).standardized
        let normalizedPath = url.path()
        
        // Resolve any symlinks in the normalized path
        let resolvedURL = URL(filePath: normalizedPath).resolvingSymlinksInPath()
        let finalPath = resolvedURL.path()

        guard finalPath.hasPrefix(workspaceRoot) else {
            throw PermissionError.pathOutsideWorkspace(
                path: finalPath,
                workspaceRoot: workspaceRoot
            )
        }

        return finalPath
    }

    /// Check if a shell command is allowed.
    public func isCommandAllowed(_ command: String) -> Bool {
        // Check deny list first
        for pattern in deniedCommands {
            if matchesGlob(command, pattern: pattern) {
                return false
            }
        }

        // Check allow list
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
            let candidate = expanded.hasPrefix("/") ? expanded : workspaceRoot + "/" + expanded
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
    /// Accepts relative or absolute paths.
    public func isPathIgnored(_ path: String) -> Bool {
        guard !ignoredPathPatterns.isEmpty else {
            return false
        }

        let relativePath: String
        if path.hasPrefix(workspaceRoot + "/") {
            relativePath = String(path.dropFirst(workspaceRoot.count + 1))
        } else if path == workspaceRoot {
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

    // MARK: - Private

    private func matchesGlob(_ string: String, pattern: String) -> Bool {
        // Use fnmatch for proper glob pattern matching
        // This prevents bypasses using regex metacharacters
        // fnmatch matches patterns literally except for POSIX glob wildcards (*, ?, [])
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
