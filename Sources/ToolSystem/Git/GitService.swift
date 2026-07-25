// Sources/ToolSystem/Git/GitService.swift
// High-level git operations for orchestration

import Foundation

public actor GitService {
    public struct WorktreeInfo: Sendable {
        public let path: String
        public let branch: String?
    }

    /// Wall-clock timeout applied to every `git` subprocess invocation
    /// (`runGitCommand`). Without a deadline, a stalled network `push`/
    /// `pull`/`fetch` against a black-holed remote blocks this actor —
    /// and therefore every other queued `GitService` call — forever.
    ///
    /// Not `private`: it's used as a default-parameter value on `public`
    /// methods, and a default-value expression must be at least as visible
    /// as the parameter it defaults.
    public static let gitCommandTimeout: TimeInterval = 120

    /// Wall-clock timeout applied to `runVerification` (arbitrary lint/
    /// build/test commands). Longer than `gitCommandTimeout` since builds
    /// legitimately take longer than a git round-trip, but still bounded so
    /// a hung verification command can't wedge this actor indefinitely.
    public static let verificationCommandTimeout: TimeInterval = 300

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
    public func initializeRepository() async throws -> String {
        let gitDir = (projectRoot as NSString).appendingPathComponent(".git")
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        guard !(fileManager.fileExists(atPath: gitDir, isDirectory: &isDir) && isDir.boolValue) else {
            return "Repository already initialized"
        }

        let output = try await runGitCommand(["init"], cwd: projectRoot)
        _ = try await runGitCommand(["config", "user.email", "agent@mlx-coder.local"], cwd: projectRoot)
        _ = try await runGitCommand(["config", "user.name", "Native Agent"], cwd: projectRoot)

        // Create initial commit if there are files to commit
        let statusOutput = try await runGitCommand(["status", "--porcelain"], cwd: projectRoot)
        if !statusOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = try await runGitCommand(["add", "."], cwd: projectRoot)
            _ = try await runGitCommand(["commit", "-m", "Initial commit by mlx-coder"], cwd: projectRoot)
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Get current branch name
    public func getCurrentBranch(in workingDirectory: String? = nil) async throws -> String {
        guard isRepositoryInitialized() else {
            throw GitError.repositoryNotInitialized
        }

        let cwd = resolveWorkingDirectory(workingDirectory)
        let output = try await runGitCommand(["rev-parse", "--abbrev-ref", "HEAD"], cwd: cwd)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Check if repository has remote origin
    public func hasRemote() async throws -> Bool {
        guard isRepositoryInitialized() else {
            return false
        }

        do {
            let output = try await runGitCommand(["remote", "get-url", "origin"], cwd: projectRoot)
            let url = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return !url.isEmpty && !url.contains("fatal:")
        } catch {
            return false
        }
    }

    /// Get list of available branches
    public func listBranches() async throws -> [String] {
        guard isRepositoryInitialized() else {
            throw GitError.repositoryNotInitialized
        }

        let output = try await runGitCommand(["branch", "-a"], cwd: projectRoot)
        let branches = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.hasPrefix("* ") ? String($0.dropFirst(2)) : $0 }

        return branches
    }

    /// Get list of local branches only.
    public func listLocalBranches() async throws -> [String] {
        guard isRepositoryInitialized() else {
            throw GitError.repositoryNotInitialized
        }

        let output = try await runGitCommand(["branch", "--format=%(refname:short)"], cwd: projectRoot)
        return output
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Create a new worktree for a branch
    public func createWorktree(branchName: String, fromBranch: String = "main") async throws -> String {
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
            _ = try await runGitCommand(
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
    public func commit(message: String, in workingDirectory: String? = nil) async throws -> String {
        guard isRepositoryInitialized() else {
            throw GitError.repositoryNotInitialized
        }

        guard !message.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw GitError.commitFailed(reason: "Commit message cannot be empty")
        }

        do {
            // Check if there are changes to commit
            let cwd = resolveWorkingDirectory(workingDirectory)
            let statusOutput = try await runGitCommand(["status", "--porcelain"], cwd: cwd)
            guard !statusOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw GitError.nothingToCommit
            }

            // Stage all changes
            _ = try await runGitCommand(["add", "-A"], cwd: cwd)

            // Commit
            let output = try await runGitCommand(["commit", "-m", message], cwd: cwd)
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch GitError.nothingToCommit {
            throw GitError.nothingToCommit
        } catch {
            throw GitError.commitFailed(reason: error.localizedDescription)
        }
    }

    /// Push current branch to remote
    public func push(in workingDirectory: String? = nil) async throws -> String {
        guard isRepositoryInitialized() else {
            throw GitError.repositoryNotInitialized
        }

        guard try await hasRemote() else {
            throw GitError.remoteNotConfigured
        }

        do {
            let cwd = resolveWorkingDirectory(workingDirectory)
            let currentBranch = try await getCurrentBranch(in: cwd)
            let output = try await runGitCommand(
                ["push", "-u", "origin", currentBranch],
                cwd: cwd
            )
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw GitError.pushFailed(reason: error.localizedDescription)
        }
    }

    /// Get git log for current branch vs base branch
    public func getCommitsSince(baseBranch: String, in workingDirectory: String? = nil) async throws -> [String] {
        guard isRepositoryInitialized() else {
            throw GitError.repositoryNotInitialized
        }

        let cwd = resolveWorkingDirectory(workingDirectory)
        let output = try await runGitCommand(
            ["log", "\(baseBranch)..HEAD", "--pretty=format:%h %s"],
            cwd: cwd
        )

        let commits = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return commits
    }

    /// Keep base branch up to date with origin when a remote exists.
    public func syncBaseBranch(_ baseBranch: String) async throws -> String {
        guard try await hasRemote() else {
            return "No remote configured - skipping '\(baseBranch)' sync"
        }

        do {
            _ = try await runGitCommand(["checkout", baseBranch], cwd: projectRoot)
            let output = try await runGitCommand(["pull", "--ff-only", "origin", baseBranch], cwd: projectRoot)
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw GitError.gitCommandFailed(
                command: "checkout/pull \(baseBranch)",
                stderr: error.localizedDescription
            )
        }
    }

    /// Return review log between base branch and HEAD.
    public func getCommitLogSince(baseBranch: String, in workingDirectory: String? = nil) async throws -> String {
        guard isRepositoryInitialized() else {
            throw GitError.repositoryNotInitialized
        }

        let cwd = resolveWorkingDirectory(workingDirectory)
        let output = try await runGitCommand(["log", "\(baseBranch)..HEAD", "--oneline"], cwd: cwd)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Return diff between base branch and HEAD.
    public func getDiff(baseBranch: String, in workingDirectory: String? = nil, filePath: String? = nil) async throws -> String {
        guard isRepositoryInitialized() else {
            throw GitError.repositoryNotInitialized
        }

        let cwd = resolveWorkingDirectory(workingDirectory)
        var args = ["diff", "\(baseBranch)...HEAD"]
        if let filePath, !filePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args.append("--")
            args.append(filePath)
        }
        let output = try await runGitCommand(args, cwd: cwd)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Return working tree diff relative to HEAD in the selected working directory.
    public func getWorkingTreeDiff(in workingDirectory: String? = nil) async throws -> String {
        guard isRepositoryInitialized() else {
            throw GitError.repositoryNotInitialized
        }

        let cwd = resolveWorkingDirectory(workingDirectory)
        let output = try await runGitCommand(["diff", "HEAD"], cwd: cwd)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Merge branch into base branch using `--squash`.
    public func mergeSquash(baseBranch: String, sourceBranch: String, commitMessage: String) async throws -> String {
        guard isRepositoryInitialized() else {
            throw GitError.repositoryNotInitialized
        }

        do {
            let baseCwd = try await resolveWorktreePath(for: baseBranch) ?? projectRoot
            _ = try await runGitCommand(["checkout", baseBranch], cwd: baseCwd)
            _ = try await runGitCommand(["merge", "--squash", sourceBranch], cwd: baseCwd)
            let output = try await runGitCommand(["commit", "-m", commitMessage], cwd: baseCwd)
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw GitError.mergeFailed(reason: error.localizedDescription)
        }
    }

    /// Merge branch into base branch preserving history.
    public func mergeNoFastForward(baseBranch: String, sourceBranch: String, mergeMessage: String) async throws -> String {
        guard isRepositoryInitialized() else {
            throw GitError.repositoryNotInitialized
        }

        do {
            let baseCwd = try await resolveWorktreePath(for: baseBranch) ?? projectRoot
            _ = try await runGitCommand(["checkout", baseBranch], cwd: baseCwd)
            let output = try await runGitCommand(["merge", "--no-ff", sourceBranch, "-m", mergeMessage], cwd: baseCwd)
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw GitError.mergeFailed(reason: error.localizedDescription)
        }
    }

    /// Rebase branch on base and fast-forward merge into base.
    public func rebaseAndFastForward(baseBranch: String, sourceBranch: String) async throws -> String {
        guard isRepositoryInitialized() else {
            throw GitError.repositoryNotInitialized
        }

        do {
            let sourceCwd = try await resolveWorktreePath(for: sourceBranch) ?? projectRoot
            let baseCwd = try await resolveWorktreePath(for: baseBranch) ?? projectRoot

            _ = try await runGitCommand(["checkout", sourceBranch], cwd: sourceCwd)
            _ = try await runGitCommand(["rebase", baseBranch], cwd: sourceCwd)
            _ = try await runGitCommand(["checkout", baseBranch], cwd: baseCwd)
            let output = try await runGitCommand(["merge", "--ff-only", sourceBranch], cwd: baseCwd)
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw GitError.rebaseFailed(reason: error.localizedDescription)
        }
    }

    /// Remove an existing worktree path.
    public func removeWorktree(path: String) async throws {
        do {
            _ = try await runGitCommand(["worktree", "remove", path], cwd: projectRoot)
        } catch {
            throw GitError.cleanupFailed(reason: error.localizedDescription)
        }
    }

    /// Delete a local branch.
    public func deleteBranch(_ branchName: String, force: Bool = false) async throws {
        do {
            let deleteFlag = force ? "-D" : "-d"
            _ = try await runGitCommand(["branch", deleteFlag, branchName], cwd: projectRoot)
        } catch {
            throw GitError.cleanupFailed(reason: error.localizedDescription)
        }
    }

    /// List active worktrees.
    public func listWorktrees() async throws -> [String] {
        let output = try await runGitCommand(["worktree", "list"], cwd: projectRoot)
        return output
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// List active worktrees with structured path/branch information.
    public func listWorktreeInfos() async throws -> [WorktreeInfo] {
        let output = try await runGitCommand(["worktree", "list", "--porcelain"], cwd: projectRoot)
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
    public func pruneWorktrees() async throws {
        do {
            _ = try await runGitCommand(["worktree", "prune"], cwd: projectRoot)
        } catch {
            throw GitError.cleanupFailed(reason: error.localizedDescription)
        }
    }

    /// Run verification command (e.g. lint/test/build) in the selected working directory.
    public func runVerification(
        command: String,
        in workingDirectory: String? = nil,
        timeout: TimeInterval = GitService.verificationCommandTimeout
    ) async throws -> String {
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

        let startedAt = Date()
        ToolTimingLog.log("verification start: \(command) (cwd=\(cwd))")

        try shell.run()
        // Off-pool wait (see `runGitCommand`) plus a hard deadline — this
        // actor must never block indefinitely on an arbitrary verification
        // command (e.g. a test that itself makes a network call and hangs).
        let (out, err, timedOut) = await ProcessIO.drainAndWaitAsync(
            process: shell,
            stdoutPipe: stdout,
            stderrPipe: stderr,
            timeout: timeout
        )
        let merged = (out + err).trimmingCharacters(in: .whitespacesAndNewlines)

        let elapsed = Date().timeIntervalSince(startedAt)
        ToolTimingLog.log("verification end: \(command) elapsed=\(String(format: "%.2f", elapsed))s timedOut=\(timedOut)")

        if timedOut {
            throw GitError.gitCommandFailed(
                command: command,
                stderr: "Timed out after \(Int(timeout))s running verification command"
            )
        }

        guard shell.terminationStatus == 0 else {
            throw GitError.gitCommandFailed(command: command, stderr: merged.isEmpty ? "Command failed" : merged)
        }

        return merged
    }

    /// Run a git command and return output.
    ///
    /// Every invocation is bounded by `timeout` (default `gitCommandTimeout`)
    /// and waits off the cooperative-pool thread (`ProcessIO.drainAndWaitDataAsync`)
    /// so a stalled network operation (`push`/`pull`/`fetch` against a
    /// black-holed remote) can neither wedge this actor forever nor starve
    /// other components that rely on `Task.sleep`-based timeouts. On
    /// expiry the child is killed (SIGTERM, then SIGKILL) — best-effort as
    /// a process-group kill (see `ProcessIO.makeProcessGroupLeader`) so
    /// transport helper children (e.g. git's http/askpass helpers) die too.
    private func runGitCommand(
        _ args: [String],
        cwd: String,
        timeout: TimeInterval = GitService.gitCommandTimeout
    ) async throws -> String {
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

        let commandDescription = "git \(args.joined(separator: " "))"
        let startedAt = Date()
        ToolTimingLog.log("git start: \(commandDescription) (cwd=\(cwd))")

        try process.run()
        // Best-effort process-group leader so a timeout kill can reach
        // transport helper children, not just the tracked git PID.
        let isGroupLeader = ProcessIO.makeProcessGroupLeader(process)

        let (outputData, errorData, timedOut) = await ProcessIO.drainAndWaitDataAsync(
            process: process,
            stdoutPipe: standardOutput,
            stderrPipe: standardError,
            timeout: timeout,
            killProcessGroup: isGroupLeader
        )

        let elapsed = Date().timeIntervalSince(startedAt)
        ToolTimingLog.log("git end: \(commandDescription) elapsed=\(String(format: "%.2f", elapsed))s timedOut=\(timedOut)")

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        if timedOut {
            throw GitError.gitCommandFailed(
                command: commandDescription,
                stderr: "Timed out after \(Int(timeout))s waiting for '\(commandDescription)' (likely a stalled network operation)"
            )
        }

        guard process.terminationStatus == 0 else {
            throw GitError.gitCommandFailed(
                command: commandDescription,
                stderr: errorOutput.isEmpty ? "Unknown error" : errorOutput
            )
        }

        return output
    }

    private func resolveWorktreePath(for branch: String) async throws -> String? {
        let infos = try await listWorktreeInfos()
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

        // Harden git's network transports against a stalled/black-holed
        // remote: abort the transfer if throughput drops below ~1000
        // bytes/sec for more than 15s, and never block waiting on a
        // credential prompt (which would hang this actor exactly like a
        // stalled TCP connection — there's no TTY to prompt on here anyway).
        // These are defaults; a user-set `GIT_*` value re-added below still
        // wins, so explicit configuration is never clobbered.
        env["GIT_HTTP_LOW_SPEED_LIMIT"] = "1000"
        env["GIT_HTTP_LOW_SPEED_TIME"] = "15"
        env["GIT_TERMINAL_PROMPT"] = "0"

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
