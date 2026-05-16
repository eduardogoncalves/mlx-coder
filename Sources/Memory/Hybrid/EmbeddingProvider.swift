// Sources/Memory/Hybrid/EmbeddingProvider.swift
// Pluggable embedding provider for the hybrid memory stack.

import Foundation
import CryptoKit

/// Produces fixed-dimension embedding vectors for short text snippets.
///
/// The protocol is intentionally minimal so that the default deterministic
/// `HashEmbeddingProvider` (zero new dependencies) can be swapped for an
/// MLX-backed embedding model (e.g. a small sentence-encoder loaded via
/// `MLXLLM`) without touching the rest of the memory stack.
public protocol EmbeddingProvider: Sendable {
    /// Stable identifier — persisted alongside vectors so that mixed-model
    /// corpora can be detected and re-embedded if needed.
    var modelID: String { get }

    /// Output dimensionality.
    var dimension: Int { get }

    /// Compute a normalized (unit-length) embedding for the given text.
    func embed(_ text: String) async throws -> [Float]
}

/// Default embedding provider — deterministic hashed bag-of-trigrams.
///
/// Why this exists: mlx-coder must remain dependency-free at the local edge.
/// A real semantic encoder requires a model download + MLX context. This
/// fallback uses character trigrams and SHA-256 bucketing to produce a stable
/// vector that:
///  - never requires network/model load,
///  - is deterministic across processes (hashing is content-based, NOT
///    `String.hashValue`'s seeded variant),
///  - captures meaningful lexical/morphological overlap so cosine similarity
///    above a threshold is a good *near-duplicate* signal,
///  - is provably worse than a learned encoder for free-form semantic recall.
///
/// Treat it as the "no-embedding-model-available" baseline; production users
/// should plug in a learned provider for full semantic recall.
public struct HashEmbeddingProvider: EmbeddingProvider {
    public let modelID: String
    public let dimension: Int

    public init(dimension: Int = 256) {
        precondition(dimension > 0 && dimension % 4 == 0,
                     "dimension must be a positive multiple of 4")
        self.dimension = dimension
        self.modelID = "hash-trigram-v1-d\(dimension)"
    }

    public func embed(_ text: String) async throws -> [Float] {
        var vec = [Float](repeating: 0, count: dimension)
        let normalized = HashEmbeddingProvider.normalize(text)
        guard !normalized.isEmpty else {
            return vec  // all-zero vector; cosine with anything is 0
        }

        let scalars = Array(normalized.unicodeScalars)
        guard scalars.count >= 3 else {
            // Short input: hash whole string as one token
            apply(token: normalized, into: &vec)
            return HashEmbeddingProvider.l2Normalize(vec)
        }

        for i in 0...(scalars.count - 3) {
            let trigram = String(String.UnicodeScalarView(scalars[i..<(i + 3)]))
            apply(token: trigram, into: &vec)
        }
        return HashEmbeddingProvider.l2Normalize(vec)
    }

    /// Normalize text: lowercase, collapse whitespace, strip non-printable.
    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let scalars = lowered.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
        }
        let collapsed = String(String.UnicodeScalarView(scalars))
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed
    }

    /// Bucket a token into the embedding using SHA-256 to pick the slot
    /// (deterministic across processes, unlike Swift's seeded `hashValue`).
    private func apply(token: String, into vec: inout [Float]) {
        let digest = SHA256.hash(data: Data(token.utf8))
        // Use first 4 bytes as bucket index, next byte's low bit as sign.
        var iterator = digest.makeIterator()
        let b0 = UInt32(iterator.next() ?? 0)
        let b1 = UInt32(iterator.next() ?? 0)
        let b2 = UInt32(iterator.next() ?? 0)
        let b3 = UInt32(iterator.next() ?? 0)
        let signByte = iterator.next() ?? 0
        let raw = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
        let bucket = Int(raw % UInt32(dimension))
        let sign: Float = (signByte & 1) == 0 ? 1.0 : -1.0
        vec[bucket] += sign
    }

    /// L2-normalize in place; returns same vector for fluency.
    static func l2Normalize(_ vec: [Float]) -> [Float] {
        var sumSq: Float = 0
        for v in vec { sumSq += v * v }
        guard sumSq > 0 else { return vec }
        let inv = 1.0 / sqrtf(sumSq)
        return vec.map { $0 * inv }
    }

    /// Cosine similarity between two unit vectors.
    /// Falls back to a manual normalization step if either vector is not unit.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        let count = Swift.min(a.count, b.count)
        guard count > 0 else { return 0 }
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        for i in 0..<count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0 && nb > 0 else { return 0 }
        return Double(dot / (sqrtf(na) * sqrtf(nb)))
    }
}

/// Helpers for converting `[Float]` to/from a SQLite BLOB representation.
public enum EmbeddingBlob {
    /// Little-endian Float32 packing — compatible with sqlite-vec's `vec0`
    /// blob format so the same column can be migrated to a `vec0` virtual
    /// table later without re-encoding.
    public static func encode(_ vector: [Float]) -> Data {
        var bytes = Data(capacity: vector.count * MemoryLayout<Float>.size)
        for value in vector {
            var le = value.bitPattern.littleEndian
            withUnsafeBytes(of: &le) { bytes.append(contentsOf: $0) }
        }
        return bytes
    }

    public static func decode(_ data: Data, dimension: Int) -> [Float]? {
        guard data.count == dimension * MemoryLayout<Float>.size else {
            return nil
        }
        var result = [Float](repeating: 0, count: dimension)
        for i in 0..<dimension {
            let start = i * MemoryLayout<Float>.size
            let slice = data.subdata(in: start..<(start + MemoryLayout<Float>.size))
            let bits: UInt32 = slice.withUnsafeBytes { ptr in
                var raw: UInt32 = 0
                memcpy(&raw, ptr.baseAddress!, MemoryLayout<UInt32>.size)
                return UInt32(littleEndian: raw)
            }
            result[i] = Float(bitPattern: bits)
        }
        return result
    }
}
