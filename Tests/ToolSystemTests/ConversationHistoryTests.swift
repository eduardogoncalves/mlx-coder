import XCTest
@testable import MLXCoder

final class ConversationHistoryTests: XCTestCase {
    func testMarkdownTranscriptIncludesRolesAndContent() {
        var history = ConversationHistory(systemPrompt: "system prompt")
        history.addUser("hello")
        history.addAssistant("world")
        history.addToolResponse("tool output")

        let markdown = history.asMarkdownTranscript()

        XCTAssertTrue(markdown.contains("# mlx-coder Session Transcript"))
        XCTAssertTrue(markdown.contains("## 1. System"))
        XCTAssertTrue(markdown.contains("## 2. User"))
        XCTAssertTrue(markdown.contains("## 3. Assistant"))
        XCTAssertTrue(markdown.contains("## 4. Tool"))
        XCTAssertTrue(markdown.contains("system prompt"))
        XCTAssertTrue(markdown.contains("hello"))
        XCTAssertTrue(markdown.contains("world"))
        XCTAssertTrue(markdown.contains("tool output"))
    }

    func testJSONTranscriptRoundTrip() throws {
        var history = ConversationHistory(systemPrompt: "sys")
        history.addUser("u")
        history.addAssistant("a")

        let json = try history.asJSONTranscript()

        var restored = ConversationHistory(systemPrompt: "placeholder")
        try restored.restoreFromJSONTranscript(Data(json.utf8))

        XCTAssertEqual(restored.messages.count, 3)
        XCTAssertEqual(restored.messages[0].role, .system)
        XCTAssertEqual(restored.messages[1].role, .user)
        XCTAssertEqual(restored.messages[2].role, .assistant)
        XCTAssertEqual(restored.messages[0].content, "sys")
    }

    func testJSONTranscriptIncludesEnvelopeVersion() throws {
        var history = ConversationHistory(systemPrompt: "sys")
        history.addUser("u")

        let json = try history.asJSONTranscript()
        XCTAssertTrue(json.contains("\"version\""))
        XCTAssertTrue(json.contains("\"messages\""))
    }

    func testRestoreFromLegacyArrayJSONTranscriptStillWorks() throws {
        let legacy = """
        [
          {"role":"system","content":"sys","toolCallId":null},
          {"role":"user","content":"hello","toolCallId":null}
        ]
        """

        var history = ConversationHistory(systemPrompt: "placeholder")
        try history.restoreFromJSONTranscript(Data(legacy.utf8))

        XCTAssertEqual(history.messages.count, 2)
        XCTAssertEqual(history.messages[0].role, .system)
        XCTAssertEqual(history.messages[0].content, "sys")
        XCTAssertEqual(history.messages[1].role, .user)
    }

    func testJSONTranscriptRequiresLeadingSystemMessage() {
        let invalid = """
        [
          {"role":"user","content":"hello","toolCallId":null}
        ]
        """

        var history = ConversationHistory(systemPrompt: "sys")
        XCTAssertThrowsError(try history.restoreFromJSONTranscript(Data(invalid.utf8)))
    }

    func testDeterministicCompactionPreservesSystemAndRecentMessages() {
        var history = ConversationHistory(systemPrompt: "sys")
        for index in 0..<24 {
            history.addUser("u\(index)-" + String(repeating: "x", count: 80))
            history.addAssistant("a\(index)-" + String(repeating: "y", count: 80))
        }

        let compacted = history.compactDeterministically(maxEstimatedTokens: 120, keepRecentMessages: 6)

        XCTAssertTrue(compacted)
        XCTAssertEqual(history.messages.first?.role, .system)
        XCTAssertTrue(history.messages.contains { $0.content.contains("[Context compaction summary]") })
        XCTAssertLessThanOrEqual(history.estimatedTokenCount, 120)
    }
}
