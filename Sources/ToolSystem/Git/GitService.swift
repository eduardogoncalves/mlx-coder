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

    /// Get list of local branches only.
    public func listLocalBranches() throws -> [String] {
        guard isRepositoryInitialized() else {
            throw GitError.repositoryNotInitialized
        }

        let output = try runGitCommand(["branch", "--format=%(refname:short)"], cwd: projectRoot)
        return output
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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

    /// Return working tree diff relative to HEAD in the selected working directory.
    public func getWorkingTreeDiff(in workingDirectory: String? = nil) throws -> String {
        guard isRepositoryInitialized() else {
            throw GitError.repositoryNotInitialized
        }

        let cwd = resolveWorkingDirectory(workingDirectory)
        let output = try runGitCommand(["diff", "HEAD"], cwd: cwd)
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
    public func deleteBranch(_ branchName: String, force: Bool = false) throws {
        do {
            let deleteFlag = force ? "-D" : "-d"
            _ = try runGitCommand(["branch", deleteFlag, branchName], cwd: projectRoot)
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
        // Use "-c" (not "-lc") so that login profiles (~/.zprofile, ~/.zshrc)
        // are never sourced. Combined with the scrubbed environment below this
        // prevents DYLD_*, LD_*, IFS, and other injected variables from
        // reaching the verification command (mirrors BashTool.safeEnvironment).
        shell.arguments = ["-c", command]
        shell.currentDirectoryURL = URL(fileURLWithPath: cwd)
        shell.environment = safeEnvironment()

        let stdout = Pipe()
        let stderr = Pipe()
        shell.standardOutput = stdout
        shell.standardError = stderr

        try shell.run()
        let (out, err) = Self.drainAndWait(process: shell, stdoutPipe: stdout, stderrPipe: stderr)
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
        // Git honours several sensitive env vars (GIT_EXEC_PATH, LD_PRELOAD,
        // DYLD_INSERT_LIBRARIES, etc.). Use a scrubbed environment that blocks
        // loader-injection variables while preserving the auth passthrough
        // (SSH agent socket, GIT_SSH*, askpass) that remote push/pull needs.
        process.environment = gitEnvironment()

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()
        let (output, errorOutput) = Self.drainAndWait(
            process: process,
            stdoutPipe: standardOutput,
            stderrPipe: standardError
        )

        guard process.terminationStatus == 0 else {
            throw GitError.gitCommandFailed(
                command: "git \(args.joined(separator: " "))",
                stderr: errorOutput.isEmpty ? "Unknown error" : errorOutput
            )
        }

        return output
    }

    /// Drain stdout and stderr pipes concurrently with the child process to
    /// avoid the pipe-buffer deadlock that occurs when a child writes more
    /// than ~16-64 KiB before exiting. Delegates to the shared `ProcessIO`
    /// helper used across the codebase.
    private static func drainAndWait(
        process: Process,
        stdoutPipe: Pipe,
        stderrPipe: Pipe
    ) -> (stdout: String, stderr: String) {
        return ProcessIO.drainAndWait(
            process: process,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe
        )
    }

    private func resolveWorktreePath(for branch: String) throws -> String? {
        let infos = try listWorktreeInfos()
        guard let match = infos.first(where: { $0.branch == branch }) else {
            return nil
        }
        return URL(filePath: match.path).standardized.path()
    }

    /// Returns a scrubbed, whitelisted environment for all child processes.
    ///
    /// Mirrors the isolation strategy used by BashTool.safeEnvironment.
    /// Starting from an empty dictionary ensures that no DYLD_*, LD_*, IFS,
    /// or other injected loader/shell variables leak into child processes.
    /// Only a minimal allow-list of keys is copied from the parent environment,
    /// then PATH is unconditionally replaced with a known-safe value so that
    /// git and shell built-ins can still be located without relying on
    /// attacker-controlled PATH entries.
    private func safeEnvironment() -> [String: String] {
        let parent = ProcessInfo.processInfo.environment
        let allowedKeys = ["PATH", "HOME", "USER", "LANG", "LC_ALL", "TERM"]

        // Start empty — guarantees no DYLD_*/LD_* bleed-through.
        var env: [String: String] = [:]
        for key in allowedKeys {
            if let value = parent[key] {
                env[key] = value
            }
        }

        // Override PATH with a known-safe set of directories regardless of
        // what the parent process had set.
        env["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

        return env
    }

    /// Environment for `git` subprocesses. Starts from the scrubbed base (no
    /// DYLD_*/LD_*/IFS bleed-through, safe PATH) and then re-adds the subset of
    /// parent variables that remote operations legitimately need — the SSH agent
    /// socket, SSH/askpass helpers, and user-set `GIT_*` configuration — so
    /// `push`/`pull`/`fetch` over SSH or credential-helper HTTPS keep working.
    /// None of the re-added keys can influence the dynamic loader, so the
    /// injection hardening from `safeEnvironment()` is preserved.
    private func gitEnvironment() -> [String: String] {
        var env = safeEnvironment()
        let parent = ProcessInfo.processInfo.environment

        // Auth/transport passthrough keys that are safe (not loader variables).
        let authKeys = [
            "SSH_AUTH_SOCK", "SSH_AGENT_PID", "SSH_ASKPASS", "DISPLAY",
            "GIT_SSH", "GIT_SSH_COMMAND", "GIT_ASKPASS", "GIT_TERMINAL_PROMPT",
        ]
        for key in authKeys {
            if let value = parent[key] {
                env[key] = value
            }
        }

        // Pass through user-set GIT_* configuration (author/committer identity,
        // config overrides, etc.) except GIT_EXEC_PATH, which can redirect git
        // to attacker-supplied helper binaries.
        for (key, value) in parent where key.hasPrefix("GIT_") && key != "GIT_EXEC_PATH" {
            env[key] = value
        }

        return env
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
