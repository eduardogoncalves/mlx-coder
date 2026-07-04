// Tests for provider-agnostic remote inference: RemoteProvider env-var derivation,
// the built-in provider registry, case-insensitive lookup, and InferenceBackend's
// generic `remote:` round-trip (plus legacy `openrouter:` back-compat).
//
// Note: file-touching registry behaviors (addOrUpdate/remove) are intentionally
// NOT tested here to avoid writing to the user's real ~/.mlx-coder.

import XCTest
@testable import MLXCoder

final class RemoteProviderTests: XCTestCase {
    func testEnvVarNameDefaults() {
        let openrouter = RemoteProvider(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", requiresAuth: true, apiKeyEnv: nil)
        XCTAssertEqual(openrouter.envVarName, "OPENROUTER_API_KEY")

        let mlxlm = RemoteProvider(id: "mlx-lm", name: "mlx-lm.server", baseURL: "http://localhost:8080/v1", requiresAuth: false, apiKeyEnv: nil)
        XCTAssertEqual(mlxlm.envVarName, "MLX_LM_API_KEY")
    }

    func testEnvVarNameOverride() {
        let custom = RemoteProvider(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", requiresAuth: true, apiKeyEnv: "MY_CUSTOM_KEY")
        XCTAssertEqual(custom.envVarName, "MY_CUSTOM_KEY")
    }

    func testBuiltInsContainExpectedProviders() {
        let builtIns = RemoteProviderRegistry.builtIns
        let byID = Dictionary(uniqueKeysWithValues: builtIns.map { ($0.id, $0) })

        XCTAssertEqual(byID["openrouter"]?.baseURL, "https://openrouter.ai/api/v1")
        XCTAssertEqual(byID["openrouter"]?.requiresAuth, true)

        XCTAssertEqual(byID["lmstudio"]?.baseURL, "http://localhost:1234/v1")
        XCTAssertEqual(byID["lmstudio"]?.requiresAuth, false)

        XCTAssertEqual(byID["vllm"]?.baseURL, "http://localhost:8000/v1")
        XCTAssertEqual(byID["vllm"]?.requiresAuth, false)

        XCTAssertEqual(byID["mlx-lm"]?.baseURL, "http://localhost:8080/v1")
        XCTAssertEqual(byID["mlx-lm"]?.requiresAuth, false)
    }

    func testProviderLookupIsCaseInsensitive() {
        XCTAssertEqual(RemoteProviderRegistry.provider(id: "OpenRouter")?.id, "openrouter")
        XCTAssertEqual(RemoteProviderRegistry.provider(id: "LMSTUDIO")?.id, "lmstudio")
        XCTAssertNil(RemoteProviderRegistry.provider(id: "does-not-exist"))
    }

    func testGenericRemoteRoundTrip() {
        let backend = InferenceBackend(modelPath: "remote:lmstudio:qwen2.5-coder")
        XCTAssertTrue(backend.isOnline)
        XCTAssertEqual(backend.providerID, "lmstudio")
        XCTAssertEqual(backend.remoteModelID, "qwen2.5-coder")
        XCTAssertEqual(backend.modelPath, "remote:lmstudio:qwen2.5-coder")
    }

    func testLegacyOpenRouterMapsToRemote() {
        let backend = InferenceBackend(modelPath: "openrouter:foo/bar")
        XCTAssertTrue(backend.isOnline)
        XCTAssertEqual(backend.providerID, "openrouter")
        XCTAssertEqual(backend.remoteModelID, "foo/bar")
        guard case .remote(let providerID, let modelID) = backend else {
            return XCTFail("expected .remote case")
        }
        XCTAssertEqual(providerID, "openrouter")
        XCTAssertEqual(modelID, "foo/bar")
    }
}
