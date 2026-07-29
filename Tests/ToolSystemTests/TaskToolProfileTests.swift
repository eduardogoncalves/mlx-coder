import XCTest
@testable import MLXCoder

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
            // Each profile leads with its own single identity statement
            // ("You are the X agent...") rather than a generic preamble.
            XCTAssertTrue(instructions?.hasPrefix("You are") == true)
            XCTAssertTrue(instructions?.contains("Do not ask the user for permission to proceed.") == true)
        }
    }

    func testInvalidProfileHasNoInstructions() {
        XCTAssertNil(TaskTool.baseInstructions(for: "unknown_profile"))
    }

    // Supplying `isolation_directory` without `isolate: true` no longer errors —
    // the directory is the intent to isolate, so `isolate` is inferred true
    // instead of wasting a round-trip on the missing companion flag.
    func testIsolationDirectoryInfersIsolate() {
        switch TaskTool.validateAndNormalizeArguments([
            "description": "do work",
            "isolation_directory": "tmp/custom",
        ]) {
        case .success(let args):
            XCTAssertTrue(args.isolate)
            XCTAssertEqual(args.isolationDirectory, "tmp/custom")
        case .failure(.message(let message)):
            XCTFail("Expected isolation_directory to infer isolate=true, got error: \(message)")
        }
    }

    func testIsolateWithDirectoryIsAccepted() {
        switch TaskTool.validateAndNormalizeArguments([
            "description": "do work",
            "isolate": true,
            "isolation_directory": "tmp/custom",
        ]) {
        case .success(let args):
            XCTAssertTrue(args.isolate)
            XCTAssertEqual(args.isolationDirectory, "tmp/custom")
        case .failure(.message(let message)):
            XCTFail("Expected isolate+directory to succeed, got error: \(message)")
        }
    }

    // `isolate: true` with no directory is a no-op (sub-agents already share
    // the orchestrator's workspace), not an error — this keeps existing
    // callers that always pass `isolate: true` from breaking.
    func testIsolateAloneIsAcceptedAsNoOp() {
        switch TaskTool.validateAndNormalizeArguments([
            "description": "do work",
            "isolate": true,
        ]) {
        case .success(let args):
            XCTAssertTrue(args.isolate)
            XCTAssertNil(args.isolationDirectory)
        case .failure(.message(let message)):
            XCTFail("Expected isolate-alone to succeed, got error: \(message)")
        }
    }

    func testSanitizeRequestedToolsAllowsEmptyList() {
        // An empty `tools` list is now valid at the sanitize layer — callers fall
        // back to the profile's default tool preset in validateAndNormalizeArguments.
        switch TaskTool.sanitizeRequestedTools([]) {
        case .success(let tools):
            XCTAssertEqual(tools, [])
        case .failure(.message(let message)):
            XCTFail("Expected empty tool list to succeed, got error: \(message)")
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

    func testValidateAndNormalizeArgumentsInfersIsolateFromDirectory() {
        // isolation_directory without an explicit isolate flag no longer fails —
        // the directory is the intent, so isolate is inferred true.
        let arguments: [String: Any] = [
            "description": "investigate failures",
            "tools": ["read_file"],
            "isolation_directory": "tmp/custom",
        ]

        switch TaskTool.validateAndNormalizeArguments(arguments) {
        case .success(let args):
            XCTAssertTrue(args.isolate)
            XCTAssertEqual(args.isolationDirectory, "tmp/custom")
        case .failure(.message(let message)):
            XCTFail("Expected isolation_directory to infer isolate=true, got error: \(message)")
        }
    }

    func testValidateAndNormalizeArgumentsReturnsSanitizedValues() {
        let arguments: [String: Any] = [
            "description": "  investigate failures  ",
            "tools": [" read_file ", "Read_File", "grep"],
            "profile": "security-review",
            "isolate": true,
            "isolation_directory": "tmp/custom",
        ]

        switch TaskTool.validateAndNormalizeArguments(arguments) {
        case .failure(.message(let message)):
            XCTFail("Expected validation success, got error: \(message)")
        case .success(let values):
            XCTAssertEqual(values.description, "investigate failures")
            XCTAssertEqual(values.tools, ["read_file", "grep"])
            XCTAssertEqual(values.profileName, "security_review")
            XCTAssertTrue(values.isolate)
            XCTAssertEqual(values.isolationDirectory, "tmp/custom")
        }
    }

    // MARK: - Resume argument

    func testExtractResumeDefaultsToNilWhenMissing() {
        switch TaskTool.extractResume(from: [:]) {
        case .success(let value):
            XCTAssertNil(value)
        case .failure(let error):
            XCTFail("Expected nil resume, got error: \(error)")
        }
    }

    func testExtractResumeTreatsBlankAsNil() {
        switch TaskTool.extractResume(from: ["resume": "   "]) {
        case .success(let value):
            XCTAssertNil(value)
        case .failure(let error):
            XCTFail("Expected nil resume for blank, got error: \(error)")
        }
    }

    func testExtractResumeRejectsInvalidType() {
        switch TaskTool.extractResume(from: ["resume": 42]) {
        case .success:
            XCTFail("Expected failure for non-string resume")
        case .failure(.message(let message)):
            XCTAssertTrue(message.contains("resume must be a string"))
        }
    }

    func testExtractResumeResolvesBareRunID() {
        switch TaskTool.extractResume(from: ["resume": "20260726-planner-abc12345"]) {
        case .success(let value):
            XCTAssertEqual(value, ".native-agent/subagent-logs/20260726-planner-abc12345/history.json")
        case .failure(let error):
            XCTFail("Expected resolved path, got error: \(error)")
        }
    }

    func testExtractResumeResolvesArchiveDirectoryPath() {
        switch TaskTool.extractResume(from: ["resume": ".native-agent/subagent-logs/run-1"]) {
        case .success(let value):
            XCTAssertEqual(value, ".native-agent/subagent-logs/run-1/history.json")
        case .failure(let error):
            XCTFail("Expected resolved path, got error: \(error)")
        }
    }

    func testValidateAndNormalizeArgumentsPopulatesResume() {
        let arguments: [String: Any] = [
            "description": "continue",
            "resume": "run-42",
        ]
        switch TaskTool.validateAndNormalizeArguments(arguments) {
        case .failure(.message(let message)):
            XCTFail("Expected success, got error: \(message)")
        case .success(let values):
            XCTAssertEqual(values.resumeHistoryPath, ".native-agent/subagent-logs/run-42/history.json")
        }
    }

    func testValidateAndNormalizeArgumentsResumeNilWhenAbsent() {
        switch TaskTool.validateAndNormalizeArguments(["description": "fresh"]) {
        case .failure(.message(let message)):
            XCTFail("Expected success, got error: \(message)")
        case .success(let values):
            XCTAssertNil(values.resumeHistoryPath)
        }
    }

    func testMetadataPathIsSiblingOfHistory() {
        XCTAssertEqual(
            TaskTool.metadataPath(forHistoryPath: ".native-agent/subagent-logs/run-1/history.json"),
            ".native-agent/subagent-logs/run-1/metadata.json"
        )
    }

    // MARK: - Archive metadata backward-compat

    func testSubagentArchiveMetadataDecodesLegacyBlobWithoutResumeFields() throws {
        // A metadata.json written before resume support: no tools/responseMode/
        // isolationDirectory/resumedFrom keys. It must still decode, defaulting
        // the new fields so old archives remain loadable.
        let legacy = """
        {
          "id": "run-legacy",
          "createdAt": "2026-01-01T00:00:00Z",
          "status": "success",
          "profile": "codebase_research",
          "taskDescription": "read a file",
          "messageCount": 4,
          "toolResponseCount": 1,
          "finalResponseLength": 120
        }
        """
        let decoded = try JSONDecoder().decode(
            TaskTool.SubagentArchiveMetadata.self,
            from: Data(legacy.utf8)
        )
        XCTAssertEqual(decoded.id, "run-legacy")
        XCTAssertEqual(decoded.profile, "codebase_research")
        XCTAssertEqual(decoded.tools, [])
        XCTAssertEqual(decoded.responseMode, "summary")
        XCTAssertNil(decoded.isolationDirectory)
        XCTAssertNil(decoded.resumedFrom)
    }

    func testSubagentArchiveMetadataRoundTripsResumeFields() throws {
        let metadata = TaskTool.SubagentArchiveMetadata(
            id: "run-new",
            createdAt: "2026-07-26T10:00:00Z",
            status: "success",
            profile: "executor",
            taskDescription: "edit a file",
            messageCount: 6,
            toolResponseCount: 2,
            finalResponseLength: 200,
            tools: ["read_file", "edit_file"],
            responseMode: "raw",
            isolationDirectory: nil,
            resumedFrom: "run-old"
        )
        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(TaskTool.SubagentArchiveMetadata.self, from: data)
        XCTAssertEqual(decoded.tools, ["read_file", "edit_file"])
        XCTAssertEqual(decoded.responseMode, "raw")
        XCTAssertEqual(decoded.resumedFrom, "run-old")
    }

    func testCompactDigestSummaryLimitsLinesAndCharacters() {
        let text = """
        line one
        line two
        line three
        line four
        """

        let summary = TaskTool.compactDigestSummary(from: text, maxLines: 2, maxCharacters: 40)
        XCTAssertEqual(summary.text, "line one\nline two")
        // 4 lines in, only 2 kept — that's a truncation the caller must know about.
        XCTAssertTrue(summary.truncated)

        let longText = String(repeating: "a", count: 120)
        let clipped = TaskTool.compactDigestSummary(from: longText, maxLines: 5, maxCharacters: 20)
        XCTAssertEqual(clipped.text.count, 23)
        XCTAssertTrue(clipped.text.hasSuffix("..."))
        XCTAssertTrue(clipped.truncated)
    }

    func testSummaryDigestCapsLiftedByMustNotTruncate() {
        let defaultCaps = TaskTool.summaryDigestCaps(mustNotTruncate: false)
        XCTAssertEqual(defaultCaps.maxLines, TaskTool.maxDigestSummaryLines)
        XCTAssertEqual(defaultCaps.maxCharacters, TaskTool.maxDigestSummaryCharacters)

        let preservedCaps = TaskTool.summaryDigestCaps(mustNotTruncate: true)
        XCTAssertEqual(preservedCaps.maxCharacters, TaskTool.maxRawSummaryCharacters)
        XCTAssertGreaterThan(preservedCaps.maxCharacters, TaskTool.maxDigestSummaryCharacters)

        // A summary that would be clipped under the default cap survives intact
        // when must_not_truncate lifts the caps — the flag now actually prevents
        // truncation instead of merely reporting it.
        let big = (1...40).map { "line \($0): " + String(repeating: "x", count: 60) }.joined(separator: "\n")
        XCTAssertTrue(big.count > TaskTool.maxDigestSummaryCharacters)

        let clipped = TaskTool.compactDigestSummary(from: big, maxLines: defaultCaps.maxLines, maxCharacters: defaultCaps.maxCharacters)
        XCTAssertTrue(clipped.truncated)

        let preserved = TaskTool.compactDigestSummary(from: big, maxLines: preservedCaps.maxLines, maxCharacters: preservedCaps.maxCharacters)
        XCTAssertFalse(preserved.truncated)
    }

    func testCompactDigestSummaryReturnsFallbackForEmptyInput() {
        let summary = TaskTool.compactDigestSummary(from: "   \n\n   ")
        XCTAssertEqual(summary.text, "No summary available.")
        XCTAssertFalse(summary.truncated)
    }

    func testCompactDigestSummaryNotTruncatedWhenEverythingFits() {
        let summary = TaskTool.compactDigestSummary(from: "just one short line", maxLines: 8, maxCharacters: 700)
        XCTAssertEqual(summary.text, "just one short line")
        XCTAssertFalse(summary.truncated)
    }

    func testFallbackToolActivitySummaryReturnsNilWhenNoToolMessages() {
        let messages: [Message] = [
            Message(role: .user, content: "do the thing", toolCallId: nil, origin: .human),
            Message(role: .assistant, content: "", toolCallId: nil, origin: .human),
        ]
        XCTAssertNil(TaskTool.fallbackToolActivitySummary(from: messages))
    }

    func testFallbackToolActivitySummaryRecoversLastToolOutput() {
        let messages: [Message] = [
            Message(role: .user, content: "read the file and report back", toolCallId: nil, origin: .human),
            Message(role: .assistant, content: "", toolCallId: nil, origin: .human),
            Message(role: .tool, content: "<!DOCTYPE html><html>...", toolCallId: "read_file", origin: .human),
        ]

        let summary = TaskTool.fallbackToolActivitySummary(from: messages)
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary!.contains("read_file"))
        XCTAssertTrue(summary!.contains("<!DOCTYPE html>"))
    }

    func testFallbackToolActivitySummaryTruncatesLongToolOutput() {
        let longContent = String(repeating: "x", count: 500)
        let messages: [Message] = [
            Message(role: .tool, content: longContent, toolCallId: "web_search", origin: .human),
        ]

        let summary = TaskTool.fallbackToolActivitySummary(from: messages, maxCharactersPerTool: 50)
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary!.contains("..."))
        XCTAssertFalse(summary!.contains(longContent))
    }

    func testMakeSubagentDigestShortensLongTaskEcho() {
        // A multi-hundred-character task spec must not be echoed verbatim into
        // the digest — it crowds out the summary payload. The echo is collapsed
        // to a short, single-line identifier.
        let longTask = String(repeating: "step ", count: 100) // 500 chars, single line
        let digest = TaskTool.makeSubagentDigest(
            status: "success",
            profileName: "executor",
            taskDescription: longTask,
            summary: "done",
            archivePath: nil
        )
        let taskLine = digest.split(separator: "\n").first { $0.hasPrefix("task: ") }!
        XCTAssertLessThanOrEqual(taskLine.count, TaskTool.maxDigestTaskEchoCharacters + "task: …".count + 4)
        XCTAssertTrue(taskLine.hasSuffix("…"))
    }

    func testMakeSubagentDigestAddsRecoveryHintWhenTruncated() {
        let digest = TaskTool.makeSubagentDigest(
            status: "partial",
            profileName: "terminal",
            taskDescription: "list vulnerable packages",
            summary: "dotnet list package --vulnerable\n...",
            archivePath: ".native-agent/subagent-logs/abc",
            summaryTruncated: true
        )
        XCTAssertTrue(digest.contains("recovery:"))
        XCTAssertTrue(digest.contains("response_mode:\"raw\""))
        // With an archive present, it points the caller at task_output.
        XCTAssertTrue(digest.contains("task_output"))
        XCTAssertTrue(digest.contains(".native-agent/subagent-logs/abc"))
    }

    func testMakeSubagentDigestOmitsRecoveryHintWhenNotTruncated() {
        let digest = TaskTool.makeSubagentDigest(
            status: "success",
            profileName: "terminal",
            taskDescription: "list packages",
            summary: "all good",
            archivePath: ".native-agent/subagent-logs/abc",
            summaryTruncated: false
        )
        XCTAssertFalse(digest.contains("recovery:"))
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

    // MARK: - Digest structured metadata (1A)

    func testMakeSubagentDigestIncludesStructuredMetadataLinesByDefault() {
        let digest = TaskTool.makeSubagentDigest(
            status: "success",
            profileName: "general",
            taskDescription: "do the thing",
            summary: "Did the thing",
            archivePath: nil
        )
        XCTAssertTrue(digest.contains("stdout_truncated: false"))
        XCTAssertTrue(digest.contains("summary_bytes: 0"))
        XCTAssertTrue(digest.contains("tool_calls: 0"))
        XCTAssertFalse(digest.contains("contract:"))
    }

    func testMakeSubagentDigestReflectsTruncationAndCounts() {
        let digest = TaskTool.makeSubagentDigest(
            status: "partial",
            profileName: "terminal",
            taskDescription: "list vulnerable packages",
            summary: "dotnet list package --vulnerable\n...",
            archivePath: nil,
            summaryTruncated: true,
            summaryBytes: 4096,
            toolCalls: 3
        )
        XCTAssertTrue(digest.contains("stdout_truncated: true"))
        XCTAssertTrue(digest.contains("summary_bytes: 4096"))
        XCTAssertTrue(digest.contains("tool_calls: 3"))
    }

    func testMakeSubagentDigestIncludesContractLineWhenSupplied() {
        let digest = TaskTool.makeSubagentDigest(
            status: "partial",
            profileName: "terminal",
            taskDescription: "check for vulnerable packages",
            summary: "no known vulnerabilities",
            archivePath: nil,
            contractLine: "contract: failed(missing expected pattern(s): CVE-)"
        )
        XCTAssertTrue(digest.contains("contract: failed(missing expected pattern(s): CVE-)"))
    }

    func testMakeSubagentDigestPreservesFieldOrderAndOmitsContractByDefault() {
        let digest = TaskTool.makeSubagentDigest(
            status: "success",
            profileName: "codebase_research",
            taskDescription: "inspect router",
            summary: "Found two call sites",
            archivePath: ".native-agent/subagent-logs/abc",
            modifiedFiles: ["b.swift", "a.swift"]
        )
        let statusIndex = digest.range(of: "status:")!.lowerBound
        let profileIndex = digest.range(of: "profile:")!.lowerBound
        let taskIndex = digest.range(of: "task:")!.lowerBound
        let summaryIndex = digest.range(of: "summary:")!.lowerBound
        let archiveIndex = digest.range(of: "archive:")!.lowerBound
        let modifiedIndex = digest.range(of: "modified_files:")!.lowerBound

        XCTAssertTrue(statusIndex < profileIndex)
        XCTAssertTrue(profileIndex < taskIndex)
        XCTAssertTrue(taskIndex < summaryIndex)
        XCTAssertTrue(summaryIndex < archiveIndex)
        XCTAssertTrue(archiveIndex < modifiedIndex)
        XCTAssertFalse(digest.contains("contract:"))
    }

    // MARK: - Result contract evaluation (1C)

    func testEvaluateResultContractReturnsNilLineWhenNoContractSupplied() {
        let result = TaskTool.evaluateResultContract(
            body: "anything",
            truncated: true,
            expectedPatterns: [],
            mustNotTruncate: false
        )
        XCTAssertNil(result.line)
        XCTAssertFalse(result.failed)
    }

    func testEvaluateResultContractFailsWhenExpectedPatternMissing() {
        let result = TaskTool.evaluateResultContract(
            body: "no known vulnerabilities found",
            truncated: false,
            expectedPatterns: ["CVE-2024"],
            mustNotTruncate: false
        )
        XCTAssertTrue(result.failed)
        XCTAssertEqual(result.line, "contract: failed(missing expected pattern(s): CVE-2024)")
    }

    func testEvaluateResultContractPassesWhenAllPatternsPresent() {
        let result = TaskTool.evaluateResultContract(
            body: "Found CVE-2024-1234 in package Foo",
            truncated: false,
            expectedPatterns: ["CVE-2024-1234", "Foo"],
            mustNotTruncate: false
        )
        XCTAssertFalse(result.failed)
        XCTAssertEqual(result.line, "contract: pass")
    }

    func testEvaluateResultContractFailsWhenMustNotTruncateAndTruncated() {
        let result = TaskTool.evaluateResultContract(
            body: "partial output...",
            truncated: true,
            expectedPatterns: [],
            mustNotTruncate: true
        )
        XCTAssertTrue(result.failed)
        XCTAssertEqual(result.line, "contract: failed(output was truncated)")
    }

    func testEvaluateResultContractPassesWhenMustNotTruncateAndNotTruncated() {
        let result = TaskTool.evaluateResultContract(
            body: "complete output",
            truncated: false,
            expectedPatterns: [],
            mustNotTruncate: true
        )
        XCTAssertFalse(result.failed)
        XCTAssertEqual(result.line, "contract: pass")
    }

    // MARK: - response_mode argument (1B)

    func testExtractResponseModeDefaultsToSummaryWhenOmitted() {
        let result = TaskTool.extractResponseMode(from: [:])
        switch result {
        case .success(let mode):
            XCTAssertEqual(mode, "summary")
        case .failure:
            XCTFail("Expected default response_mode of 'summary'")
        }
    }

    func testExtractResponseModeAcceptsRaw() {
        let result = TaskTool.extractResponseMode(from: ["response_mode": "raw"])
        switch result {
        case .success(let mode):
            XCTAssertEqual(mode, "raw")
        case .failure:
            XCTFail("Expected 'raw' to be accepted")
        }
    }

    func testExtractResponseModeIsCaseInsensitive() {
        let result = TaskTool.extractResponseMode(from: ["response_mode": "RAW"])
        switch result {
        case .success(let mode):
            XCTAssertEqual(mode, "raw")
        case .failure:
            XCTFail("Expected 'RAW' to normalize to 'raw'")
        }
    }

    func testExtractResponseModeRejectsInvalidValue() {
        let result = TaskTool.extractResponseMode(from: ["response_mode": "verbose"])
        switch result {
        case .success:
            XCTFail("Expected an invalid response_mode to fail")
        case .failure(.message(let message)):
            XCTAssertTrue(message.contains("response_mode"))
        }
    }

    func testExtractResponseModeRejectsNonStringType() {
        let result = TaskTool.extractResponseMode(from: ["response_mode": 42])
        switch result {
        case .success:
            XCTFail("Expected a non-string response_mode to fail")
        case .failure(.message(let message)):
            XCTAssertTrue(message.contains("response_mode"))
        }
    }

    // MARK: - expected_patterns / must_not_truncate arguments (1C)

    func testExtractExpectedPatternsDefaultsToEmpty() {
        let result = TaskTool.extractExpectedPatterns(from: [:])
        switch result {
        case .success(let patterns):
            XCTAssertEqual(patterns, [])
        case .failure:
            XCTFail("Expected empty default for expected_patterns")
        }
    }

    func testExtractExpectedPatternsAcceptsArrayOfStrings() {
        let result = TaskTool.extractExpectedPatterns(from: ["expected_patterns": ["CVE-", "vulnerable"]])
        switch result {
        case .success(let patterns):
            XCTAssertEqual(patterns, ["CVE-", "vulnerable"])
        case .failure:
            XCTFail("Expected array of strings to be accepted")
        }
    }

    func testExtractExpectedPatternsRejectsWrongType() {
        let result = TaskTool.extractExpectedPatterns(from: ["expected_patterns": "CVE-"])
        switch result {
        case .success:
            XCTFail("Expected a non-array expected_patterns to fail")
        case .failure(.message(let message)):
            XCTAssertTrue(message.contains("expected_patterns"))
        }
    }

    func testExtractMustNotTruncateDefaultsToFalse() {
        let result = TaskTool.extractMustNotTruncate(from: [:])
        switch result {
        case .success(let value):
            XCTAssertFalse(value)
        case .failure:
            XCTFail("Expected default of false for must_not_truncate")
        }
    }

    func testExtractMustNotTruncateRejectsWrongType() {
        let result = TaskTool.extractMustNotTruncate(from: ["must_not_truncate": "yes"])
        switch result {
        case .success:
            XCTFail("Expected a non-boolean must_not_truncate to fail")
        case .failure(.message(let message)):
            XCTAssertTrue(message.contains("must_not_truncate"))
        }
    }

    // MARK: - validateAndNormalizeArguments new fields

    func testValidateAndNormalizeArgumentsDefaultsNewFieldsWhenOmitted() {
        let result = TaskTool.validateAndNormalizeArguments(["description": "do the thing"])
        switch result {
        case .success(let values):
            XCTAssertEqual(values.responseMode, "summary")
            XCTAssertEqual(values.expectedPatterns, [])
            XCTAssertFalse(values.mustNotTruncate)
        case .failure:
            XCTFail("Expected minimal arguments to validate successfully")
        }
    }

    func testValidateAndNormalizeArgumentsPropagatesNewFields() {
        let result = TaskTool.validateAndNormalizeArguments([
            "description": "check for vulnerable packages",
            "response_mode": "raw",
            "expected_patterns": ["CVE-"],
            "must_not_truncate": true,
        ])
        switch result {
        case .success(let values):
            XCTAssertEqual(values.responseMode, "raw")
            XCTAssertEqual(values.expectedPatterns, ["CVE-"])
            XCTAssertTrue(values.mustNotTruncate)
        case .failure:
            XCTFail("Expected valid new-field arguments to validate successfully")
        }
    }

    func testValidateAndNormalizeArgumentsRejectsInvalidResponseMode() {
        let result = TaskTool.validateAndNormalizeArguments([
            "description": "do the thing",
            "response_mode": "verbose",
        ])
        switch result {
        case .success:
            XCTFail("Expected an invalid response_mode to fail validation")
        case .failure(.message(let message)):
            XCTAssertTrue(message.contains("response_mode"))
        }
    }

    // MARK: - baseInstructions response_mode threading (1B)

    func testBaseInstructionsDefaultsToSummaryOutputRules() {
        let instructions = TaskTool.baseInstructions(for: "general")
        XCTAssertTrue(instructions?.contains("output a concise final summary") == true)
        XCTAssertFalse(instructions?.contains("verbatim") == true)
    }

    func testBaseInstructionsUsesVerbatimOutputRulesInRawMode() {
        let instructions = TaskTool.baseInstructions(for: "general", responseMode: "raw")
        XCTAssertTrue(instructions?.contains("verbatim") == true)
        XCTAssertTrue(instructions?.contains("Do NOT summarize") == true)
        // Every profile's identity + "no permission asking" guarantee must
        // still hold regardless of response_mode.
        XCTAssertTrue(instructions?.hasPrefix("You are") == true)
        XCTAssertTrue(instructions?.contains("Do not ask the user for permission to proceed.") == true)
    }

}
