// Tests/MemoryTests/KnowledgeRetrieverTests.swift
// Tests for deterministic 5-tier restore algorithm.

import XCTest
@testable import MLXCoder

final class KnowledgeRetrieverTests: XCTestCase {
    
    var tempDir: String!
    var store: KnowledgeStore!
    
    override func setUp() async throws {
        try await super.setUp()
        
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        tempDir = tempURL.path
        
        let dbPath = (tempDir as NSString).appendingPathComponent("test.db")
        store = KnowledgeStore(dbPath: dbPath)
        try await store.initialize()
    }
    
    override func tearDown() async throws {
        await store.close()
        try? FileManager.default.removeItem(atPath: tempDir)
        try await super.tearDown()
    }
    
    func testTier1SessionState() async throws {
        // Create 10 session state entries, 5 within 48h window
        let now = Date()
        
        for i in 0..<5 {
            let entry = KnowledgeEntry(
                type: .sessionState,
                content: "Recent work \(i)",
                surface: "tests",
                branch: "main",
                projectRoot: "/test/project",
                createdAt: now.addingTimeInterval(-Double(i) * 3600), // Within 48h
                expiresAt: now.addingTimeInterval(48 * 3600)
            )
            try await store.insert(entry)
        }
        
        for i in 5..<10 {
            let entry = KnowledgeEntry(
                type: .sessionState,
                content: "Old work \(i)",
                surface: "tests",
                branch: "main",
                projectRoot: "/test/project",
                createdAt: now.addingTimeInterval(-Double(i) * 24 * 3600), // > 48h ago
                expiresAt: now.addingTimeInterval(48 * 3600)
            )
            try await store.insert(entry)
        }
        
        let context = RestoreContext(projectRoot: "/test/project", surface: "tests", branch: "main")
        let result = try await KnowledgeRetriever.retrieve(from: store, context: context)
        
        // Should only get entries within 48h window
        let sessionEntries = result.entries.filter { $0.type == .sessionState }
        XCTAssertLessThanOrEqual(sessionEntries.count, 6) // Max 4 surface-matched + 2 other
    }
    
    func testTokenBudgetEnforcement() async throws {
        // Create entries that would exceed token budget
        for i in 0..<20 {
            let content = String(repeating: "a", count: 1000) // ~250 tokens each
            let entry = KnowledgeEntry(
                type: .decision,
                content: content,
                projectRoot: "/test/project"
            )
            try await store.insert(entry)
        }
        
        let context = RestoreContext(projectRoot: "/test/project")
        let result = try await KnowledgeRetriever.retrieve(from: store, context: context)
        
        // Should respect 2000 token budget
        XCTAssertLessThanOrEqual(result.tokenEstimate, KnowledgeRetriever.tokenBudget)
    }
    
    func testDeterministicOrdering() async throws {
        // Insert entries in random order
        let entries = [
            KnowledgeEntry(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, type: .decision, content: "Decision 1", projectRoot: "/test/project"),
            KnowledgeEntry(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, type: .decision, content: "Decision 3", projectRoot: "/test/project"),
            KnowledgeEntry(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, type: .decision, content: "Decision 2", projectRoot: "/test/project"),
        ]
        
        for entry in entries.shuffled() {
            try await store.insert(entry)
        }
        
        let context = RestoreContext(projectRoot: "/test/project")
        let result1 = try await KnowledgeRetriever.retrieve(from: store, context: context)
        let result2 = try await KnowledgeRetriever.retrieve(from: store, context: context)
        
        // Results should be identical
        XCTAssertEqual(result1.entries.map(\.id), result2.entries.map(\.id))
    }
    
    func testSurfaceMatching() async throws {
        let surfaceMatch = KnowledgeEntry(
            type: .gotcha,
            content: "Tests gotcha",
            surface: "tests",
            projectRoot: "/test/project"
        )
        
        let noSurfaceMatch = KnowledgeEntry(
            type: .gotcha,
            content: "Server gotcha",
            surface: "server",
            projectRoot: "/test/project"
        )
        
        try await store.insert(surfaceMatch)
        try await store.insert(noSurfaceMatch)
        
        let context = RestoreContext(projectRoot: "/test/project", surface: "tests")
        let result = try await KnowledgeRetriever.retrieve(from: store, context: context)
        
        // Surface-matched entry should come first
        if let firstGotcha = result.entries.first(where: { $0.type == .gotcha }) {
            XCTAssertEqual(firstGotcha.surface, "tests")
        }
    }
    
    func testTierQuotas() async throws {
        // Create more entries than tier quotas allow
        for i in 0..<10 {
            try await store.insert(KnowledgeEntry(type: .plan, content: "Plan \(i)", projectRoot: "/test/project"))
            try await store.insert(KnowledgeEntry(type: .decision, content: "Decision \(i)", projectRoot: "/test/project"))
            try await store.insert(KnowledgeEntry(type: .gotcha, content: "Gotcha \(i)", projectRoot: "/test/project"))
            try await store.insert(KnowledgeEntry(type: .pattern, content: "Pattern \(i)", projectRoot: "/test/project"))
        }
        
        let context = RestoreContext(projectRoot: "/test/project")
        let result = try await KnowledgeRetriever.retrieve(from: store, context: context)
        
        // Check tier quotas are respected
        XCTAssertLessThanOrEqual(result.tiersUsed[.plan, default: 0], 2)
        XCTAssertLessThanOrEqual(result.tiersUsed[.decision, default: 0], 3)
        XCTAssertLessThanOrEqual(result.tiersUsed[.gotchaPattern, default: 0], 4)
    }
}
