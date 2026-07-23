// Sources/ToolSystem/Web/WebFetchTool.swift
// Fetch URL content

import Darwin   // inet_aton, inet_pton, getaddrinfo, in_addr, in6_addr
import Foundation
import MLX
import MLXLLM
import MLXLMCommon

// MARK: - SSRF guard

/// Validates that a URL is safe to fetch (SSRF mitigation).
///
/// Blocks non-HTTP/HTTPS schemes, loopback addresses, link-local ranges, private
/// network ranges, unique-local IPv6, and hostnames that resolve to blocked IPs.
/// The async DNS resolution step defeats DNS-rebinding attacks and catches hostnames
/// (e.g. attacker-controlled domains) whose A/AAAA records point at internal addresses.
enum URLFetchValidator {

    enum ValidationError: LocalizedError {
        case disallowedScheme(String)
        case missingHost
        case blockedHost(String)

        var errorDescription: String? {
            switch self {
            case .disallowedScheme(let scheme):
                return "URL scheme '\(scheme)' is not allowed; only http and https are permitted"
            case .missingHost:
                return "URL must include a host"
            case .blockedHost(let host):
                return "Requests to '\(host)' are not permitted"
            }
        }
    }

    /// Throws `ValidationError` when `url` must not be fetched.
    ///
    /// Synchronous fast-path: checks the scheme and tests the host against blocked
    /// IP literals (decimal, octal, hex, and multi-part forms) and known-blocked
    /// hostnames. Does NOT perform DNS resolution — use the async overload for that.
    static func validate(_ url: URL) throws {
        try validateLiterals(url)
    }

