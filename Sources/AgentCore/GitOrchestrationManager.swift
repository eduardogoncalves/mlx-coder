// Sources/AgentCore/GitOrchestrationManager.swift
// Manages git lifecycle for coding tasks (feature branches, commits, worktrees)

import Foundation

/// Manages git orchestration for a coding task session
public actor GitOrchestrationManager {
    private let gitService: GitService
    private let stateTracker: GitStateTracker
    private var currentWorktreePath: String?
    private var currentBranchName: String?
    private var baseBranch: String = "main"
    private var filesModifiedInCurrentSubtask: Set<String> = []
    private var subtaskCount: Int = 0
    
    public enum Status: Equatable, Sendable {
        case notInitialized
        case ready(branchName: String, worktreePath: String?)
        case waitingForUserConfirmation(message: String)
        case error(message: String)
    }
    
    /// Initialize orchestration manager for a project
    public static func create(projectRoot: String) async throws -> GitOrchestrationManager {
        let gitService = try GitService(projectRoot: projectRoot)
        let stateTracker = try GitStateTracker(projectRoot: projectRoot)
        
        // Try to load existing state
        try await stateTracker.loadState()
        
        return GitOrchestrationManager(gitService: gitService, stateTracker: stateTracker)
    }
    
    private init(gitService: GitService, stateTracker: GitStateTracker) {
        self.gitService = gitService
        self.stateTracker = stateTracker
    }
    
    /// Prepare a coding task (extract branch name, determine base branch)
    /// Does NOT create worktree yet (lazy initialization)
    public func prepareTask(userMessage: String, shouldPromptForBaseBranch: Bool = true) async throws -> (branchName: String, baseBranch: String, warning: String?) {
        // Parse message to get branch info
        let branchInfo = try BranchNamer.parse(userMessage: userMessage)
        self.currentBranchName = branchInfo.branchName
        
        // Record in state tracker
        await stateTracker.setBranchName(branchInfo.branchName)
        
        // Ensure git is initialized
        if !gitService.isRepositoryInitialized() {
            _ = try await gitService.initializeRepository()
            await stateTracker.markGitInitialized(true)
        }
        
        // Validate current branch setup
        let currentBranch = try? await gitService.getCurrentBranch()
        let taskSetupValidation = validateTaskSetup(
            repositoryInitialized: gitService.isRepositoryInitialized(),
            currentBranch: currentBranch
        )
        
        if !taskSetupValidation.isValid {
            throw GitError.notOnCorrectBranch(expected: "main/master", actual: currentBranch ?? "unknown")
        }

        let prepareWarning = taskSetupValidation.warning
        
        // Determine base branch
        let hasRemote = try await gitService.hasRemote()
        await stateTracker.setHasRemote(hasRemote)
        
        if hasRemote && shouldPromptForBaseBranch {
            let branches = try await gitService.listBranches()
            
            // Validate worktree creation is possible
            let worktreeValidation = validateWorktreeCreation(
                newBranchName: branchInfo.branchName,
                existingBranches: branches
            )
            
            if !worktreeValidation.isValid {
                if let warning = worktreeValidation.warning {
                    if warning.localizedCaseInsensitiveContains("already exists") {
                        throw GitError.failedToCreateWorktree(branchName: branchInfo.branchName, reason: warning)
                    }
                    throw GitError.invalidBranchName(warning)
                }
            }
            
            // Infer base branch (prefer main, fallback to master, then first remote)
            if branches.contains("main") {
                self.baseBranch = "main"
            } else if branches.contains("master") {
                self.baseBranch = "master"
            } else if let first = branches.first {
                self.baseBranch = first
            }
        }
        
        await stateTracker.setBaseBranch(baseBranch)
        try await stateTracker.saveState()
        
        return (branchName: branchInfo.branchName, baseBranch: baseBranch, warning: prepareWarning)
    }
    
    // MARK: - Validation Helpers
    
    /// Validate if task setup is safe to proceed
    private func validateTaskSetup(repositoryInitialized: Bool, currentBranch: String?) -> (isValid: Bool, warning: String?) {
        GitErrorHandler.validateTaskSetup(
            isRepositoryInitialized: repositoryInitialized,
            currentBranch: currentBranch,
            shouldBeOnMain: true
        )
    }
    
    /// Validate worktree creation preconditions
    private func validateWorktreeCreation(newBranchName: String, existingBranches: [String]) -> (isValid: Bool, warning: String?) {
        GitErrorHandler.validateWorktreeCreation(
            newBranchName: newBranchName,
            existingBranches: existingBranches
        )
    }
    
    /// Called when user confirms which base branch to use
    public func setBaseBranch(_ branchName: String) async throws {
        self.baseBranch = branchName
        await stateTracker.setBaseBranch(branchName)
        try await stateTracker.saveState()
    }
    
    /// Called on first file modification - creates worktree (lazy initialization)
    public func onFirstFileModification(filename: String? = nil) async throws {
        // Only create worktree once
        guard self.currentWorktreePath == nil else {
            return
        }
        
        guard let branchName = self.currentBranchName else {
            throw GitError.invalidBranchName("No branch name set - call prepareTask first")
        }
        
        // Create worktree
        let worktreePath = try await gitService.createWorktree(
            branchName: branchName,
            fromBranch: baseBranch
        )
        
        self.currentWorktreePath = worktreePath
        await stateTracker.setWorktreeRoot(worktreePath)
        
        if let filename = filename {
            await stateTracker.recordModifiedFile(filename)
        }
        
        try await stateTracker.saveState()
    }
    
    /// Track tool execution and modified files
    public func trackToolExecution(toolName: String, modifiedFiles: [String] = []) async {
        for file in modifiedFiles {
            filesModifiedInCurrentSubtask.insert(file)
            await stateTracker.recordModifiedFile(file)
        }
    }
    
    /// Determine if we're at a subtask boundary
    public func shouldCommit(toolName: String) -> Bool {
        // Heuristics for subtask boundaries:
        // 1. After completing tests
        if toolName.contains("test") || toolName.contains("spec") {
            return true
        }
        
        // 2. After explicit completion indicators
        if toolName == "task" {
            return true
        }
        
        // 3. Multiple file modifications suggest a logical unit
        if filesModifiedInCurrentSubtask.count >= 3 {
            return true
        }
        
        return false
    }
    
    /// Commit changes for a subtask with enhanced error handling
    public func commitSubtask(description: String) async throws -> String {
        guard !filesModifiedInCurrentSubtask.isEmpty else {
            throw GitError.nothingToCommit
        }
        
        subtaskCount += 1
        let commitMessage = "[\(subtaskCount)] \(description)"
        
        do {
            let result = try await gitService.commit(message: commitMessage)
            await stateTracker.recordCommit(message: commitMessage)
            
            // Clear subtask tracking
            filesModifiedInCurrentSubtask.removeAll()
            
            try await stateTracker.saveState()
            return result
        } catch GitError.nothingToCommit {
            // Ignore if nothing to commit in this subtask
            filesModifiedInCurrentSubtask.removeAll()
            return "No changes to commit (working tree clean)"
        } catch {
            // Enhance error with context
            let userError = GitErrorHandler.analyzeError(error)
            
            // Non-recoverable failures must bubble up immediately.
            if !userError.isRecoverable {
                throw error
            }
            
            // Recoverable commit failure: keep tracked files so a later commit can retry.
            return "Commit skipped: \(userError.message)"
        }
    }
    
    /// Attempt to push with graceful fallback
    private func attemptPush() async -> (succeeded: Bool, message: String) {
        do {
            guard try await gitService.hasRemote() else {
                return (false, "No remote configured")
            }
            
            let result = try await gitService.push()
            return (true, result)
        } catch GitError.remoteNotConfigured {
            return (false, "No remote configured - commits saved locally")
        } catch GitError.pushFailed(let reason) {
            return (false, "Push failed: \(reason) - commits saved locally")
        } catch {
            return (false, error.localizedDescription)
        }
    }
    
    /// Called when task is complete
    public func onTaskComplete() async throws -> TaskCompletionGuide {
        // Final commit if there are pending changes
        if !filesModifiedInCurrentSubtask.isEmpty {
            do {
                _ = try await commitSubtask(description: "Final changes")
            } catch GitError.nothingToCommit {
                // Expected if no changes since last commit
            } catch {
                // Non-fatal - log but continue
            }
        }
        
        // Try to push to remote (non-blocking failure)
        let pushResult = await attemptPush()
        
        // Get commit info for PR guidance
        let commits = try await gitService.getCommitsSince(baseBranch: baseBranch)
        
        let guide = TaskCompletionGuide(
            branchName: currentBranchName ?? "unknown",
            baseBranch: baseBranch,
            commits: commits,
            worktreePath: currentWorktreePath,
            filesModified: await stateTracker.getModifiedFiles(),
            pushStatus: pushResult
        )
        
        try await stateTracker.saveState()
        return guide
    }
    
    /// Get current status
    public func getStatus() async -> Status {
        guard let branchName = currentBranchName else {
            return .notInitialized
        }
        
        return .ready(branchName: branchName, worktreePath: currentWorktreePath)
    }
    
    /// Get current branch name
    public func getCurrentBranchName() -> String? {
        currentBranchName
    }
    
    /// Get number of commits made this session
    public func getCommitCount() async -> Int {
        await stateTracker.getCommitCount()
    }
}

