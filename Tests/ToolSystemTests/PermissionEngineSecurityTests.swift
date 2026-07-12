// Tests/ToolSystemTests/PermissionEngineSecurityTests.swift
// Regression tests for two security hardenings:
//   1. validatePath must not accept sibling directories that merely share the
//      workspace-root prefix (e.g. `/tmp/proj-secrets` for workspace `/tmp/proj`).
//   2. The default command denylist must catch common bypasses of the original
//      intent (path-prefixed sudo, root globs, flag reordering, power state,
//      raw-device destruction) while leaving legitimate relative deletes alone.

import XCTest
@testable import MLXCoder

final class PermissionEngineSecurityTests: XCTestCase {

    // MARK: - Finding #1: sibling-directory escape

    func testValidatePathRejectsSiblingDirectorySharingPrefix() {
        let engine = PermissionEngine(workspaceRoot: "/tmp/workspace")
        // `/tmp/workspace-secrets` shares the "/tmp/workspace" prefix but is a
        // sibling of the workspace and must be rejected for write/search.
        XCTAssertThrowsError(try engine.validatePath("/tmp/workspace-secrets/keys.txt"))
    }

    func testValidatePathAllowsWorkspaceRootItself() throws {
        let engine = PermissionEngine(workspaceRoot: "/tmp/workspace")
        let resolved = try engine.validatePath("/tmp/workspace")
        XCTAssertEqual(resolved, engine.effectiveWorkspaceRoot)
    }

    func testValidatePathAllowsNestedWorkspaceFile() throws {
        let engine = PermissionEngine(workspaceRoot: "/tmp/workspace")
        let resolved = try engine.validatePath("/tmp/workspace/src/main.swift")
        XCTAssertTrue(resolved.hasPrefix("/tmp/workspace/"))
    }

    // MARK: - Finding #2: strengthened default denylist

    func testDenylistBlocksPathPrefixedSudo() {
        let engine = PermissionEngine(workspaceRoot: "/tmp/workspace")
        XCTAssertFalse(engine.isCommandAllowed("/usr/bin/sudo rm file"))
        XCTAssertFalse(engine.isCommandAllowed("sudo apt-get install foo"))
        XCTAssertFalse(engine.isCommandAllowed("doas reboot"))
    }

    func testDenylistBlocksRootDeleteVariants() {
        let engine = PermissionEngine(workspaceRoot: "/tmp/workspace")
        XCTAssertFalse(engine.isCommandAllowed("rm -rf /"))
        XCTAssertFalse(engine.isCommandAllowed("rm -rf /*"))
        XCTAssertFalse(engine.isCommandAllowed("rm -fr /etc"))
        XCTAssertFalse(engine.isCommandAllowed("rm -rf ~/Documents"))
        XCTAssertFalse(engine.isCommandAllowed("rm -rf --no-preserve-root /"))
    }

    func testDenylistAllowsRelativeDeletes() {
        let engine = PermissionEngine(workspaceRoot: "/tmp/workspace")
        // Ordinary cleanup inside the workspace must keep working.
        XCTAssertTrue(engine.isCommandAllowed("rm -rf build"))
        XCTAssertTrue(engine.isCommandAllowed("rm -rf ./out"))
        XCTAssertTrue(engine.isCommandAllowed("rm -rf node_modules"))
    }

    func testDenylistBlocksPowerStateCommands() {
        let engine = PermissionEngine(workspaceRoot: "/tmp/workspace")
        XCTAssertFalse(engine.isCommandAllowed("shutdown -h now"))
        XCTAssertFalse(engine.isCommandAllowed("/sbin/shutdown -h now"))
        XCTAssertFalse(engine.isCommandAllowed("reboot"))
        XCTAssertFalse(engine.isCommandAllowed("poweroff"))
        XCTAssertFalse(engine.isCommandAllowed("halt"))
    }

    func testDenylistDoesNotBlockMentioningPowerWordAsArgument() {
        let engine = PermissionEngine(workspaceRoot: "/tmp/workspace")
        // Grepping for the word "shutdown" is legitimate and must not be denied.
        XCTAssertTrue(engine.isCommandAllowed("grep shutdown server.log"))
    }

    func testDenylistBlocksRawDeviceDestruction() {
        let engine = PermissionEngine(workspaceRoot: "/tmp/workspace")
        XCTAssertFalse(engine.isCommandAllowed("mkfs.ext4 /dev/sda"))
        XCTAssertFalse(engine.isCommandAllowed("dd if=/dev/zero of=/dev/disk2"))
        XCTAssertFalse(engine.isCommandAllowed("diskutil eraseDisk JHFS+ Untitled /dev/disk3"))
        XCTAssertFalse(engine.isCommandAllowed("echo x > /dev/rdisk0"))
    }
}
