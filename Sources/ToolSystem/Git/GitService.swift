// Sources/ToolSystem/Git/GitService.swift
// High-level git operations for orchestration

import Foundation

public actor GitService {
    private let projectRoot: String
    
    public init(projectRoot: String) throws {
        self.projectRoot = projectRoot
        
        // Validate project root exists
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: projectRoot, isDirectory: &isDir), isDir.boolValue else {
            throw GitError.invalidWorkspace(projectRoot)
        }
    }
    
    /// Check if git repository is initialized
    nonisolated public func isRepositoryInitialized() -> Bool {
        let gitDir = (projectRoot as NSString).appendingPathComponent(".git")
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: gitDir, isDirectory: &isDir) && isDir.boolValue
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
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Get current branch name
    public func getCurrentBranch() throws -> String {
        guard isRepositoryInitialized() else {
            throw GitError.repositoryNotInitialized
        }
        
        let output = try runGitCommand(["rev-parse", "--abbrev-ref", "HEAD"], cwd: projectRoot)
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
        
        // Validate branch name format
        guard BranchNamer.isValidBranchName(branchName) else {
            throw GitError.invalidBranchName(branchName)
        }
        
        // Create worktree directory path
        let worktreeDir = (projectRoot as NSString).appendingPathComponent(".mlx-coder-work-\(UUID().uuidString.prefix(8))")
        
        do {
            // Create worktree with new branch based on fromBranch
            _ = try runGitCommand(
                ["worktree", "add", "-b", branchName, worktreeDir, fromBranch],
                cwd: projectRoot
            )
            return worktreeDir
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
    public func commit(message: String) throws -> String {
        guard isRepositoryInitialized() else {
            throw GitError.repositoryNotInitialized
        }
        
        guard !message.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw GitError.commitFailed(reason: "Commit message cannot be empty")
        }
        
        do {
            // Check if there are changes to commit
            let statusOutput = try runGitCommand(["status", "--porcelain"], cwd: projectRoot)
            guard !statusOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw GitError.nothingToCommit
            }
            
            // Stage all changes
            _ = try runGitCommand(["add", "-A"], cwd: projectRoot)
            
            // Commit
            let output = try runGitCommand(["commit", "-m", message], cwd: projectRoot)
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch GitError.nothingToCommit {
            throw GitError.nothingToCommit
        } catch {
            throw GitError.commitFailed(reason: error.localizedDescription)
        }
    }
    
    /// Push current branch to remote
    public func push() throws -> String {
        guard isRepositoryInitialized() else {
            throw GitError.repositoryNotInitialized
        }
        
        guard try hasRemote() else {
            throw GitError.remoteNotConfigured
        }
        
        do {
            let currentBranch = try getCurrentBranch()
            let output = try runGitCommand(
                ["push", "-u", "origin", currentBranch],
                cwd: projectRoot
            )
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw GitError.pushFailed(reason: error.localizedDescription)
        }
    }
    
    /// Get git log for current branch vs base branch
    public func getCommitsSince(baseBranch: String) throws -> [String] {
        guard isRepositoryInitialized() else {
            throw GitError.repositoryNotInitialized
        }
        
        let output = try runGitCommand(
            ["log", "\(baseBranch)..HEAD", "--pretty=format:%h %s"],
            cwd: projectRoot
        )
        
        let commits = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        
        return commits
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
}
