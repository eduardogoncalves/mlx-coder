// Sources/ToolSystem/Web/WebFetchCache.swift
// Disk-based cache for web_fetch responses stored under /tmp.

import CryptoKit
import Foundation

/// Caches raw and HTML-stripped responses under `/tmp/mlx-coder-webcache/`.
///
/// Two variants are stored per URL:
/// - `<hash>.raw`  — original network response (UTF-8 text)
/// - `<hash>.txt`  — HTML-stripped plain text (only when text_only mode was used)
///
/// Callers first ask `rawContent(for:)` / `textContent(for:)` to check the cache,
/// then call `save(raw:text:for:)` after a successful fetch.
struct WebFetchCache {

    // MARK: - Shared instance

    static let shared = WebFetchCache()

    // MARK: - Constants

    private static let cacheDir: URL = {
        let fileManager = FileManager.default
        let dir = URL(fileURLWithPath: "/tmp/mlx-coder-webcache", isDirectory: true)
        do {
            if fileManager.fileExists(atPath: dir.path) {
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            } else {
                try fileManager.createDirectory(
                    at: dir,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
        } catch {
            fatalError("Unable to initialize web cache directory securely at \(dir.path): \(error.localizedDescription)")
        }
        return dir
    }()

    // MARK: - Public API

    /// Returns the cached raw response for `urlString`, or `nil` if not cached.
    func rawContent(for urlString: String) -> String? {
        read(file: rawURL(for: urlString))
    }

    /// Returns the cached HTML-stripped text for `urlString`, or `nil` if not cached.
    func textContent(for urlString: String) -> String? {
        read(file: textURL(for: urlString))
    }

    /// Persists fetched content.
    /// - Parameters:
    ///   - raw:  Original network response. Always saved.
    ///   - text: HTML-stripped text. Saved only when non-nil (i.e. text_only was applied).
    ///   - urlString: The URL that was fetched.
    func save(raw: String, text: String?, for urlString: String) {
        write(raw, to: rawURL(for: urlString))
        if let text {
            write(text, to: textURL(for: urlString))
        } else {
            try? FileManager.default.removeItem(at: textURL(for: urlString))
        }
    }

    // MARK: - Path helpers

    func rawURL(for urlString: String) -> URL {
        Self.cacheDir.appendingPathComponent("\(cacheKey(urlString)).raw")
    }

    func textURL(for urlString: String) -> URL {
        Self.cacheDir.appendingPathComponent("\(cacheKey(urlString)).txt")
    }

    // MARK: - Private helpers

    private func cacheKey(_ urlString: String) -> String {
        let hash = SHA256.hash(data: Data(urlString.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func read(file url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func write(_ content: String, to url: URL) {
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }
}
