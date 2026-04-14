// Sources/ToolSystem/Git/GitService.swift
// High-level git operations for orchestration

import Foundation

public actor GitService {
    public struct WorktreeInfo: Sendable {
        public let path: String
        public let branch: String?
    }

    private let projectRoot: String
    
    public init(projectRoot: String) throws {
        let expanded = NSString(string: projectRoot).expandingTildeInPath
        let normalizedRoot: String
        if expanded.hasPrefix("/") {
            normalizedRoot = URL(filePath: expanded).standardized.path()
        } else {
            normalizedRoot = URL(filePath: FileManager.default.currentDirectoryPath)
                .appending(path: expanded)
                .standardized.path()
        }
        self.projectRoot = normalizedRoot
        
        // Validate project root exists
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: normalizedRoot, isDirectory: &isDir), isDir.boolValue else {
            throw GitError.invalidWorkspace(normalizedRoot)
        }
    }
    
    /// Check if git repository is initialized
    nonisolated public func isRepositoryInitialized() -> Bool {
        let gitDir = (projectRoot as NSString).appendingPathComponent(".git")
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: gitDir, isDirectory: &isDir) else {
            return false
        }
        // In linked worktrees, .git is a file that points to the common git dir.
        return true
    }
    
    /// Initialize git repository
    public func initializeRepository() throws -> String {
        let gitDir = (projectRoot as NSString).appendingPathComponent(".git")
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        guard !(fileManager.fileExists(atPath: gitDir, isDirectory: &isDir) && isDir.boolValue) else {
            return "Repository already initialized"
        }
        
        let output = try runGitCommand(["init"], cwd: projectRoot)
        _ = try runGitCommand(["config", "user.email", "agent@mlx-coder.local"], cwd: projectRoot)
        _ = try runGitCommand(["config", "user.name", "Native Agent"], cwd: projectRoot)
        
        // Create initial commit if there are files to commit
        let statusOutput = try runGitCommand(["status", "--porcelain"], cwd: projectRoot)
        if !statusOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = try runGitCommand(["add", "."], cwd: projectRoot)
            _ = try runGitCommand(["commit", "-m", "Initial commit by mlx-coder"], cwd: projectRoot)
        }
        
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Get current branch name
    public func getCurrentBranch(in workingDirectory: String? = nil) throws -> String {
        guard isRepositoryInitialized() else {
            throw GitError.repositoryNotInitialized
        }

        let cwd = resolveWorkingDirectory(workingDirectory)
        let output = try runGitCommand(["rev-parse", "--abbrev-ref", "HEAD"], cwd: cwd)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Check if repository has remote origin
    public func hasRemote() throws -> Bool {
        guard isRepositoryInitialized() else {
            return false
        }
        
        do {
            let output = try runGitCommand(["remote", "get-url", "origin"], cwd: projectRoot)
            let url = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return !url.isEmpty && !url.contains("fatal:")
        } catch {
            return false
        }
    }
    
    /// Get list of available branches
    public func listBranches() throws -> [String] {
        guard isRepositoryInitialized() else {
            throw GitError.repositoryNotInitialized
        }
        
        let output = try runGitCommand(["branch", "-a"], cwd: projectRoot)
        let branches = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.hasPrefix("* ") ? String($0.dropFirst(2)) : $0 }
        
        return branches
    }
    
    /// Create a new worktree for a branch
    public func createWorktree(branchName: String, fromBranch: String = "main") throws -> String {
        guard isRepositoryInitialized() else {
            throw GitError.repositoryNotInitialized
        }
        
        // Validate branch name format (accept both auto-generated and custom)
        guard BranchNamer.isValidBranchName(branchName) || BranchNamer.isValidCustomBranchName(branchName) else {
            throw GitError.invalidBranchName(branchName)
        }
        
        // Create worktree directory path (absolute path)
        let worktreeDir = (projectRoot as NSString).appendingPathComponent(".mlx-coder-work-\(UUID().uuidString.prefix(8))")
        
        do {
            // Create worktree with new branch based on fromBranch
            _ = try runGitCommand(
                ["worktree", "add", "-b", branchName, worktreeDir, fromBranch],
                cwd: projectRoot
            )
            // Return absolute path
            return URL(filePath: worktreeDir).standardized.path()
        } catch {
            throw GitError.failedToCreateWorktree(branchName: branchName, reason: error.localizedDescription)
        }
    }
    
    /// Switch to an existing worktree
    public func switchWorktree(path: String) throws {
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw GitError.worktreeNotFound(path: path)
        }
        
        // Validate it's a git worktree
        let gitDir = (path as NSString).appendingPathComponent(".git")
        guard fileManager.fileExists(atPath: gitDir) else {
            throw GitError.worktreeNotFound(path: path)
        }
    }
    
    /// Commit staged changes
    public func commit(message: String, in workingDirectory: String? = nil) throws -> String {
        guard isRepositoryInitialized() else {
            throw GitError.repositoryNotInitialized
        }
        
        guard !message.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw GitError.commitFailed(reason: "Commit message cannot be empty")
        }
        
        do {
            // Check if there are changes to commit
            let cwd = resolveWorkingDirectory(workingDirectory)
            let statusOutput = try runGitCommand(["status", "--porcelain"], cwd: cwd)
            guard !statusOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw GitError.nothingToCommit
            }
            
            // Stage all changes
            _ = try runGitCommand(["add", "-A"], cwd: cwd)
            
            // Commit
            let output = try runGitCommand(["commit", "-m", message], cwd: cwd)
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch GitError.nothingToCommit {
            throw GitError.nothingToCommit
        } catch {
            throw GitError.commitFailed(reason: error.localizedDescription)
        }
    }
    
    /// Push current branch to remote
    public func push(in workingDirectory: String? = nil) throws -> String {
        guard isRepositoryInitialized() else {
            throw GitError.repositoryNotInitialized
        }
        
        guard try hasRemote() else {
            throw GitError.remoteNotConfigured
        }
        
        do {
            let cwd = resolveWorkingDirectory(workingDirectory)
            let currentBranch = try getCurrentBranch(in: cwd)
            let output = try runGitCommand(
                ["push", "-u", "origin", currentBranch],
                cwd: cwd
            )
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw GitError.pushFailed(reason: error.localizedDescription)
        }
    }
    
    /// Get git log for current branch vs base branch
    public func getCommitsSince(baseBranch: String, in workingDirectory: String? = nil) throws -> [String] {
        guard isRepositoryInitialized() else {
            throw GitError.repositoryNotInitialized
        }

        let cwd = resolveWorkingDirectory(workingDirectory)
        let output = try runGitCommand(
            ["log", "\(baseBranch)..HEAD", "--pretty=format:%h %s"],
            cwd: cwd
        )
        
        let commits = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        
        return commits
    }

    /// Keep base branch up to date with origin when a remote exists.
    public func syncBaseBranch(_ baseBranch: String) throws -> String {
        guard try hasRemote() else {
            return "No remote configured - skipping '\(baseBranch)' sync"
        }

        do {
            _ = try runGitCommand(["checkout", baseBranch], cwd: projectRoot)
            let output = try runGitCommand(["pull", "--ff-only", "origin", baseBranch], cwd: projectRoot)
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw GitError.gitCommandFailed(
                command: "checkout/pull \(baseBranch)",
                stderr: error.localizedDescription
            )
        }
    }

    /// Return review log between base branch and HEAD.
    public func getCommitLogSince(baseBranch: String, in workingDirectory: String? = nil) throws -> String {
        guard isRepositoryInitialized() else {
            throw GitError.repositoryNotInitialized
        }

        let cwd = resolveWorkingDirectory(workingDirectory)
        let output = try runGitCommand(["log", "\(baseBranch)..HEAD", "--oneline"], cwd: cwd)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Return diff between base branch and HEAD.
    public func getDiff(baseBranch: String, in workingDirectory: String? = nil, filePath: String? = nil) throws -> String {
        guard isRepositoryInitialized() else {
            throw GitError.repositoryNotInitialized
        }

        let cwd = resolveWorkingDirectory(workingDirectory)
        var args = ["diff", "\(baseBranch)...HEAD"]
        if let filePath, !filePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args.append("--")
            args.append(filePath)
        }
        let output = try runGitCommand(args, cwd: cwd)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Merge branch into base branch using `--squash`.
    public func mergeSquash(baseBranch: String, sourceBranch: String, commitMessage: String) throws -> String {
        guard isRepositoryInitialized() else {
            throw GitError.repositoryNotInitialized
        }

        do {
            let baseCwd = try resolveWorktreePath(for: baseBranch) ?? projectRoot
            _ = try runGitCommand(["checkout", baseBranch], cwd: baseCwd)
            _ = try runGitCommand(["merge", "--squash", sourceBranch], cwd: baseCwd)
            let output = try runGitCommand(["commit", "-m", commitMessage], cwd: baseCwd)
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw GitError.mergeFailed(reason: error.localizedDescription)
        }
    }

    /// Merge branch into base branch preserving history.
    public func mergeNoFastForward(baseBranch: String, sourceBranch: String, mergeMessage: String) throws -> String {
        guard isRepositoryInitialized() else {
            throw GitError.repositoryNotInitialized
        }

        do {
            let baseCwd = try resolveWorktreePath(for: baseBranch) ?? projectRoot
            _ = try runGitCommand(["checkout", baseBranch], cwd: baseCwd)
            let output = try runGitCommand(["merge", "--no-ff", sourceBranch, "-m", mergeMessage], cwd: baseCwd)
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw GitError.mergeFailed(reason: error.localizedDescription)
        }
    }

    /// Rebase branch on base and fast-forward merge into base.
    public func rebaseAndFastForward(baseBranch: String, sourceBranch: String) throws -> String {
        guard isRepositoryInitialized() else {
            throw GitError.repositoryNotInitialized
        }

        do {
            let sourceCwd = try resolveWorktreePath(for: sourceBranch) ?? projectRoot
            let baseCwd = try resolveWorktreePath(for: baseBranch) ?? projectRoot

            _ = try runGitCommand(["checkout", sourceBranch], cwd: sourceCwd)
            _ = try runGitCommand(["rebase", baseBranch], cwd: sourceCwd)
            _ = try runGitCommand(["checkout", baseBranch], cwd: baseCwd)
            let output = try runGitCommand(["merge", "--ff-only", sourceBranch], cwd: baseCwd)
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw GitError.rebaseFailed(reason: error.localizedDescription)
        }
    }

    /// Remove an existing worktree path.
    public func removeWorktree(path: String) throws {
        do {
            _ = try runGitCommand(["worktree", "remove", path], cwd: projectRoot)
        } catch {
            throw GitError.cleanupFailed(reason: error.localizedDescription)
        }
    }

    /// Delete a local branch.
    public func deleteBranch(_ branchName: String) throws {
        do {
            _ = try runGitCommand(["branch", "-d", branchName], cwd: projectRoot)
        } catch {
            throw GitError.cleanupFailed(reason: error.localizedDescription)
        }
    }

    /// List active worktrees.
    public func listWorktrees() throws -> [String] {
        let output = try runGitCommand(["worktree", "list"], cwd: projectRoot)
        return output
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// List active worktrees with structured path/branch information.
    public func listWorktreeInfos() throws -> [WorktreeInfo] {
        let output = try runGitCommand(["worktree", "list", "--porcelain"], cwd: projectRoot)
        let blocks = output
            .split(separator: "\n\n")
            .map(String.init)

        var infos: [WorktreeInfo] = []
        for block in blocks {
            let lines = block
                .split(separator: "\n")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            guard let worktreeLine = lines.first(where: { $0.hasPrefix("worktree ") }) else {
                continue
            }
            let path = String(worktreeLine.dropFirst("worktree ".count))
            let branchLine = lines.first(where: { $0.hasPrefix("branch ") })
            let branchRef = branchLine.map { String($0.dropFirst("branch ".count)) }
            let branchName = branchRef.map { ref -> String in
                if ref.hasPrefix("refs/heads/") {
                    return String(ref.dropFirst("refs/heads/".count))
                }
                return ref
            }
            infos.append(WorktreeInfo(path: path, branch: branchName))
        }

        return infos
    }

    /// Prune stale worktree metadata.
    public func pruneWorktrees() throws {
        do {
            _ = try runGitCommand(["worktree", "prune"], cwd: projectRoot)
        } catch {
            throw GitError.cleanupFailed(reason: error.localizedDescription)
        }
    }

    /// Run verification command (e.g. lint/test/build) in the selected working directory.
    public func runVerification(command: String, in workingDirectory: String? = nil) throws -> String {
        let cwd = resolveWorkingDirectory(workingDirectory)
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", command]
        shell.currentDirectoryURL = URL(fileURLWithPath: cwd)

        let stdout = Pipe()
        let stderr = Pipe()
        shell.standardOutput = stdout
        shell.standardError = stderr

        try shell.run()
        shell.waitUntilExit()

        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let merged = (out + err).trimmingCharacters(in: .whitespacesAndNewlines)

        guard shell.terminationStatus == 0 else {
            throw GitError.gitCommandFailed(command: command, stderr: merged.isEmpty ? "Command failed" : merged)
        }

        return merged
    }
    
    /// Run a git command and return output
    private func runGitCommand(_ args: [String], cwd: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        
        try process.run()
        process.waitUntilExit()
        
        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
        
        guard process.terminationStatus == 0 else {
            throw GitError.gitCommandFailed(
                command: "git \(args.joined(separator: " "))",
                stderr: errorOutput.isEmpty ? "Unknown error" : errorOutput
            )
        }
        
        return output
    }

    private func resolveWorktreePath(for branch: String) throws -> String? {
        let infos = try listWorktreeInfos()
        guard let match = infos.first(where: { $0.branch == branch }) else {
            return nil
        }
        return URL(filePath: match.path).standardized.path()
    }

    private func resolveWorkingDirectory(_ workingDirectory: String?) -> String {
        guard let workingDirectory, !workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return projectRoot
        }

        let expanded = NSString(string: workingDirectory).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(filePath: expanded).standardized.path()
        }
        return URL(filePath: projectRoot).appending(path: expanded).standardized.path()
    }
}
