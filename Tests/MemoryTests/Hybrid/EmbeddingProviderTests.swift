// Tests/MemoryTests/Hybrid/EmbeddingProviderTests.swift
// Default embedding provider + blob round-trip behaviour.

import XCTest
@testable import MLXCoder

final class EmbeddingProviderTests: XCTestCase {

    func testEmbeddingsAreUnitLength() async throws {
        let provider = HashEmbeddingProvider(dimension: 128)
        let vec = try await provider.embed("Always use xcodebuild for this project")
        let norm = sqrtf(vec.reduce(0) { $0 + $1 * $1 })
        XCTAssertEqual(Double(norm), 1.0, accuracy: 1e-4)
    }

    func testEmbeddingsAreDeterministicAcrossInstances() async throws {
        let a = HashEmbeddingProvider(dimension: 128)
        let b = HashEmbeddingProvider(dimension: 128)
        let v1 = try await a.embed("hello world")
        let v2 = try await b.embed("hello world")
        XCTAssertEqual(v1, v2)
    }

    func testCosineSimilarityIsHigherForRelatedTexts() async throws {
        let provider = HashEmbeddingProvider(dimension: 128)
        let v1 = try await provider.embed("Always use xcodebuild for this project")
        let v2 = try await provider.embed("Always use xcodebuild for builds in this repo")
        let v3 = try await provider.embed("Network protocols and TCP retransmission")
        let related = HashEmbeddingProvider.cosine(v1, v2)
        let unrelated = HashEmbeddingProvider.cosine(v1, v3)
        XCTAssertGreaterThan(related, unrelated)
        XCTAssertGreaterThan(related, 0.4,
                             "trigram-shared phrases should be moderately similar")
    }

    func testBlobRoundTripPreservesValues() {
        let original: [Float] = [0.0, 1.0, -0.5, 3.14159, -2.71828]
        let blob = EmbeddingBlob.encode(original)
        let decoded = EmbeddingBlob.decode(blob, dimension: original.count)
        XCTAssertEqual(decoded, original)
    }

    func testBlobDecodeRejectsWrongLength() {
        let blob = EmbeddingBlob.encode([1.0, 2.0])
        XCTAssertNil(EmbeddingBlob.decode(blob, dimension: 5))
    }
}
