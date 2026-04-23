// Sources/ToolSystem/Git/BranchNamer.swift
// Parses user messages and generates standardized branch names

import Foundation

public struct BranchNamer {
    /// Branch type enumeration
    public enum BranchType: String, Sendable {
        case feature
        case fix
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
            let sanitized = BranchNamer.sanitizeTaskName(taskName)
            self.branchName = "\(type.prefix)/\(sanitized)"
        }
    }
    
    /// Detect branch type from user message
    private static func detectBranchType(from message: String) -> BranchType {
        let lowercased = message.lowercased()
        
        // Check for explicit type keywords
        if lowercased.contains("hotfix") || lowercased.contains("fix bug") || lowercased.contains("emergency") || lowercased.contains("fix ") {
            return .fix
        }
        
        if lowercased.contains("chore") || lowercased.contains("refactor") || lowercased.contains("cleanup") {
            return .chore
        }

        if lowercased.contains("corrig") || lowercased.contains("bug") || lowercased.contains("erro") {
            return .fix
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
        let normalized = normalizeMessage(message)
        if normalized.isEmpty {
            return "update-task"
        }

        let tokens = normalized
            .split(separator: " ")
            .map(String.init)
            .map { token in
                token
                    .folding(options: .diacriticInsensitive, locale: .current)
                    .lowercased()
                    .replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)
            }
            .filter { !$0.isEmpty }

        if tokens.isEmpty {
            return "update-task"
        }

        let allowShortWords: Set<String> = ["ui", "ux", "db", "ci", "cd", "api", "sdk", "lsp", "cli", "git"]
        let stopwords: Set<String> = [
            "a", "as", "o", "os", "de", "da", "do", "das", "dos", "e", "em", "no", "na", "nos", "nas", "para", "por",
            "com", "sem", "que", "se", "uma", "um", "uns", "umas", "ao", "aos", "ou", "como", "mais", "menos", "muito",
            "muita", "muitos", "muitas", "sobre", "entre", "todo", "toda", "todos", "todas", "isso", "essa", "esse",
            "the", "and", "for", "with", "from", "into", "onto", "your", "this", "that", "these", "those", "is", "are",
            "to", "of", "in", "on", "at", "by", "be", "it", "or", "an", "a", "as", "now", "also", "before", "after",
            "etapa", "etapas", "passo", "passos", "guia", "completo", "workflow", "task", "tarefa", "fazer", "make",
            "vamos", "melhorar", "implementar", "implementando", "adicionar", "adiciona", "adicionando"
        ]
        let signalWords: Set<String> = [
            "auth", "authentication", "jwt", "token", "worktree", "merge", "rebase", "squash", "cleanup", "branch",
            "pipeline", "test", "tests", "lint", "build", "commit", "commits", "approval", "review", "diff", "main",
            "release", "version", "bug", "fix", "error", "perf", "performance", "security", "middleware", "api", "cli",
            "swift", "xcode", "mlx", "coder", "git", "chore", "feature", "docs"
        ]

        var scored: [(token: String, score: Int, index: Int)] = []
        for (index, token) in tokens.enumerated() {
            if stopwords.contains(token) { continue }
            if token.count < 3 && !allowShortWords.contains(token) { continue }
            if token.allSatisfy({ $0.isNumber }) { continue }

            var score = 10
            score += max(0, 10 - index) // terms near the start tend to be the task headline
            if signalWords.contains(token) { score += 8 }
            if token.count >= 5 && token.count <= 14 { score += 3 }
            scored.append((token: token, score: score, index: index))
        }

        if scored.isEmpty {
            return "update-task"
        }

        // Keep high-value words while preserving original order.
        let selectedSet = Set(
            scored
                .sorted { lhs, rhs in
                    if lhs.score == rhs.score { return lhs.index < rhs.index }
                    return lhs.score > rhs.score
                }
                .prefix(6)
                .map(\.token)
        )

        var ordered: [String] = []
        for token in tokens where selectedSet.contains(token) {
            if !ordered.contains(token) {
                ordered.append(token)
            }
            if ordered.count == 5 { break }
        }

        if ordered.isEmpty {
            return "update-task"
        }

        return ordered.joined(separator: "-")
    }
    
    /// Sanitize task name for use in branch name
    public static func sanitizeTaskName(_ name: String) -> String {
        // Remove/replace invalid git branch characters
        let valid = name
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\-]", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        
        // Enforce max length
        if valid.count > 40 {
            return String(valid.prefix(40))
        }
        
        return valid
    }

    private static func normalizeMessage(_ message: String) -> String {
        var text = message

        // Remove markdown code blocks to avoid path/command noise.
        text = text.replacingOccurrences(
            of: "```[\\s\\S]*?```",
            with: " ",
            options: .regularExpression
        )

        // Remove inline code and URLs.
        text = text.replacingOccurrences(of: "`[^`]*`", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "https?://\\S+", with: " ", options: .regularExpression)

        // Replace separators with spaces and collapse whitespace.
        text = text.replacingOccurrences(of: "[\\n\\r\\t/_]", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "[^\\p{L}\\p{N} -]", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let modernPattern = "^(feature|fix|chore)/[a-z0-9][a-z0-9\\-]{0,98}$"
        let legacyPattern = "^(feature|hotfix|chore)/\\d{8}-[a-z0-9\\-]+$"

        func matches(_ pattern: String) -> Bool {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            return regex.firstMatch(in: name, range: range) != nil
        }

        return matches(modernPattern) || matches(legacyPattern)
    }
    
    /// Validate custom branch name (more permissive than auto-generated names)
    public static func isValidCustomBranchName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        
        // Check length limits
        if trimmed.count > 100 || trimmed.count < 1 { return false }
        
        // Check for invalid patterns
        if trimmed.hasPrefix("-") || trimmed.hasSuffix("-") { return false }
        if trimmed.contains("..") { return false }
        if trimmed.contains("//") { return false }
        
        // Must contain only valid git branch characters
        // Git allows: letters, numbers, . - _ /
        let validPattern = "^[a-zA-Z0-9][a-zA-Z0-9._/-]*$"
        if let regex = try? NSRegularExpression(pattern: validPattern) {
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            if regex.firstMatch(in: trimmed, range: range) == nil {
                return false
            }
        } else {
            return false
        }
        
        // Check for git reserved names
        let reserved = [".", "..", "CON", "PRN", "AUX", "NUL", "COM1", "LPT1"]
        if reserved.contains(trimmed) { return false }
        
        return true
    }
}
