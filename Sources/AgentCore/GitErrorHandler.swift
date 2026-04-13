// Sources/AgentCore/GitErrorHandler.swift
// Comprehensive error handling and recovery for git operations

import Foundation

/// Handles git errors with recovery guidance and user-friendly messages
public struct GitErrorHandler: Sendable {
    /// Categorizes errors for appropriate handling
    public enum ErrorCategory: Sendable {
        case repositoryNotSetup
        case workingTreeConflict
        case remoteConfiguration
        case commitValidation
        case userConfirmationNeeded
        case networkFailure
        case permissionDenied
        case unknown
    }
    
    /// User-friendly error with recovery suggestions (conforms to Error)
    public struct UserError: Sendable, LocalizedError {
        public let title: String
        public let message: String
        public let suggestions: [String]
        public let isRecoverable: Bool
        public let category: ErrorCategory
        
        public var errorDescription: String? {
            message
        }
        
        public var recoverySuggestion: String? {
            suggestions.isEmpty ? nil : suggestions.joined(separator: "\n")
        }
    }
    
    /// Analyze git error and provide recovery guidance
    public static func analyzeError(_ error: Error) -> UserError {
        if let gitError = error as? GitError {
            return handleGitError(gitError)
        }
        
        let description = error.localizedDescription
        
        // Pattern matching for common error scenarios
        if description.contains("Permission denied") {
            return permissionDeniedError()
        }
        
        if description.contains("Network") || description.contains("Connection refused") {
            return networkError(underlying: description)
        }
        
        if description.contains("not a git repository") {
            return repositoryNotInitializedError()
        }
        
        return unknownError(underlying: description)
    }
    
    // MARK: - Error Handlers
    
    private static func handleGitError(_ error: GitError) -> UserError {
        switch error {
        case .repositoryNotInitialized:
            return repositoryNotInitializedError()
        
        case .worktreeAlreadyExists(let path):
            return worktreeExistsError(path: path)
        
        case .worktreeNotFound(let path):
            return worktreeNotFoundError(path: path)
        
        case .failedToCreateWorktree(let branch, let reason):
            return createWorktreeFailedError(branch: branch, reason: reason)
        
        case .failedToSwitchWorktree(let path, let reason):
            return switchWorktreeFailedError(path: path, reason: reason)
        
        case .commitFailed(let reason):
            return commitFailedError(reason: reason)
        
        case .pushFailed(let reason):
            return pushFailedError(reason: reason)
        
        case .invalidBranchName(let name):
            return invalidBranchNameError(name: name)
        
        case .notOnCorrectBranch(let expected, let actual):
            return notOnCorrectBranchError(expected: expected, actual: actual)
        
        case .remoteNotConfigured:
            return remoteNotConfiguredError()
        
        case .failedToReadState(let reason):
            return readStateFailedError(reason: reason)
        
        case .failedToWriteState(let reason):
            return writeStateFailedError(reason: reason)
        
        case .gitCommandFailed(let command, let stderr):
            return gitCommandFailedError(command: command, stderr: stderr)
        
        case .invalidWorkspace(let path):
            return invalidWorkspaceError(path: path)
        
        case .nothingToCommit:
            return nothingToCommitWarning()
        
        case .stateFileNotFound:
            return stateFileNotFoundError()
        
        case .invalidCustomBranchName(let name):
            return invalidCustomBranchNameError(name: name)
        
        case .branchNameAlreadyExists(let name):
            return branchNameAlreadyExistsError(name: name)
        }
    }
    
    // MARK: - Specific Error Creators
    
    private static func repositoryNotInitializedError() -> UserError {
        UserError(
            title: "Repository Not Initialized",
            message: "Git repository has not been initialized in this directory.",
            suggestions: [
                "Run 'git init' to initialize the repository",
                "Or point to an existing git repository",
                "The agent can initialize automatically if you give permission"
            ],
            isRecoverable: true,
            category: .repositoryNotSetup
        )
    }
    
    private static func worktreeExistsError(path: String) -> UserError {
        UserError(
            title: "Worktree Already Exists",
            message: "A worktree already exists at: \(path)",
            suggestions: [
                "Use the existing worktree for this task",
                "Remove it with: git worktree remove \(path)",
                "Or use a different branch name"
            ],
            isRecoverable: true,
            category: .workingTreeConflict
        )
    }
    
    private static func worktreeNotFoundError(path: String) -> UserError {
        UserError(
            title: "Worktree Not Found",
            message: "Worktree does not exist at: \(path)",
            suggestions: [
                "Check if the worktree was deleted",
                "Run 'git worktree list' to see available worktrees",
                "Start a new task to create a new worktree"
            ],
            isRecoverable: false,
            category: .workingTreeConflict
        )
    }
    
