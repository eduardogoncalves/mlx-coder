// Tests/ModelEngineTests/LLMClientTests.swift
// Pure-Swift tests for the deterministic parts of LLMClient: the derived
// one-shot GenerationEngine.Config and usability gating. These never load a
// model — the actual completion paths are exercised in live smoke runs.

import XCTest
@testable import MLXCoder

final class LLMClientTests: XCTestCase {

    private func baseConfig() -> GenerationEngine.Config {
        GenerationEngine.Config(
            maxTokens: 4096,
            temperature: 0.7,
            topP: 0.9,
            topK: 40,
            minP: 0.05,
            repetitionPenalty: 1.1,
            repetitionContextSize: 32,
            kvBits: 4,                 // must be stripped
            kvGroupSize: 32,
            quantizedKVStart: 128,
            longContextThreshold: 12_000,
            turboQuantBits: 3,         // must be stripped
            numDraftTokens: 3
        )
    }

    func testDeriveConfig_forcesOffKVQuantization() {
        let derived = LLMClient.deriveConfig(from: baseConfig(), maxTokens: 8, temperature: 0.0)
        XCTAssertNil(derived.kvBits, "kvBits must be nil to avoid the quantized-KV fatalError")
        XCTAssertNil(derived.turboQuantBits, "TurboQuant is incompatible with one-shot caches")
    }

    func testDeriveConfig_appliesOverrides() {
        let derived = LLMClient.deriveConfig(from: baseConfig(), maxTokens: 5, temperature: 0.2)
        XCTAssertEqual(derived.maxTokens, 5)
        XCTAssertEqual(derived.temperature, 0.2, accuracy: 1e-6)
    }

    func testDeriveConfig_clampsMaxTokensToAtLeastOne() {
        let derived = LLMClient.deriveConfig(from: baseConfig(), maxTokens: 0, temperature: 0.0)
        XCTAssertGreaterThanOrEqual(derived.maxTokens, 1)
    }

    func testDeriveConfig_preservesSamplingKnobs() {
        let derived = LLMClient.deriveConfig(from: baseConfig(), maxTokens: 8, temperature: 0.0)
        XCTAssertEqual(derived.topP, 0.9, accuracy: 1e-6)
        XCTAssertEqual(derived.topK, 40)
        XCTAssertEqual(derived.kvGroupSize, 32)
        XCTAssertEqual(derived.longContextThreshold, 12_000)
    }

    func testIsUsable_localRequiresContainer() {
        let client = LLMClient(
            backend: .local(modelPath: "/models/qwen"),
            container: nil,
            baseConfig: baseConfig()
        )
        XCTAssertFalse(client.isUsable, "A local backend with no container cannot run")
    }

    func testIsUsable_remoteAlwaysUsable() {
        let client = LLMClient(
            backend: .remote(providerID: "openrouter", modelID: "qwen/qwen3"),
            container: nil,
            baseConfig: baseConfig()
        )
        XCTAssertTrue(client.isUsable)
    }
}
