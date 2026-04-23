// Tests/MemoryTests/KnowledgeStoreTests.swift
// Tests for SQLite-backed knowledge store.

import XCTest
@testable import MLXCoder

final class KnowledgeStoreTests: XCTestCase {
    
    var tempDir: String!
    var store: KnowledgeStore!
    
    override func setUp() async throws {
        try await super.setUp()
        
        // Create temp directory for test DB
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
    
    func testInsertAndRetrieve() async throws {
        let entry = KnowledgeEntry(
            type: .decision,
            content: "Always use xcodebuild for this project",
            tags: ["build", "xcode"],
            surface: "tests",
            branch: "main",
            projectRoot: "/test/project"
        )
        
        try await store.insert(entry)
        
        let entries = try await store.list(projectRoot: "/test/project", type: .decision)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.content, entry.content)
        XCTAssertEqual(entries.first?.tags, ["build", "xcode"])
    }
    
    func testDeduplication() async throws {
        let entry1 = KnowledgeEntry(
            type: .gotcha,
            content: "API requires custom header",
            projectRoot: "/test/project"
        )
        
        let entry2 = KnowledgeEntry(
            type: .gotcha,
            content: "API requires custom header", // Same content
            projectRoot: "/test/project"
        )
        
        try await store.insert(entry1)
        try await store.insert(entry2) // Should be deduplicated
        
        let entries = try await store.list(projectRoot: "/test/project", type: .gotcha)
        XCTAssertEqual(entries.count, 1, "Duplicate entries should be deduplicated")
    }
    
    func testExpiry() async throws {
        let expired = KnowledgeEntry(
            type: .sessionState,
            content: "Old session state",
            projectRoot: "/test/project",
            expiresAt: Date().addingTimeInterval(-3600) // Expired 1 hour ago
        )
        
        let valid = KnowledgeEntry(
            type: .sessionState,
            content: "Current session state",
            projectRoot: "/test/project",
            expiresAt: Date().addingTimeInterval(3600) // Expires in 1 hour
        )
        
        try await store.insert(expired)
        try await store.insert(valid)
        
        try await store.pruneExpired()
        
        let entries = try await store.list(projectRoot: "/test/project", type: .sessionState)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.content, "Current session state")
    }
    
    func testSearch() async throws {
        let entry1 = KnowledgeEntry(
            type: .pattern,
            content: "Use dependency injection for testability",
            projectRoot: "/test/project"
        )
        
        let entry2 = KnowledgeEntry(
            type: .decision,
            content: "Adopt SwiftUI for new screens",
            projectRoot: "/test/project"
        )
        
        try await store.insert(entry1)
        try await store.insert(entry2)
        
        let results = try await store.search(query: "SwiftUI", projectRoot: "/test/project")
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results.first?.content.contains("SwiftUI") ?? false)
    }
    
    func testDelete() async throws {
        let entry = KnowledgeEntry(
            type: .plan,
            content: "Implement feature X",
            projectRoot: "/test/project"
        )
        
        try await store.insert(entry)
        
        let beforeDelete = try await store.list(projectRoot: "/test/project", type: .plan)
        XCTAssertEqual(beforeDelete.count, 1)
        
        try await store.delete(id: entry.id)
        
        let afterDelete = try await store.list(projectRoot: "/test/project", type: .plan)
        XCTAssertEqual(afterDelete.count, 0)
    }
    
    func testStats() async throws {
        for i in 0..<5 {
            let entry = KnowledgeEntry(
                type: .decision,
                content: "Decision \(i)",
                projectRoot: "/test/project"
            )
            try await store.insert(entry)
        }
        
        let stats = try await store.stats()
        XCTAssertEqual(stats.entryCount, 5)
        XCTAssertGreaterThan(stats.dbSizeBytes, 0)
    }
    
    func testTagNormalization() {
        let entry = KnowledgeEntry(
            type: .pattern,
            content: "Test pattern",
            tags: ["Build", "TEST", "build"], // Should be normalized and deduplicated
            projectRoot: "/test/project"
        )
        
        XCTAssertEqual(entry.tags, ["build", "test"])
    }
}