    /// Synchronous scheme + IP-literal checks shared by both `validate` overloads.
    /// Kept as a distinct name so the `async` overload can invoke it without the
    /// call resolving back to the `async` overload (which would recurse).
    private static func validateLiterals(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw ValidationError.disallowedScheme(url.scheme ?? "(none)")
        }
        guard let host = url.host, !host.isEmpty else {
            throw ValidationError.missingHost
        }
        if isBlockedHost(host) {
            throw ValidationError.blockedHost(host)
        }
    }

    /// Full validation including async DNS resolution.
    ///
    /// Runs the synchronous IP-literal checks first, then resolves the hostname via
    /// DNS to block addresses in private/loopback/link-local/unique-local ranges,
    /// defeating DNS-rebinding attacks and hostnames that point at internal IPs.
    /// Callers with an async context should always prefer this overload.
    static func validate(_ url: URL) async throws {
        // Re-use the shared sync checks for scheme + IP-literal validation.
        try validateLiterals(url)

        guard let host = url.host, !host.isEmpty else { return }

        // DNS resolution check: resolves the hostname and blocks if any returned
        // address falls in a private/loopback/link-local/unique-local range.
        if await resolvedAddressIsBlocked(host: host) {
            throw ValidationError.blockedHost(host)
        }
    }

    // MARK: - IP literal fast-path (synchronous)

    /// Returns true if the host is a known-blocked hostname, IPv4 literal in a blocked
    /// range (decimal, octal, hex, or multi-part forms), or a blocked IPv6 literal —
    /// without performing any DNS lookup.
    static func isBlockedHost(_ host: String) -> Bool {
        let lower = host.lowercased()

        // Block well-known loopback/metadata hostnames.
        let blockedHostnames: Set<String> = [
            "localhost",
            "ip6-localhost",
            "ip6-loopback",
        ]
        if blockedHostnames.contains(lower) { return true }

        // Strip IPv6 brackets if present (e.g. [::1] → ::1).
        let bare = lower.hasPrefix("[") && lower.hasSuffix("]")
            ? String(lower.dropFirst().dropLast())
            : lower

        // IPv6 literal checks (loopback, link-local, unique-local, mapped IPv4).
        if isBlockedIPv6(bare) { return true }

        // IPv4 literal check — inet_aton handles dotted-decimal, dotted-octal,
        // dotted-hex, single decimal integer, single hex integer, and 2/3-part forms.
        if let addr = parseIPv4Literal(bare), isBlockedIPv4Addr(addr) { return true }

        return false
    }

    // MARK: - IPv4 helpers

    /// Parses an IPv4 address literal in any form accepted by Darwin's inet_aton:
    /// dotted-decimal (1.2.3.4), dotted-octal (0177.0.0.1), dotted-hex (0x7f.0.0.1),
    /// single decimal integer (2130706433), single hex integer (0x7f000001), and the
    /// 2- and 3-part variants. Returns the address in host byte order, or nil if the
    /// string is not a recognised IPv4 literal.
    static func parseIPv4Literal(_ host: String) -> UInt32? {
        var addr = in_addr()
        guard inet_aton(host, &addr) != 0 else { return nil }
        // inet_aton stores the result in network (big-endian) byte order.
        return UInt32(bigEndian: addr.s_addr)
    }

    /// Returns true for IPv4 addresses (host byte order) in loopback, private,
    /// link-local, CGNAT, documentation, or reserved ranges.
    static func isBlockedIPv4Addr(_ addr: UInt32) -> Bool {
        let a = UInt8((addr >> 24) & 0xFF)
        let b = UInt8((addr >> 16) & 0xFF)
        let c = UInt8((addr >>  8) & 0xFF)

        switch a {
        case 0:         return true                         // 0.0.0.0/8       — "this" network
        case 10:        return true                         // 10.0.0.0/8      — RFC 1918 private
        case 100:       return b >= 64 && b <= 127          // 100.64.0.0/10   — CGNAT (RFC 6598)
        case 127:       return true                         // 127.0.0.0/8     — loopback
        case 169:       return b == 254                     // 169.254.0.0/16  — link-local / cloud metadata
        case 172:       return b >= 16 && b <= 31           // 172.16.0.0/12   — RFC 1918 private
        case 192:
            if b == 168 { return true }                     // 192.168.0.0/16  — RFC 1918 private
            if b == 0 && c == 2 { return true }             // 192.0.2.0/24    — TEST-NET-1 (RFC 5737)
            return false
        case 198:
            if b == 18 || b == 19 { return true }           // 198.18.0.0/15   — benchmarking (RFC 2544)
            if b == 51 && c == 100 { return true }          // 198.51.100.0/24 — TEST-NET-2 (RFC 5737)
            return false
        case 203:       return b == 0 && c == 113           // 203.0.113.0/24  — TEST-NET-3 (RFC 5737)
        case 240...255: return true                         // 240.0.0.0/4     — reserved (RFC 1112)
        default:        return false
        }
    }

    // MARK: - IPv6 helpers

    /// Returns true for IPv6 literals in blocked ranges: loopback (::1), unspecified (::),
    /// link-local (fe80::/10), unique-local (fc00::/7), and IPv4-mapped/compatible
    /// addresses (::ffff:x.x.x.x / ::x.x.x.x) whose embedded IPv4 is in a blocked range.
    private static func isBlockedIPv6(_ bare: String) -> Bool {
        // Loopback and unspecified.
        if bare == "::1" || bare == "::" { return true }

        // Link-local fe80::/10.
        if bare.hasPrefix("fe80:") { return true }

        // Unique-local fc00::/7 — covers both fc.. and fd.. prefixes.
        if bare.hasPrefix("fc") || bare.hasPrefix("fd") { return true }

        // IPv4-mapped (::ffff:a.b.c.d) and IPv4-compatible (::a.b.c.d) —
        // extract the embedded 32-bit address and apply the same range checks.
        if let embeddedV4 = extractEmbeddedIPv4(from: bare) {
            return isBlockedIPv4Addr(embeddedV4)
        }

        return false
    }

    /// Extracts the IPv4 address embedded in an IPv4-mapped (::ffff:x.x.x.x) or
    /// IPv4-compatible (::x.x.x.x) IPv6 literal using inet_pton for correctness.
    /// Returns the address in host byte order, or nil for all other IPv6 forms.
    private static func extractEmbeddedIPv4(from bare: String) -> UInt32? {
        var addr6 = in6_addr()
        guard inet_pton(AF_INET6, bare, &addr6) == 1 else { return nil }

        let bytes = withUnsafeBytes(of: addr6) { Array($0) }
        guard bytes.count == 16 else { return nil }

        // Both IPv4-mapped and IPv4-compatible require bytes 0–9 to be zero.
        guard bytes[0..<10].allSatisfy({ $0 == 0 }) else { return nil }

        let isMapped     = bytes[10] == 0xFF && bytes[11] == 0xFF   // ::ffff:x.x.x.x
        let isCompatible = bytes[10] == 0x00 && bytes[11] == 0x00   // ::x.x.x.x
        guard isMapped || isCompatible else { return nil }

        // Reconstruct the 32-bit IPv4 address in host byte order.
        return (UInt32(bytes[12]) << 24) | (UInt32(bytes[13]) << 16)
             | (UInt32(bytes[14]) <<  8) |  UInt32(bytes[15])
    }

    // MARK: - DNS resolution check

    /// Resolves `host` to its IP addresses and returns true if ANY resolved address
    /// is in a blocked range. Skips the lookup for IP literals (already checked by
    /// isBlockedHost). Times out after 5 seconds and fails open — the network stack
    /// will surface a connection error for genuinely unreachable addresses anyway.
    private static func resolvedAddressIsBlocked(host: String) async -> Bool {
        // Skip DNS for IPv4 literals — isBlockedHost already evaluated them.
        var addr4 = in_addr()
        if inet_aton(host, &addr4) != 0 { return false }

        // Skip DNS for IPv6 literals (strip brackets first).
        let bareHost = host.hasPrefix("[") && host.hasSuffix("]")
            ? String(host.dropFirst().dropLast()) : host
        var addr6 = in6_addr()
        if inet_pton(AF_INET6, bareHost, &addr6) == 1 { return false }

        // Race the DNS check against a 5-second timeout; first result wins.
        return await withTaskGroup(of: Bool.self) { group in
            // getaddrinfo is a blocking call; we run it in a task and accept that
            // Swift's cooperative pool may expand a thread to service it. On Darwin
            // the system resolver is fast and imposes its own short timeout.
            group.addTask(priority: .utility) {
                Self.performBlockingDNSCheck(host: host)
            }
            // Fail open on timeout — let the network stack surface the error.
            group.addTask {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch {}
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// Synchronously resolves `host` via getaddrinfo and returns true if any
    /// resolved address is loopback, private, link-local, unique-local, or a
    /// cloud-metadata address (e.g. 169.254.169.254).
    private static func performBlockingDNSCheck(host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM

        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let head = res else {
            // Resolution failed: fail open and let the network stack handle it.
            return false
        }
        defer { freeaddrinfo(head) }

        var current: UnsafeMutablePointer<addrinfo>? = head
        while let entry = current {
            defer { current = entry.pointee.ai_next }

            switch entry.pointee.ai_family {
            case AF_INET:
                // ai_addrlen is socklen_t (UInt32); MemoryLayout.size is Int — cast to avoid type mismatch.
                guard Int(entry.pointee.ai_addrlen) >= MemoryLayout<sockaddr_in>.size else { continue }
                let sa = entry.pointee.ai_addr.withMemoryRebound(
                    to: sockaddr_in.self, capacity: 1) { $0.pointee }
                let hostOrd = UInt32(bigEndian: sa.sin_addr.s_addr)
                if isBlockedIPv4Addr(hostOrd) { return true }

            case AF_INET6:
                guard Int(entry.pointee.ai_addrlen) >= MemoryLayout<sockaddr_in6>.size else { continue }
                let sa6 = entry.pointee.ai_addr.withMemoryRebound(
                    to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                let bytes = withUnsafeBytes(of: sa6.sin6_addr) { Array($0) }
                guard bytes.count == 16 else { continue }

                // Loopback ::1
                if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }
                // Link-local fe80::/10
                if bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80 { return true }
                // Unique-local fc00::/7
                if (bytes[0] & 0xFE) == 0xFC { return true }
                // IPv4-mapped (::ffff:x.x.x.x) and IPv4-compatible (::x.x.x.x)
                if bytes[0..<10].allSatisfy({ $0 == 0 }) {
                    let isMapped = bytes[10] == 0xFF && bytes[11] == 0xFF
                    let isCompat = bytes[10] == 0x00 && bytes[11] == 0x00
                    if isMapped || isCompat {
                        let v4 = (UInt32(bytes[12]) << 24) | (UInt32(bytes[13]) << 16)
                               | (UInt32(bytes[14]) <<  8) |  UInt32(bytes[15])
                        if isBlockedIPv4Addr(v4) { return true }
                    }
                }

            default:
                break
            }
        }
        return false
    }
}

// MARK: - WebFetchTool

/// Fetches content from a URL and returns it as text, optionally extracting relevant context via LLM.
public struct WebFetchTool: Tool {
    public let name = "web_fetch"
    public let description = """
        Fetch content from a URL and return it as text. The full page is downloaded, optionally \
        HTML-stripped, and cached on disk; only a bounded window of at most \
        \(WebFetchTool.defaultMaxOutputLength) characters is returned per call to keep the context \
        small. See each parameter's description for exact usage (text_only, query, offset, fresh).
        """
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "url": PropertySchema(type: "string", description: "URL to fetch"),
            "text_only": PropertySchema(type: "boolean",
                description: "When true, strip all HTML markup (tags, CSS, scripts) and return plain readable text. Recommended for web pages when you need the content rather than the markup structure."),
            "query": PropertySchema(type: "string",
                description: "Specific question or information to extract from the page via LLM. If empty, returns the full text (after optional HTML stripping)."),
            "offset": PropertySchema(type: "integer",
                description: "Character offset to start reading from (default: 0). Use to continue reading a page that was truncated: pass the next offset reported in the truncation marker. The chunk is served from the disk cache. Ignored when query is set."),
            "fresh": PropertySchema(type: "boolean",
                description: "When true, ignore any cached copy and re-download from the network (default: false). Use only when you need an up-to-date version of a page that may have changed."),
            "timeout": PropertySchema(type: "integer", description: "Timeout in seconds (default: 15)"),
        ],
        required: ["url"]
    )

    // Per-call window returned to the model. The full page is always cached; this
    // only bounds how much reaches the main context at once. Kept moderate so a
    // typical JSON API response fits in one or two chunks with correct, absolute
    // offset-based continuation, rather than being silently clipped downstream.
    public static let defaultMaxOutputLength = 12_000

    private let maxOutputLength: Int
    private let modelContainer: ModelContainer?
    private let generationConfig: GenerationEngine.Config?

    public init(maxOutputLength: Int = WebFetchTool.defaultMaxOutputLength, modelContainer: ModelContainer? = nil, generationConfig: GenerationEngine.Config? = nil) {
        self.maxOutputLength = maxOutputLength
        self.modelContainer = modelContainer
        self.generationConfig = generationConfig
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        try await execute(arguments: arguments, reportProgress: { _ in })
    }
}

