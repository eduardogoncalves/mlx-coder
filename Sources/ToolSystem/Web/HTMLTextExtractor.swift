// Sources/ToolSystem/Web/HTMLTextExtractor.swift
// Converts HTML to a compact Markdown representation for LLM consumption.

import Foundation
import SwiftSoup

/// Converts HTML into compact Markdown: boilerplate (nav/ads/scripts/sidebars) is
/// removed, the main content block is isolated with a lightweight text-density
/// heuristic, and headings/links/lists/emphasis are preserved as Markdown syntax
/// so URLs and structure survive — unlike plain-text stripping. Publish date and
/// title, when present in `<meta>`/`<time>`/JSON-LD, are surfaced as a short header.
enum HTMLTextExtractor {

    // MARK: - Public API

    /// Extract Markdown from an HTML string. `baseURL`, when provided, is used to
    /// resolve relative `href`/`src` attributes to absolute URLs. Falls back to
    /// returning the input unchanged if it cannot be parsed as HTML (e.g. plain text,
    /// JSON) or if extraction fails for any reason.
    static func extract(from html: String, baseURL: URL? = nil) -> String {
        (try? extractMarkdown(from: html, baseURL: baseURL)) ?? html
    }

    // MARK: - Pipeline

    private static func extractMarkdown(from html: String, baseURL: URL?) throws -> String {
        let doc = try SwiftSoup.parse(html, baseURL?.absoluteString ?? "")

        let metadata = extractMetadata(doc: doc)
        try removeBoilerplate(doc: doc)

        guard let contentNode = try mainContentNode(doc: doc) else { return "" }

        let markdown = collapseWhitespace(renderMarkdown(contentNode))

        var header: [String] = []
        if let title = metadata.title, !title.isEmpty { header.append("Title: \(title)") }
        if let date = metadata.publishedDate, !date.isEmpty { header.append("Published: \(date)") }
        let headerBlock = header.isEmpty ? "" : header.joined(separator: "\n") + "\n\n"

        return (headerBlock + markdown).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Metadata extraction

    private struct Metadata {
        var title: String?
        var publishedDate: String?
    }

    private static func extractMetadata(doc: Document) -> Metadata {
        var metadata = Metadata()
        if let title = try? doc.title(), !title.isEmpty {
            metadata.title = title
        }
        metadata.publishedDate = publishedDate(doc: doc)
        return metadata
    }

    private static let dateMetaSelectors = [
        "meta[property=\"article:published_time\"]",
        "meta[property=\"og:published_time\"]",
        "meta[name=\"article:published_time\"]",
        "meta[name=\"publish-date\"]",
        "meta[name=\"publishdate\"]",
        "meta[name=\"date\"]",
        "meta[name=\"sailthru.date\"]",
        "meta[name=\"parsely-pub-date\"]",
        "meta[itemprop=\"datePublished\"]",
    ]

    private static func publishedDate(doc: Document) -> String? {
        for selector in dateMetaSelectors {
            if let el = try? doc.select(selector).first(),
               let content = try? el.attr("content"), !content.isEmpty {
                return content
            }
        }
        if let timeEl = try? doc.select("time[datetime]").first(),
           let datetime = try? timeEl.attr("datetime"), !datetime.isEmpty {
            return datetime
        }
        return jsonLDPublishedDate(doc: doc)
    }

    private static func jsonLDPublishedDate(doc: Document) -> String? {
        guard let scripts = try? doc.select("script[type=\"application/ld+json\"]") else { return nil }
        for script in scripts {
            guard let jsonText = try? script.html(), !jsonText.isEmpty,
                  let data = jsonText.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else { continue }
            if let date = findDatePublished(in: object) { return date }
        }
        return nil
    }

    private static func findDatePublished(in object: Any) -> String? {
        if let dict = object as? [String: Any] {
            if let date = dict["datePublished"] as? String, !date.isEmpty { return date }
            if let graph = dict["@graph"] as? [Any] {
                for item in graph {
                    if let date = findDatePublished(in: item) { return date }
                }
            }
        } else if let array = object as? [Any] {
            for item in array {
                if let date = findDatePublished(in: item) { return date }
            }
        }
        return nil
    }

    // MARK: - Boilerplate removal

    // Substring matches (advert, not "ad") to avoid false positives on words like
    // "header", "load", "gadget" that merely contain the shorter fragment.
    private static let boilerplateSelector = [
        "script", "style", "noscript", "svg", "iframe", "form",
        "nav", "header", "footer", "aside",
        "[role=navigation]", "[role=banner]", "[role=contentinfo]", "[role=complementary]",
        "[aria-hidden=true]", "[hidden]",
        "[class*=advert]", "[id*=advert]",
        "[class*=sidebar]", "[id*=sidebar]",
        "[class*=social-share]", "[class*=share-buttons]",
        "[class*=cookie]", "[class*=popup]", "[class*=modal]",
        "[class*=newsletter]", "[class*=subscribe]",
        "[class*=related-posts]", "[class*=comment]", "[id*=comment]",
    ].joined(separator: ", ")

    private static func removeBoilerplate(doc: Document) throws {
        for element in try doc.select(boilerplateSelector) {
            try? element.remove()
        }
    }

    // MARK: - Main content selection

    // Fast path: common semantic containers used by most blogs/news/docs sites.
    // Falls back to a text-density heuristic (favor text-heavy, link-light blocks)
    // over `div`/`section` when no semantic container is found — a simplified stand-in
    // for a full Readability scoring pass.
    private static let contentSelectors = [
        "article", "main", "[role=main]",
        "#content", "#main-content", "#main",
        ".post-content", ".article-content", ".article-body", ".entry-content", ".story-body",
    ]

    private static func mainContentNode(doc: Document) throws -> Element? {
        for selector in contentSelectors {
            if let element = try doc.select(selector).first(),
               try element.text().count > 200 {
                return element
            }
        }
        return try densestElement(doc: doc) ?? doc.body()
    }

    private static func densestElement(doc: Document) throws -> Element? {
        guard let body = doc.body() else { return nil }

        var best: Element?
        var bestScore = 0
        for candidate in try body.select("div, section") {
            let text = try candidate.text()
            let textLength = text.count
            guard textLength > 200 else { continue }

            var linkTextLength = 0
            for link in try candidate.select("a") {
                linkTextLength += try link.text().count
            }
            let linkDensity = textLength > 0 ? Double(linkTextLength) / Double(textLength) : 1.0
            guard linkDensity < 0.5 else { continue }

            let paragraphCount = try candidate.select("p").array().count
            let score = textLength + paragraphCount * 100
            if score > bestScore {
                bestScore = score
                best = candidate
            }
        }
        return best
    }

    // MARK: - Markdown rendering

    // Containers that don't map to a specific Markdown construct but should still
    // be visually separated from surrounding content (matches the old extractor's
    // "block tags produce newlines" behavior).
    private static let blockContainerTags: Set<String> = [
        "div", "section", "article", "main", "figure", "figcaption",
        "details", "summary", "dl", "dt", "dd", "address",
    ]

    private static func renderMarkdown(_ node: Node) -> String {
        node.getChildNodes().map(renderNode).joined()
    }

    private static func renderNode(_ node: Node) -> String {
        if let text = node as? TextNode {
            return text.text()
        }
        guard let element = node as? Element else { return "" }

        let tag = element.tagName().lowercased()
        switch tag {
        case "script", "style", "noscript", "template", "svg":
            return ""
        case "br":
            return "\n"
        case "hr":
            return "\n\n---\n\n"
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(tag.dropFirst()) ?? 1
            return "\n\n" + String(repeating: "#", count: level) + " " + inline(element) + "\n\n"
        case "p":
            return "\n\n" + inline(element) + "\n\n"
        case "a":
            let text = inline(element).trimmingCharacters(in: .whitespacesAndNewlines)
            let href = (try? element.absUrl("href")).flatMap { $0.isEmpty ? nil : $0 }
                ?? (try? element.attr("href")) ?? ""
            guard !text.isEmpty, !href.isEmpty else { return text }
            return "[\(text)](\(href))"
        case "img":
            let alt = (try? element.attr("alt")) ?? ""
            let src = (try? element.absUrl("src")).flatMap { $0.isEmpty ? nil : $0 }
                ?? (try? element.attr("src")) ?? ""
            return src.isEmpty ? "" : "![\(alt)](\(src))"
        case "strong", "b":
            return wrapNonEmpty(inline(element), with: "**")
        case "em", "i":
            return wrapNonEmpty(inline(element), with: "*")
        case "code":
            return wrapNonEmpty((try? element.text()) ?? "", with: "`")
        case "pre":
            let code = (try? element.text()) ?? ""
            return "\n\n```\n\(code)\n```\n\n"
        case "blockquote":
            let inner = renderMarkdown(element).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !inner.isEmpty else { return "" }
            let quoted = inner.components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n")
            return "\n\n" + quoted + "\n\n"
        case "ul", "ol":
            return "\n\n" + renderList(element, ordered: tag == "ol") + "\n\n"
        case "table":
            return "\n\n" + renderTable(element) + "\n\n"
        default:
            if blockContainerTags.contains(tag) {
                let inner = renderMarkdown(element).trimmingCharacters(in: .whitespacesAndNewlines)
                return inner.isEmpty ? "" : "\n\n" + inner + "\n\n"
            }
            return renderMarkdown(element)
        }
    }

    private static func inline(_ element: Element) -> String {
        element.getChildNodes().map(renderNode).joined()
    }

    private static func wrapNonEmpty(_ text: String, with marker: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : "\(marker)\(trimmed)\(marker)"
    }

    private static func renderList(_ list: Element, ordered: Bool) -> String {
        var lines: [String] = []
        var index = 0
        for item in list.children() where item.tagName().lowercased() == "li" {
            index += 1
            let marker = ordered ? "\(index)." : "-"
            let text = inline(item).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            lines.append("\(marker) \(text)")
        }
        return lines.joined(separator: "\n")
    }

    private static func renderTable(_ table: Element) -> String {
        guard let rows = try? table.select("tr"), !rows.isEmpty() else { return "" }
        var lines: [String] = []
        for (index, row) in rows.enumerated() {
            let cells = (try? row.select("th, td").array()) ?? []
            guard !cells.isEmpty else { continue }
            let cellTexts = cells.map { (try? $0.text()) ?? "" }
            lines.append("| " + cellTexts.joined(separator: " | ") + " |")
            if index == 0 {
                lines.append("| " + cellTexts.map { _ in "---" }.joined(separator: " | ") + " |")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Whitespace collapsing

    // Collapses per-line whitespace and consecutive blank lines. Line-by-line
    // (rather than a `\n{3,}` regex) because a whitespace-only text node between
    // two block tags — e.g. the newline in the source between `</h1>` and `<p>` —
    // renders as a lone space that would otherwise break a run of newlines into
    // two shorter runs a bare `\n{3,}` regex fails to match.
    private static func collapseWhitespace(_ text: String) -> String {
        var lines: [String] = []
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine
                .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if line.isEmpty, lines.last?.isEmpty == true { continue }
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
