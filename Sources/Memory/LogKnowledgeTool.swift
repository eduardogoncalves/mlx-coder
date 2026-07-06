// Sources/Memory/LogKnowledgeTool.swift
// LLM tool for self-logging important findings to durable memory.

import Foundation

/// Tool that allows the LLM to persist, update, or remove knowledge from durable memory.
public struct LogKnowledgeTool: Tool {
    public let name = "log_knowledge"
    public let description = """
    Manage durable memory entries across sessions.

    IMPORTANT RULES:
    - When the user asks to update or correct existing knowledge, use action "update" with the id \
    from search_knowledge — NEVER log a new entry for information that already exists.
    - When the user asks to delete or remove knowledge, use action "remove" with the id.
    - Only use action "log" for genuinely new information that does not already exist.
    - After an update or remove, also remove any duplicate/stale entries for the same fact.

    Actions:
    - "log":    Persist new knowledge. Requires: type, content. Optional: tags.
    - "update": Replace an existing entry's content. Requires: id (from search_knowledge), content.
    - "remove": Delete an entry. Requires: id (from search_knowledge).

    Examples:
    - New fact:  { "action": "log",    "type": "gotcha", "content": "Always use xcodebuild" }
    - Correct:   { "action": "update", "id": "<uuid>",   "content": "Corrected text" }
    - Delete:    { "action": "remove", "id": "<uuid>" }
    """

    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "action": PropertySchema(
                type: "string",
                description: "Operation to perform: log (default), update, or remove",
                enumValues: ["log", "update", "remove"]
            ),
            "id": PropertySchema(
                type: "string",
                description: "Entry UUID — required for update and remove (obtained from search_knowledge)"
            ),
            "type": PropertySchema(
                type: "string",
                description: "Type of knowledge for log action: decision, gotcha, pattern, plan",
                enumValues: ["decision", "gotcha", "pattern", "plan"]
            ),
            "content": PropertySchema(
                type: "string",
                description: "The knowledge text — required for log and update (max 2000 characters)"
            ),
            "tags": PropertySchema(
                type: "array",
                description: "Optional tags for categorization — applies to log (max 10)",
                items: PropertySchema(type: "string")
            )
        ],
        required: []
    )
    
    private let workspaceRoot: String
    
    public init(workspaceRoot: String) {
        // Canonicalize to match the path stored during restore
        self.workspaceRoot = URL(fileURLWithPath: workspaceRoot).standardized.path
    }
    
    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        let action = (arguments["action"] as? String) ?? "log"

        let store = KnowledgeStore.shared
        do { try await store.initialize() } catch {
            return .error("Failed to initialize memory store: \(error.localizedDescription)")
        }

        switch action {
        case "remove":
            guard let idStr = arguments["id"] as? String, let id = UUID(uuidString: idStr) else {
                return .error("Missing or invalid argument: id (UUID string required for remove)")
            }
            do {
                try await store.delete(id: id)
                return .success("Entry \(idStr) removed.")
            } catch {
                return .error("Failed to remove entry: \(error.localizedDescription)")
            }

        case "update":
            guard let idStr = arguments["id"] as? String, let id = UUID(uuidString: idStr) else {
                return .error("Missing or invalid argument: id (UUID string required for update)")
            }
            guard let content = arguments["content"] as? String else {
                return .error("Missing required argument: content")
            }
            guard content.count <= 2000 else {
                return .error("Content exceeds 2000 character limit")
            }
            do {
                try await store.update(id: id, content: content)
                return .success("Entry \(idStr) updated.")
            } catch {
                return .error("Failed to update entry: \(error.localizedDescription)")
            }

        default: // "log"
            guard let typeStr = arguments["type"] as? String,
                  let type = KnowledgeType(rawValue: typeStr) else {
                return .error("Invalid or missing type. Use: decision, gotcha, pattern, plan")
            }
            guard let content = arguments["content"] as? String else {
                return .error("Missing required argument: content")
            }
            guard content.count <= 2000 else {
                return .error("Content exceeds 2000 character limit")
            }
            var tags: [String] = []
            if let tagsArray = arguments["tags"] as? [String] {
                tags = Array(tagsArray.prefix(10))
            }
            let surface = SurfaceDetector.detectSurface(workspacePath: workspaceRoot)
            let branch = SurfaceDetector.currentBranch(in: workspaceRoot)
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
}
