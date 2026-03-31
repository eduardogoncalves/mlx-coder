import Foundation

public struct SkillMetadata: Codable, Sendable {
    public let name: String
    public let description: String
    public let filePath: String
    public let tags: [String]

    public init(name: String, description: String, filePath: String, tags: [String] = []) {
        self.name = name
        self.description = description
        self.filePath = filePath
        self.tags = tags
    }
}

public actor SkillsRegistry {
    private struct SkillEntry: Sendable {
        let metadata: SkillMetadata
        let absolutePath: String
    }

    private var entriesByName: [String: SkillEntry] = [:]
    private var cachedBodies: [String: String] = [:]

    public init(workspaceRoot: String) {
        let discovered = SkillsRegistry.discoverSkills(workspaceRoot: workspaceRoot)
        var map: [String: SkillEntry] = [:]
        for entry in discovered {
            map[entry.metadata.name] = entry
        }
        self.entriesByName = map
    }

    public func listMetadata() -> [SkillMetadata] {
        entriesByName
            .values
            .map(\.metadata)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func loadBody(name: String) throws -> String? {
        if let cached = cachedBodies[name] {
            return cached
        }
        guard let entry = entriesByName[name] else {
            return nil
        }

        let body = try String(contentsOfFile: entry.absolutePath, encoding: .utf8)
        cachedBodies[name] = body
        return body
    }

    private static func discoverSkills(workspaceRoot: String) -> [SkillEntry] {
        let fm = FileManager.default
        let candidateRoots = [
            workspaceRoot + "/.github/skills",
            workspaceRoot + "/skills"
        ]

        var entries: [SkillEntry] = []

        for root in candidateRoots {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            guard let enumerator = fm.enumerator(atPath: root) else {
                continue
            }

            for case let relative as String in enumerator {
                guard relative.hasSuffix("/SKILL.md") || relative == "SKILL.md" else {
                    continue
                }

                let absolutePath = root + "/" + relative
                guard let metadata = loadMetadata(absolutePath: absolutePath, workspaceRoot: workspaceRoot) else {
                    continue
                }

                entries.append(SkillEntry(metadata: metadata, absolutePath: absolutePath))
            }
        }

        return entries
    }

    private static func loadMetadata(absolutePath: String, workspaceRoot: String) -> SkillMetadata? {
        guard let contents = try? String(contentsOfFile: absolutePath, encoding: .utf8) else {
            return nil
        }

        let relativePath = makeRelative(path: absolutePath, workspaceRoot: workspaceRoot)
        let fallbackName = URL(filePath: absolutePath)
            .deletingLastPathComponent()
            .lastPathComponent

        var name = fallbackName
        var description = "Skill metadata"
        var tags: [String] = []

        if let frontmatter = parseFrontmatter(contents) {
            if let value = frontmatter["name"], !value.isEmpty {
                name = value
            }
            if let value = frontmatter["description"], !value.isEmpty {
                description = value
            }
            if let value = frontmatter["tags"], !value.isEmpty {
                tags = value
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        } else if let firstTextLine = firstContentLine(contents) {
            description = firstTextLine
        }

        return SkillMetadata(name: name, description: description, filePath: relativePath, tags: tags)
    }

    private static func parseFrontmatter(_ text: String) -> [String: String]? {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            return nil
        }

        var values: [String: String] = [:]
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "---" {
                return values
            }
            guard let separator = trimmed.firstIndex(of: ":") else {
                continue
            }
            let key = trimmed[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            var value = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("[") && value.hasSuffix("]") {
                value.removeFirst()
                value.removeLast()
            }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            values[key] = value
        }

        return nil
    }

    private static func firstContentLine(_ text: String) -> String? {
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line == "---" || line.hasPrefix("#") {
                continue
            }
            return line
        }
        return nil
    }

    private static func makeRelative(path: String, workspaceRoot: String) -> String {
        if path.hasPrefix(workspaceRoot + "/") {
            return String(path.dropFirst(workspaceRoot.count + 1))
        }
        return path
    }
}
