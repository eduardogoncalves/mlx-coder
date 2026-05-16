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

        let currentVersion = MLXCoderCLI.configuration.version

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
        defer {
            // Clean up both the .pkg and its parent UUID directory (created
            // by `downloadAsset` with 0700 perms to defeat symlink races).
            let parent = URL(fileURLWithPath: pkgPath).deletingLastPathComponent()
            try? FileManager.default.removeItem(atPath: pkgPath)
            try? FileManager.default.removeItem(at: parent)
        }

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

        // Download into a freshly created 0700 directory so a local attacker
        // cannot race a symlink onto the predictable destination path between
        // download and `sudo installer`.
        let parentDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mlx-coder-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: parentDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let destination = parentDir.appendingPathComponent("mlx-coder-\(version).pkg").path

        print("Downloading \(asset.name)…")

        // Reject HTTP redirects that leave the github.com / githubusercontent.com
        // trust set. Without this, a compromised CDN or DNS could substitute
        // an attacker-controlled installer payload that we then run as root.
        let session = URLSession(
            configuration: .ephemeral,
            delegate: GitHubRedirectGuard(),
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        let (tmpURL, response) = try await session.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        try? FileManager.default.removeItem(atPath: destination)
        try FileManager.default.moveItem(at: tmpURL, to: URL(fileURLWithPath: destination))
        // Tighten perms on the downloaded payload so other local users cannot
        // tamper with it before it is consumed by `installer`.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination
        )
        print("Downloaded to \(destination)")
        return destination
    }

    // MARK: - Install

    private func runInstaller(pkgPath: String) throws {
        // Verify the package signature before invoking `sudo installer`. An
        // unsigned or non-Apple-trusted pkg should never be silently
        // installed with root privileges; this is the last line of defence if
        // an attacker controlled the GitHub release asset.
        try verifyPackageSignature(pkgPath: pkgPath)

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

    /// Runs `pkgutil --check-signature` and refuses to install when the
    /// package is not signed by a trusted Apple Developer ID. The accepted
    /// substrings match `pkgutil`'s human-readable status lines on macOS 13+.
    private func verifyPackageSignature(pkgPath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
        process.arguments = ["--check-signature", pkgPath]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Drain concurrently to avoid the pipe-buffer deadlock pattern: a
        // `pkgutil --check-signature` of a deeply-chained certificate could
        // in theory exceed the kernel pipe buffer (~16-64 KiB) and stall
        // `waitUntilExit` while the child blocks on `write(2)`.
        let collector = PipeOutputCollector()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            collector.appendStdout(data)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            collector.appendStderr(data)
        }

        do {
            try process.run()
        } catch {
            throw UpdateError.installFailed(-1)
        }
        process.waitUntilExit()

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        let tailOut = outPipe.fileHandleForReading.availableData
        let tailErr = errPipe.fileHandleForReading.availableData
        if !tailOut.isEmpty { collector.appendStdout(tailOut) }
        if !tailErr.isEmpty { collector.appendStderr(tailErr) }

        let out = String(data: collector.stdoutSnapshot(), encoding: .utf8) ?? ""
        let err = String(data: collector.stderrSnapshot(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            fputs("error: package signature check failed:\n\(out)\(err)", stderr)
            throw UpdateError.installFailed(process.terminationStatus)
        }

        // pkgutil prints e.g. "Status: signed by a developer certificate issued by Apple for distribution"
        // (Developer ID-signed installers on modern macOS) or, for Apple's own
        // packages, "Status: signed Apple Software" / "signed by a certificate
        // trusted by Mac OS X" (the latter is legacy branding still emitted
        // on some packages). We accept all three; any other status — including
        // "no signature", "broken", or distrust strings — falls through to the
        // refusal path below.
        let acceptableStatuses = [
            "signed by a developer certificate issued by Apple",
            "signed Apple Software",
            "signed by a certificate trusted by Mac OS X",
        ]
        guard acceptableStatuses.contains(where: { out.contains($0) }) else {
            fputs("error: refusing to install — package is not signed by a trusted Apple Developer ID:\n\(out)", stderr)
            throw UpdateError.installFailed(-1)
        }
    }
}

/// URLSession delegate that refuses HTTP redirects whose host is not on the
/// known GitHub release-asset trust set. Without this, a hijacked redirect
/// could swap the downloaded `.pkg` payload before `sudo installer` runs it.
///
/// `@unchecked Sendable` is safe here: the delegate holds no mutable state —
/// the only field is the static `allowedHosts: Set<String>` which is
/// initialised once and only read.
private final class GitHubRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private static let allowedHosts: Set<String> = [
        // Public GitHub web + asset hosts. GitHub redirects release-asset
        // download URLs through some of these depending on age and region,
        // so each must be in the trust set:
        //   - github.com / api.github.com: the canonical release-metadata
        //     endpoints; the initial URL handed to us comes from here.
        //   - objects.githubusercontent.com: legacy raw-content / large-file
        //     storage backend that release-asset URLs may 302 to.
        //   - release-assets.githubusercontent.com: current dedicated host
        //     for `/releases/download/...` payloads.
        //   - codeload.github.com: source-archive endpoint; included for
        //     completeness so a future archive-download path doesn't break.
        "github.com",
        "api.github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
        "codeload.github.com",
    ]

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let host = request.url?.host?.lowercased() else {
            fputs("update: refused redirect to URL with no host\n", stderr)
            completionHandler(nil)
            return
        }
        if Self.allowedHosts.contains(host) {
            completionHandler(request)
        } else {
            // Cancel the request by passing nil; URLSession will fail the
            // task. Log the rejected host so that legitimate GitHub
            // infrastructure changes (new CDN endpoints) can be diagnosed
            // and the allowlist updated.
            fputs("update: refused redirect to disallowed host \"\(host)\"\n", stderr)
            completionHandler(nil)
        }
    }
}
