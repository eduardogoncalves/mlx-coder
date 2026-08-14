// Tests for the internal-agent profile presets (planner/executor/reviewer/
// filesystem/terminal) added on top of TaskTool's existing specialist
// profiles: default tool scopes, the optional-`tools` fallback to those
// presets, and the modified_files digest line used to bridge a sub-agent's
// file edits back into the parent orchestrator's build-check/git flow.

import XCTest
@testable import MLXCoder

final class TaskToolRoleTests: XCTestCase {
    func testPlannerDefaultToolsExcludeMutatingTools() {
        let tools = TaskTool.defaultTools(for: "planner")
        XCTAssertFalse(tools.isEmpty)
        for mutating in ["write_file", "edit_file", "append_file", "patch", "bash"] {
            XCTAssertFalse(tools.contains(mutating), "planner should not default to '\(mutating)'")
        }
        XCTAssertTrue(tools.contains("plan_file"))
    }

    func testExecutorDefaultToolsIncludeMutatingAndShellTools() {
        let tools = TaskTool.defaultTools(for: "executor")
        for expected in ["write_file", "edit_file", "patch", "bash"] {
            XCTAssertTrue(tools.contains(expected), "executor should default to '\(expected)'")
        }
    }

    func testReviewerDefaultToolsAreReadOnlyPlusBuildCheck() {
        let tools = TaskTool.defaultTools(for: "reviewer")
        XCTAssertTrue(tools.contains("build_check"))
        for mutating in ["write_file", "edit_file", "append_file", "patch", "bash"] {
            XCTAssertFalse(tools.contains(mutating), "reviewer should not default to '\(mutating)'")
        }
    }

    func testFilesystemProfileHasNoBash() {
        XCTAssertFalse(TaskTool.defaultTools(for: "filesystem").contains("bash"))
    }

    func testTerminalProfileIsBashOnly() {
        XCTAssertEqual(Set(TaskTool.defaultTools(for: "terminal")), ["bash", "build_check"])
    }

    func testUnknownProfileHasNoDefaultTools() {
        XCTAssertTrue(TaskTool.defaultTools(for: "not_a_real_profile").isEmpty)
    }

    func testValidateAndNormalizeArgumentsFallsBackToProfileDefaultsWhenToolsOmitted() throws {
        let result = TaskTool.validateAndNormalizeArguments([
            "description": "Implement the feature",
            "profile": "executor"
        ])
        switch result {
        case .success(let values):
            XCTAssertEqual(values.profileName, "executor")
            XCTAssertEqual(values.tools, TaskTool.defaultTools(for: "executor"))
        case .failure(.message(let message)):
            XCTFail("Expected fallback to executor's default tools, got error: \(message)")
        }
    }

    func testValidateAndNormalizeArgumentsExplicitToolsOverridePreset() throws {
        let result = TaskTool.validateAndNormalizeArguments([
            "description": "Read one file",
            "profile": "executor",
            "tools": ["read_file"]
        ])
        switch result {
        case .success(let values):
            XCTAssertEqual(values.tools, ["read_file"])
        case .failure(.message(let message)):
            XCTFail("Expected explicit tools to override the preset, got error: \(message)")
        }
    }

    func testValidateAndNormalizeArgumentsFailsForUnknownProfileWithNoTools() throws {
        let result = TaskTool.validateAndNormalizeArguments([
            "description": "Do something",
            "profile": "not_a_real_profile"
        ])
        switch result {
        case .success:
            XCTFail("Expected an unknown profile with no explicit tools to fail")
        case .failure(.message(let message)):
            XCTAssertTrue(message.contains("no default preset"))
        }
    }

    // MARK: - modified_files digest bridging

    func testDigestOmitsModifiedFilesLineWhenEmpty() {
        let digest = TaskTool.makeSubagentDigest(
            status: "success",
            profileName: "planner",
            taskDescription: "research the router",
            summary: "Found the entry point",
            archivePath: nil
        )
        XCTAssertFalse(digest.contains("modified_files:"))
        XCTAssertEqual(TaskTool.parseModifiedFiles(fromDigest: digest), [])
    }

    // MARK: - Role-model fallback mapping

    func testRoleModelKeyMapsResearchFlavoredProfilesToPlanner() {
        XCTAssertEqual(TaskTool.roleModelKey(forProfile: "planner"), "planner")
        XCTAssertEqual(TaskTool.roleModelKey(forProfile: "codebase_research"), "planner")
    }

