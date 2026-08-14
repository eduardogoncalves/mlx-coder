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

    public init(workspaceRoot: String, includeHomeSkills: Bool = true) {
        let discovered = SkillsRegistry.discoverSkills(
            workspaceRoot: workspaceRoot,
            includeHomeSkills: includeHomeSkills
        )
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

    public func metadata(name: String) -> SkillMetadata? {
        resolveEntry(name: name)?.metadata
    }

    public func loadBody(name: String) throws -> String? {
        guard let entry = resolveEntry(name: name) else {
            return nil
        }
        if let cached = cachedBodies[entry.metadata.name] {
            return cached
        }

        let body = try String(contentsOfFile: entry.absolutePath, encoding: .utf8)
        cachedBodies[entry.metadata.name] = body
        return body
    }

    /// Exact lookup first, then case-insensitive fallback so model-typed names
    /// like "Dotnet-CLI" still resolve to "dotnet-cli".
    private func resolveEntry(name: String) -> SkillEntry? {
        if let entry = entriesByName[name] {
            return entry
        }
        return entriesByName.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func discoverSkills(
        workspaceRoot: String,
        includeHomeSkills: Bool
    ) -> [SkillEntry] {
        let fm = FileManager.default

        // Dynamically discover any <workspace>/.<dotdir>/skills directories
        // (e.g. .github/skills, .claude/skills, .copilot/skills, .codex/skills, etc.)
        var candidateRoots: [String] = []
        if let topLevel = try? fm.contentsOfDirectory(atPath: workspaceRoot) {
            for entry in topLevel where entry.hasPrefix(".") {
                let skillsPath = workspaceRoot + "/" + entry + "/skills"
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: skillsPath, isDirectory: &isDir), isDir.boolValue {
                    candidateRoots.append(skillsPath)
                }
            }
        }
        candidateRoots.append(workspaceRoot + "/skills")
        if includeHomeSkills {
            candidateRoots.append(FileManager.default.homeDirectoryForCurrentUser.path + "/skills")
        }

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

extension SkillsRegistry {
    /// Ranks `skills` by lexical overlap with `query` (a tag match counts
    /// more than a name match, which counts more than a description-word
    /// match) and returns the top `limit` with a nonzero score, highest
    /// first. Deliberately a cheap, deterministic keyword filter — no model
    /// call — since this is meant to run on every user turn.
    ///
    /// Exists so a workspace with many skills doesn't have to choose between
    /// dumping every skill's metadata into the model's context on every turn
    /// (diluting attention on small models — see `PromptComposer`) or hiding
    /// skills entirely. Callers inject the result per-turn, alongside the
    /// user's message (see `AgentLoop.processUserMessage`), never into the
    /// static system prompt — mirrors `ContextRetriever`'s per-turn
    /// injection, which exists for the same KV-cache-prefix reason.
    public static func relevantSkills(_ skills: [SkillMetadata], to query: String, limit: Int = 3) -> [SkillMetadata] {
        let queryTokens = tokenize(query)
        guard !queryTokens.isEmpty else { return [] }

        func score(_ skill: SkillMetadata) -> Int {
            let tagTokens = Set(skill.tags.flatMap(tokenize))
            let nameTokens = tokenize(skill.name)
            let descriptionTokens = tokenize(skill.description)
            var total = 0
            for token in queryTokens {
                if tagTokens.contains(token) { total += 3 }
                if nameTokens.contains(token) { total += 2 }
                if descriptionTokens.contains(token) { total += 1 }
            }
            return total
        }

        return skills
            .map { ($0, score($0)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    private static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "for", "to", "of", "in", "on", "with",
        "this", "that", "is", "are", "how", "what", "do", "does", "use", "using",
        "can", "you", "please", "need", "want", "add", "make", "get", "set",
    ]

    private static func tokenize(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 && !stopwords.contains($0) }
        )
    }
}
