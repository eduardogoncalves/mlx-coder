// Sources/MLXCoder/RemoteProvider.swift
// Provider-agnostic description of a remote, OpenAI-API-compatible inference
// endpoint (OpenRouter, LM Studio, vLLM, mlx-lm.server, an internal gateway, …).
//
// Providers are read exclusively from ~/.mlx-coder/config.json:
//   { "providers": [ { "name": "OpenRouter",
//                      "baseURL": "https://openrouter.ai/api/v1",
//                      "apiKey": "sk-or-..." } ] }
// Only providers listed there are offered by `/model remote` — there are no
// built-ins. Each provider's `id` (used in model carrier strings and cache
// paths) is derived from its `name`. `apiKey` is optional: omit or leave it
// empty for keyless local servers.

import Foundation

struct RemoteProvider: Codable, Sendable, Equatable {
    var name: String          // display + identity, e.g. "OpenRouter"
    var baseURL: String       // OpenAI-compatible base, e.g. "https://openrouter.ai/api/v1"
    var apiKey: String?       // optional; omit/empty for keyless local servers

    init(name: String, baseURL: String, apiKey: String? = nil) {
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    /// Stable lowercase id derived from `name`. Used in model carrier strings
    /// (`<id>:<model>`), cache file paths, and provider lookups.
    var id: String { RemoteProvider.slug(name) }

    /// The base URL as a `URL`, or nil if malformed.
    var baseURLValue: URL? { URL(string: baseURL) }

    /// Whether a non-empty API key is configured for this provider.
    var hasAPIKey: Bool { !(apiKey ?? "").isEmpty }

    /// Slugify a display name into a stable id: lowercase, runs of
    /// spaces/underscores/dots/hyphens collapse to a single hyphen, other
    /// punctuation is dropped. "LM Studio" -> "lm-studio", "OpenRouter" -> "openrouter".
    static func slug(_ name: String) -> String {
        var out = ""
        var pendingSeparator = false
        for ch in name.lowercased() {
            if ch.isLetter || ch.isNumber {
                if pendingSeparator && !out.isEmpty { out.append("-") }
                pendingSeparator = false
                out.append(ch)
            } else if ch == " " || ch == "_" || ch == "-" || ch == "." {
                pendingSeparator = true
            }
            // any other punctuation is dropped
        }
        return out
    }

    // Lenient decoding so users aren't tripped up by casing:
    // baseURL/baseUrl/baseurl and apiKey/apikey/api_key are all accepted.
    private enum CodingKeys: String, CodingKey {
        case name
        case baseURL, baseUrl, baseurl
        case apiKey, apikey, api_key
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL)
            ?? c.decodeIfPresent(String.self, forKey: .baseUrl)
            ?? c.decode(String.self, forKey: .baseurl)
        self.apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey)
            ?? c.decodeIfPresent(String.self, forKey: .apikey)
            ?? c.decodeIfPresent(String.self, forKey: .api_key)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(baseURL, forKey: .baseURL)
        try c.encodeIfPresent(apiKey, forKey: .apiKey)
    }
}

enum RemoteProviderRegistry {
    static let directoryPath: String = {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.mlx-coder"
    }()

    static let filePath: String = directoryPath + "/config.json"

    /// Providers configured by the user in ~/.mlx-coder/config.json, de-duped by
    /// derived id (first entry wins). Empty when the file is missing or invalid.
    ///
    /// The file may contain `//` line and `/* */` block comments (JSONC); they're
    /// stripped before parsing so the auto-generated sample stays inert until the
    /// user uncomments it.
    static func providers() -> [RemoteProvider] {
        guard FileManager.default.fileExists(atPath: filePath),
              let raw = try? String(contentsOf: URL(filePath: filePath), encoding: .utf8),
              let data = stripJSONComments(raw).data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ConfigFile.self, from: data)
        else {
            return []
        }
        var seen = Set<String>()
        return decoded.providers.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
    }

    /// Create ~/.mlx-coder/config.json with a commented-out sample provider when
    /// the file doesn't exist yet, so first-run users have a documented template
    /// to fill in. The sample lives inside JSONC comments, so it isn't parsed —
    /// `providers()` returns empty until the user uncomments or adds an entry.
    /// Returns true if a file was created. Never overwrites an existing file.
    @discardableResult
    static func ensureConfigFileExists() -> Bool {
        guard !FileManager.default.fileExists(atPath: filePath) else { return false }
        do {
            try FileManager.default.createDirectory(
                atPath: directoryPath,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard let data = sampleConfigTemplate.data(using: .utf8) else { return false }
            try data.write(to: URL(filePath: filePath), options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: filePath
            )
            return true
        } catch {
            return false
        }
    }

    /// JSONC template written on first run. The active document is just an empty
    /// `providers` array; the sample entry is commented out so it isn't parsed.
    static let sampleConfigTemplate = """
    {
      // mlx-coder reads OpenAI-API-compatible providers from this file.
      // Each provider needs a "name" and "baseURL"; "apiKey" is optional
      // (leave it empty for keyless local servers like LM Studio or vLLM).
      //
      // Uncomment the sample below and fill in your key, or add your own
      // entries. Only providers inside the "providers" array are used —
      // anything in comments is ignored.
      "providers": [
        // {
        //   "name": "OpenRouter",
        //   "baseURL": "https://openrouter.ai/api/v1",
        //   "apiKey": "sk-or-your-key-here"
        // }
      ]
    }

    """

    /// Strip `//` line comments and `/* */` block comments from JSONC text while
    /// leaving comment-like sequences inside string literals (e.g. the `//` in a
    /// URL) untouched.
    static func stripJSONComments(_ text: String) -> String {
        let chars = Array(text)
        var out = String()
        out.reserveCapacity(chars.count)
        var i = 0
        var inString = false
        var escaped = false

        while i < chars.count {
            let c = chars[i]

            if inString {
                out.append(c)
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
                i += 1
                continue
            }

            if c == "\"" {
                inString = true
                out.append(c)
                i += 1
                continue
            }

            if c == "/", i + 1 < chars.count {
                let next = chars[i + 1]
                if next == "/" {
                    i += 2
                    while i < chars.count && chars[i] != "\n" { i += 1 }
                    continue
                }
                if next == "*" {
                    i += 2
                    while i + 1 < chars.count && !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                    i += 2   // consume the closing */
                    continue
                }
            }

            out.append(c)
            i += 1
        }

        return out
    }

    /// Look up a configured provider by id (case-insensitive).
    static func provider(id: String) -> RemoteProvider? {
        let needle = id.lowercased()
        return providers().first { $0.id == needle }
    }

    /// The API key for a configured provider, or nil if none/empty is set.
    static func apiKey(for id: String) -> String? {
        guard let key = provider(id: id)?.apiKey, !key.isEmpty else { return nil }
        return key
    }

    /// Whether the given provider id is present in ~/.mlx-coder/config.json.
    static func isConfigured(_ id: String) -> Bool {
        provider(id: id) != nil
    }

    // MARK: - Internals

    struct ConfigFile: Codable {
        var providers: [RemoteProvider]

        init(providers: [RemoteProvider]) { self.providers = providers }

        // Accept both the current `providers` key and the legacy
        // `remoteProviders` key so older configs keep working.
        private enum CodingKeys: String, CodingKey {
            case providers, remoteProviders
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.providers = (try? c.decodeIfPresent([RemoteProvider].self, forKey: .providers) ?? nil)
                ?? (try? c.decodeIfPresent([RemoteProvider].self, forKey: .remoteProviders) ?? nil)
                ?? []
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(providers, forKey: .providers)
        }
    }
}
