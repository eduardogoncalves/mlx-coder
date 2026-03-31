// Sources/ToolSystem/Agent/AgentLoader.swift
// Sub-agent spawning with max depth enforcement

import Foundation
import Yams

/// Loads sub-agent definitions and enforces max depth 1.
public struct AgentLoader: Sendable {

    /// A sub-agent definition loaded from YAML.
    public struct AgentDefinition: Sendable {
        public let name: String
        public let description: String
        public let systemPrompt: String
        public let tools: [String]

        public init(name: String, description: String, systemPrompt: String, tools: [String]) {
            self.name = name
            self.description = description
            self.systemPrompt = systemPrompt
            self.tools = tools
        }
    }

    /// Maximum depth for sub-agent spawning.
    /// Sub-agents cannot spawn sub-agents (depth 0 = main agent, depth 1 = sub-agent).
    public static let maxDepth = 1

    /// Load agent definitions from YAML files in the given directory.
    public static func loadDefinitions(from directory: String) throws -> [AgentDefinition] {
        let expandedPath = NSString(string: directory).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            return []
        }

        let contents = try FileManager.default.contentsOfDirectory(atPath: expandedPath)
        let yamlFiles = contents.filter { $0.hasSuffix(".yaml") || $0.hasSuffix(".yml") }

        var definitions: [AgentDefinition] = []

        for file in yamlFiles {
            let filePath = (expandedPath as NSString).appendingPathComponent(file)
            let content = try String(contentsOfFile: filePath, encoding: .utf8)

            guard let yaml = try Yams.load(yaml: content) as? [String: Any] else {
                continue
            }

            let name = yaml["name"] as? String ?? file.replacingOccurrences(of: ".yaml", with: "")
            let description = yaml["description"] as? String ?? ""
            let systemPrompt = yaml["system_prompt"] as? String ?? ""
            let tools = yaml["tools"] as? [String] ?? []

            definitions.append(AgentDefinition(
                name: name,
                description: description,
                systemPrompt: systemPrompt,
                tools: tools
            ))
        }

        return definitions
    }

    /// Check if spawning a sub-agent is allowed at the given depth.
    public static func canSpawn(at depth: Int) -> Bool {
        depth < maxDepth
    }
}