extension WebFetchTool: ProgressReportingTool {
    public func execute(arguments: [String: Any], reportProgress: @escaping ToolProgressHandler) async throws -> ToolResult {
        guard let urlString = arguments["url"] as? String else {
            return .error("Missing required argument: url")
        }

        guard let url = URL(string: urlString) else {
            return .error("Invalid URL: \(urlString)")
        }

        do {
            try await URLFetchValidator.validate(url)
        } catch {
            return .error(error.localizedDescription)
        }

        if let host = url.host, !host.isEmpty {
            reportProgress("preparing request for \(host)")
        } else {
            reportProgress("preparing request")
        }

        let query = arguments["query"] as? String
        let textOnly = arguments["text_only"] as? Bool ?? false
        let offset = max(0, arguments["offset"] as? Int ?? 0)
        let fresh = arguments["fresh"] as? Bool ?? false

        let timeout = arguments["timeout"] as? Int ?? 15

        // --- Cache lookup ---
        // Continuation reads (offset > 0) and repeated reads are served from the
        // on-disk cache so the model can page through a large page without issuing
        // a new network request. `fresh: true` bypasses the cache to force a
        // re-download when the page may have changed.
        let cache = WebFetchCache.shared

        // If text_only and a pre-stripped copy exists, use it immediately
        if !fresh, textOnly, let cached = cache.textContent(for: urlString) {
            reportProgress("cache hit (text) — skipping network request")
            return try await resolveResult(text: cached, query: query, offset: offset, reportProgress: reportProgress)
        }

        // If a raw copy exists, we can skip the network request entirely
        if !fresh, let cachedRaw = cache.rawContent(for: urlString) {
            reportProgress("cache hit (raw) — skipping network request")
            if textOnly {
                let isHTML = cachedRaw.prefix(512).lowercased().contains("<!doctype html")
                    || cachedRaw.prefix(512).lowercased().contains("<html")
                if isHTML {
                    reportProgress("parsing HTML → extracting text")
                    let stripped = HTMLTextExtractor.extract(from: cachedRaw)
                    // Persist the stripped copy so next call is even faster
                    cache.save(raw: cachedRaw, text: stripped, for: urlString)
                    return try await resolveResult(
                        text: stripped, query: query, offset: offset, reportProgress: reportProgress)
                }
            }
            return try await resolveResult(
                text: cachedRaw, query: query, offset: offset, reportProgress: reportProgress)
        }

        // --- Network fetch ---
        var request = URLRequest(url: url)
        request.timeoutInterval = TimeInterval(timeout)
        request.setValue("mlx-coder/0.1", forHTTPHeaderField: "User-Agent")

        do {
            reportProgress("sending request")
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .error("Non-HTTP response received")
            }

            reportProgress("received response (HTTP \(httpResponse.statusCode))")

            guard (200...299).contains(httpResponse.statusCode) else {
                return .error("HTTP \(httpResponse.statusCode): \(HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode))")
            }

            reportProgress("reading response body")
            guard let rawText = String(data: data, encoding: .utf8) else {
                return .error("Response body is not valid UTF-8 text")
            }

            // Determine whether to strip HTML markup.
            // Strip when text_only is explicitly true AND the response is HTML.
            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
            let isHTML = contentType.lowercased().contains("text/html")
                || rawText.prefix(512).lowercased().contains("<!doctype html")
                || rawText.prefix(512).lowercased().contains("<html")

            let strippedText: String?
            if textOnly && isHTML {
                reportProgress("parsing HTML → extracting text")
                strippedText = HTMLTextExtractor.extract(from: rawText)
            } else {
                strippedText = nil
            }

            // Persist to disk cache
            reportProgress("saving to cache")
            cache.save(raw: rawText, text: strippedText, for: urlString)

            let text = strippedText ?? rawText
            return try await resolveResult(text: text, query: query, offset: offset, reportProgress: reportProgress)
        } catch {
            return .error("Fetch failed: \(error.localizedDescription)")
        }
    }

    // Applies truncation limits to build the final ToolResult, optionally
    // serving a window of the full content starting at `offset`. When more
    // content remains after the returned window, the truncation marker reports
    // the next offset so the model can continue reading the cached page.
    private func buildResult(text: String, offset: Int = 0) -> ToolResult {
        let total = text.count
        let safeOffset = min(max(0, offset), total)

        if safeOffset >= total {
            // Offset is at or past the end — nothing left to read.
            guard total > 0 else { return .success(text) }
            return .success("[offset \(offset) is at or beyond the end of the page (\(total) characters total); no more content to read]")
        }

        let window = text.dropFirst(safeOffset)
        if window.count > maxOutputLength {
            let truncated = String(window.prefix(maxOutputLength))
            let nextOffset = safeOffset + maxOutputLength
            let omitted = total - nextOffset
            let marker = "[... \(omitted) characters omitted (showing \(safeOffset)–\(nextOffset) of \(total)). "
                + "To continue reading this page, call web_fetch again with the same url and offset: \(nextOffset) ...]"
            return ToolResult(content: truncated, truncationMarker: marker)
        }

        // Final (or only) chunk fits within the limit.
        if safeOffset > 0 {
            return .success("[showing \(safeOffset)–\(total) of \(total) characters — end of page]\n\(String(window))")
        }
        return .success(String(window))
    }

    // Runs optional LLM query extraction, then applies size limits.
    private func resolveResult(
        text: String,
        query: String?,
        offset: Int = 0,
        reportProgress: @escaping ToolProgressHandler
    ) async throws -> ToolResult {
        if let query = query, !query.isEmpty, let container = modelContainer, let config = generationConfig {
            reportProgress("processing page content")
            reportProgress("extracting relevant information")
            let extracted = try await extractWithLLM(text: text, query: query, container: container, config: config)
            reportProgress("finalizing result")
            // Query extraction already condenses the page, so offset does not apply.
            return buildResult(text: "Extracted information for query '\(query)':\n\n\(extracted)")
        }
        reportProgress("finalizing result")
        return buildResult(text: text, offset: offset)
    }

    private func extractWithLLM(text: String, query: String, container: ModelContainer, config: GenerationEngine.Config) async throws -> String {
        // Truncate text context slightly to ensure it fits in prompt
        let maxLength = 30_000
        let safeText = text.count > maxLength ? String(text.prefix(maxLength)) + "...(truncated)" : text
        
        // Fast deterministic config
        let extractConfig = GenerationEngine.Config(
            maxTokens: 1024,
            temperature: 0.1,
            topP: config.topP,
            topK: config.topK,
            minP: config.minP,
            repetitionPenalty: config.repetitionPenalty,
            repetitionContextSize: config.repetitionContextSize,
            presencePenalty: config.presencePenalty,
            presenceContextSize: config.presenceContextSize,
            frequencyPenalty: config.frequencyPenalty,
            frequencyContextSize: config.frequencyContextSize,
            kvBits: nil, // maybeQuantizeKVCache + direct cache.update() = fatalError
            kvGroupSize: config.kvGroupSize,
            quantizedKVStart: config.quantizedKVStart,
            numDraftTokens: config.numDraftTokens
        )
        let prompt = """
        [INSTRUCTION]
        You are an expert information extractor. The user fetched a webpage to answer their question.

        USER'S QUESTION:
        \(query)

        Your task:
        - Read the webpage text below and answer the user's question directly and concisely.
        - Base your answer ONLY on the webpage content — do not use outside knowledge.
        - If the answer involves data (temperatures, times, percentages), include the exact values from the page.
        - If the webpage does not contain enough information to answer the question, respond with: "The requested information was not found on this page."

        WEBPAGE TEXT:
        \(safeText)
        [INSTRUCTION]
        """
        
        // Perform generation
        let extractedText = try await container.perform { context in
            let chatML = "<|im_start|>system\nYou are a helpful AI.<|im_end|>\n<|im_start|>user\n\(prompt)<|im_end|>\n<|im_start|>assistant\n"
            var tokens = context.tokenizer.encode(text: chatML)
            if tokens.isEmpty {
                tokens = context.tokenizer.encode(text: "hi")
            }
            if tokens.isEmpty {
                throw NSError(
                    domain: "WebFetchTool",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Tokenizer produced an empty prompt for web extraction."]
                )
            }
            let inputTokens = MLXArray(tokens)
            let input = LMInput(tokens: inputTokens)
            
            var responseText = ""
            
            let tokenStream = try MLXLMCommon.generateTokens(
                input: input,
                parameters: extractConfig.generateParameters,
                context: context
            )
            for await item in tokenStream {
                if Task.isCancelled { throw CancellationError() }
                switch item {
                case .token(let id):
                    responseText += context.tokenizer.decode(tokenIds: [id])
                case .info:
                    break
                }
            }
            
            return responseText.replacingOccurrences(of: "<|im_end|>", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return extractedText
    }
}
