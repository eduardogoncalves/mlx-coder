// Sources/CLI/AtFileReferenceExpander.swift
// Expands @<path> tokens in a user prompt to inline file content.
//
// Image tokens are handled separately by ImageAttachmentParser; this
// expander processes non-image text files that exist on disk and appends
// their content as fenced code blocks at the end of the prompt.

import Foundation

enum AtFileReferenceExpander {

    // Maximum file size that will be inlined (larger files are left as tokens
    // so the agent can read them selectively using its tools).
    private static let maxFileSizeBytes = 512_000 // 512 KB

    /// Scans `prompt` for `@path` tokens referencing existing, readable
    /// non-image text files.  For each such token the file is read and its
    /// content is appended as a fenced code block.  Tokens that cannot be
    /// resolved (missing file, binary, oversized, or image) are left verbatim.
    ///
    /// - Parameters:
    ///   - prompt: Raw user prompt, possibly containing `@path/to/file` tokens.
    ///   - workspaceRoot: Base directory used to resolve relative paths.
    ///     Defaults to `FileManager.default.currentDirectoryPath`.
    /// - Returns: The (possibly augmented) prompt string.
    static func expand(_ prompt: String, workspaceRoot: String? = nil) -> String {
        let base = workspaceRoot ?? FileManager.default.currentDirectoryPath

        // Split on whitespace so @path tokens separated by spaces/tabs/newlines
        // are all discovered.
        let tokens = prompt.split(whereSeparator: \.isWhitespace).map(String.init)

        struct Attachment {
            let displayPath: String
            let resolvedURL: URL
            let content: String
            let ext: String
        }

        var seenPaths = Set<String>()
        var attachments: [Attachment] = []

        for token in tokens {
            guard token.hasPrefix("@") else { continue }

            let rawPath = trimTrailingTokenPunctuation(String(token.dropFirst()))
            guard !rawPath.isEmpty else { continue }

            let expandedPath = NSString(string: rawPath).expandingTildeInPath
            let url: URL
            if expandedPath.hasPrefix("/") {
                url = URL(fileURLWithPath: expandedPath)
            } else {
                url = URL(fileURLWithPath: base).appendingPathComponent(expandedPath)
            }

            let ext = url.pathExtension.lowercased()

            // Skip images — handled by ImageAttachmentParser.
            if ImageAttachmentParser.imageExtensions.contains(ext) { continue }

            let resolvedPath = url.standardizedFileURL.path
            guard !seenPaths.contains(resolvedPath) else { continue }
            guard FileManager.default.isReadableFile(atPath: url.path) else { continue }

            // Skip oversized files.
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            guard size > 0, size <= maxFileSizeBytes else { continue }

            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }

            seenPaths.insert(resolvedPath)
            attachments.append(Attachment(
                displayPath: rawPath,
                resolvedURL: url,
                content: content,
                ext: ext
            ))
        }

        guard !attachments.isEmpty else { return prompt }

        var result = prompt
        result += "\n\n"

        for att in attachments {
            result += "**Contents of `\(att.displayPath)`:**\n"
            result += "```\(att.ext)\n"
            result += att.content
            if !att.content.hasSuffix("\n") { result += "\n" }
            result += "```\n\n"
        }

        return result.trimmingCharacters(in: .newlines)
    }

    private static func trimTrailingTokenPunctuation(_ path: String) -> String {
        var result = path
        // Strip sentence punctuation from the token boundary.
        // Note: trailing "." is intentionally trimmed so "@file.swift." is
        // resolved as "@file.swift" in prose.
        while let last = result.last,
              last.isPunctuation,
              !["-", "_", "/"].contains(last) {
            result.removeLast()
        }
        return result
    }
}
