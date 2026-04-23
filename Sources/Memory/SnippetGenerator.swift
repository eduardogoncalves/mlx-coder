// Sources/Memory/SnippetGenerator.swift
// Generates work summaries from stored knowledge entries.

import Foundation

/// Generates formatted work summaries from knowledge entries.
public enum SnippetGenerator {
    
    public enum OutputFormat {
        case markdown
        case standup
        case json
    }
    
    public enum TimeWindow {
        case today
        case week
        case all
        
        var startDate: Date {
            let calendar = Calendar.current
            let now = Date()
            
            switch self {
            case .today:
                return calendar.startOfDay(for: now)
            case .week:
                return calendar.date(byAdding: .day, value: -7, to: now) ?? now
            case .all:
                return Date.distantPast
            }
        }
    }
    
    /// Generate a work summary for the given time window.
    public static func generate(
        from store: KnowledgeStore,
        projectRoot: String,
        window: TimeWindow,
        format: OutputFormat
    ) async throws -> String {
        let entries = try await store.list(projectRoot: projectRoot, limit: 500)
        let filtered = entries.filter { $0.createdAt >= window.startDate }
        
        switch format {
        case .markdown:
            return generateMarkdown(entries: filtered)
        case .standup:
            return generateStandup(entries: filtered)
        case .json:
            return try generateJSON(entries: filtered)
        }
    }
    
    private static func generateMarkdown(entries: [KnowledgeEntry]) -> String {
        guard !entries.isEmpty else {
            return "No entries found for the specified time window."
        }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none
        
        var sections: [String] = []
        
        sections.append("# Work Summary — mlx-coder")
        sections.append("")
        sections.append("Generated: \(dateFormatter.string(from: Date()))")
        sections.append("")
        
        // Group by type
        let grouped = Dictionary(grouping: entries, by: { $0.type })
        
        // Session states (chronological)
        if let sessionEntries = grouped[.sessionState], !sessionEntries.isEmpty {
            sections.append("### Accomplished")
            sections.append("")
            for entry in sessionEntries.sorted(by: { $0.createdAt < $1.createdAt }) {
                sections.append("- \(entry.content)")
            }
            sections.append("")
        }
        
        // Decisions
        if let decisionEntries = grouped[.decision], !decisionEntries.isEmpty {
            sections.append("### Decisions Made")
            sections.append("")
            for entry in decisionEntries.sorted(by: { $0.createdAt < $1.createdAt }) {
                sections.append("- \(entry.content)")
            }
            sections.append("")
        }
        
        // Patterns
        if let patternEntries = grouped[.pattern], !patternEntries.isEmpty {
            sections.append("### Patterns Discovered")
            sections.append("")
            for entry in patternEntries.sorted(by: { $0.createdAt < $1.createdAt }) {
                sections.append("- \(entry.content)")
            }
            sections.append("")
        }
        
        // Gotchas
        if let gotchaEntries = grouped[.gotcha], !gotchaEntries.isEmpty {
            sections.append("### Gotchas Logged")
            sections.append("")
            for entry in gotchaEntries.sorted(by: { $0.createdAt < $1.createdAt }) {
                sections.append("- \(entry.content)")
            }
            sections.append("")
        }
        
        // Plans
        if let planEntries = grouped[.plan], !planEntries.isEmpty {
            sections.append("### Plans")
            sections.append("")
            for entry in planEntries.sorted(by: { $0.createdAt < $1.createdAt }) {
                sections.append("- \(entry.content)")
            }
            sections.append("")
        }
        
        return sections.joined(separator: "\n")
    }
    
    private static func generateStandup(entries: [KnowledgeEntry]) -> String {
        guard !entries.isEmpty else {
            return "No entries found for the specified time window."
        }
        
        var sections: [String] = []
        
        sections.append("# Daily Standup")
        sections.append("")
        
        let grouped = Dictionary(grouping: entries, by: { $0.type })
        
        // What was accomplished
        if let sessionEntries = grouped[.sessionState], !sessionEntries.isEmpty {
            sections.append("**What I did:**")
            for entry in sessionEntries.sorted(by: { $0.createdAt < $1.createdAt }).prefix(5) {
                sections.append("- \(entry.content)")
            }
            sections.append("")
        }
        
        // Blockers/gotchas
        if let gotchaEntries = grouped[.gotcha], !gotchaEntries.isEmpty {
            sections.append("**Blockers/Gotchas:**")
            for entry in gotchaEntries.sorted(by: { $0.createdAt > $1.createdAt }).prefix(3) {
                sections.append("- \(entry.content)")
            }
            sections.append("")
        }
        
        // Plans/next steps
        if let planEntries = grouped[.plan], !planEntries.isEmpty {
            sections.append("**Next steps:**")
            for entry in planEntries.sorted(by: { $0.createdAt > $1.createdAt }).prefix(3) {
                sections.append("- \(entry.content)")
            }
            sections.append("")
        }
        
        return sections.joined(separator: "\n")
    }
    
    private static func generateJSON(entries: [KnowledgeEntry]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        
        let data = try encoder.encode(entries)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
