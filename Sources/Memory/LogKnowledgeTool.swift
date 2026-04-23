// Sources/Memory/LogKnowledgeTool.swift
// LLM tool for self-logging important findings to durable memory.

import Foundation

/// Tool that allows the LLM to persist important findings to durable memory.
public struct LogKnowledgeTool: Tool {
    public let name = "log_knowledge"
    public let description = """
    Persist an important decision, gotcha, or pattern to durable memory for future sessions.
    Use this proactively when you discover something important that should be remembered across sessions.
    Examples:
    - Decisions: "Always use xcodebuild instead of swift build for this project"
    - Gotchas: "The API requires auth token in X-Custom-Header, not Authorization header"
    - Patterns: "Test files follow the pattern Foo.test.ts in the same directory as Foo.ts"
    - Plans: "Next steps: implement auth layer, then add UI components"
    """
    
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "type": PropertySchema(
                type: "string",
                description: "Type of knowledge: decision, gotcha, pattern, plan",
                enumValues: ["decision", "gotcha", "pattern", "plan"]
            ),
            "content": PropertySchema(
                type: "string",
                description: "The knowledge to persist (max 2000 characters)"
            ),
            "tags": PropertySchema(
                type: "array",
                description: "Optional tags for categorization (max 10)",
                items: PropertySchema(type: "string")
            )
        ],
        required: ["type", "content"]
    )
    
    private let workspaceRoot: String
    
    public init(workspaceRoot: String) {
        self.workspaceRoot = workspaceRoot
    }
    
    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let typeStr = arguments["type"] as? String,
              let type = KnowledgeType(rawValue: typeStr) else {
            return .error("Invalid type. Use: decision, gotcha, pattern, plan")
        }
        
        guard let content = arguments["content"] as? String else {
            return .error("Missing required argument: content")
        }
        
        // Enforce max length
        guard content.count <= 2000 else {
            return .error("Content exceeds 2000 character limit")
        }
        
        // Parse tags
        var tags: [String] = []
        if let tagsArray = arguments["tags"] as? [String] {
            tags = Array(tagsArray.prefix(10))
        }
        
        // Initialize store
        let store = KnowledgeStore.shared
        do {
            try await store.initialize()
        } catch {
            return .error("Failed to initialize memory store: \(error.localizedDescription)")
        }
        
        // Detect surface and branch
        let surface = SurfaceDetector.detectSurface(workspacePath: workspaceRoot)
        let branch = SurfaceDetector.currentBranch(in: workspaceRoot)
        
        // Create entry (no expiry for non-session_state types)
        let entry = KnowledgeEntry(
            type: type,
            content: content,
            tags: tags,
            surface: surface,
            branch: branch,
            projectRoot: workspaceRoot,
            expiresAt: nil
        )
        
        do {
            try await store.insert(entry)
            return .success("Knowledge logged as \(type.rawValue)")
        } catch {
            return .error("Failed to log knowledge: \(error.localizedDescription)")
        }
    }
}
