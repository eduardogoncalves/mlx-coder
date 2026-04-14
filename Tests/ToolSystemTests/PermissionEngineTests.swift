// Tests/ToolSystemTests/PermissionEngineTests.swift

import XCTest
@testable import MLXCoder

final class PermissionEngineTests: XCTestCase {

    func testPathInsideWorkspace() throws {
        let engine = PermissionEngine(workspaceRoot: "/tmp/workspace")
        let resolved = try engine.validatePath("/tmp/workspace/src/main.swift")
        XCTAssertTrue(resolved.hasPrefix("/tmp/workspace"))
    }

    func testPathOutsideWorkspaceThrows() {
        let engine = PermissionEngine(workspaceRoot: "/tmp/workspace")
        XCTAssertThrowsError(try engine.validatePath("/etc/passwd"))
    }

    func testRelativePathResolves() throws {
        let engine = PermissionEngine(workspaceRoot: "/tmp/workspace")
        let resolved = try engine.validatePath("src/main.swift")
        XCTAssertTrue(resolved.hasPrefix("/tmp/workspace"))
    }

    func testDeniedCommandBlocked() {
        let engine = PermissionEngine(workspaceRoot: "/tmp/workspace")
        XCTAssertFalse(engine.isCommandAllowed("sudo rm -rf /"))
    }

    func testApprovalModeDefaultsToDefault() {
        let engine = PermissionEngine(workspaceRoot: "/tmp/workspace")
        XCTAssertEqual(engine.approvalMode, .default)
    }

    func testApprovalModeCanBeConfigured() {
        let engine = PermissionEngine(workspaceRoot: "/tmp/workspace", approvalMode: .autoEdit)
        XCTAssertEqual(engine.approvalMode, .autoEdit)
    }

    func testPolicyDeniesMatchingToolAndPath() {
        let policy = PermissionEngine.PolicyDocument(rules: [
            PermissionEngine.PolicyRule(
                effect: .deny,
                tools: ["write_*"],
                paths: ["/tmp/workspace/secrets/*"],
                reason: "Writes to secrets are blocked"
            )
        ])

        let engine = PermissionEngine(workspaceRoot: "/tmp/workspace", policy: policy)
        let decision = engine.evaluateToolPolicy(toolName: "write_file", targetPath: "secrets/keys.txt")
        XCTAssertEqual(decision, .denied(reason: "Writes to secrets are blocked"))
    }

    func testPolicyAllowsWhenNoRuleMatches() {
        let policy = PermissionEngine.PolicyDocument(rules: [
            PermissionEngine.PolicyRule(effect: .deny, tools: ["bash"], paths: ["/tmp/workspace/blocked/*"])
        ])

        let engine = PermissionEngine(workspaceRoot: "/tmp/workspace", policy: policy)
        let decision = engine.evaluateToolPolicy(toolName: "write_file", targetPath: "src/main.swift")
        XCTAssertEqual(decision, .allowed)
    }

    func testIgnorePatternsMatchRelativeAndAbsolutePaths() {
        let engine = PermissionEngine(
            workspaceRoot: "/tmp/workspace",
            ignoredPathPatterns: ["**/*.generated.swift", "vendor/*"]
        )

        XCTAssertTrue(engine.isPathIgnored("Sources/API.generated.swift"))
        XCTAssertTrue(engine.isPathIgnored("/tmp/workspace/vendor/lib/file.swift"))
        XCTAssertFalse(engine.isPathIgnored("Sources/Main.swift"))
    }

    func testEffectiveWorkspaceRootMatchesWorkspaceRoot() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-coder-permissions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let engine = PermissionEngine(workspaceRoot: tempRoot.path)

        XCTAssertTrue((engine.effectiveWorkspaceRoot as NSString).isAbsolutePath)
        XCTAssertEqual(engine.effectiveWorkspaceRoot, URL(filePath: tempRoot.path).standardized.path())
    }
}
