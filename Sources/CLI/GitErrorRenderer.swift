// Sources/CLI/GitErrorRenderer.swift
// Renders git errors and recovery guidance to the terminal

import Foundation

/// Renders git errors and recovery suggestions to the console
public struct GitErrorRenderer {
    private let renderer: StreamRenderer
    
    public init(_ streamRenderer: StreamRenderer) {
        self.renderer = streamRenderer
    }
    
    /// Display a user-friendly error with recovery suggestions
    public func displayError(_ userError: GitErrorHandler.UserError) {
        let errorEmoji = "❌"
        
        // Display title
        renderer.printStatus("\(errorEmoji) \(userError.title)")
        
        // Display message with indentation
        let indentedMessage = userError.message
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "   \($0)" }
            .joined(separator: "\n")
        renderer.printStatus(indentedMessage)
        
        // Display suggestions if recoverable
        if !userError.suggestions.isEmpty {
            renderer.printStatus("")
            renderer.printStatus("💡 Recovery options:")
            for suggestion in userError.suggestions {
                renderer.printStatus("   • \(suggestion)")
            }
        }
        
        // Print category hint
        let categoryHint = getCategoryHint(userError.category)
        if !categoryHint.isEmpty {
            renderer.printStatus("")
            renderer.printStatus("📚 \(categoryHint)")
        }
        
        renderer.printStatus("")
    }
    
    /// Display a warning (recoverable error)
    public func displayWarning(_ userError: GitErrorHandler.UserError) {
        let warningEmoji = "⚠️ "
        
        renderer.printStatus("\(warningEmoji)\(userError.title)")
        renderer.printStatus("   \(userError.message)")
        
        if !userError.suggestions.isEmpty {
            renderer.printStatus("")
            renderer.printStatus("   Options:")
            for suggestion in userError.suggestions.prefix(2) {
                renderer.printStatus("   • \(suggestion)")
            }
        }
        
        renderer.printStatus("")
    }
    
    /// Display validation result with optional warning
    public func displayValidationResult(_ result: (isValid: Bool, warning: String?)) {
        if !result.isValid {
            renderer.printStatus("❌ Validation failed")
            if let warning = result.warning {
                renderer.printStatus("   \(warning)")
            }
        } else if let warning = result.warning {
            renderer.printStatus("\(warning)")
        }
    }
    
    /// Display git state validation summary
    public func displayStateCheckStart() {
        renderer.printStatus("🔍 Checking git state...")
    }
    
    /// Display successful state check
    public func displayStateCheckSuccess(
        repositoryInitialized: Bool,
        currentBranch: String?,
        hasRemote: Bool,
        worktreeActive: Bool
    ) {
        var status = "✅ Git state:"
        if repositoryInitialized {
            status += " repository initialized"
        }
        if let branch = currentBranch {
            status += " | branch: \(branch)"
        }
        if hasRemote {
            status += " | remote configured"
        }
        if worktreeActive {
            status += " | worktree active"
        }
        renderer.printStatus(status)
    }
    
    /// Display user confirmation prompt
    public func promptUserConfirmation(message: String, defaultResponse: Bool = false) -> Bool {
        renderer.printStatus("")
        renderer.printStatus(message)
        
        if defaultResponse {
            renderer.printStatus("(default: Yes) Continue? (y/n): ", newline: false)
        } else {
            renderer.printStatus("(default: No) Continue? (y/n): ", newline: false)
        }
        
        fflush(stdout)
        
        // Read user input
        guard let input = readLine()?.lowercased().trimmingCharacters(in: .whitespaces) else {
            return defaultResponse
        }
        
        switch input {
        case "y", "yes":
            return true
        case "n", "no":
            return false
        default:
            return defaultResponse
        }
    }
    
    /// Display commit summary before committing
    public func displayCommitSummary(
        message: String,
        filesChanged: [String],
        branchName: String?
    ) {
        renderer.printStatus("📝 Preparing commit:")
        renderer.printStatus("   Message: \(message)")
        
        if let branch = branchName {
            renderer.printStatus("   Branch: \(branch)")
        }
        
        if !filesChanged.isEmpty {
            renderer.printStatus("   Files changed: \(filesChanged.count)")
            let preview = filesChanged.prefix(3)
            for file in preview {
                renderer.printStatus("     • \(file)")
            }
            if filesChanged.count > 3 {
                renderer.printStatus("     ... and \(filesChanged.count - 3) more")
            }
        }
        
        renderer.printStatus("")
    }
    
    /// Display push status
    public func displayPushAttempt(
        branchName: String,
        hasRemote: Bool
    ) {
        if hasRemote {
            renderer.printStatus("📤 Pushing \(branchName) to remote...")
        } else {
            renderer.printStatus("⚠️  No remote configured - skipping push")
        }
    }
    
    /// Display push success
    public func displayPushSuccess(branchName: String) {
        renderer.printStatus("✅ Successfully pushed \(branchName)")
    }
    
    /// Display push failure (non-fatal)
    public func displayPushFailure(reason: String) {
        renderer.printStatus("⚠️  Push failed (non-fatal): \(reason)")
        renderer.printStatus("   Commits are saved locally, push manually when ready")
    }
    
    // MARK: - Private Helpers
    
    private func getCategoryHint(_ category: GitErrorHandler.ErrorCategory) -> String {
        switch category {
        case .repositoryNotSetup:
            return "Repository and branch setup issues"
        case .workingTreeConflict:
            return "Working tree or worktree path conflicts"
        case .remoteConfiguration:
            return "Remote repository configuration"
        case .commitValidation:
            return "Commit validation and staging"
        case .userConfirmationNeeded:
            return "User confirmation required for operation"
        case .networkFailure:
            return "Network and connectivity issues"
        case .permissionDenied:
            return "File system permissions and access rights"
        case .unknown:
            return "Check your git setup and try again"
        }
    }
    
    /// Format error for logging/reporting
    public static func formatErrorForLog(_ error: GitErrorHandler.UserError) -> String {
        var log = "ERROR: \(error.title)\n"
        log += "  Message: \(error.message)\n"
        log += "  Category: \(error.category)\n"
        log += "  Recoverable: \(error.isRecoverable)\n"
        
        if !error.suggestions.isEmpty {
            log += "  Suggestions:\n"
            for suggestion in error.suggestions {
                log += "    - \(suggestion)\n"
            }
        }
        
        return log
    }
}

// MARK: - StreamRenderer Extension for Convenience

extension StreamRenderer {
    /// Print status message with optional newline
    public func printStatus(_ message: String, newline: Bool = true) {
        if newline {
            print(message)
        } else {
            print(message, terminator: "")
        }
        fflush(stdout)
    }
}
