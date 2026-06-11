// Sources/ToolSystem/Agent/ReadSkillTool.swift
// Read the full instructions of a discovered skill (SKILL.md) by name, with pagination.

import Foundation

/// Reads a skill's SKILL.md by skill name via the SkillsRegistry.
/// Unlike read_file, this resolves skills outside the workspace (e.g. ~/skills)
/// and always reports exactly which lines were returned plus how to continue.
public struct ReadSkillTool: Tool {
    public let name = "read_skill"
    public let description = "Load the full instructions of an available skill by its name (from 'Available skills metadata'). ALWAYS use this instead of read_file for SKILL.md files. Output is paginated: when a skill is longer than one page, the result states the last line returned — call read_skill again with start_line set to the next line to read the continuation."
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "name": PropertySchema(type: "string", description: "Skill name exactly as listed in the available skills metadata (e.g. 'dotnet-cli')"),
            "start_line": PropertySchema(type: "integer", description: "First line to return (1-indexed, optional). Use the continuation hint from a previous read_skill result to resume reading."),
        ],
        required: ["name"]
    )

    private let skills: SkillsRegistry
    private let maxOutputLines: Int

    public init(skills: SkillsRegistry, maxOutputLines: Int = 500) {
        self.skills = skills
        self.maxOutputLines = maxOutputLines
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let skillName = (arguments["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !skillName.isEmpty else {
            return .error("Missing required argument: name (the skill name)")
        }

        let body: String
        guard let metadata = await skills.metadata(name: skillName) else {
            let available = await skills.listMetadata().map(\.name)
            if available.isEmpty {
                return .error("Unknown skill '\(skillName)'. No skills are available in this workspace.")
            }
            return .error("Unknown skill '\(skillName)'. Available skills: \(available.joined(separator: ", "))")
        }
        do {
            guard let loaded = try await skills.loadBody(name: skillName) else {
                return .error("Failed to load skill '\(skillName)'")
            }
            body = loaded
        } catch {
            return .error("Failed to load skill '\(skillName)': \(error.localizedDescription)")
        }

        var allLines = body.components(separatedBy: "\n")
        // A trailing newline yields one empty final component; drop it from line accounting.
        if allLines.count > 1, allLines.last?.isEmpty == true {
            allLines.removeLast()
        }
        let totalLines = allLines.count

        let startLine = max(1, integerArgument(arguments["start_line"]) ?? 1)
        guard startLine <= totalLines else {
            return .error("start_line \(startLine) is out of range — skill '\(metadata.name)' has \(totalLines) lines.")
        }

        let endLine = min(startLine + maxOutputLines - 1, totalLines)
        let selected = allLines[(startLine - 1)..<endLine].joined(separator: "\n")

        let header = "Skill '\(metadata.name)' (\(metadata.filePath)) — lines \(startLine)-\(endLine) of \(totalLines):"
        let content = header + "\n" + selected

        if endLine < totalLines {
            let marker = "[Skill continues: \(totalLines - endLine) more lines. Call read_skill with {\"name\": \"\(metadata.name)\", \"start_line\": \(endLine + 1)} to continue reading.]"
            return ToolResult(content: content, truncationMarker: marker)
        }

        return .success(content)
    }

    private func integerArgument(_ value: Any?) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }
        if let stringValue = value as? String {
            return Int(stringValue.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}
