// Sources/Memory/MemoryFormatter.swift
// Formats restored knowledge entries for injection into the system prompt.

import Foundation

/// Formats restored knowledge entries for the system prompt memory section.
public enum MemoryFormatter {
    
    /// Format restored context for system prompt injection.
    public static func formatRestoredContext(_ result: RestoreResult) -> String {
        guard !result.entries.isEmpty else {
            return ""
        }
        
        var sections: [String] = []
        
        sections.append("# Restored Memory (\(result.tokenEstimate) tokens)")
        sections.append("")
        sections.append("The following knowledge was restored from previous sessions:")
        sections.append("")
        
        // Group by type
        let grouped = Dictionary(grouping: result.entries, by: { $0.type })
        
        // Session state
        if let sessionEntries = grouped[.sessionState], !sessionEntries.isEmpty {
            sections.append("## Session State")
            sections.append("")
            for entry in sessionEntries {
                sections.append(formatEntry(entry))
                sections.append("")
            }
        }
        
        // Plans
        if let planEntries = grouped[.plan], !planEntries.isEmpty {
            sections.append("## Plans")
            sections.append("")
            for entry in planEntries {
                sections.append(formatEntry(entry))
                sections.append("")
            }
        }
        
        // Decisions
        if let decisionEntries = grouped[.decision], !decisionEntries.isEmpty {
            sections.append("## Decisions")
            sections.append("")
            for entry in decisionEntries {
                sections.append(formatEntry(entry))
                sections.append("")
            }
        }
        
        // Gotchas
        if let gotchaEntries = grouped[.gotcha], !gotchaEntries.isEmpty {
            sections.append("## Gotchas")
            sections.append("")
            for entry in gotchaEntries {
                sections.append(formatEntry(entry))
                sections.append("")
            }
        }
        
        // Patterns
        if let patternEntries = grouped[.pattern], !patternEntries.isEmpty {
            sections.append("## Patterns")
            sections.append("")
            for entry in patternEntries {
                sections.append(formatEntry(entry))
                sections.append("")
            }
        }
        
        return sections.joined(separator: "\n")
    }
    
    private static func formatEntry(_ entry: KnowledgeEntry) -> String {
        var lines: [String] = []
        
        // Metadata line
        var meta: [String] = []
        if let surface = entry.surface {
            meta.append("surface: \(surface)")
        }
        if let branch = entry.branch {
            meta.append("branch: \(branch)")
        }
        if !entry.tags.isEmpty {
            meta.append("tags: \(entry.tags.joined(separator: ", "))")
        }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .none
        meta.append("date: \(dateFormatter.string(from: entry.createdAt))")
        
        lines.append("**[\(meta.joined(separator: " | "))]**")
        lines.append(entry.content)
        
        return lines.joined(separator: "\n")
    }
}
