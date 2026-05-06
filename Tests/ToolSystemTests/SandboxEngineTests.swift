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
}
