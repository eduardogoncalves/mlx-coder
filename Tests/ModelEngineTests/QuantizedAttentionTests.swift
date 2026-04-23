// Tests/ModelEngineTests/QuantizedAttentionTests.swift
// Tests for metal quantized attention (quantized KV cache) parameters

import XCTest
@testable import MLXCoder

final class QuantizedAttentionTests: XCTestCase {

    // MARK: - ParameterProfile: quantizedKVStart

    func testAllProfilesExposeQuantizedKVStart() {
        XCTAssertEqual(ParameterProfile.m1_8gb.quantizedKVStart, 0)
        XCTAssertEqual(ParameterProfile.standard_16gb.quantizedKVStart, 0)
        XCTAssertEqual(ParameterProfile.performant.quantizedKVStart, 0)
    }

    func testAllProfilesHave4BitKVQuantization() {
        XCTAssertEqual(ParameterProfile.m1_8gb.kvBits, 4)
        XCTAssertEqual(ParameterProfile.standard_16gb.kvBits, 4)
        XCTAssertEqual(ParameterProfile.performant.kvBits, 4)
    }

    func testAllProfilesHaveKVGroupSize64() {
        XCTAssertEqual(ParameterProfile.m1_8gb.kvGroupSize, 64)
        XCTAssertEqual(ParameterProfile.standard_16gb.kvGroupSize, 64)
        XCTAssertEqual(ParameterProfile.performant.kvGroupSize, 64)
    }

    // MARK: - GenerationEngine.Config: quantized attention parameters

    func testGenerationConfigDefaultsMatchGeneralDefaults() {
        let config = GenerationEngine.Config()
        XCTAssertNil(config.kvBits)
        XCTAssertEqual(config.kvGroupSize, 64)
        XCTAssertEqual(config.quantizedKVStart, 0)
    }

    func test4BitQuantizedAttentionConfig() {
        let config = GenerationEngine.Config(kvBits: 4, kvGroupSize: 64, quantizedKVStart: 0)
        XCTAssertEqual(config.kvBits, 4)
        XCTAssertEqual(config.kvGroupSize, 64)
        XCTAssertEqual(config.quantizedKVStart, 0)
    }

    func test8BitQuantizedAttentionConfig() {
        let config = GenerationEngine.Config(kvBits: 8, kvGroupSize: 32, quantizedKVStart: 0)
        XCTAssertEqual(config.kvBits, 8)
        XCTAssertEqual(config.kvGroupSize, 32)
        XCTAssertEqual(config.quantizedKVStart, 0)
    }

    func testDelayedQuantizationStartConfig() {
        // Quantization starts at layer 4 — first 4 layers use full precision for
        // higher output quality on chips with sufficient memory.
        let config = GenerationEngine.Config(kvBits: 4, kvGroupSize: 64, quantizedKVStart: 4)
        XCTAssertEqual(config.kvBits, 4)
        XCTAssertEqual(config.quantizedKVStart, 4)
    }

    func testNoQuantizationConfig() {
        let config = GenerationEngine.Config(kvBits: nil)
        XCTAssertNil(config.kvBits)
    }

    // MARK: - GenerationEngine.Config derived from ParameterProfile

    func testConfigFromM1Profile() {
        let profile = ParameterProfile.m1_8gb
        let config = GenerationEngine.Config(
            maxTokens: profile.maxTokens,
            temperature: profile.temperature,
            topP: profile.topP,
            kvBits: profile.kvBits,
            kvGroupSize: profile.kvGroupSize,
            quantizedKVStart: profile.quantizedKVStart,
            longContextThreshold: profile.longContextThreshold
        )
        XCTAssertEqual(config.kvBits, 4)
        XCTAssertEqual(config.kvGroupSize, 64)
        XCTAssertEqual(config.quantizedKVStart, 0)
    }

    func testConfigFromPerformantProfile() {
        let profile = ParameterProfile.performant
        let config = GenerationEngine.Config(
            maxTokens: profile.maxTokens,
            temperature: profile.temperature,
            topP: profile.topP,
            kvBits: profile.kvBits,
            kvGroupSize: profile.kvGroupSize,
            quantizedKVStart: profile.quantizedKVStart,
            longContextThreshold: profile.longContextThreshold
        )
        XCTAssertEqual(config.kvBits, 4)
        XCTAssertEqual(config.kvGroupSize, 64)
        XCTAssertEqual(config.quantizedKVStart, 0)
        XCTAssertEqual(config.maxTokens, 8192)
    }
}
