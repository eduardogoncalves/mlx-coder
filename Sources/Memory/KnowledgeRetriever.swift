// Sources/Memory/KnowledgeRetriever.swift
// Deterministic 5-tier restore algorithm with token budget enforcement.

import Foundation

/// Retrieves knowledge entries using a 5-tier priority system with deterministic ordering.
public enum KnowledgeRetriever {
    
    /// Token budget for restored context (estimated as content.count / 4).
    public static let tokenBudget = 2000
    
    /// Retrieve knowledge entries for the given restore context.
    /// Never exceeds token budget and never truncates mid-entry.
    public static func retrieve(
        from store: KnowledgeStore,
        context: RestoreContext
    ) async throws -> RestoreResult {
        var selectedEntries: [KnowledgeEntry] = []
        var tiersUsed: [RestoreTier: Int] = [:]
        var tokenCount = 0
        
        // Tier 1: Session state (48h window, up to 4 surface-matched + 2 other)
        let sessionEntries = try await retrieveTier1(
            from: store,
            context: context,
            remainingTokens: tokenBudget - tokenCount
        )
        for entry in sessionEntries {
            let entryTokens = estimateTokens(entry.content)
            if tokenCount + entryTokens <= tokenBudget {
                selectedEntries.append(entry)
                tokenCount += entryTokens
                tiersUsed[.sessionState, default: 0] += 1
            } else {
                break
            }
        }
        
        // Tier 2: Plans (all time, up to 2)
        let planEntries = try await retrieveTier2(
            from: store,
            context: context,
            remainingTokens: tokenBudget - tokenCount
        )
        for entry in planEntries {
            let entryTokens = estimateTokens(entry.content)
            if tokenCount + entryTokens <= tokenBudget && tiersUsed[.plan, default: 0] < 2 {
                selectedEntries.append(entry)
                tokenCount += entryTokens
                tiersUsed[.plan, default: 0] += 1
            } else if tiersUsed[.plan, default: 0] >= 2 {
                break
            }
        }
        
        // Tier 3: Decisions (all time, up to 3)
        let decisionEntries = try await retrieveTier3(
            from: store,
            context: context,
            remainingTokens: tokenBudget - tokenCount
        )
        for entry in decisionEntries {
            let entryTokens = estimateTokens(entry.content)
            if tokenCount + entryTokens <= tokenBudget && tiersUsed[.decision, default: 0] < 3 {
                selectedEntries.append(entry)
                tokenCount += entryTokens
                tiersUsed[.decision, default: 0] += 1
            } else if tiersUsed[.decision, default: 0] >= 3 {
                break
            }
        }
        
        // Tier 4: Gotchas + Patterns (all time, up to 4 combined)
        let gotchaPatternEntries = try await retrieveTier4(
            from: store,
            context: context,
            remainingTokens: tokenBudget - tokenCount
        )
        for entry in gotchaPatternEntries {
            let entryTokens = estimateTokens(entry.content)
            if tokenCount + entryTokens <= tokenBudget && tiersUsed[.gotchaPattern, default: 0] < 4 {
                selectedEntries.append(entry)
                tokenCount += entryTokens
                tiersUsed[.gotchaPattern, default: 0] += 1
            } else if tiersUsed[.gotchaPattern, default: 0] >= 4 {
                break
            }
        }
        
        // Tier 5: Cross-project (from OTHER project roots, up to 2)
        let crossProjectEntries = try await retrieveTier5(
            from: store,
            context: context,
            remainingTokens: tokenBudget - tokenCount
        )
        for entry in crossProjectEntries {
            let entryTokens = estimateTokens(entry.content)
            if tokenCount + entryTokens <= tokenBudget && tiersUsed[.crossProject, default: 0] < 2 {
                selectedEntries.append(entry)
                tokenCount += entryTokens
                tiersUsed[.crossProject, default: 0] += 1
            } else if tiersUsed[.crossProject, default: 0] >= 2 {
                break
            }
        }
        
        return RestoreResult(
            entries: selectedEntries,
            tokenEstimate: tokenCount,
            tiersUsed: tiersUsed
        )
    }
    
    // MARK: - Tier Implementations
    
