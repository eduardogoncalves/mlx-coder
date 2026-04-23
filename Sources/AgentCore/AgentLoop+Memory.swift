// Sources/AgentCore/AgentLoop+Memory.swift
// Memory subsystem integration for durable knowledge persistence.

import Foundation

extension AgentLoop {
    
    /// Synthesize a session state checkpoint from recent conversation history.
    /// Extracts a concise summary of what the agent was working on.
    public func synthesizeCheckpoint() -> String? {
        // Get the last 5 assistant messages to understand recent work
        let recentAssistant = history.messages
            .filter { $0.role == .assistant }
            .suffix(5)
            .map { $0.content }
        
        guard !recentAssistant.isEmpty else {
            return nil
        }
        
        // Simple heuristic: extract task-related sentences
        var taskSentences: [String] = []
        for content in recentAssistant {
            // Look for sentences that suggest actions or tasks
            let lines = content.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Filter for actionable statements (simple heuristic)
                if trimmed.count > 20 && trimmed.count < 300 &&
                   (trimmed.contains("will ") || trimmed.contains("need to") ||
                    trimmed.contains("working on") || trimmed.contains("implement") ||
                    trimmed.contains("fix") || trimmed.contains("add") ||
                    trimmed.contains("update") || trimmed.contains("create")) {
                    taskSentences.append(trimmed)
                }
            }
        }
        
        // Take up to 3 most recent task sentences
        let checkpoint = taskSentences.suffix(3).joined(separator: " ")
        
        return checkpoint.isEmpty ? nil : checkpoint
    }
    
    /// Save a checkpoint to durable memory before clearing history.
    public func saveCheckpointBeforeClear() async {
        guard let checkpoint = synthesizeCheckpoint() else {
            return
        }
        
        let store = KnowledgeStore.shared
        
        // Initialize store if not already done
        do {
            try await store.initialize()
        } catch {
            renderer.printError("Failed to initialize memory store: \(error)")
            return
        }
        
        // Detect surface and branch
        let surface = SurfaceDetector.detectSurface(workspacePath: workspace)
        let branch = SurfaceDetector.currentBranch(in: projectWorkspaceRoot)
        
        // Create entry with 48h TTL
        let expiresAt = Date().addingTimeInterval(48 * 3600)
        let entry = KnowledgeEntry(
            type: .sessionState,
            content: checkpoint,
            surface: surface,
            branch: branch,
            projectRoot: projectWorkspaceRoot,
            expiresAt: expiresAt
        )
        
        do {
            try await store.insert(entry)
            renderer.printStatus("Checkpoint saved to memory")
        } catch {
            renderer.printError("Failed to save checkpoint: \(error)")
        }
    }
    
    /// Clear history with automatic checkpoint.
    public func clearHistoryWithCheckpoint() async {
        await saveCheckpointBeforeClear()
        clearHistory()
    }
}
