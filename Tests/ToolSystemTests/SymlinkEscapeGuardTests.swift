// Tests/ToolSystemTests/SymlinkEscapeGuardTests.swift

import XCTest
@testable import MLXCoder

final class SymlinkEscapeGuardTests: XCTestCase {

    // MARK: - Basic cases

    func testEscapingSymlinkIsBlocked() {
        let error = SymlinkEscapeGuard.checkLnCommand(
            "ln -s ../../etc/passwd link",
            workspaceRoot: "/workspace"
        )
        XCTAssertNotNil(error, "Symlink pointing outside workspace must be blocked")
    }

    func testInsideWorkspaceSymlinkIsAllowed() {
        let error = SymlinkEscapeGuard.checkLnCommand(
            "ln -s ./subdir/file.txt link",
            workspaceRoot: "/workspace"
        )
        XCTAssertNil(error, "Symlink staying inside workspace must be allowed")
    }

    func testHardLinkIsAllowed() {
        // Hard links (no -s) are permitted regardless of target.
        let error = SymlinkEscapeGuard.checkLnCommand(
            "ln /etc/passwd link",
            workspaceRoot: "/workspace"
        )
        XCTAssertNil(error, "Hard links must not be blocked")
    }

    // MARK: - cd-tracking: the key regression scenario from review feedback

    /// `cd subdir && ln -s ../etc link` should be ALLOWED:
    /// `../etc` is relative to `workspaceRoot/subdir`, so it resolves to
    /// `workspaceRoot/etc` — still inside the workspace.
    /// Before the fix, the guard resolved relative to `workspaceRoot` and
    /// would refuse this legitimate command.
    func testCdSubdirThenInsideLinkIsAllowed() {
        let error = SymlinkEscapeGuard.checkLnCommand(
            "cd subdir && ln -s ../etc link",
            workspaceRoot: "/workspace"
        )
        XCTAssertNil(
            error,
            "ln -s ../etc after cd subdir resolves to /workspace/etc (inside) — must be allowed"
        )
    }

    /// `cd subdir && ln -s ../../etc link` IS escaping:
    /// `../../etc` relative to `workspaceRoot/subdir` resolves to `/etc`
    /// (outside the workspace) and must be blocked.
    func testCdSubdirThenEscapingLinkIsBlocked() {
        let error = SymlinkEscapeGuard.checkLnCommand(
            "cd subdir && ln -s ../../etc link",
            workspaceRoot: "/workspace"
        )
        XCTAssertNotNil(
            error,
            "ln -s ../../etc after cd subdir resolves outside workspace — must be blocked"
        )
    }

    /// A bare `cd` resets CWD to home (unknown), so the subsequent `ln -s`
    /// check is deferred to the post-execution sweep (no false-positive block).
    func testBareCdSkipsLnCheck() {
        let error = SymlinkEscapeGuard.checkLnCommand(
            "cd && ln -s ../etc link",
            workspaceRoot: "/workspace"
        )
        XCTAssertNil(error, "ln after bare cd must not produce a false positive")
    }

    /// `cd -` (switch to previous directory) is undeterminable statically;
    /// subsequent `ln` check must be skipped (no false positive).
    func testCdDashSkipsLnCheck() {
        let error = SymlinkEscapeGuard.checkLnCommand(
            "cd - && ln -s ../etc link",
            workspaceRoot: "/workspace"
        )
        XCTAssertNil(error, "ln after cd - must not produce a false positive")
    }
}
