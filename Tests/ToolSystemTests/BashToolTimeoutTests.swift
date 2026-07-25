import XCTest
@testable import MLXCoder

/// Proves the hang/leak fixes: a bash command that would otherwise run long
/// past its `timeout` must (a) return the tool call promptly at the deadline,
/// and (b) actually kill the whole process tree, not just the `zsh` wrapper —
/// so orphaned pipeline/`&&` children (the network-stalled `curl` in the real
/// report) don't survive.
final class BashToolTimeoutTests: XCTestCase {
    private func makeTempWorkspace() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bash-timeout-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testHangingCommandReturnsAtTimeoutNotAfter() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let tool = BashTool(permissions: PermissionEngine(workspaceRoot: workspace.path))

        let start = Date()
        let result = try await tool.execute(arguments: ["command": "sleep 30", "timeout": 1])
        let elapsed = Date().timeIntervalSince(start)

        // Must come back shortly after the 1s deadline, NOT wait out the 30s sleep.
        XCTAssertLessThan(elapsed, 10, "bash returned after \(elapsed)s; the timeout did not fire")
        XCTAssertTrue(result.isError, "a timed-out command should surface as an error result")
    }

    func testTimeoutKillsChildrenNotJustTheShell() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        // `sleep 3 && touch <sentinel>` forces zsh to fork `sleep` as a child
        // (it must stay alive to run `touch` afterwards). If the timeout only
        // killed the tracked zsh PID, the orphaned `sleep` would survive its
        // reparenting and create the sentinel ~3s later. The process-tree kill
        // must prevent that.
        let sentinel = workspace.appendingPathComponent("sentinel-\(UUID().uuidString).txt")
        let tool = BashTool(permissions: PermissionEngine(workspaceRoot: workspace.path))

        let start = Date()
        _ = try await tool.execute(arguments: [
            "command": "sleep 3 && touch '\(sentinel.path)'",
            "timeout": 1,
        ])
        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "the call itself must return at the deadline")

        // Wait past when a surviving orphan would have reached the `touch`.
        try await Task.sleep(for: .seconds(4))

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sentinel.path),
            "a child process outlived the timeout — the process tree was not fully killed"
        )
    }
}
