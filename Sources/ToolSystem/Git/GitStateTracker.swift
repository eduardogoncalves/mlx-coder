// Sources/ToolSystem/Git/GitStateTracker.swift
// Tracks and persists git state for orchestration sessions

import Foundation

/// Represents the persistent state of a git orchestration session
public struct GitSessionState: Codable, Sendable {
    public var projectRoot: String
    public var worktreeRoot: String?
    public var branchName: String?
    public var baseBranch: String?
    public var commitsThisSession: [String] = []
    public var filesModifiedThisSession: [String] = []
    public var gitInitialized: Bool = false
    public var hasRemote: Bool = false
    public var timestamp: TimeInterval = Date().timeIntervalSince1970
    
    public init(projectRoot: String) {
        self.projectRoot = projectRoot
    }
}

/// Tracks and persists git state across agent sessions
public actor GitStateTracker {
    private var state: GitSessionState
    private let stateFilePath: String
    
    public init(projectRoot: String) throws {
        self.state = GitSessionState(projectRoot: projectRoot)
        
        // Determine state file path - store in .mlx-coder directory
        let mlxCoderDir = (projectRoot as NSString).appendingPathComponent(".mlx-coder")
        self.stateFilePath = (mlxCoderDir as NSString).appendingPathComponent("git-state.json")
    }
    
    /// Load state from file if it exists (must be called after init)
    public func loadState() throws {
        let fileManager = FileManager.default
        
        if fileManager.fileExists(atPath: stateFilePath) {
            let data = try Data(contentsOf: URL(fileURLWithPath: stateFilePath))
            let decoder = JSONDecoder()
            self.state = try decoder.decode(GitSessionState.self, from: data)
        }
    }
    
    /// Save state to file
    public func saveState() throws {
        let fileManager = FileManager.default
        let url = URL(fileURLWithPath: stateFilePath)
        let directory = url.deletingLastPathComponent()
        
        // Create .mlx-coder directory if needed
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: url)
    }
    
    /// Get current git session state
    public func getState() -> GitSessionState {
        state
    }
    
    /// Set worktree root path
    public func setWorktreeRoot(_ path: String) {
        state.worktreeRoot = path
    }
    
    /// Set current branch name
    public func setBranchName(_ name: String) {
        state.branchName = name
    }
    
    /// Set base branch
    public func setBaseBranch(_ name: String) {
        state.baseBranch = name
    }
    
    /// Mark git as initialized
    public func markGitInitialized(_ initialized: Bool = true) {
        state.gitInitialized = initialized
    }
    
    /// Mark if remote exists
    public func setHasRemote(_ hasRemote: Bool) {
        state.hasRemote = hasRemote
    }
    
    /// Record a commit message
    public func recordCommit(message: String) {
        state.commitsThisSession.append(message)
    }
    
    /// Record modified file
    public func recordModifiedFile(_ path: String) {
        if !state.filesModifiedThisSession.contains(path) {
            state.filesModifiedThisSession.append(path)
        }
    }
    
    /// Record multiple modified files
    public func recordModifiedFiles(_ paths: [String]) {
        for path in paths {
            recordModifiedFile(path)
        }
    }
    
    /// Get all commits made this session
    public func getSessionCommits() -> [String] {
        state.commitsThisSession
    }
    
    /// Get all files modified this session
    public func getModifiedFiles() -> [String] {
        state.filesModifiedThisSession
    }
    
    /// Reset state for new task
    public func resetState(keepProjectRoot: Bool = true) {
        let projectRoot = state.projectRoot
        state = GitSessionState(projectRoot: projectRoot)
        state.gitInitialized = keepProjectRoot
    }
    
    /// Check if worktree is initialized
    public func isWorktreeInitialized() -> Bool {
        state.worktreeRoot != nil && !state.worktreeRoot!.isEmpty
    }
    
    /// Get number of commits made this session
    public func getCommitCount() -> Int {
        state.commitsThisSession.count
    }
}
