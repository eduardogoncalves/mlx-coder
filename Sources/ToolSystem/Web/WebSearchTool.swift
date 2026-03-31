// Sources/ToolSystem/Web/WebSearchTool.swift
// Web search via configurable backend

import Foundation

actor WebSearchCache {
    var visitedQueries: Set<String> = []

    func hasVisited(_ query: String) -> Bool {
        visitedQueries.contains(query)
    }

    func markVisited(_ query: String) {
        visitedQueries.insert(query)
    }
}

/// Performs a web search and returns results.
public struct WebSearchTool: Tool {
    public let name = "web_search"
    public let description = "Search the web for information. Returns a list of search results with titles and URLs."
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "query": PropertySchema(type: "string", description: "Search query"),
            "limit": PropertySchema(type: "integer", description: "Maximum number of results (default: 5)"),
        ],
        required: ["query"]
    )

    private let cache: WebSearchCache

    public init() {
        self.cache = WebSearchCache()
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let query = arguments["query"] as? String else {
            return .error("Missing required argument: query")
        }

        if await cache.hasVisited(query) {
            return .error("Search query '\(query)' has already been searched in this session. Do not search it again unless the user explicitly requested.")
        }
        await cache.markVisited(query)

        let limit = arguments["limit"] as? Int ?? 5

        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return .error("Failed to encode search query")
        }

        let urlString = "https://html.duckduckgo.com/html/?q=\(encodedQuery)"
        guard let url = URL(string: urlString) else {
            return .error("Invalid URL")
        }

        var request = URLRequest(url: url)
        // DuckDuckGo blocks default Swift URLSession user agents. We must spoof a normal browser.
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return .error("Search failed with status code: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        guard let html = String(data: data, encoding: .utf8) else {
            return .error("Failed to decode HTML response")
        }

        // We use simple regex to extract the results from the HTML. 
        // DuckDuckGo lite HTML format typically has:
        // <a class="result__url" href="URL">...</a>
        // <a class="result__snippet"...>SNIPPET</a>
        
        let resultRegex = try NSRegularExpression(
            pattern: "<a class=\"result__url\" href=\"([^\"]+)\"[^>]*>(.*?)</a>(?:.*?)<a class=\"result__snippet\"[^>]*>(.*?)</a>", 
            options: [.dotMatchesLineSeparators]
        )

        let nsString = html as NSString
        let matches = resultRegex.matches(in: html, options: [], range: NSRange(location: 0, length: nsString.length))

        var results: [String] = []
        var count = 0

        for match in matches {
            if count >= limit { break }
            guard match.numberOfRanges == 4 else { continue }

            // Extract URL
            var urlStr = nsString.substring(with: match.range(at: 1))
            if urlStr.hasPrefix("//duckduckgo.com/l/?uddg=") {
                // Decode the wrapped DDG redirect URL if possible
                let components = URLComponents(string: "https:" + urlStr)
                if let uddg = components?.queryItems?.first(where: { $0.name == "uddg" })?.value {
                    urlStr = uddg
                }
            }
            
            // Clean up basic HTML tags from snippet
            let rawSnippet = nsString.substring(with: match.range(at: 3))
            // Strip tags using direct string replacement instead of regex templates
            // Avoids potential template injection vulnerabilities
            let snippet = rawSnippet
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            results.append("Result \(count + 1):\nURL: \(urlStr)\nSnippet: \(snippet)\n")
            count += 1
        }

        if results.isEmpty {
            return .success("No results found for '\(query)'. Make sure you aren't doing too many rapid searches (rate limiting).")
        }

        return .success(results.joined(separator: "\n"))
    }
}
