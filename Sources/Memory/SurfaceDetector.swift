// Sources/Memory/SurfaceDetector.swift
// Infers the current "surface" (subsystem) from workspace paths and detects git branch.

import Foundation

/// Detects the current surface (subsystem) and git branch for context-aware memory restore.
public enum SurfaceDetector {
    
    /// Detect the current surface from workspace path and recent files.
    /// Returns a simple label like "tests", "server", "ios", "docs", "scripts", etc.
    public static func detectSurface(workspacePath: String, recentFiles: [String] = []) -> String? {
        let allPaths = [workspacePath] + recentFiles
        
        // Count occurrences of each surface keyword in paths
        var surfaceScores: [String: Int] = [:]
        
        for path in allPaths {
            let lowercased = path.lowercased()
            
            // Tests
            if lowercased.contains("/tests/") || lowercased.contains("/test/") || 
               lowercased.contains("spec") || lowercased.hasSuffix("test.swift") ||
               lowercased.hasSuffix("tests.swift") {
                surfaceScores["tests", default: 0] += 1
            }
            
            // Server/Backend
            if lowercased.contains("/server") || lowercased.contains("/backend") ||
               lowercased.contains("/api") {
                surfaceScores["server", default: 0] += 1
            }
            
            // iOS
            if lowercased.contains("/ios") || lowercased.contains("uikit") ||
               lowercased.contains("swiftui") {
                surfaceScores["ios", default: 0] += 1
            }
            
            // macOS
            if lowercased.contains("/macos") || lowercased.contains("appkit") {
                surfaceScores["macos", default: 0] += 1
            }
            
            // Docs
            if lowercased.contains("/docs") || lowercased.contains("/documentation") ||
               lowercased.hasSuffix(".md") {
                surfaceScores["docs", default: 0] += 1
            }
            
            // Scripts/Build
            if lowercased.contains("/scripts") || lowercased.contains("/build") ||
               lowercased.hasSuffix(".sh") {
                surfaceScores["scripts", default: 0] += 1
            }
            
            // CLI
            if lowercased.contains("/cli") || lowercased.contains("command") {
                surfaceScores["cli", default: 0] += 1
            }
            
            // Core/Engine
            if lowercased.contains("/core") || lowercased.contains("/engine") {
                surfaceScores["core", default: 0] += 1
            }
        }
        
        // Return the surface with the highest score, if any
        return surfaceScores.max(by: { $0.value < $1.value })?.key
    }
    
    /// Get the current git branch for the given workspace.
    /// Returns nil if not a git repo or on detached HEAD.
    public static func currentBranch(in workspacePath: String) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", workspacePath, "rev-parse", "--abbrev-ref", "HEAD"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe() // Discard stderr
        
        do {
            try process.run()
            
            // Set a timeout of 2 seconds
            let timeoutDate = Date().addingTimeInterval(2.0)
            while process.isRunning && Date() < timeoutDate {
                Thread.sleep(forTimeInterval: 0.01)
            }
            
            if process.isRunning {
                process.terminate()
                return nil
            }
            
            process.waitUntilExit()
            
            guard process.terminationStatus == 0 else {
                return nil
            }
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Filter out "HEAD" (detached HEAD state)
            if let branch = output, !branch.isEmpty, branch != "HEAD" {
                return branch
            }
            
            return nil
        } catch {
            return nil
        }
    }
}
