// Sources/ToolSystem/Git/BranchNamer.swift
// Parses user messages and generates standardized branch names

import Foundation

public struct BranchNamer {
    /// Branch type enumeration
    public enum BranchType: String, Sendable {
        case feature
        case hotfix
        case chore
        
        var prefix: String { self.rawValue }
    }
    
    /// Parsed branch information
    public struct BranchInfo: Sendable {
        public let type: BranchType
        public let taskName: String
        public let branchName: String
        
        public init(type: BranchType, taskName: String) {
            self.type = type
            self.taskName = taskName
            
            let timestamp = DateFormatter.branchTimestamp()
            let sanitized = BranchNamer.sanitizeTaskName(taskName)
            self.branchName = "\(type.prefix)/\(timestamp)-\(sanitized)"
        }
    }
    
    /// Detect branch type from user message
    private static func detectBranchType(from message: String) -> BranchType {
        let lowercased = message.lowercased()
        
        // Check for explicit type keywords
        if lowercased.contains("hotfix") || lowercased.contains("fix bug") || lowercased.contains("emergency") {
            return .hotfix
        }
        
        if lowercased.contains("chore") || lowercased.contains("refactor") || lowercased.contains("cleanup") {
            return .chore
        }
        
        // Check for feature-like action verbs
        let actionVerbs = ["add", "implement", "create", "build", "develop", "feature", "enhance"]
        for verb in actionVerbs {
            if lowercased.contains(verb) {
                return .feature
            }
        }
        
        // Default to feature if uncertain
        return .feature
    }
    
    /// Extract task name from user message
    private static func extractTaskName(from message: String) -> String {
        // Take first 50-100 characters or first sentence
        let components = message.split(separator: "\n", maxSplits: 1)
        var firstLine = String(components.first ?? "")
        
        // Remove common prefixes
        let prefixes = ["feature: ", "hotfix: ", "chore: ", "feat: ", "fix: "]
        for prefix in prefixes {
            if firstLine.lowercased().hasPrefix(prefix) {
                firstLine = String(firstLine.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        
        // Limit length
        if firstLine.count > 60 {
            firstLine = String(firstLine.prefix(60))
            if let lastSpace = firstLine.lastIndex(of: " ") {
                firstLine = String(firstLine[..<lastSpace])
            }
        }
        
        return firstLine.trimmingCharacters(in: .whitespaces)
    }
    
    /// Sanitize task name for use in branch name
    public static func sanitizeTaskName(_ name: String) -> String {
        // Remove/replace invalid git branch characters
        let valid = name
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\-_/]", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        
        // Enforce max length
        if valid.count > 40 {
            return String(valid.prefix(40))
        }
        
        return valid
    }
    
    /// Parse user message and generate branch info
    public static func parse(userMessage: String) throws -> BranchInfo {
        guard !userMessage.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw GitError.invalidBranchName("Empty message")
        }
        
        let branchType = detectBranchType(from: userMessage)
        let taskName = extractTaskName(from: userMessage)
        
        guard !taskName.isEmpty else {
            throw GitError.invalidBranchName("Could not extract task name from message")
        }
        
        return BranchInfo(type: branchType, taskName: taskName)
    }
    
    /// Validate branch name format
    public static func isValidBranchName(_ name: String) -> Bool {
        // Format: [feature|hotfix|chore]/YYYYMMDD-task-name
        let pattern = "^(feature|hotfix|chore)/\\d{8}-[a-z0-9\\-]+$"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            return regex.firstMatch(in: name, range: range) != nil
        }
        return false
    }
}

// MARK: - Extension for date formatting
private extension DateFormatter {
    static func branchTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: Date())
    }
}
