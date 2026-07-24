import XCTest
@testable import MLXCoder

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

        XCTAssertTrue(composition.prompt.contains("SECTION:core"))
        XCTAssertTrue(composition.prompt.contains("SECTION:memory"))
        XCTAssertTrue(composition.prompt.contains("SECTION:customization"))
        XCTAssertTrue(composition.prompt.contains("SECTION:runtime"))
        XCTAssertTrue(composition.prompt.contains("SECTION:skills"))
        XCTAssertTrue(composition.prompt.contains("SECTION:tools"))

        XCTAssertGreaterThan(composition.sectionTokenEstimates[.core, default: 0], 0)
        XCTAssertGreaterThan(composition.sectionTokenEstimates[.runtime, default: 0], 0)
        XCTAssertGreaterThan(composition.sectionTokenEstimates[.tools, default: 0], 0)
        XCTAssertGreaterThan(composition.sectionTokenEstimates[.skills, default: 0], 0)
    }

    /// Regression test: native-tool-calling backends pass an empty
    /// `toolsBlock` (schemas travel in the API's own `tools` field instead —
    /// see AgentLoop+SystemPrompt.swift). Before this fix, `compose` always
    /// appended the `.tools` layer regardless, producing a useless
    /// `<!-- SECTION:tools -->\n\n<!-- /SECTION:tools -->`
    /// pair in every native-tool-calling prompt (i.e. every remote-model
    /// sub-agent). Empty/whitespace-only optional sections must be omitted
    /// entirely, the same way memory/customization already are.
    func testComposeOmitsEmptyToolsSection() {
        let composition = PromptComposer.compose(
            coreInstructions: "core",
            memorySection: nil,
            customizationSection: nil,
            runtimeSection: "runtime",
            skillsMetadata: [],
            toolsBlock: "",
            maxTokens: nil
        )

        XCTAssertFalse(composition.prompt.contains("SECTION:tools"))
        XCTAssertFalse(composition.prompt.contains("SECTION:memory"))
        XCTAssertFalse(composition.prompt.contains("SECTION:customization"))
        XCTAssertFalse(composition.prompt.contains("SECTION:skills"))
        XCTAssertTrue(composition.prompt.contains("SECTION:core"))
        XCTAssertTrue(composition.prompt.contains("SECTION:runtime"))
    }

    func testComposeOmitsWhitespaceOnlyToolsSection() {
        let composition = PromptComposer.compose(
            coreInstructions: "core",
            memorySection: nil,
            customizationSection: nil,
            runtimeSection: "runtime",
            skillsMetadata: [],
            toolsBlock: "   \n  ",
            maxTokens: nil
        )

        XCTAssertFalse(composition.prompt.contains("SECTION:tools"))
    }

    /// Regression test: `maxTokens` used to be appended as its own separate
    /// `.runtime`-tagged layer *after* the real runtime section, producing
    /// two `SECTION:runtime` marker pairs in one prompt. It must
    /// merge into the same layer as the runtime section instead.
    func testComposeMergesMaxTokensGuardrailIntoSingleRuntimeSection() {
        let composition = PromptComposer.compose(
            coreInstructions: "core",
            memorySection: nil,
            customizationSection: nil,
            runtimeSection: "runtime",
            skillsMetadata: [],
            toolsBlock: "",
            maxTokens: 2048
        )

        let runtimeOpenMarkerCount = composition.prompt.components(separatedBy: "<!-- SECTION:runtime -->").count - 1
        XCTAssertEqual(runtimeOpenMarkerCount, 1, "maxTokens guardrail must merge into the single runtime layer, not append a second one")
        XCTAssertTrue(composition.prompt.contains("runtime"))
        XCTAssertTrue(composition.prompt.contains("2048"))
    }

    /// The incremental-write guardrail ("build it incrementally … use
    /// write_file/append_file") is contradictory noise for a caller with no
    /// file-writing tools (the orchestrator). It must be omitted when
    /// `includeFileGenerationGuardrail` is false, even with `maxTokens` set.
    func testComposeOmitsFileGenerationGuardrailWhenDisabled() {
        let composition = PromptComposer.compose(
            coreInstructions: "core",
            memorySection: nil,
            customizationSection: nil,
            runtimeSection: "runtime",
            skillsMetadata: [],
            toolsBlock: "",
            maxTokens: 2048,
            includeFileGenerationGuardrail: false
        )

        XCTAssertFalse(composition.prompt.contains("build it incrementally"))
        XCTAssertFalse(composition.prompt.contains("append_file"))
        XCTAssertTrue(composition.prompt.contains("SECTION:runtime"))
    }

    /// The guardrail must still appear for a file-writing caller (the default),
    /// so executor-style prompts keep their incremental-write instruction.
    func testComposeKeepsFileGenerationGuardrailByDefault() {
        let composition = PromptComposer.compose(
            coreInstructions: "core",
            memorySection: nil,
            customizationSection: nil,
            runtimeSection: "runtime",
            skillsMetadata: [],
            toolsBlock: "",
            maxTokens: 2048
        )

        XCTAssertTrue(composition.prompt.contains("build it incrementally"))
    }
}
