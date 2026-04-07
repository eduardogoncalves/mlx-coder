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
    /// - Parameter prompt: The raw user prompt, possibly containing `@/path/to/image.png`
    ///   or `@~/path/to/image.jpg` tokens.
    /// - Returns: A ``ParseResult`` with the cleaned prompt and resolved image URLs.
    public static func parse(prompt: String) -> ParseResult {
        // Tokenise on whitespace, keeping track of which tokens are image attachments.
        let tokens = prompt.split(separator: " ", omittingEmptySubsequences: false).map(String.init)

        var cleanedParts: [String] = []
        var imageURLs: [URL] = []

        for token in tokens {
            if token.hasPrefix("@") {
                // Strip the leading '@' then strip any trailing punctuation characters
                // (e.g. sentence-ending '.', ',', '!', '?') so that "describe @img.jpg."
                // is handled correctly.
                var rawPath = String(token.dropFirst())
                while let last = rawPath.last, last.isPunctuation, ![".", "-", "_"].contains(last) {
                    rawPath = String(rawPath.dropLast())
                }
                let expandedPath = NSString(string: rawPath).expandingTildeInPath
                let ext = URL(fileURLWithPath: expandedPath).pathExtension.lowercased()
                if imageExtensions.contains(ext) {
                    imageURLs.append(URL(fileURLWithPath: expandedPath))
                    // Remove the token from the cleaned prompt.
                    continue
                }
            }
            cleanedParts.append(token)
        }

        // Re-join, collapsing multiple spaces that arise from removed tokens.
        let cleaned = cleanedParts
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        return ParseResult(cleanedPrompt: cleaned, imageURLs: imageURLs)
    }
}
