import XCTest
@testable import NativeAgent

final class TaskToolProfileTests: XCTestCase {
    func testNormalizeProfileDefaultsToGeneral() {
        XCTAssertEqual(TaskTool.normalizeProfileName(nil), "general")
        XCTAssertEqual(TaskTool.normalizeProfileName(""), "general")
        XCTAssertEqual(TaskTool.normalizeProfileName("  "), "general")
    }

    func testNormalizeProfileConvertsHyphenToUnderscore() {
        XCTAssertEqual(TaskTool.normalizeProfileName("security-review"), "security_review")
    }

    func testBaseInstructionsExistForAllSupportedProfiles() {
        for name in TaskTool.supportedProfileNames {
            let instructions = TaskTool.baseInstructions(for: name)
            XCTAssertNotNil(instructions, "Expected instructions for profile: \(name)")
            XCTAssertTrue(instructions?.contains("specialized sub-agent") == true)
        }
    }

    func testInvalidProfileHasNoInstructions() {
        XCTAssertNil(TaskTool.baseInstructions(for: "unknown_profile"))
    }

    func testResolveIsolationPlanDefaultsUnderWorkspaceAndIsEphemeral() throws {
        let workspace = makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(atPath: workspace) }

        let plan = try TaskTool.resolveIsolationPlan(workspaceRoot: workspace, requestedSubdirectory: nil)
        XCTAssertTrue(plan.root.hasPrefix(workspace + "/"))
        XCTAssertTrue(plan.root.contains(".native-agent/subagent-runs/"))
        XCTAssertTrue(plan.isEphemeral)
    }

    func testResolveIsolationPlanRejectsTraversalOutsideWorkspace() throws {
        let workspace = makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(atPath: workspace) }

        XCTAssertThrowsError(
            try TaskTool.resolveIsolationPlan(workspaceRoot: workspace, requestedSubdirectory: "../outside")
        )
    }

    func testResolveIsolationPlanWithCustomDirectoryIsNotEphemeral() throws {
        let workspace = makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(atPath: workspace) }

        let plan = try TaskTool.resolveIsolationPlan(workspaceRoot: workspace, requestedSubdirectory: "tmp/subagent")
        XCTAssertTrue(plan.root.hasSuffix("/tmp/subagent"))
        XCTAssertFalse(plan.isEphemeral)
    }

    func testValidateIsolationOptionsRejectsCleanupWithoutIsolation() {
        let error = TaskTool.validateIsolationOptions(
            isolate: false,
            requestedSubdirectory: nil,
            cleanupIsolation: true
        )
        XCTAssertEqual(error, "cleanup_isolation=true requires isolate=true.")
    }

    func testValidateIsolationOptionsRejectsIsolationDirectoryWithoutIsolation() {
        let error = TaskTool.validateIsolationOptions(
            isolate: false,
            requestedSubdirectory: "tmp/custom",
            cleanupIsolation: false
        )
        XCTAssertEqual(error, "isolation_directory requires isolate=true.")
    }

    func testValidateIsolationOptionsRejectsCleanupWithCustomIsolationDirectory() {
        let error = TaskTool.validateIsolationOptions(
            isolate: true,
            requestedSubdirectory: "tmp/custom",
            cleanupIsolation: true
        )
        XCTAssertEqual(
            error,
            "cleanup_isolation=true is only allowed for auto-created isolated directories. Omit isolation_directory or disable cleanup_isolation."
        )
    }

    func testValidateIsolationOptionsAllowsEphemeralCleanup() {
        let error = TaskTool.validateIsolationOptions(
            isolate: true,
            requestedSubdirectory: nil,
            cleanupIsolation: true
        )
        XCTAssertNil(error)
    }

    func testSanitizeRequestedToolsRejectsEmptyList() {
        switch TaskTool.sanitizeRequestedTools([]) {
        case .success:
            XCTFail("Expected empty tool list to fail")
        case .failure(.message(let message)):
            XCTAssertEqual(message, "Task tool requires at least one tool in 'tools'.")
        }
    }

    func testSanitizeRequestedToolsRejectsRecursiveTaskTool() {
        switch TaskTool.sanitizeRequestedTools(["read_file", "task"]) {
        case .success:
            XCTFail("Expected recursive task tool to fail")
        case .failure(.message(let message)):
            XCTAssertEqual(message, "Task tool cannot include 'task' in delegated sub-agent tools (max depth 1).")
        }
    }

    func testSanitizeRequestedToolsRejectsRecursiveTaskToolCaseInsensitively() {
        switch TaskTool.sanitizeRequestedTools(["read_file", "TaSk"]) {
        case .success:
            XCTFail("Expected recursive task tool to fail")
        case .failure(.message(let message)):
            XCTAssertEqual(message, "Task tool cannot include 'task' in delegated sub-agent tools (max depth 1).")
        }
    }

    func testSanitizeRequestedToolsRejectsMoreThanLimit() {
        let tools = (0...TaskTool.maxDelegatedTools).map { "tool_\($0)" }
        switch TaskTool.sanitizeRequestedTools(tools) {
        case .success:
            XCTFail("Expected oversized delegated tools list to fail")
        case .failure(.message(let message)):
            XCTAssertEqual(message, "Task tool supports at most \(TaskTool.maxDelegatedTools) delegated tools.")
        }
    }

    func testSanitizeRequestedToolsDeduplicatesAndTrims() {
        switch TaskTool.sanitizeRequestedTools([" read_file ", "read_file", "grep", ""]) {
        case .failure(.message(let message)):
            XCTFail("Expected sanitization success, got error: \(message)")
        case .success(let tools):
            XCTAssertEqual(tools, ["read_file", "grep"])
        }
    }

    func testSanitizeRequestedToolsPreservesOriginalCasing() {
        switch TaskTool.sanitizeRequestedTools(["Read_File", "GREP"]) {
        case .failure(.message(let message)):
            XCTFail("Expected sanitization success, got error: \(message)")
        case .success(let tools):
            XCTAssertEqual(tools, ["Read_File", "GREP"])
        }
    }

    func testSanitizeRequestedToolsDeduplicatesCaseInsensitively() {
        switch TaskTool.sanitizeRequestedTools(["Read_File", "read_file", "Grep"]) {
        case .failure(.message(let message)):
            XCTFail("Expected sanitization success, got error: \(message)")
        case .success(let tools):
            XCTAssertEqual(tools, ["Read_File", "Grep"])
        }
    }

    func testSanitizeDescriptionRejectsWhitespaceOnly() {
        switch TaskTool.sanitizeDescription("   \n\t ") {
        case .success:
            XCTFail("Expected whitespace-only description to fail")
        case .failure(.message(let message)):
            XCTAssertEqual(message, "Task tool requires a non-empty 'description'.")
        }
    }

    func testSanitizeDescriptionTrimsWhitespace() {
        switch TaskTool.sanitizeDescription("  investigate failing test  ") {
        case .failure(.message(let message)):
            XCTFail("Expected description sanitization success, got error: \(message)")
        case .success(let description):
            XCTAssertEqual(description, "investigate failing test")
        }
    }

    func testSanitizeDescriptionRejectsOverLimitLength() {
        let tooLong = String(repeating: "a", count: TaskTool.maxDescriptionCharacters + 1)
        switch TaskTool.sanitizeDescription(tooLong) {
        case .success:
            XCTFail("Expected oversized description to fail")
        case .failure(.message(let message)):
            XCTAssertEqual(
                message,
                "Task description exceeds maximum length of \(TaskTool.maxDescriptionCharacters) characters."
            )
        }
    }

    func testExtractDescriptionRejectsMissingValue() {
        switch TaskTool.extractDescription(from: [:]) {
        case .success:
            XCTFail("Expected missing description to fail")
        case .failure(.message(let message)):
            XCTAssertEqual(message, "Missing required argument: description")
        }
    }

    func testExtractDescriptionRejectsInvalidType() {
        switch TaskTool.extractDescription(from: ["description": 123]) {
        case .success:
            XCTFail("Expected invalid description type to fail")
        case .failure(.message(let message)):
            XCTAssertEqual(message, "Invalid argument type: description must be a string")
        }
    }

    func testExtractRequestedToolsRejectsInvalidType() {
        switch TaskTool.extractRequestedTools(from: ["tools": [1, 2, 3]]) {
        case .success:
            XCTFail("Expected invalid tools type to fail")
        case .failure(.message(let message)):
            XCTAssertEqual(message, "Invalid argument type: tools must be an array of strings")
        }
    }

    func testExtractRequestedToolsDefaultsToEmptyWhenMissing() {
        switch TaskTool.extractRequestedTools(from: [:]) {
        case .failure(.message(let message)):
            XCTFail("Expected missing tools to default to empty, got error: \(message)")
        case .success(let tools):
            XCTAssertEqual(tools, [])
        }
    }

    func testExtractProfileNameRejectsInvalidType() {
        switch TaskTool.extractProfileName(from: ["profile": 10]) {
        case .success:
            XCTFail("Expected invalid profile type to fail")
        case .failure(.message(let message)):
            XCTAssertEqual(message, "Invalid argument type: profile must be a string")
        }
    }

    func testExtractIsolateRejectsInvalidType() {
        switch TaskTool.extractIsolate(from: ["isolate": "true"]) {
        case .success:
            XCTFail("Expected invalid isolate type to fail")
        case .failure(.message(let message)):
            XCTAssertEqual(message, "Invalid argument type: isolate must be a boolean")
        }
    }

    func testExtractIsolationDirectoryRejectsInvalidType() {
        switch TaskTool.extractIsolationDirectory(from: ["isolation_directory": true]) {
        case .success:
            XCTFail("Expected invalid isolation_directory type to fail")
        case .failure(.message(let message)):
            XCTAssertEqual(message, "Invalid argument type: isolation_directory must be a string")
        }
    }

    func testExtractIsolationDirectoryRejectsBlankValue() {
        switch TaskTool.extractIsolationDirectory(from: ["isolation_directory": "   "]) {
        case .success:
            XCTFail("Expected blank isolation_directory to fail")
        case .failure(.message(let message)):
            XCTAssertEqual(message, "Invalid argument value: isolation_directory must be non-empty when provided")
        }
    }

    func testExtractCleanupIsolationRejectsInvalidType() {
        switch TaskTool.extractCleanupIsolation(from: ["cleanup_isolation": "yes"]) {
        case .success:
            XCTFail("Expected invalid cleanup_isolation type to fail")
        case .failure(.message(let message)):
            XCTAssertEqual(message, "Invalid argument type: cleanup_isolation must be a boolean")
        }
    }

    func testValidateAndNormalizeArgumentsRejectsInvalidIsolationCombo() {
        let arguments: [String: Any] = [
            "description": "investigate failures",
            "tools": ["read_file"],
            "cleanup_isolation": true,
        ]

        switch TaskTool.validateAndNormalizeArguments(arguments) {
        case .success:
            XCTFail("Expected invalid isolation option combination to fail")
        case .failure(.message(let message)):
            XCTAssertEqual(message, "cleanup_isolation=true requires isolate=true.")
        }
    }

    func testValidateAndNormalizeArgumentsReturnsSanitizedValues() {
        let arguments: [String: Any] = [
            "description": "  investigate failures  ",
            "tools": [" read_file ", "Read_File", "grep"],
            "profile": "security-review",
            "isolate": true,
            "cleanup_isolation": false,
        ]

        switch TaskTool.validateAndNormalizeArguments(arguments) {
        case .failure(.message(let message)):
            XCTFail("Expected validation success, got error: \(message)")
        case .success(let values):
            XCTAssertEqual(values.description, "investigate failures")
            XCTAssertEqual(values.tools, ["read_file", "grep"])
            XCTAssertEqual(values.profileName, "security_review")
            XCTAssertTrue(values.isolate)
            XCTAssertNil(values.isolationDirectory)
            XCTAssertFalse(values.cleanupIsolation)
        }
    }

    func testCompactDigestSummaryLimitsLinesAndCharacters() {
        let text = """
        line one
        line two
        line three
        line four
        """

        let summary = TaskTool.compactDigestSummary(from: text, maxLines: 2, maxCharacters: 40)
        XCTAssertEqual(summary, "line one\nline two")

        let longText = String(repeating: "a", count: 120)
        let clipped = TaskTool.compactDigestSummary(from: longText, maxLines: 5, maxCharacters: 20)
        XCTAssertEqual(clipped.count, 23)
        XCTAssertTrue(clipped.hasSuffix("..."))
    }

    func testCompactDigestSummaryReturnsFallbackForEmptyInput() {
        let summary = TaskTool.compactDigestSummary(from: "   \n\n   ")
        XCTAssertEqual(summary, "No summary available.")
    }

    func testMakeSubagentDigestIncludesArchiveWhenProvided() {
        let digest = TaskTool.makeSubagentDigest(
            status: "success",
            profileName: "codebase_research",
            taskDescription: "inspect router",
            summary: "Found two call sites",
            archivePath: ".native-agent/subagent-logs/abc"
        )

        XCTAssertTrue(digest.contains("[Sub-agent digest]"))
        XCTAssertTrue(digest.contains("status: success"))
        XCTAssertTrue(digest.contains("profile: codebase_research"))
        XCTAssertTrue(digest.contains("task: inspect router"))
        XCTAssertTrue(digest.contains("archive: .native-agent/subagent-logs/abc"))
    }

    func testSubagentRunIDIncludesProfileAndSuffix() {
        let id = TaskTool.subagentRunID(profileName: "Security Review")
        XCTAssertTrue(id.contains("security-review"))
        XCTAssertEqual(id.split(separator: "-").count >= 4, true)
    }

    private func makeTemporaryWorkspace() -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path()
    }
}
