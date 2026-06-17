// Tests for the BYOK plumbing: Credentials storage, InferenceBackend round-trip,
// and the /login command parser. Touch points cross-cut MLXCoder, ModelEngine,
// and CLI — exercising them together catches integration drift in one place.

import XCTest
@testable import MLXCoder

final class InferenceBackendTests: XCTestCase {
    func testLocalRoundTrip() {
        let backend = InferenceBackend(modelPath: "~/models/Qwen3-4B-4bit")
        XCTAssertTrue(backend.isLocal)
        XCTAssertNil(backend.providerID)
        XCTAssertEqual(backend.modelPath, "~/models/Qwen3-4B-4bit")
    }

    func testOpenRouterRoundTrip() {
        let backend = InferenceBackend(modelPath: "openrouter:anthropic/claude-sonnet-4.5")
        XCTAssertTrue(backend.isOnline)
        XCTAssertEqual(backend.providerID, "openrouter")
        XCTAssertEqual(backend.modelPath, "openrouter:anthropic/claude-sonnet-4.5")
        guard case .openRouter(let id) = backend else {
            return XCTFail("expected .openRouter case")
        }
        XCTAssertEqual(id, "anthropic/claude-sonnet-4.5")
    }

    func testEmptyOnlineIDFallsBackToLocal() {
        // `openrouter:` with no model id is meaningless online — keep it as a
        // local "path" so we don't accidentally route through the HTTP backend.
        let backend = InferenceBackend(modelPath: "openrouter:")
        XCTAssertTrue(backend.isLocal)
    }
}

final class TUILoginCommandParserTests: XCTestCase {
    func testBareLoginOpensMenu() {
        XCTAssertEqual(TUILoginCommandParser.resolve(input: "/login"), .openMenu)
        XCTAssertEqual(TUILoginCommandParser.resolve(input: "  /login  "), .openMenu)
    }

    func testLoginWithProviderOnlyShowsHelp() {
        XCTAssertEqual(
            TUILoginCommandParser.resolve(input: "/login openrouter"),
            .showHelp(provider: "openrouter")
        )
    }

    func testLoginWithKeySaves() {
        XCTAssertEqual(
            TUILoginCommandParser.resolve(input: "/login openrouter sk-or-abc123"),
            .saveKey(provider: "openrouter", key: "sk-or-abc123")
        )
    }

    func testUnknownProvider() {
        XCTAssertEqual(
            TUILoginCommandParser.resolve(input: "/login made-up-provider"),
            .unknownProvider("made-up-provider")
        )
    }

    func testLogoutClearsProvider() {
        XCTAssertEqual(
            TUILoginCommandParser.resolve(input: "/logout openrouter"),
            .clearKey(provider: "openrouter")
        )
    }

    func testNonLoginInputReturnsNil() {
        XCTAssertNil(TUILoginCommandParser.resolve(input: "/model"))
        XCTAssertNil(TUILoginCommandParser.resolve(input: "hello"))
    }
}

final class CredentialsRoundTripTests: XCTestCase {
    func testEnvVarFallbackUsesProviderUppercase() {
        XCTAssertEqual(Credentials.envVarName(for: "openrouter"), "OPENROUTER_API_KEY")
        XCTAssertEqual(Credentials.envVarName(for: "Anthropic"), "ANTHROPIC_API_KEY")
    }
}
