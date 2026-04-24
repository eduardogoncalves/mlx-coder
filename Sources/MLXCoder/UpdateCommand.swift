// Sources/MLXCoder/UpdateCommand.swift
// mlx-coder update — check for and optionally install a newer release.
//
// Usage:
//   mlx-coder update           — check, prompt, then download + install if confirmed
//   mlx-coder update --check   — only check; exits 0 when up to date, 1 when update available
//   mlx-coder update --yes     — skip confirmation prompt and install automatically

import ArgumentParser
import Foundation

struct UpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Check for a newer mlx-coder release and optionally install it"
    )

    @Flag(name: .long, help: "Only check for updates; do not download or install")
    var check: Bool = false

    @Flag(name: [.customShort("y"), .long], help: "Skip the confirmation prompt and install automatically")
    var yes: Bool = false

    @Flag(name: .long, help: "Emit machine-readable JSON output")
    var json: Bool = false

    @OptionGroup var testAbsorber: TestAbsorber

    mutating func run() async throws {
        guard !testAbsorber.isTestInvocation else { return }

        let currentVersion = MLXCoderCLI.configuration.version ?? "0.0.0"

        if json {
            try await runJSON(currentVersion: currentVersion)
        } else {
            try await runHuman(currentVersion: currentVersion)
        }
    }

    // MARK: - Human-readable output

    private func runHuman(currentVersion: String) async throws {
        print("Checking for updates…")

        let release: GitHubRelease
        do {
            release = try await UpdateChecker.fetchLatestRelease()
        } catch {
            fputs("error: could not reach GitHub — \(error.localizedDescription)\n", stderr)
            throw ExitCode.failure
        }

        let latestVersion = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName

        if !UpdateChecker.isNewer(latestVersion, than: currentVersion) {
            print("Already up to date (version \(currentVersion)).")
            return
        }

        print("New version available: \(latestVersion) (current: \(currentVersion))")
        print("Release: \(release.htmlURL)")

        if check {
            throw ExitCode(1)
        }

        guard let pkgAsset = release.assets.first(where: { $0.name.hasSuffix(".pkg") }) else {
            print("No .pkg installer found in the release assets.")
            print("Visit \(release.htmlURL) to install manually.")
            throw ExitCode.failure
        }

        let sizeMB = String(format: "%.1f", Double(pkgAsset.size) / 1_048_576)
        print("Installer: \(pkgAsset.name) (\(sizeMB) MB)")

        if !yes {
            print("Install now? [y/N] ", terminator: "")
            let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            guard answer == "y" || answer == "yes" else {
                print("Cancelled.")
                return
            }
        }

        let pkgPath = try await downloadAsset(pkgAsset, version: latestVersion)
        defer { try? FileManager.default.removeItem(atPath: pkgPath) }

        try runInstaller(pkgPath: pkgPath)
        print("Update complete. mlx-coder \(latestVersion) is now installed.")
    }

    // MARK: - JSON output

    private func runJSON(currentVersion: String) async throws {
        struct UpdateResult: Encodable {
            let currentVersion: String
            let latestVersion: String
            let updateAvailable: Bool
            let releaseURL: String?
        }

        let release: GitHubRelease
        do {
            release = try await UpdateChecker.fetchLatestRelease()
        } catch {
            let result = UpdateResult(
                currentVersion: currentVersion,
                latestVersion: currentVersion,
                updateAvailable: false,
                releaseURL: nil
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(result), as: UTF8.self))
            throw ExitCode.failure
        }

        let latestVersion = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        let updateAvailable = UpdateChecker.isNewer(latestVersion, than: currentVersion)

        let result = UpdateResult(
            currentVersion: currentVersion,
            latestVersion: latestVersion,
            updateAvailable: updateAvailable,
            releaseURL: updateAvailable ? release.htmlURL : nil
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(result), as: UTF8.self))

        if check && updateAvailable {
            throw ExitCode(1)
        }
    }

    // MARK: - Download

    private func downloadAsset(_ asset: GitHubReleaseAsset, version: String) async throws -> String {
        guard let url = URL(string: asset.browserDownloadURL) else {
            throw UpdateError.downloadFailed("invalid URL: \(asset.browserDownloadURL)")
        }

        let destination = NSTemporaryDirectory() + "mlx-coder-update-\(version).pkg"

        print("Downloading \(asset.name)…")

        let (tmpURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        try? FileManager.default.removeItem(atPath: destination)
        try FileManager.default.moveItem(at: tmpURL, to: URL(fileURLWithPath: destination))
        print("Downloaded to \(destination)")
        return destination
    }

    // MARK: - Install

    private func runInstaller(pkgPath: String) throws {
        print("Running installer (may require your password)…")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["installer", "-pkg", pkgPath, "-target", "/"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.installFailed(process.terminationStatus)
        }
    }
}