    private static func createWorktreeFailedError(branch: String, reason: String) -> UserError {
        UserError(
            title: "Failed to Create Worktree",
            message: "Could not create worktree for branch '\(branch)': \(reason)",
            suggestions: [
                "Check if the branch name is valid",
                "Ensure you have write permissions in the repository",
                "Try using a simpler task description",
                reason.contains("already exists") ? "Use a different branch name" : nil
            ].compactMap { $0 },
            isRecoverable: true,
            category: .workingTreeConflict
        )
    }
    
    private static func switchWorktreeFailedError(path: String, reason: String) -> UserError {
        UserError(
            title: "Failed to Switch Worktree",
            message: "Could not switch to worktree at '\(path)': \(reason)",
            suggestions: [
                "Verify the worktree path is correct",
                "Check file system permissions",
                "Run 'git worktree list' to verify the worktree exists"
            ],
            isRecoverable: true,
            category: .workingTreeConflict
        )
    }
    
    private static func commitFailedError(reason: String) -> UserError {
        if reason.contains("nothing to commit") {
            return nothingToCommitWarning()
        }
        
        return UserError(
            title: "Commit Failed",
            message: "Could not commit changes: \(reason)",
            suggestions: [
                "Verify that changes have been made to files",
                "Check file permissions on modified files",
                "Ensure git is properly configured with user.name and user.email"
            ],
            isRecoverable: reason.contains("Permission") ? false : true,
            category: .commitValidation
        )
    }
    
    private static func pushFailedError(reason: String) -> UserError {
        UserError(
            title: "Push Failed",
            message: "Could not push to remote: \(reason)",
            suggestions: [
                "Check your network connection",
                "Verify remote credentials are configured",
                "Pull latest changes: git pull",
                "Try pushing again"
            ],
            isRecoverable: true,
            category: reason.contains("Connection") ? .networkFailure : .unknown
        )
    }
    
    private static func invalidBranchNameError(name: String) -> UserError {
        UserError(
            title: "Invalid Branch Name",
            message: "Branch name '\(name)' does not match required format.",
            suggestions: [
                "Branch names must match: [feature|hotfix|chore]/YYYYMMDD-task-name",
                "Example: 'feature/20260328-add-git-support'",
                "Use simpler, lowercase task descriptions",
                "Avoid special characters"
            ],
            isRecoverable: true,
            category: .repositoryNotSetup
        )
    }
    
    private static func notOnCorrectBranchError(expected: String, actual: String) -> UserError {
        UserError(
            title: "On Wrong Branch",
            message: "Expected to be on '\(expected)' but currently on '\(actual)'.",
            suggestions: [
                "Switch to the correct branch: git checkout \(expected)",
                "Or continue on current branch '\(actual)' (confirm if intentional)",
                "Check git status: git status"
            ],
            isRecoverable: true,
            category: .userConfirmationNeeded
        )
    }
    
    private static func remoteNotConfiguredError() -> UserError {
        UserError(
            title: "Remote Not Configured",
            message: "No remote 'origin' configured in this repository.",
            suggestions: [
                "Add a remote: git remote add origin <repository-url>",
                "Commits will be made locally, but cannot be pushed",
                "You can configure the remote later"
            ],
            isRecoverable: true,
            category: .remoteConfiguration
        )
    }
    
    private static func readStateFailedError(reason: String) -> UserError {
        UserError(
            title: "Failed to Read State",
            message: "Could not read git orchestration state: \(reason)",
            suggestions: [
                "Check file system permissions",
                "Verify .native-agent directory exists",
                "Try deleting .native-agent/git-state.json and restarting"
            ],
            isRecoverable: true,
            category: .unknown
        )
    }
    
    private static func writeStateFailedError(reason: String) -> UserError {
        UserError(
            title: "Failed to Save State",
            message: "Could not save git orchestration state: \(reason)",
            suggestions: [
                "Check write permissions in project directory",
                "Ensure .native-agent directory is writable",
                "Check available disk space"
            ],
            isRecoverable: true,
            category: reason.contains("Permission") ? .permissionDenied : .unknown
        )
    }
    
    private static func gitCommandFailedError(command: String, stderr: String) -> UserError {
        UserError(
            title: "Git Command Failed",
            message: "Git command failed: git \(command)",
            suggestions: [
                "Verify git is installed and available in PATH",
                "Check repository state: git status",
                "Review error details: \(stderr.prefix(100))"
            ],
            isRecoverable: stderr.contains("not a git repository") == false,
            category: .unknown
        )
    }
    
    private static func invalidWorkspaceError(path: String) -> UserError {
        UserError(
            title: "Invalid Workspace",
            message: "The specified workspace directory does not exist: \(path)",
            suggestions: [
                "Verify the path is correct",
                "Check if the directory was moved or deleted",
                "Use an absolute path instead of relative"
            ],
            isRecoverable: false,
            category: .repositoryNotSetup
        )
    }
    
