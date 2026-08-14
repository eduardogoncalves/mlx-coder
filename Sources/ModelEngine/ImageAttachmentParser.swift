// Sources/ModelEngine/ImageAttachmentParser.swift
// Parses @path/to/image tokens from a prompt string.

import Foundation

/// Parses `@path/to/file` attachment tokens from a prompt string.
///
/// Tokens are identified by a leading `@` followed by a path whose file-extension
/// matches a supported image type.  Tilde (`~`) expansion is applied automatically.
///
/// Only tokens whose extension matches ``imageExtensions`` are treated as image
/// attachments; all other `@`-tokens are left untouched in the returned prompt.
public enum ImageAttachmentParser {

    /// File extensions (lowercased, without leading dot) that are recognised as images.
    public static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp",
    ]

    /// The result of parsing a prompt for image attachments.
    public struct ParseResult: Sendable {
        /// The original prompt with all recognised image-attachment tokens removed.
        public let cleanedPrompt: String
        /// Resolved (tilde-expanded, absolute) `file://` URLs for each image attachment.
        public let imageURLs: [URL]
    }

    /// Scan `prompt` for `@path` tokens, extract image paths, and return the cleaned
    /// prompt text together with the resolved image URLs.
    ///
    /// A token starting with `@` is treated as an image attachment if the path's
    /// file-extension (after stripping any trailing punctuation) matches
    /// ``imageExtensions``.  The `@` token is removed from the returned cleaned prompt.
    ///
    /// Paths may contain spaces (e.g. macOS screenshot filenames such as
    /// `Screenshot 2026-07-31 at 21.46.35.png`): candidate paths are tried
    /// longest-first, and a multi-word candidate wins only if it resolves to a
    /// file that actually exists on disk. Otherwise the first (space-free) word
    /// after `@` is used, matching the legacy single-word behavior.
    ///
    /// - Parameter prompt: The raw user prompt, possibly containing `@/path/to/image.png`
    ///   or `@~/path/to/image.jpg` tokens.
    /// - Returns: A ``ParseResult`` with the cleaned prompt and resolved image URLs.
    public static func parse(prompt: String) -> ParseResult {
        var imageURLs: [URL] = []
        var matchedRanges: [Range<String.Index>] = []

        var searchStart = prompt.startIndex
        while searchStart < prompt.endIndex, let atIndex = prompt[searchStart...].firstIndex(of: "@") {
            searchStart = prompt.index(after: atIndex)

            // Only treat '@' as a token start if it's at the beginning of the
            // string or preceded by whitespace.
            if atIndex != prompt.startIndex, !prompt[prompt.index(before: atIndex)].isWhitespace {
                continue
            }

            let pathStart = prompt.index(after: atIndex)
            guard pathStart < prompt.endIndex else { continue }

            // The candidate zone runs to the next newline or the next
            // whitespace-preceded '@' (the start of another candidate token).
            var zoneEnd = pathStart
            while zoneEnd < prompt.endIndex {
                let ch = prompt[zoneEnd]
                if ch == "\n" { break }
                if ch == "@", prompt[prompt.index(before: zoneEnd)].isWhitespace { break }
                zoneEnd = prompt.index(after: zoneEnd)
            }

            // Candidate end positions at each word boundary within the zone,
            // tried longest-first.
            var candidateEnds: [String.Index] = [zoneEnd]
            var cursor = pathStart
            while cursor < zoneEnd {
                if prompt[cursor] == " " { candidateEnds.append(cursor) }
                cursor = prompt.index(after: cursor)
            }
            candidateEnds.sort(by: >)

            var matchedEnd: String.Index?
            var matchedURL: URL?
            for end in candidateEnds {
                guard pathStart < end else { continue }
                let trimmed = trimTrailingPunctuation(String(prompt[pathStart..<end]))
                guard !trimmed.isEmpty else { continue }
                let expandedPath = NSString(string: trimmed).expandingTildeInPath
                let ext = URL(fileURLWithPath: expandedPath).pathExtension.lowercased()
                guard imageExtensions.contains(ext) else { continue }

                if FileManager.default.fileExists(atPath: expandedPath) {
                    matchedEnd = end
                    matchedURL = URL(fileURLWithPath: expandedPath)
                    break
                }
                // Fall back to the shortest (single-word) candidate even if the
                // file doesn't exist yet, preserving legacy single-word behavior.
                if end == candidateEnds.last {
                    matchedEnd = end
                    matchedURL = URL(fileURLWithPath: expandedPath)
                }
            }

            if let end = matchedEnd, let url = matchedURL {
                imageURLs.append(url)
                matchedRanges.append(atIndex..<end)
            }
        }

        var cleaned = prompt
        for range in matchedRanges.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            cleaned.removeSubrange(range)
        }
        // Collapse the double spaces left behind by removed tokens.
        while cleaned.contains("  ") {
            cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)

        return ParseResult(cleanedPrompt: cleaned, imageURLs: imageURLs)
    }

    private static func trimTrailingPunctuation(_ path: String) -> String {
        var result = path
        while let last = result.last, last.isPunctuation, ![".", "-", "_"].contains(last) {
            result.removeLast()
        }
        return result
    }
}
