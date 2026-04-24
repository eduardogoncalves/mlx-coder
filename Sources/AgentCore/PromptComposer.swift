import Foundation

public enum PromptSection: String, CaseIterable, Sendable {
    case core
    case memory
    case customization
    case runtime
    case skills
    case tools
}

public struct PromptComposition: Sendable {
    public let prompt: String
    public let sectionTokenEstimates: [PromptSection: Int]

    public init(prompt: String, sectionTokenEstimates: [PromptSection: Int]) {
        self.prompt = prompt
        self.sectionTokenEstimates = sectionTokenEstimates
    }
}

public enum PromptComposer {
    public static func compose(
        coreInstructions: String,
        memorySection: String?,
        customizationSection: String?,
        runtimeSection: String,
        skillsMetadata: [SkillMetadata],
        toolsBlock: String,
        maxTokens: Int?
    ) -> PromptComposition {
        var layers: [(PromptSection, String)] = []
        layers.append((.core, coreInstructions))

        if let memorySection {
            let trimmed = memorySection.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                layers.append((.memory, trimmed))
            }
        }

        if let customizationSection {
            let trimmed = customizationSection.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                layers.append((.customization, trimmed))
            }
        }

        layers.append((.runtime, runtimeSection))

        if !skillsMetadata.isEmpty {
            let skillsBody = skillsMetadata
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { skill in
                    if skill.tags.isEmpty {
                        return "- \(skill.name): \(skill.description) (\(skill.filePath))"
                    }
                    return "- \(skill.name): \(skill.description) (\(skill.filePath), tags: \(skill.tags.joined(separator: ", ")))"
                }
                .joined(separator: "\n")
            layers.append((.skills, "Available skills metadata:\n\(skillsBody)"))
        }

        layers.append((.tools, toolsBlock))

        var sectionEstimates: [PromptSection: Int] = [:]
        var promptParts: [String] = []

        for (section, body) in layers {
            let wrapped = wrap(section: section, body: body)
            promptParts.append(wrapped)
            sectionEstimates[section] = estimatedTokens(body)
        }

        if let maxTokens {
            let generationGuardrail = """
            CRITICAL INSTRUCTION: You have a maximum generation limit of \(maxTokens) tokens per turn.
            If you need to write or generate a file, you MUST build it incrementally.
            First, use the `write_file` tool to create the file with the minimal valid structure (scaffold).
            Then, in subsequent turns, add one section at a time using `patch_file`. This ensures high quality and controlled generation.
            """
            let wrapped = wrap(section: .runtime, body: generationGuardrail)
            promptParts.append(wrapped)
            sectionEstimates[.runtime, default: 0] += estimatedTokens(generationGuardrail)
        }

        let prompt = promptParts.joined(separator: "\n\n")
        return PromptComposition(prompt: prompt, sectionTokenEstimates: sectionEstimates)
    }

    private static func wrap(section: PromptSection, body: String) -> String {
        """
        <!-- PROMPT_SECTION:\(section.rawValue) -->
        \(body)
        <!-- END_PROMPT_SECTION:\(section.rawValue) -->
        """
    }

    private static func estimatedTokens(_ text: String) -> Int {
        max(1, text.count / 4)
    }
}