    private static func nothingToCommitWarning() -> UserError {
        UserError(
            title: "Nothing to Commit",
            message: "No changes detected in the working tree.",
            suggestions: [
                "Make changes to files before committing",
                "Run 'git status' to see current state",
                "Changes will be committed after you modify files"
            ],
            isRecoverable: true,
            category: .commitValidation
        )
    }
    
    private static func stateFileNotFoundError() -> UserError {
        UserError(
            title: "State File Not Found",
            message: "Git orchestration state file not found.",
            suggestions: [
                "This may be the first task in this directory",
                "State will be created automatically",
                "Or load an existing state with 'git worktree list'"
            ],
            isRecoverable: true,
            category: .unknown
        )
    }
    
    private static func invalidCustomBranchNameError(name: String) -> UserError {
        UserError(
            title: "Invalid Branch Name",
            message: "Branch name '\(name)' is not valid.",
            suggestions: [
                "Use letters, numbers, hyphens (-), underscores (_), or slashes (/)",
                "Avoid leading or trailing hyphens",
                "Avoid consecutive slashes",
                "Example valid names: feature/my-feature, hotfix/bug-fix, my-branch"
            ],
            isRecoverable: true,
            category: .commitValidation
        )
    }
    
    private static func branchNameAlreadyExistsError(name: String) -> UserError {
        UserError(
            title: "Branch Already Exists",
            message: "Branch '\(name)' already exists in this repository.",
            suggestions: [
                "Choose a different branch name",
                "Use 'git branch -a' to see existing branches",
                "Or delete the existing branch first: git branch -D \(name)"
            ],
            isRecoverable: true,
            category: .workingTreeConflict
        )
    }
    
    private static func permissionDeniedError() -> UserError {
        UserError(
            title: "Permission Denied",
            message: "You do not have permission to perform this operation.",
            suggestions: [
                "Check file and directory permissions",
                "Verify your user has write access to the repository",
                "Run 'ls -la' to check permissions on key files"
            ],
            isRecoverable: false,
            category: .permissionDenied
        )
    }
    
    private static func networkError(underlying: String) -> UserError {
        UserError(
            title: "Network Error",
            message: "Network connection failed: \(underlying)",
            suggestions: [
                "Check your internet connection",
                "Verify the remote URL is accessible",
                "Try again in a moment"
            ],
            isRecoverable: true,
            category: .networkFailure
        )
    }
    
    private static func unknownError(underlying: String) -> UserError {
        UserError(
            title: "Unknown Error",
            message: "An unexpected error occurred: \(underlying)",
            suggestions: [
                "Check the error details above",
                "Verify your environment setup",
                "Try the operation manually with git"
            ],
            isRecoverable: false,
            category: .unknown
        )
    }
    
    // MARK: - Edge Case Validators
    
    /// Check if can safely proceed with a task
    public static func validateTaskSetup(
        isRepositoryInitialized: Bool,
        currentBranch: String?,
        shouldBeOnMain: Bool = true
    ) -> (isValid: Bool, warning: String?) {
        guard isRepositoryInitialized else {
            return (false, "Repository not initialized")
        }
        
        guard let branch = currentBranch else {
            return (false, "Could not determine current branch")
        }
        
        // Warn if not on main but should be
        if shouldBeOnMain && !["main", "master"].contains(branch) {
            return (true, "⚠️  Warning: Currently on branch '\(branch)'. New worktree will be based on this branch, not main.")
        }
        
        return (true, nil)
    }
    
    /// Check for common worktree issues
    public static func validateWorktreeCreation(
        newBranchName: String,
        existingBranches: [String]
    ) -> (isValid: Bool, warning: String?) {
        // Check if branch already exists
        if existingBranches.contains(newBranchName) {
            return (false, "Branch '\(newBranchName)' already exists")
        }
        
        // Warn if name is very similar to existing branch
        for existing in existingBranches {
            let similarity = levenshteinDistance(newBranchName, existing)
            if similarity < 3 && similarity > 0 {
                return (true, "⚠️  Warning: Branch name '\(newBranchName)' is very similar to '\(existing)'")
            }
        }
        
        return (true, nil)
    }
    
    /// Levenshtein distance for typo detection
    private static func levenshteinDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a)
        let b = Array(b)
        let m = a.count
        let n = b.count
        
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        
        for i in 0...m { dp[i][0] = i }
        for j in 0...n { dp[0][j] = j }
        
        for i in 1...m {
            for j in 1...n {
                if a[i-1] == b[j-1] {
                    dp[i][j] = dp[i-1][j-1]
                } else {
                    dp[i][j] = 1 + min(dp[i-1][j], dp[i][j-1], dp[i-1][j-1])
                }
            }
        }
        
        return dp[m][n]
    }
}