    func testRoleModelKeyMapsMutationCapableProfilesToExecutor() {
        for profile in ["executor", "general", "filesystem", "terminal", "test_engineering", "docs"] {
            XCTAssertEqual(TaskTool.roleModelKey(forProfile: profile), "executor", "\(profile) should map to executor")
        }
    }

    func testRoleModelKeyMapsReadOnlyVerificationProfilesToReviewer() {
        XCTAssertEqual(TaskTool.roleModelKey(forProfile: "reviewer"), "reviewer")
        XCTAssertEqual(TaskTool.roleModelKey(forProfile: "security_review"), "reviewer")
    }

    func testRoleModelKeyFallsBackToProfileNameForUnknownProfiles() {
        XCTAssertEqual(TaskTool.roleModelKey(forProfile: "some_future_profile"), "some_future_profile")
    }

    func testDigestRoundTripsModifiedFiles() {
        let digest = TaskTool.makeSubagentDigest(
            status: "success",
            profileName: "executor",
            taskDescription: "add the login button",
            summary: "Added the button and wired the handler",
            archivePath: nil,
            modifiedFiles: ["Sources/UI/Login.swift", "Sources/App/Router.swift"]
        )
        XCTAssertTrue(digest.contains("modified_files:"))
        XCTAssertEqual(
            TaskTool.parseModifiedFiles(fromDigest: digest),
            ["Sources/App/Router.swift", "Sources/UI/Login.swift"]
        )
    }

    // MARK: - files_read digest bridging (WorkflowEngine's {{all_files}} source)

    func testDigestOmitsReadFilesLineWhenEmpty() {
        let digest = TaskTool.makeSubagentDigest(
            status: "success",
            profileName: "codebase_research",
            taskDescription: "find the auth entry point",
            summary: "It's in Router.swift",
            archivePath: nil
        )
        XCTAssertFalse(digest.contains("files_read:"))
        XCTAssertEqual(TaskTool.parseReadFiles(fromDigest: digest), [])
    }

    func testDigestRoundTripsReadFiles() {
        let digest = TaskTool.makeSubagentDigest(
            status: "success",
            profileName: "codebase_research",
            taskDescription: "find the auth entry point",
            summary: "It's in Router.swift",
            archivePath: nil,
            readFiles: ["Sources/App/Router.swift", "Sources/Auth/Session.swift"]
        )
        XCTAssertTrue(digest.contains("files_read:"))
        XCTAssertEqual(
            TaskTool.parseReadFiles(fromDigest: digest),
            ["Sources/App/Router.swift", "Sources/Auth/Session.swift"]
        )
    }

    func testDigestExcludesModifiedFilesFromReadFilesLine() {
        // A file the stage both read and then edited is already covered by
        // modified_files — repeating it in files_read would just be noise.
        let digest = TaskTool.makeSubagentDigest(
            status: "success",
            profileName: "executor",
            taskDescription: "add the login button",
            summary: "Added the button",
            archivePath: nil,
            modifiedFiles: ["Sources/UI/Login.swift"],
            readFiles: ["Sources/UI/Login.swift", "Sources/App/Router.swift"]
        )
        XCTAssertEqual(TaskTool.parseModifiedFiles(fromDigest: digest), ["Sources/UI/Login.swift"])
        XCTAssertEqual(TaskTool.parseReadFiles(fromDigest: digest), ["Sources/App/Router.swift"])
    }

    // MARK: - statusLineSummary

    /// Regression test: TaskTool used to embed the full, unbounded (often
    /// multi-line) task description verbatim in the "Starting sub-agent..."
    /// status line. A multi-paragraph spec pushed through the TUI's
    /// single-line status/spinner render path corrupted the whole layout
    /// below it — see the "Starting sub-agent (profile=executor" report.
    func testStatusLineSummaryCollapsesMultiLineDescriptionToOneLine() {
        let description = """
        Crie um arquivo HTML com as seguintes funcionalidades:
        1. Um campo de input de texto para informar o CNPJ.
        2. Uma função que aplique a máscara do CNPJ automaticamente.
        """
        let summary = TaskTool.statusLineSummary(description)
        XCTAssertFalse(summary.contains("\n"))
        XCTAssertTrue(summary.hasPrefix("Crie um arquivo HTML"))
        XCTAssertTrue(summary.hasSuffix("…"), "multi-line input must be marked as truncated")
    }

