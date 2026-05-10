// Sources/ToolSystem/Web/HTMLTextExtractor.swift
// Strips HTML markup and returns readable plain text.

import Foundation

/// Converts HTML to plain text by removing markup, scripts, styles, and
/// collapsing whitespace.  The result is suitable for LLM consumption —
/// much smaller than raw HTML and free of CSS / JS noise.
enum HTMLTextExtractor {

    // MARK: - Public API

    /// Extract readable text from an HTML string.
    ///
    /// The transformation pipeline:
    /// 1. Remove `<head>` block (metadata, styles, scripts)
    /// 2. Remove `<style>` and `<script>` blocks (anywhere in the document)
    /// 3. Insert whitespace around block-level tags so words don't run together
    /// 4. Strip all remaining HTML tags
    /// 5. Decode common HTML entities
    /// 6. Collapse runs of blank lines / spaces
    static func extract(from html: String) -> String {
        var text = html

        // 1. Drop <head>…</head>
        text = removeBlock(tag: "head", from: text)

        // 2. Drop <style>…</style> and <script>…</script>
        text = removeBlock(tag: "style", from: text)
        text = removeBlock(tag: "script", from: text)
        text = removeBlock(tag: "noscript", from: text)
        text = removeBlock(tag: "svg", from: text)

        // 3. Replace block-level / structural tags with newlines so adjacent
        //    content doesn't merge into one run-on word.
        let blockTags = ["p", "div", "br", "li", "dt", "dd", "tr", "td", "th",
                         "h1", "h2", "h3", "h4", "h5", "h6",
                         "article", "section", "header", "footer", "nav", "main",
                         "blockquote", "pre", "code", "ul", "ol", "table"]
        for tag in blockTags {
            // Opening tags → newline
            text = text.replacingOccurrences(
                of: #"<\#(tag)(\s[^>]*)?\s*/?>"#,
                with: "\n",
                options: [.regularExpression, .caseInsensitive]
            )
            // Closing tags → newline
            text = text.replacingOccurrences(
                of: #"</\#(tag)\s*>"#,
                with: "\n",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        // 4. Strip all remaining HTML tags
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)

        // 5. Decode HTML entities
        text = decodeEntities(text)

        // 6. Collapse whitespace
        //    - Replace runs of spaces/tabs with a single space
        //    - Collapse 3+ consecutive newlines to 2
        text = text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)

        // Trim leading/trailing whitespace on each line, keep blank lines as paragraph breaks
        let rawLines = text.components(separatedBy: "\n")
        let lines = rawLines.map { $0.trimmingCharacters(in: .whitespaces) }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private helpers

    /// Removes all occurrences of `<tag>…</tag>` (case-insensitive, dotAll).
    private static func removeBlock(tag: String, from html: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"<\#(tag)(\s[^>]*)?>.*?</\#(tag)\s*>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return html }
        let range = NSRange(html.startIndex..., in: html)
        return regex.stringByReplacingMatches(in: html, range: range, withTemplate: "")
    }

    // swiftlint:disable cyclomatic_complexity
    private static func decodeEntities(_ text: String) -> String {
        var result = text

        // Named entities (common subset)
        let named: [(String, String)] = [
            ("&amp;",   "&"),
            ("&lt;",    "<"),
            ("&gt;",    ">"),
            ("&quot;",  "\""),
            ("&apos;",  "'"),
            ("&#39;",   "'"),
            ("&nbsp;",  " "),
            ("&ndash;", "–"),
            ("&mdash;", "—"),
            ("&lsquo;", "\u{2018}"),
            ("&rsquo;", "\u{2019}"),
            ("&ldquo;", "\u{201C}"),
            ("&rdquo;", "\u{201D}"),
            ("&hellip;","…"),
            ("&copy;",  "©"),
            ("&reg;",   "®"),
            ("&trade;", "™"),
            ("&bull;",  "•"),
            ("&middot;","·"),
            ("&times;", "×"),
            ("&divide;","÷"),
            ("&rarr;",  "→"),
            ("&larr;",  "←"),
            ("&uarr;",  "↑"),
            ("&darr;",  "↓"),
        ]
        for (entity, replacement) in named {
            result = result.replacingOccurrences(of: entity, with: replacement,
                                                  options: .caseInsensitive)
        }

        // Numeric decimal entities: &#NNN;
        if let regex = try? NSRegularExpression(pattern: #"&#(\d+);"#) {
            let nsResult = NSMutableString(string: result)
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let numRange = Range(match.range(at: 1), in: result),
                      let codePoint = UInt32(result[numRange]),
                      let scalar = Unicode.Scalar(codePoint) else { continue }
                let fullRange = match.range
                nsResult.replaceCharacters(in: fullRange, with: String(scalar))
            }
            result = nsResult as String
        }

        // Numeric hex entities: &#xHH;
        if let regex = try? NSRegularExpression(pattern: #"&#x([0-9a-fA-F]+);"#) {
            let nsResult = NSMutableString(string: result)
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let hexRange = Range(match.range(at: 1), in: result),
                      let codePoint = UInt32(result[hexRange], radix: 16),
                      let scalar = Unicode.Scalar(codePoint) else { continue }
                nsResult.replaceCharacters(in: match.range, with: String(scalar))
            }
            result = nsResult as String
        }

        return result
    }
    // swiftlint:enable cyclomatic_complexity
}