/// Guidance for completing a task and creating a PR
public struct TaskCompletionGuide: Sendable {
    public let branchName: String
    public let baseBranch: String
    public let commits: [String]
    public let worktreePath: String?
    public let filesModified: [String]
    public let pushStatus: (succeeded: Bool, message: String)?
    
    public init(
        branchName: String,
        baseBranch: String,
        commits: [String],
        worktreePath: String?,
        filesModified: [String],
        pushStatus: (succeeded: Bool, message: String)? = nil
    ) {
        self.branchName = branchName
        self.baseBranch = baseBranch
        self.commits = commits
        self.worktreePath = worktreePath
        self.filesModified = filesModified
        self.pushStatus = pushStatus
    }
    
    public var formattedMessage: String {
        var message = """
        ✅ Task Complete!
        
        Your branch is ready for review:
          Branch: \(branchName)
          Base: \(baseBranch)
          Commits: \(commits.count)
        """
        
        if !commits.isEmpty {
            message += "\n\n  Commit history:"
            for commit in commits {
                message += "\n    • \(commit)"
            }
        }
        
        // Add push status if available
        if let pushStatus = pushStatus {
            message += "\n\n  Push status: "
            if pushStatus.succeeded {
                message += "✅ Pushed successfully"
            } else {
                message += "⚠️  \(pushStatus.message)"
            }
        }
        
        message += """
        
        Next steps:
          1. Review all changes with: git diff \(baseBranch)..HEAD
          2. Create a pull request on your repository
          3. Or merge locally: git checkout \(baseBranch) && git merge \(branchName)
        """
        
        return message
    }
}