    func testStatusLineSummaryTruncatesLongSingleLineDescriptions() {
        let description = String(repeating: "a", count: 500)
        let summary = TaskTool.statusLineSummary(description, maxCharacters: 160)
        XCTAssertEqual(summary.count, 161) // 160 chars + the "…" marker
        XCTAssertTrue(summary.hasSuffix("…"))
    }

    func testStatusLineSummaryLeavesShortSingleLineDescriptionsUnchanged() {
        let summary = TaskTool.statusLineSummary("add a login button")
        XCTAssertEqual(summary, "add a login button")
    }

    // MARK: - isMutatingTaskCall

    /// The orchestrator must be free to delegate research without an approval
    /// prompt — even in PLAN mode, since that's the only way it can research
    /// anything (see AgentLoop.isDestructiveToolCall).
    func testReadOnlyProfilesAreNotMutating() {
        for profile in ["planner", "reviewer", "codebase_research", "security_review"] {
            XCTAssertFalse(
                TaskTool.isMutatingTaskCall(arguments: ["profile": profile]),
                "'\(profile)' has no mutating tools by default and should not require approval"
            )
        }
    }

    func testMutationCapableProfilesAreMutating() {
        for profile in ["executor", "filesystem", "terminal", "docs", "general", "test_engineering"] {
            XCTAssertTrue(
                TaskTool.isMutatingTaskCall(arguments: ["profile": profile]),
                "'\(profile)' can write files or run shell commands and should require approval"
            )
        }
    }

    func testMissingProfileDefaultsToGeneralWhichIsMutating() {
        // normalizeProfileName(nil) -> "general", whose default tools include bash/write_file.
        XCTAssertTrue(TaskTool.isMutatingTaskCall(arguments: [:]))
    }

    func testExplicitToolsOverridePresetForMutationClassification() {
        // A read-only profile explicitly handed a mutating tool must still be
        // treated as mutating — the explicit `tools` list always wins.
        XCTAssertTrue(TaskTool.isMutatingTaskCall(arguments: ["profile": "planner", "tools": ["bash"]]))
        // A normally-mutating profile explicitly restricted to read-only
        // tools must not require approval.
        XCTAssertFalse(TaskTool.isMutatingTaskCall(arguments: ["profile": "executor", "tools": ["read_file"]]))
    }

    func testPlanFileAloneDoesNotCountAsMutating() {
        // `planner`'s default tools include `plan_file` — writing PLAN.MD is
        // already treated as a safe planning action, not a destructive one,
        // whether triggered directly or via a delegated planner sub-agent.
        XCTAssertFalse(TaskTool.isMutatingTaskCall(arguments: ["profile": "planner", "tools": ["plan_file"]]))
    }

    // MARK: - toolResultLooksTruncated (used to detect a trailing-fragment
    // final response right after a truncated tool result — see the
    // else-if branch in TaskTool.run beside the empty-response nudge).

    func testToolResultLooksTruncatedDetectsBoundedRawFallbackMarker() {
        let message = Message(
            role: .tool,
            content: "[Tool output could not be summarized; bounded raw fallback]\nTool: read_file\n...\n[... 1124 characters omitted ...]"
        )
        XCTAssertTrue(TaskTool.toolResultLooksTruncated(message))
    }

    func testToolResultLooksTruncatedDetectsBudgetGuardMarker() {
        let message = Message(role: .tool, content: "[Context budget guard] This result has 400 lines...")
        XCTAssertTrue(TaskTool.toolResultLooksTruncated(message))
    }

    func testToolResultLooksTruncatedDetectsReadFileContinuationMarker() {
        let message = Message(role: .tool, content: "[Read lines 1-200 of 900. File continues — call read_file with start_line: 201 to read the next section.]")
        XCTAssertTrue(TaskTool.toolResultLooksTruncated(message))
    }

    func testToolResultLooksTruncatedFalseForOrdinaryResult() {
        let message = Message(role: .tool, content: "using System;\nnamespace Foo { }")
        XCTAssertFalse(TaskTool.toolResultLooksTruncated(message))
    }

    func testToolResultLooksTruncatedFalseForNonToolRole() {
        // The marker text alone must not match on a non-tool message — only
        // an actual tool result can have been truncated.
        let message = Message(role: .assistant, content: "characters omitted, as I was saying")
        XCTAssertFalse(TaskTool.toolResultLooksTruncated(message))
    }
}
