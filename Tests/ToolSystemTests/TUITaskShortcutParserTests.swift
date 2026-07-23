// Tests for `/planner <message>`-style shortcuts that dispatch a named
// internal agent directly (AgentLoop.dispatchTaskShortcut), bypassing the
// orchestrator's own reasoning.

import XCTest
@testable import MLXCoder

final class TUITaskShortcutParserTests: XCTestCase {
    func testParsesKnownProfileShortcuts() {
        let result = TUITaskShortcutParser.parse("/planner research the auth flow")
        XCTAssertEqual(result?.profile, "planner")
        XCTAssertEqual(result?.message, "research the auth flow")
    }

    func testNormalizesHyphenatedProfileNames() {
        let result = TUITaskShortcutParser.parse("/security-review check the login endpoint")
        XCTAssertEqual(result?.profile, "security_review")
        XCTAssertEqual(result?.message, "check the login endpoint")
    }

    func testIsCaseInsensitive() {
        let result = TUITaskShortcutParser.parse("/Executor implement the button")
        XCTAssertEqual(result?.profile, "executor")
    }

    func testReturnsNilForUnknownProfile() {
        XCTAssertNil(TUITaskShortcutParser.parse("/notaprofile do something"))
    }

    func testReturnsNilForUnrelatedExistingCommandsEvenWithSharedPrefix() {
        // "/plan" is an existing, unrelated toggle command — must not
        // fuzzy-match "planner".
        XCTAssertNil(TUITaskShortcutParser.parse("/plan"))
        XCTAssertNil(TUITaskShortcutParser.parse("/plan mode please"))
    }

    func testReturnsNilWhenMessageIsMissing() {
        XCTAssertNil(TUITaskShortcutParser.parse("/planner"))
        XCTAssertNil(TUITaskShortcutParser.parse("/planner   "))
    }

    func testReturnsNilForNonSlashInput() {
        XCTAssertNil(TUITaskShortcutParser.parse("planner do something"))
    }

    func testAllSupportedProfilesParse() {
        for profile in TaskTool.supportedProfileNames {
            let result = TUITaskShortcutParser.parse("/\(profile) do the thing")
            XCTAssertEqual(result?.profile, profile, "expected '\(profile)' to parse as a shortcut")
            XCTAssertEqual(result?.message, "do the thing")
        }
    }
}
