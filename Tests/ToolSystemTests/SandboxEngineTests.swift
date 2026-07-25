import XCTest
@testable import MLXCoder

final class SandboxEngineTests: XCTestCase {
    func testWrapUsesShellEntrypoint() {
        let engine = SandboxEngine()
        let wrapped = engine.wrap(command: "echo hello > file.txt", workspaceRoot: "/tmp/workspace")

        XCTAssertTrue(wrapped.contains("sandbox-exec -p '"))
        XCTAssertTrue(wrapped.contains("/bin/zsh -c 'echo hello > file.txt'"))
    }

    func testProfileUsesCanonicalWorkspaceRoot() {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-coder-sandbox-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let canonical = workspace.resolvingSymlinksInPath().path()
        let engine = SandboxEngine()
        let wrapped = engine.wrap(command: "pwd", workspaceRoot: workspace.path())

        XCTAssertTrue(wrapped.contains("(subpath \"\(canonical)\")"))
    }

    func testProfileIncludesBalancedDeveloperCachePaths() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let engine = SandboxEngine()
        let wrapped = engine.wrap(command: "true", workspaceRoot: "/tmp/workspace")

        XCTAssertTrue(wrapped.contains("(subpath \"\(home)/.pnpm-store\")"))
        XCTAssertTrue(wrapped.contains("(subpath \"\(home)/.gradle\")"))
        XCTAssertTrue(wrapped.contains("(subpath \"\(home)/.m2\")"))
        XCTAssertTrue(wrapped.contains("(subpath \"\(home)/go/pkg/mod\")"))
        XCTAssertTrue(wrapped.contains("(subpath \"\(home)/.swiftpm\")"))
        XCTAssertTrue(wrapped.contains("(subpath \"\(home)/.cache/uv\")"))
    }

    func testProfileScopesNodeConfigToNodejsSuffixOnly() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let engine = SandboxEngine()
        let wrapped = engine.wrap(command: "true", workspaceRoot: "/tmp/workspace")

        // env-paths/Conf (create-next-app and other Node CLIs) store config at
        // ~/Library/Preferences/<name>-nodejs. Grant read+write scoped to that
        // suffix via a regex — never a subpath over the whole Preferences tree,
        // which would expose every app's preference plist. Conf reads its
        // existing config before writing, so both rules must be present.
        let pattern = "^\(home)/Library/Preferences/[^/]+-nodejs(/|$)"
        XCTAssertTrue(wrapped.contains("(allow file-write* (regex \"\(pattern)\"))"))
        XCTAssertTrue(wrapped.contains("(allow file-read* (regex \"\(pattern)\"))"))
        // The broad-subpath form must NOT be present.
        XCTAssertFalse(wrapped.contains("(subpath \"\(home)/Library/Preferences\")"))
    }

    func testProfileAllowsMetadataReadsOnWorkspaceAncestors() {
        let engine = SandboxEngine()
        let wrapped = engine.wrap(command: "true", workspaceRoot: "/Users/example/Dev/proj")

        // Each ancestor is stat-able (metadata only) so npm/git tree walk-ups
        // don't fail with EPERM, but never via subpath (no content exposure).
        XCTAssertTrue(wrapped.contains("(allow file-read-metadata (literal \"/Users\"))"))
        XCTAssertTrue(wrapped.contains("(allow file-read-metadata (literal \"/Users/example\"))"))
        XCTAssertTrue(wrapped.contains("(allow file-read-metadata (literal \"/Users/example/Dev\"))"))
        // The workspace itself is covered by the full read/write allow, not the
        // ancestor metadata rules.
        XCTAssertFalse(wrapped.contains("(allow file-read-metadata (literal \"/Users/example/Dev/proj\"))"))
    }

    func testAncestorDirectoriesEnumeratesParentsExcludingRootAndSelf() {
        let engine = SandboxEngine()
        XCTAssertEqual(
            engine.ancestorDirectories(of: "/Users/example/Dev/proj/"),
            ["/Users", "/Users/example", "/Users/example/Dev"]
        )
        XCTAssertEqual(engine.ancestorDirectories(of: "/proj"), [])
        XCTAssertEqual(engine.ancestorDirectories(of: "/"), [])
    }
}
