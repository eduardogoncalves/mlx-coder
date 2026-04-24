// Sources/MLXCoder/UpdateChecker.swift
// GitHub release check logic shared by UpdateCommand and startup notice.

import Foundation

// MARK: - GitHub Release Model

struct GitHubRelease: Decodable, Sendable {
    let tagName: String
    let htmlURL: String
    let name: String
    let prerelease: Bool
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case name
        case prerelease
        case assets
    }
}

struct GitHubReleaseAsset: Decodable, Sendable {
    let name: String
    let browserDownloadURL: String
    let size: Int

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
    }
}

// MARK: - Update Info

struct UpdateInfo: Sendable {
    let currentVersion: String
    let latestVersion: String
    let releaseURL: String
    let pkgAsset: GitHubReleaseAsset?
}

// MARK: - UpdateChecker

enum UpdateChecker {
    static let apiURL = "https://api.github.com/repos/eduardogoncalves/mlx-coder/releases/latest"

    /// Fetches the latest non-prerelease release from GitHub.
    /// Returns nil when the network is unavailable or the request fails silently.
    static func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: URL(string: apiURL)!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    /// Checks whether a newer version than `currentVersion` is available.
    /// Returns nil if up to date or if the check fails silently.
    static func checkForUpdate(currentVersion: String) async -> UpdateInfo? {
        guard let release = try? await fetchLatestRelease() else { return nil }
        let latest = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        guard isNewer(latest, than: currentVersion) else { return nil }

        let pkgAsset = release.assets.first { $0.name.hasSuffix(".pkg") }
        return UpdateInfo(
            currentVersion: currentVersion,
            latestVersion: latest,
            releaseURL: release.htmlURL,
            pkgAsset: pkgAsset
        )
    }

    /// Returns true when `candidate` is strictly newer than `installed` using
    /// numeric dot-separated comparison. Trailing zeros are treated as equal.
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        let lhs = versionComponents(candidate)
        let rhs = versionComponents(installed)
        let count = max(lhs.count, rhs.count)
        for i in 0..<count {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: - Private

    private static func versionComponents(_ version: String) -> [Int] {
        version.split(separator: ".").compactMap { Int($0) }
    }
}

// MARK: - Errors

enum UpdateError: Error, LocalizedError {
    case httpError(Int)
    case downloadFailed(String)
    case installFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .httpError(let code): return "GitHub API returned HTTP \(code)"
        case .downloadFailed(let msg): return "Download failed: \(msg)"
        case .installFailed(let status): return "Installer exited with status \(status)"
        }
    }
}
