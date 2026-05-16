// Sources/Memory/Hybrid/MemoryChunker.swift
// Pure text chunker for the hybrid memory stack.
//
// Long memory content (imports, large reflections, transcript snippets) is
// split into smaller chunks before being persisted so that:
//   * each chunk fits comfortably in the embedding model's context window,
//   * lexical (FTS5) and semantic recall return more focused snippets,
//   * the reranker / context-injector can pick the few most relevant chunks
//     instead of paying for a single oversized document.
//
// The chunker has no dependency on the store; it is a pure function over
// strings so it can be unit-tested in isolation.

import Foundation

public enum MemoryChunker {

    /// Default chunk soft-max in characters. Sized so that with ~4 chars/token
    /// average a chunk stays well under typical 512-token embedder windows.
    public static let defaultMaxChars = 1_400

    /// Default character overlap between adjacent chunks. Small enough to
    /// avoid duplicate dominance during retrieval, large enough to keep
    /// adjacent-paragraph context for sentence-level queries.
    public static let defaultOverlapChars = 160

    /// Hard floor — content shorter than this is never split.
    public static let minSplitChars = 400

    /// Split `text` into chunks of approximately `maxChars` characters with
    /// `overlap` characters of tail/head overlap between neighbours.
    ///
    /// The splitter prefers to break on (in order):
    ///   1. Markdown / code-block boundaries (`\n```` …)
    ///   2. Paragraph boundaries (`\n\n`)
    ///   3. Sentence boundaries (`. ` / `? ` / `! `)
    ///   4. Whitespace
    ///   5. Hard cut at `maxChars`
    ///
    /// Empty / whitespace-only input returns an empty array. Input shorter
    /// than `minSplitChars` returns a single chunk (the trimmed input).
    public static func chunk(
        _ text: String,
        maxChars: Int = defaultMaxChars,
        overlap: Int = defaultOverlapChars
    ) -> [String] {
        let max = Swift.max(64, maxChars)
        let lap = Swift.max(0, Swift.min(overlap, max / 2))
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.count <= Swift.max(minSplitChars, max) {
            return [trimmed]
        }

        var chunks: [String] = []
        // We use String.Index arithmetic to stay grapheme-cluster safe.
        var cursor = trimmed.startIndex
        while cursor < trimmed.endIndex {
            let remaining = trimmed.distance(from: cursor, to: trimmed.endIndex)
            if remaining <= max {
                let tail = String(trimmed[cursor...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !tail.isEmpty { chunks.append(tail) }
                break
            }

            // Soft window we are allowed to cut inside.
            let hardEnd = trimmed.index(cursor, offsetBy: max)
            let cut = preferredCut(in: trimmed, from: cursor, to: hardEnd)
            let piece = String(trimmed[cursor..<cut])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { chunks.append(piece) }

            // Advance the cursor leaving `lap` chars of overlap with the
            // next chunk, but never go backwards.
            let advance = Swift.max(1, trimmed.distance(from: cursor, to: cut) - lap)
            cursor = trimmed.index(cursor, offsetBy: advance)
        }
        return chunks
    }

    /// Locate the best cut point inside the half-open range `[from, to)`.
    /// Returns `to` if no nicer boundary is found.
    private static func preferredCut(
        in text: String,
        from start: String.Index,
        to hardEnd: String.Index
    ) -> String.Index {
        let window = text[start..<hardEnd]

        // 1) Closing fence / paragraph after 70% of the window — prefer late
        //    boundaries so chunks stay closer to maxChars.
        let earliestNice = text.index(start, offsetBy: Int(Double(text.distance(from: start, to: hardEnd)) * 0.6))

        if let r = window.range(of: "\n```", options: .backwards),
           r.upperBound >= earliestNice {
            return r.upperBound
        }
        if let r = window.range(of: "\n\n", options: .backwards),
           r.upperBound >= earliestNice {
            return r.upperBound
        }
        // 2) Sentence terminator followed by a space.
        for terminator in [". ", "? ", "! ", ".\n", "?\n", "!\n"] {
            if let r = window.range(of: terminator, options: .backwards),
               r.upperBound >= earliestNice {
                return r.upperBound
            }
        }
        // 3) Last whitespace inside the window.
        if let r = window.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards),
           r.upperBound >= earliestNice {
            return r.upperBound
        }
        // 4) Hard cut.
        return hardEnd
    }

    /// Tag prefix used to mark chunks that share a parent group.
    /// Format: `chunk:<groupUUID>:<index>/<total>`. Stored in `tags` on the
    /// resulting `DocumentInput` so retrieval can recognise siblings without
    /// any schema change.
    public static let chunkTagPrefix = "chunk:"

    /// Build the chunk tag for a sibling at position `index` within `total`.
    public static func chunkTag(groupID: UUID, index: Int, total: Int) -> String {
        "\(chunkTagPrefix)\(groupID.uuidString):\(index)/\(total)"
    }

    /// Inverse of `chunkTag`: recover (groupID, index, total) from the first
    /// chunk tag found in `tags`. Returns nil if no chunk tag is present.
    public static func parseChunkTag(in tags: [String]) -> (group: UUID, index: Int, total: Int)? {
        for tag in tags where tag.hasPrefix(chunkTagPrefix) {
            let body = tag.dropFirst(chunkTagPrefix.count)
            let parts = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let uuidPart = String(parts[0])
            let posPart = parts[1]
            guard let group = UUID(uuidString: uuidPart) else { continue }
            let posComponents = posPart.split(separator: "/", omittingEmptySubsequences: true)
            guard posComponents.count == 2,
                  let idx = Int(posComponents[0]),
                  let total = Int(posComponents[1]),
                  total > 0
            else { continue }
            return (group, idx, total)
        }
        return nil
    }
}
