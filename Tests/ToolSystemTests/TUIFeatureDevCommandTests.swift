import XCTest
@testable import MLXCoder

final class TUIFeatureDevCommandTests: XCTestCase {
    func testMatchesBareCommand() {
        XCTAssertTrue(TUIFeatureDevCommand.matches("/feature-dev"))
        XCTAssertTrue(TUIFeatureDevCommand.matches("  /feature-dev  "))
    }

    func testMatchesCommandWithArgs() {
        XCTAssertTrue(TUIFeatureDevCommand.matches("/feature-dev Add OAuth"))
    }

    func testDoesNotMatchOtherCommands() {
        XCTAssertFalse(TUIFeatureDevCommand.matches("/feature"))
        XCTAssertFalse(TUIFeatureDevCommand.matches("/feature-development"))
        XCTAssertFalse(TUIFeatureDevCommand.matches("feature-dev"))
        XCTAssertFalse(TUIFeatureDevCommand.matches("/ask /feature-dev"))
    }

    func testArgumentsEmptyWhenNoArgs() {
        XCTAssertEqual(TUIFeatureDevCommand.arguments(from: "/feature-dev"), "")
        XCTAssertEqual(TUIFeatureDevCommand.arguments(from: "  /feature-dev   "), "")
    }

    func testArgumentsExtractTrailingDescription() {
        XCTAssertEqual(
            TUIFeatureDevCommand.arguments(from: "/feature-dev Add OAuth login"),
            "Add OAuth login"
        )
        XCTAssertEqual(
            TUIFeatureDevCommand.arguments(from: "  /feature-dev   Add caching  "),
            "Add caching"
        )
    }

    func testBuildPromptSubstitutesArguments() {
        let prompt = TUIFeatureDevCommand.buildPrompt(arguments: "Add OAuth login")
        XCTAssertTrue(prompt.contains("Initial request: Add OAuth login"))
        XCTAssertFalse(prompt.contains("$ARGUMENTS"))
        XCTAssertTrue(prompt.contains("Phase 1: Discovery"))
        XCTAssertTrue(prompt.contains("Phase 7: Summary"))
    }

    func testBuildPromptPlaceholderWhenNoArguments() {
        let prompt = TUIFeatureDevCommand.buildPrompt(arguments: "")
        XCTAssertFalse(prompt.contains("$ARGUMENTS"))
        XCTAssertTrue(prompt.contains("(none provided"))
    }

    func testStatusLineReflectsArguments() {
        XCTAssertEqual(
            TUIFeatureDevCommand.statusLine(arguments: ""),
            "✨ /feature-dev — entering guided feature-development workflow."
        )
        XCTAssertEqual(
            TUIFeatureDevCommand.statusLine(arguments: "Add OAuth"),
            "✨ /feature-dev — guided feature-development workflow for: Add OAuth"
        )
    }
}
