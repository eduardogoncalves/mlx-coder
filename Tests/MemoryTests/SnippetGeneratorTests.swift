// Tests/MemoryTests/SnippetGeneratorTests.swift
// Tests for work summary generation.

import XCTest
@testable import MLXCoder

final class SnippetGeneratorTests: XCTestCase {
    
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
    
    func testMarkdownSnippetAllTypes() async throws {
        let now = Date()
        
        try await store.insert(KnowledgeEntry(type: .sessionState, content: "Implemented auth layer", projectRoot: "/test", createdAt: now))
        try await store.insert(KnowledgeEntry(type: .decision, content: "Use JWT for auth", projectRoot: "/test", createdAt: now))
        try await store.insert(KnowledgeEntry(type: .pattern, content: "Test files use .test.swift suffix", projectRoot: "/test", createdAt: now))
        try await store.insert(KnowledgeEntry(type: .gotcha, content: "API requires X-Custom-Header", projectRoot: "/test", createdAt: now))
        try await store.insert(KnowledgeEntry(type: .plan, content: "Next: add UI layer", projectRoot: "/test", createdAt: now))
        
        let snippet = try await SnippetGenerator.generate(
            from: store,
            projectRoot: "/test",
            window: .all,
            format: .markdown
        )
        
        XCTAssertTrue(snippet.contains("Accomplished"))
        XCTAssertTrue(snippet.contains("Implemented auth layer"))
        XCTAssertTrue(snippet.contains("Decisions Made"))
        XCTAssertTrue(snippet.contains("Use JWT for auth"))
        XCTAssertTrue(snippet.contains("Patterns Discovered"))
        XCTAssertTrue(snippet.contains("Test files use .test.swift suffix"))
        XCTAssertTrue(snippet.contains("Gotchas Logged"))
        XCTAssertTrue(snippet.contains("API requires X-Custom-Header"))
        XCTAssertTrue(snippet.contains("Plans"))
        XCTAssertTrue(snippet.contains("Next: add UI layer"))
    }
    
    func testStandupFormat() async throws {
        let now = Date()
        
        try await store.insert(KnowledgeEntry(type: .sessionState, content: "Finished sprint tasks", projectRoot: "/test", createdAt: now))
        try await store.insert(KnowledgeEntry(type: .gotcha, content: "Cannot use async inside forEach", projectRoot: "/test", createdAt: now))
        try await store.insert(KnowledgeEntry(type: .plan, content: "Tomorrow: PR reviews", projectRoot: "/test", createdAt: now))
        
        let snippet = try await SnippetGenerator.generate(
            from: store,
            projectRoot: "/test",
            window: .all,
            format: .standup
        )
        
        XCTAssertTrue(snippet.contains("What I did"))
        XCTAssertTrue(snippet.contains("Finished sprint tasks"))
        XCTAssertTrue(snippet.contains("Blockers"))
        XCTAssertTrue(snippet.contains("Cannot use async inside forEach"))
        XCTAssertTrue(snippet.contains("Next steps"))
        XCTAssertTrue(snippet.contains("Tomorrow: PR reviews"))
    }
    
    func testJSONFormat() async throws {
        let now = Date()
        try await store.insert(KnowledgeEntry(type: .decision, content: "Use actor for thread safety", projectRoot: "/test", createdAt: now))
        
        let snippet = try await SnippetGenerator.generate(
            from: store,
            projectRoot: "/test",
            window: .all,
            format: .json
        )
        
        XCTAssertTrue(snippet.contains("Use actor for thread safety"))
        XCTAssertTrue(snippet.contains("decision"))
        // Verify it's valid JSON
        let data = snippet.data(using: .utf8)!
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
    }
    
    func testEmptyStore() async throws {
        let snippet = try await SnippetGenerator.generate(
            from: store,
            projectRoot: "/test",
            window: .all,
            format: .markdown
        )
        
        XCTAssertTrue(snippet.contains("No entries found"))
    }
    
    func testTodayWindow() async throws {
        let today = Date()
        let yesterday = today.addingTimeInterval(-25 * 3600)
        
        try await store.insert(KnowledgeEntry(type: .sessionState, content: "Today's work", projectRoot: "/test", createdAt: today))
        try await store.insert(KnowledgeEntry(type: .sessionState, content: "Yesterday's work", projectRoot: "/test", createdAt: yesterday))
        
        let snippet = try await SnippetGenerator.generate(
            from: store,
            projectRoot: "/test",
            window: .today,
            format: .markdown
        )
        
        XCTAssertTrue(snippet.contains("Today's work"))
        XCTAssertFalse(snippet.contains("Yesterday's work"))
    }
    
    func testWeekWindow() async throws {
        let today = Date()
        let lastWeek = today.addingTimeInterval(-8 * 24 * 3600) // 8 days ago
        
        try await store.insert(KnowledgeEntry(type: .sessionState, content: "This week's work", projectRoot: "/test", createdAt: today))
        try await store.insert(KnowledgeEntry(type: .sessionState, content: "Last week's work", projectRoot: "/test", createdAt: lastWeek))
        
        let snippet = try await SnippetGenerator.generate(
            from: store,
            projectRoot: "/test",
            window: .week,
            format: .markdown
        )
        
        XCTAssertTrue(snippet.contains("This week's work"))
        XCTAssertFalse(snippet.contains("Last week's work"))
    }
}
