import XCTest
@testable import NativeAgent

final class PromptComposerTests: XCTestCase {
    func testComposeIncludesSectionsAndTokenEstimates() {
        let composition = PromptComposer.compose(
            coreInstructions: "core",
            memorySection: "memory",
            customizationSection: "custom",
            runtimeSection: "runtime",
            skillsMetadata: [
                SkillMetadata(name: "reviewer", description: "review", filePath: ".github/skills/reviewer/SKILL.md")
            ],
            toolsBlock: "<tools>[]</tools>",
            maxTokens: 2048
        )

        XCTAssertTrue(composition.prompt.contains("PROMPT_SECTION:core"))
        XCTAssertTrue(composition.prompt.contains("PROMPT_SECTION:memory"))
        XCTAssertTrue(composition.prompt.contains("PROMPT_SECTION:customization"))
        XCTAssertTrue(composition.prompt.contains("PROMPT_SECTION:runtime"))
        XCTAssertTrue(composition.prompt.contains("PROMPT_SECTION:skills"))
        XCTAssertTrue(composition.prompt.contains("PROMPT_SECTION:tools"))

        XCTAssertGreaterThan(composition.sectionTokenEstimates[.core, default: 0], 0)
        XCTAssertGreaterThan(composition.sectionTokenEstimates[.runtime, default: 0], 0)
        XCTAssertGreaterThan(composition.sectionTokenEstimates[.tools, default: 0], 0)
        XCTAssertGreaterThan(composition.sectionTokenEstimates[.skills, default: 0], 0)
    }
}
