// Sources/ToolSystem/Shell/SandboxEngine.swift
// macOS Seatbelt sandboxing for shell commands

import Foundation

/// Utility to wrap shell commands in a macOS Seatbelt sandbox using `sandbox-exec`.
public struct SandboxEngine: Sendable {
    
    public init() {}
    
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
        
        // Return the wrapped command
        // sandbox-exec -p '<profile>' '<command>'
        // Both profile and command must be quoted to prevent shell injection.
        return "sandbox-exec -p '\(escapedProfile)' '\(escapedCommand)'"
    }
    
    /// Generates a Seatbelt profile string.
    private func generateProfile(workspaceRoot: String) -> String {
        """
        (version 1)
        (allow default)
        
        ;; Block all writes by default
        (deny file-write*)
        
        ;; Allow writes to system temp and common paths
        (allow file-write* (subpath "/tmp"))
        (allow file-write* (subpath "/private/tmp"))
        (allow file-write* (subpath "/var/folders"))
        (allow file-write* (subpath "/private/var/folders"))
        
        ;; Allow writes within the workspace
        (allow file-write* (subpath "\(workspaceRoot)"))
        
        ;; Ensure we can read everything otherwise (allow default covers this but let's be explicit for write-related reads if any)
        (allow file-read*)
        
        ;; Allow process execution and networking (permissive-open style)
        (allow process*)
        (allow network*)
        """
    }
}
