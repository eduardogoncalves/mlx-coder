// Sources/ToolSystem/Git/GitError.swift
// Custom error type for git operations

import Foundation

public enum GitError: LocalizedError, Sendable {
    case repositoryNotInitialized
    case worktreeAlreadyExists(path: String)
    case worktreeNotFound(path: String)
    case failedToCreateWorktree(branchName: String, reason: String)
    case failedToSwitchWorktree(path: String, reason: String)
    case commitFailed(reason: String)
    case pushFailed(reason: String)
    case invalidBranchName(String)
    case notOnCorrectBranch(expected: String, actual: String)
    case remoteNotConfigured
    case stateFileNotFound
    case failedToReadState(reason: String)
    case failedToWriteState(reason: String)
    case gitCommandFailed(command: String, stderr: String)
    case invalidWorkspace(String)
    case nothingToCommit

    public var errorDescription: String? {
        switch self {
        case .repositoryNotInitialized:
            return "Git repository not initialized. Please run 'git init' first."
        case .worktreeAlreadyExists(let path):
            return "Worktree already exists at \(path)"
        case .worktreeNotFound(let path):
            return "Worktree not found at \(path)"
        case .failedToCreateWorktree(let name, let reason):
            return "Failed to create worktree for branch '\(name)': \(reason)"
        case .failedToSwitchWorktree(let path, let reason):
            return "Failed to switch to worktree '\(path)': \(reason)"
        case .commitFailed(let reason):
            return "Commit failed: \(reason)"
        case .pushFailed(let reason):
            return "Push failed: \(reason)"
        case .invalidBranchName(let name):
            return "Invalid branch name: '\(name)'. Expected format: [feature|hotfix|chore]/YYYYMMDD-task-name"
        case .notOnCorrectBranch(let expected, let actual):
            return "Expected to be on branch '\(expected)' but currently on '\(actual)'"
        case .remoteNotConfigured:
            return "No remote 'origin' configured in this repository"
        case .stateFileNotFound:
            return "Git state file not found"
        case .failedToReadState(let reason):
            return "Failed to read git state: \(reason)"
        case .failedToWriteState(let reason):
            return "Failed to write git state: \(reason)"
        case .gitCommandFailed(let command, let stderr):
            return "Git command failed: \(command)\nError: \(stderr)"
        case .invalidWorkspace(let path):
            return "Invalid workspace path: \(path)"
        case .nothingToCommit:
            return "Nothing to commit (working tree clean)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .repositoryNotInitialized:
            return "Initialize the repository with 'git init' before using git orchestration."
        case .worktreeAlreadyExists:
            return "Use an existing worktree or remove it with 'git worktree remove'."
        case .remoteNotConfigured:
            return "Configure a remote with 'git remote add origin <url>'."
        case .nothingToCommit:
            return "Make some changes to files before committing."
        default:
            return nil
        }
    }
}