    private static func retrieveTier1(
        from store: KnowledgeStore,
        context: RestoreContext,
        remainingTokens: Int
    ) async throws -> [KnowledgeEntry] {
        guard remainingTokens > 0 else { return [] }
        
        let windowStart = Date().addingTimeInterval(-48 * 3600) // 48 hours ago
        let allEntries = try await store.list(projectRoot: context.projectRoot, type: .sessionState, limit: 100)
        
        // Filter by 48h window
        let recentEntries = allEntries.filter { $0.createdAt >= windowStart }
        
        // Sort: surface match first, then branch match, then recency, then ID
        let sorted = recentEntries.sorted { lhs, rhs in
            let lhsSurfaceMatch = (lhs.surface == context.surface && context.surface != nil)
            let rhsSurfaceMatch = (rhs.surface == context.surface && context.surface != nil)
            
            if lhsSurfaceMatch != rhsSurfaceMatch {
                return lhsSurfaceMatch
            }
            
            let lhsBranchMatch = (lhs.branch == context.branch && context.branch != nil)
            let rhsBranchMatch = (rhs.branch == context.branch && context.branch != nil)
            
            if lhsBranchMatch != rhsBranchMatch {
                return lhsBranchMatch
            }
            
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            
            return lhs.id.uuidString < rhs.id.uuidString
        }
        
        // Take up to 4 surface-matched + 2 other
        var result: [KnowledgeEntry] = []
        var surfaceMatched = 0
        var others = 0
        
        for entry in sorted {
            if entry.surface == context.surface && context.surface != nil {
                if surfaceMatched < 4 {
                    result.append(entry)
                    surfaceMatched += 1
                }
            } else {
                if others < 2 {
                    result.append(entry)
                    others += 1
                }
            }
            
            if surfaceMatched >= 4 && others >= 2 {
                break
            }
        }
        
        return result
    }
    
    private static func retrieveTier2(
        from store: KnowledgeStore,
        context: RestoreContext,
        remainingTokens: Int
    ) async throws -> [KnowledgeEntry] {
        guard remainingTokens > 0 else { return [] }
        
        let entries = try await store.list(projectRoot: context.projectRoot, type: .plan, limit: 50)
        return sortByRelevance(entries, context: context)
    }
    
    private static func retrieveTier3(
        from store: KnowledgeStore,
        context: RestoreContext,
        remainingTokens: Int
    ) async throws -> [KnowledgeEntry] {
        guard remainingTokens > 0 else { return [] }
        
        let entries = try await store.list(projectRoot: context.projectRoot, type: .decision, limit: 50)
        return sortByRelevance(entries, context: context)
    }
    
    private static func retrieveTier4(
        from store: KnowledgeStore,
        context: RestoreContext,
        remainingTokens: Int
    ) async throws -> [KnowledgeEntry] {
        guard remainingTokens > 0 else { return [] }
        
        let gotchas = try await store.list(projectRoot: context.projectRoot, type: .gotcha, limit: 50)
        let patterns = try await store.list(projectRoot: context.projectRoot, type: .pattern, limit: 50)
        
        let combined = gotchas + patterns
        return sortByRelevance(combined, context: context)
    }
    
    private static func retrieveTier5(
        from store: KnowledgeStore,
        context: RestoreContext,
        remainingTokens: Int
    ) async throws -> [KnowledgeEntry] {
        guard remainingTokens > 0 else { return [] }
        
        // This would require querying all project roots, which is expensive
        // For now, return empty. In practice, this tier would need a separate
        // implementation that scans for other project roots.
        return []
    }
    
    // MARK: - Helpers
    
    private static func sortByRelevance(
        _ entries: [KnowledgeEntry],
        context: RestoreContext
    ) -> [KnowledgeEntry] {
        entries.sorted { lhs, rhs in
            let lhsSurfaceMatch = (lhs.surface == context.surface && context.surface != nil)
            let rhsSurfaceMatch = (rhs.surface == context.surface && context.surface != nil)
            
            if lhsSurfaceMatch != rhsSurfaceMatch {
                return lhsSurfaceMatch
            }
            
            let lhsBranchMatch = (lhs.branch == context.branch && context.branch != nil)
            let rhsBranchMatch = (rhs.branch == context.branch && context.branch != nil)
            
            if lhsBranchMatch != rhsBranchMatch {
                return lhsBranchMatch
            }
            
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
    
    private static func estimateTokens(_ text: String) -> Int {
        max(1, text.count / 4)
    }
}
