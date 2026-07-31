// Tests/CodeGraphTests/GrammarManifestTests.swift
// `grammars/manifest.json` shape + `scripts/sync-grammars.sh --check` (plan
// §13.2, §13.5): the manifest is the single source of truth for pinned
// commits/sha256/ABI, and `--check` is the fast, offline, no-network mode
// wired into `scripts/release.sh` that must fail on any drift between the
// manifest and what's actually vendored under `Sources/CTreeSitter*/`.

import XCTest
@testable import MLXCoder

final class GrammarManifestTests: XCTestCase {

    private var repoRoot: String { FileManager.default.currentDirectoryPath }
    private var manifestPath: String { "\(repoRoot)/grammars/manifest.json" }
    private var checkScriptPath: String { "\(repoRoot)/scripts/sync-grammars.sh" }

    private func loadManifest() throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "GrammarManifestTests", code: 1)
        }
        return json
    }

    @discardableResult
    private func runCheckScript() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [checkScriptPath, "--check"]
        process.currentDirectoryURL = URL(fileURLWithPath: repoRoot)
        let devNull = FileHandle.nullDevice
        process.standardOutput = devNull
        process.standardError = devNull
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    // MARK: - Shape

    func testManifestHasExpectedTopLevelShape() throws {
        let manifest = try loadManifest()
        XCTAssertNotNil(manifest["runtime"] as? [String: Any])
        XCTAssertNotNil(manifest["grammars"] as? [String: Any])
        XCTAssertNotNil(manifest["files"] as? [String: Any])
    }

    func testEveryTier1GrammarIsPresentWithPinAndSymbol() throws {
        let manifest = try loadManifest()
        guard let grammars = manifest["grammars"] as? [String: Any] else {
            return XCTFail("missing grammars section")
        }
        for name in ["swift", "csharp", "javascript", "typescript"] {
            guard let entry = grammars[name] as? [String: Any] else {
                return XCTFail("missing grammar entry for \(name)")
            }
            XCTAssertNotNil(entry["repo"] as? String)
            XCTAssertNotNil(entry["commit"] as? String)
            XCTAssertNotNil(entry["symbol"] as? String)
            XCTAssertNotNil(entry["abi"] as? Int)
        }
    }

    // MARK: - ABI compatibility (plan §13.3 rail #3)

    func testEveryGrammarABIFallsWithinTheRuntimesSupportedRange() throws {
        let manifest = try loadManifest()
        guard let runtime = manifest["runtime"] as? [String: Any],
              let maxABI = runtime["languageVersionMax"] as? Int,
              let minABI = runtime["languageVersionMin"] as? Int,
              let grammars = manifest["grammars"] as? [String: Any] else {
            return XCTFail("missing runtime/grammars section")
        }
        for (name, raw) in grammars {
            guard let entry = raw as? [String: Any], let abi = entry["abi"] as? Int else {
                return XCTFail("missing abi for \(name)")
            }
            XCTAssertTrue((minABI...maxABI).contains(abi), "\(name)'s ABI \(abi) outside runtime range \(minABI)...\(maxABI)")
        }
    }

    // MARK: - `--check` on a clean checkout

    func testCheckPassesOnCleanCheckout() throws {
        XCTAssertEqual(try runCheckScript(), 0, "sync-grammars.sh --check should pass when vendored files match the manifest")
    }

    // MARK: - `--check` fails on drift

    func testCheckFailsWhenAVendoredFileIsModified() throws {
        // Corrupt a small, cheap-to-restore vendored file (a hand-authored
        // bridging header, not one of the multi-MB generated parser.c
        // files) and confirm --check catches it, then restore it exactly —
        // this test must never leave the tree dirty on failure either.
        let target = "\(repoRoot)/Sources/CTreeSitterSwift/include/CTreeSitterSwift.h"
        let original = try Data(contentsOf: URL(fileURLWithPath: target))
        defer { try? original.write(to: URL(fileURLWithPath: target)) }

        var corrupted = original
        corrupted.append(contentsOf: "\n// drift\n".utf8)
        try corrupted.write(to: URL(fileURLWithPath: target))

        XCTAssertNotEqual(try runCheckScript(), 0, "sync-grammars.sh --check should fail on hash drift")
    }

    func testCheckFailsWhenAVendoredFileIsMissing() throws {
        let target = "\(repoRoot)/Sources/CTreeSitterJavaScript/include/CTreeSitterJavaScript.h"
        let original = try Data(contentsOf: URL(fileURLWithPath: target))
        defer { try? original.write(to: URL(fileURLWithPath: target)) }

        try FileManager.default.removeItem(atPath: target)

        XCTAssertNotEqual(try runCheckScript(), 0, "sync-grammars.sh --check should fail when a manifest-listed file is missing")
    }
}
