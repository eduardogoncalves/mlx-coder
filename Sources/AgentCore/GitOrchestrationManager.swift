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
    private var pendingApprovalSummary: TaskCompletionGuide?
    
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
        
        // Validate current branch setup - only if we have commits
        let currentBranch = try? await gitService.getCurrentBranch()
        if currentBranch != nil && currentBranch != "HEAD" {
            let taskSetupValidation = validateTaskSetup(
                repositoryInitialized: gitService.isRepositoryInitialized(),
                currentBranch: currentBranch
            )
            
            if !taskSetupValidation.isValid {
                throw GitError.notOnCorrectBranch(expected: "main/master", actual: currentBranch ?? "unknown")
            }
        }

        var warnings: [String] = []
        if currentBranch == nil || currentBranch == "HEAD" {
            warnings.append("New repository - will create branch from scratch")
        }
        
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
        } else {
            // No remote - use main or create first branch
            self.baseBranch = "main"
        }

        if hasRemote {
            do {
                _ = try await gitService.syncBaseBranch(baseBranch)
            } catch {
                warnings.append("Could not update base branch '\(baseBranch)': \(error.localizedDescription)")
            }
        }
        
        await stateTracker.setBaseBranch(baseBranch)
        try await stateTracker.saveState()
        
        let prepareWarning = warnings.isEmpty ? nil : warnings.joined(separator: " | ")
        return (branchName: branchInfo.branchName, baseBranch: baseBranch, warning: prepareWarning)
    }
    
    /// Update the branch name (e.g., if user provides custom name)
    public func updateBranchName(_ newName: String) throws {
        guard BranchNamer.isValidCustomBranchName(newName) else {
            throw GitError.invalidCustomBranchName(newName)
        }
        
        self.currentBranchName = newName
    }
    
    /// Create worktree immediately (non-lazy initialization)
    public func createWorktreeNow() async throws {
        guard let branchName = self.currentBranchName else {
            throw GitError.invalidBranchName("No branch name set - call prepareTask first")
        }
        
        guard self.currentWorktreePath == nil else {
            return
        }
        
        let worktreePath = try await gitService.createWorktree(
            branchName: branchName,
            fromBranch: baseBranch
        )
        
        self.currentWorktreePath = worktreePath
        await stateTracker.setWorktreeRoot(worktreePath)
        try await stateTracker.saveState()
    }
    
    /// Get current branch name
    public func getCurrentBranchName() -> String? {
        return currentBranchName
    }
    
    /// Get worktree path
    public func getWorktreePath() -> String? {
        return currentWorktreePath
    }
    
    /// Get base branch
    public func getBaseBranch() -> String {
        return baseBranch
    }

    /// List available git worktrees and their branches.
    public func listAvailableWorktrees() async throws -> [GitService.WorktreeInfo] {
        try await gitService.listWorktreeInfos()
    }

    /// Connect this orchestration session to an existing worktree.
    @discardableResult
    public func connectToExistingWorktree(path: String) async throws -> (path: String, branch: String) {
        try await gitService.switchWorktree(path: path)
        let branch = try await gitService.getCurrentBranch(in: path)

        currentWorktreePath = path
        currentBranchName = branch
        pendingApprovalSummary = nil

        await stateTracker.setWorktreeRoot(path)
        await stateTracker.setBranchName(branch)
        try await stateTracker.saveState()

        return (path, branch)
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
            let result = try await gitService.commit(message: commitMessage, in: currentWorktreePath)
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
            
            let result = try await gitService.push(in: currentWorktreePath)
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

        // Ensure at least one commit exists before showing merge approval guidance.
        var commits = try await gitService.getCommitsSince(baseBranch: baseBranch, in: currentWorktreePath)
        if commits.isEmpty {
            do {
                _ = try await gitService.commit(message: "Final changes", in: currentWorktreePath)
                await stateTracker.recordCommit(message: "Final changes")
                filesModifiedInCurrentSubtask.removeAll()
                try await stateTracker.saveState()
                commits = try await gitService.getCommitsSince(baseBranch: baseBranch, in: currentWorktreePath)
            } catch GitError.nothingToCommit {
                // No pending changes - keep zero commits.
            }
        }

        // Try to push to remote (non-blocking failure)
        let pushResult = await attemptPush()
        
        let guide = TaskCompletionGuide(
            branchName: currentBranchName ?? "unknown",
            baseBranch: baseBranch,
            commits: commits,
            worktreePath: currentWorktreePath,
            filesModified: await stateTracker.getModifiedFiles(),
            pushStatus: pushResult
        )
        pendingApprovalSummary = guide
        try await stateTracker.saveState()
        return guide
    }

    /// Run verification commands (e.g. lint/test/build) before merge.
    public func runVerificationPipeline(commands: [String]) async -> VerificationSummary {
        guard !commands.isEmpty else {
            return VerificationSummary(allPassed: true, results: [])
        }

        var results: [VerificationStepResult] = []
        for command in commands {
            do {
                let output = try await gitService.runVerification(command: command, in: currentWorktreePath)
                results.append(VerificationStepResult(command: command, passed: true, output: output))
            } catch {
                results.append(VerificationStepResult(command: command, passed: false, output: error.localizedDescription))
                return VerificationSummary(allPassed: false, results: results)
            }
        }

        return VerificationSummary(allPassed: true, results: results)
    }

    /// Review artifacts before merge (`git log` and `git diff` against base).
    public func buildDiffReview() async throws -> DiffReviewArtifacts {
        let commitLog = try await gitService.getCommitLogSince(baseBranch: baseBranch, in: currentWorktreePath)
        let fullDiff = try await gitService.getDiff(baseBranch: baseBranch, in: currentWorktreePath)
        return DiffReviewArtifacts(commitLog: commitLog, fullDiff: fullDiff)
    }

    /// Handle user decision at the merge approval step.
    public func finalizeAfterUserApproval(
        mergeNow: Bool,
        strategy: MergeStrategy = .squash,
        cleanupWorktree: Bool = true
    ) async throws -> MergeOutcome {
        guard let summary = pendingApprovalSummary else {
            throw GitError.mergeFailed(reason: "Task completion summary not prepared")
        }

        guard mergeNow else {
            return MergeOutcome(
                merged: false,
                cleanedUp: false,
                message: "Merge deferred. Worktree remains available at \(summary.worktreePath ?? "current directory").",
                cleanupWarnings: []
            )
        }

        // Re-sync base immediately before merge to reduce stale-base surprises.
        _ = try await gitService.syncBaseBranch(summary.baseBranch)

        let mergeMessage: String
        switch strategy {
        case .squash:
            let title = summary.commits.first?.split(separator: " ").dropFirst().joined(separator: " ")
            let sanitizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            mergeMessage = sanitizedTitle?.isEmpty == false
                ? "feat: \(sanitizedTitle!)"
                : "feat: merge \(summary.branchName)"
            _ = try await gitService.mergeSquash(
                baseBranch: summary.baseBranch,
                sourceBranch: summary.branchName,
                commitMessage: mergeMessage
            )
        case .mergeCommit:
            _ = try await gitService.mergeNoFastForward(
                baseBranch: summary.baseBranch,
                sourceBranch: summary.branchName,
                mergeMessage: "merge: integrate \(summary.branchName) into \(summary.baseBranch)"
            )
        case .rebase:
            _ = try await gitService.rebaseAndFastForward(
                baseBranch: summary.baseBranch,
                sourceBranch: summary.branchName
            )
        }

        var cleanedUp = false
        var cleanupWarnings: [String] = []
        if cleanupWorktree {
            let forceDeleteBranch: Bool
            switch strategy {
            case .squash:
                forceDeleteBranch = true
            case .mergeCommit, .rebase:
                forceDeleteBranch = false
            }
            if let worktreePath = summary.worktreePath {
                do {
                    try await gitService.removeWorktree(path: worktreePath)
                } catch {
                    cleanupWarnings.append(error.localizedDescription)
                }
            }
            do {
                try await gitService.deleteBranch(summary.branchName, force: forceDeleteBranch)
            } catch {
                cleanupWarnings.append(error.localizedDescription)
            }
            do {
                try await gitService.pruneWorktrees()
            } catch {
                cleanupWarnings.append(error.localizedDescription)
            }
            cleanedUp = cleanupWarnings.isEmpty
        }

        pendingApprovalSummary = nil
        return MergeOutcome(
            merged: true,
            cleanedUp: cleanedUp,
            message: cleanedUp
                ? "Merge completed on \(summary.baseBranch) and worktree cleaned up."
                : cleanupWorktree
                    ? "Merge completed on \(summary.baseBranch), but cleanup had issues."
                    : "Merge completed on \(summary.baseBranch). Worktree was kept.",
            cleanupWarnings: cleanupWarnings
        )
    }
    
    /// Get current status
    public func getStatus() async -> Status {
        if let summary = pendingApprovalSummary {
            return .waitingForUserConfirmation(message: summary.approvalPromptMessage)
        }

        guard let branchName = currentBranchName else {
            return .notInitialized
        }
        
        return .ready(branchName: branchName, worktreePath: currentWorktreePath)
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

        message += "\n\n" + approvalPromptMessage
        return message
    }

    public var approvalPromptMessage: String {
        """
        ⏸️ Awaiting approval before merge

        Summary:
          - Files modified: \(filesModified.count)
          - Commits created: \(commits.count)

        Merge options:
          1. Merge now
          2. Leave for later (keep worktree)
        """
    }
}

public enum MergeStrategy: String, Sendable {
    case squash
    case mergeCommit
    case rebase
}

public struct MergeOutcome: Sendable {
    public let merged: Bool
    public let cleanedUp: Bool
    public let message: String
    public let cleanupWarnings: [String]
}

public struct VerificationStepResult: Sendable {
    public let command: String
    public let passed: Bool
    public let output: String
}

public struct VerificationSummary: Sendable {
    public let allPassed: Bool
    public let results: [VerificationStepResult]
}

public struct DiffReviewArtifacts: Sendable {
    public let commitLog: String
    public let fullDiff: String
}
