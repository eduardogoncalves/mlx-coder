// Tests for provider-agnostic remote inference: RemoteProvider id derivation,
// lenient config decoding, and InferenceBackend's `<provider>:<model>` carrier
// round-trip.
//
// Note: registry lookups that touch the real ~/.mlx-coder/config.json are
// intentionally NOT tested here; decoding is exercised against in-memory JSON.

import XCTest
@testable import MLXCoder

final class RemoteProviderTests: XCTestCase {
    func testSlugDerivation() {
        XCTAssertEqual(RemoteProvider(name: "OpenRouter", baseURL: "x").id, "openrouter")
        XCTAssertEqual(RemoteProvider(name: "LM Studio", baseURL: "x").id, "lm-studio")
        XCTAssertEqual(RemoteProvider(name: "mlx-lm.server", baseURL: "x").id, "mlx-lm-server")
        XCTAssertEqual(RemoteProvider(name: "My  Gateway!!", baseURL: "x").id, "my-gateway")
    }

    func testHasAPIKey() {
        XCTAssertTrue(RemoteProvider(name: "A", baseURL: "x", apiKey: "sk-1").hasAPIKey)
        XCTAssertFalse(RemoteProvider(name: "A", baseURL: "x", apiKey: "").hasAPIKey)
        XCTAssertFalse(RemoteProvider(name: "A", baseURL: "x", apiKey: nil).hasAPIKey)
    }

    func testDecodesCanonicalKeys() throws {
        let json = """
        { "name": "OpenRouter", "baseURL": "https://openrouter.ai/api/v1", "apiKey": "sk-or-abc" }
        """.data(using: .utf8)!
        let provider = try JSONDecoder().decode(RemoteProvider.self, from: json)
        XCTAssertEqual(provider.id, "openrouter")
        XCTAssertEqual(provider.baseURL, "https://openrouter.ai/api/v1")
        XCTAssertEqual(provider.apiKey, "sk-or-abc")
    }

    func testDecodesLenientKeyCasing() throws {
        let json = """
        { "name": "LM Studio", "baseurl": "http://localhost:1234/v1", "api_key": "" }
        """.data(using: .utf8)!
        let provider = try JSONDecoder().decode(RemoteProvider.self, from: json)
        XCTAssertEqual(provider.id, "lm-studio")
        XCTAssertEqual(provider.baseURL, "http://localhost:1234/v1")
        XCTAssertEqual(provider.apiKey, "")
    }

    func testConfigFileDecodesProvidersKey() throws {
        let json = """
        { "providers": [ { "name": "OpenRouter", "baseURL": "https://openrouter.ai/api/v1", "apiKey": "sk" } ] }
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(RemoteProviderRegistry.ConfigFile.self, from: json)
        XCTAssertEqual(config.providers.map(\.id), ["openrouter"])
    }

    func testConfigFileDecodesLegacyRemoteProvidersKey() throws {
        let json = """
        { "remoteProviders": [ { "name": "vLLM", "baseURL": "http://localhost:8000/v1" } ] }
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(RemoteProviderRegistry.ConfigFile.self, from: json)
        XCTAssertEqual(config.providers.map(\.id), ["vllm"])
    }

    func testStripJSONCommentsPreservesURLsInStrings() {
        let input = """
        {
          // a line comment
          "providers": [
            { "name": "OpenRouter", /* inline */ "baseURL": "https://openrouter.ai/api/v1" }
          ]
        }
        """
        let cleaned = RemoteProviderRegistry.stripJSONComments(input)
        XCTAssertTrue(cleaned.contains("https://openrouter.ai/api/v1"))
        XCTAssertFalse(cleaned.contains("a line comment"))
        XCTAssertFalse(cleaned.contains("inline"))
        // Still valid JSON after stripping.
        let data = cleaned.data(using: .utf8)!
        let config = try! JSONDecoder().decode(RemoteProviderRegistry.ConfigFile.self, from: data)
        XCTAssertEqual(config.providers.map(\.id), ["openrouter"])
    }

    func testSampleTemplateParsesToNoProviders() {
        // The auto-generated template has its sample commented out, so nothing
        // is parsed until the user edits it.
        let cleaned = RemoteProviderRegistry.stripJSONComments(RemoteProviderRegistry.sampleConfigTemplate)
        let data = cleaned.data(using: .utf8)!
        let config = try! JSONDecoder().decode(RemoteProviderRegistry.ConfigFile.self, from: data)
        XCTAssertTrue(config.providers.isEmpty)
    }

    func testProviderCarrierRoundTrip() {
        // Prefix-less `<provider>:<model>` is the canonical carrier.
        let backend = InferenceBackend(modelPath: "openrouter:qwen/qwen3-235b-a22b")
        XCTAssertTrue(backend.isOnline)
        XCTAssertEqual(backend.providerID, "openrouter")
        XCTAssertEqual(backend.remoteModelID, "qwen/qwen3-235b-a22b")
        XCTAssertEqual(backend.modelPath, "openrouter:qwen/qwen3-235b-a22b")
    }

    func testLocalIdentifiersAreNotMistakenForRemote() {
        // Hub ids and filesystem paths have no bare `token:` prefix.
        for path in ["mlx-community/Qwen3.5-9B-5bit", "/Users/me/models/foo", "~/models/bar"] {
            XCTAssertTrue(InferenceBackend(modelPath: path).isLocal, "\(path) should be local")
        }
    }
}
