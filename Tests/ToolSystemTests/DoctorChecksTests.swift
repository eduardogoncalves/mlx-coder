import XCTest
@testable import NativeAgent

final class DoctorChecksTests: XCTestCase {
    func testDoctorShouldFailOnFailuresAlways() {
        let payload = DoctorPayload(
            workspace: "/tmp",
            checks: [],
            passCount: 1,
            warnCount: 0,
            failCount: 1
        )

        XCTAssertTrue(doctorShouldFail(payload: payload, strict: false))
        XCTAssertTrue(doctorShouldFail(payload: payload, strict: true))
    }

    func testDoctorShouldFailOnWarningsOnlyInStrictMode() {
        let payload = DoctorPayload(
            workspace: "/tmp",
            checks: [],
            passCount: 1,
            warnCount: 2,
            failCount: 0
        )

        XCTAssertFalse(doctorShouldFail(payload: payload, strict: false))
        XCTAssertTrue(doctorShouldFail(payload: payload, strict: true))
    }

    func testLSPDoctorCheckSkipsForNonDotnetWorkspace() {
        let check = lspDoctorCheck(isDotnetWorkspace: false, csharpLSAvailable: false)
        XCTAssertEqual(check.name, "lsp")
        XCTAssertEqual(check.status, .pass)
    }

    func testLSPDoctorCheckWarnsWhenDotnetMissingCSharpLS() {
        let check = lspDoctorCheck(isDotnetWorkspace: true, csharpLSAvailable: false)
        XCTAssertEqual(check.name, "lsp")
        XCTAssertEqual(check.status, .warn)
    }

    func testAppendDoctorCheckRecomputesSummaryCounts() {
        let payload = DoctorPayload(
            workspace: "/tmp/workspace",
            checks: [
                DoctorCheck(name: "a", status: .pass, message: "ok"),
                DoctorCheck(name: "b", status: .warn, message: "warn")
            ],
            passCount: 1,
            warnCount: 1,
            failCount: 0
        )

        let updated = appendDoctorCheck(payload, check: DoctorCheck(name: "c", status: .fail, message: "fail"))
        XCTAssertEqual(updated.passCount, 1)
        XCTAssertEqual(updated.warnCount, 1)
        XCTAssertEqual(updated.failCount, 1)
        XCTAssertEqual(updated.checks.count, 3)
    }

    func testDoctorPayloadWarnsWhenNoOptionalFilesOrMCPConfigured() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctor-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let payload = buildDoctorPayload(
            workspaceRoot: tempDir.path,
            runtimeConfig: RuntimeConfig(),
            cliMCPConfig: nil
        )

        XCTAssertEqual(payload.workspace, tempDir.path)
        XCTAssertEqual(payload.failCount, 0)
        XCTAssertGreaterThanOrEqual(payload.warnCount, 3)
        XCTAssertTrue(payload.checks.contains { $0.name == "workspace" && $0.status == .pass })
        XCTAssertTrue(payload.checks.contains { $0.name == "runtime-config" && $0.status == .warn })
        XCTAssertTrue(payload.checks.contains { $0.name == "skills" && $0.status == .warn })
        XCTAssertTrue(payload.checks.contains { $0.name == "mcp" && $0.status == .warn })
    }

    func testDoctorPayloadPassesWhenSkillsAreDiscovered() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctor-tests-skills-pass-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let skillDir = tempDir.appendingPathComponent(".github/skills/reviewer", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try "# Reviewer".write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let payload = buildDoctorPayload(
            workspaceRoot: tempDir.path,
            runtimeConfig: RuntimeConfig(),
            cliMCPConfig: nil
        )

        XCTAssertTrue(payload.checks.contains { $0.name == "skills" && $0.status == .pass })
    }

    func testDoctorPayloadFailsForInvalidMCPAndPolicy() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctor-tests-invalid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let policyPath = tempDir.appendingPathComponent("bad-policy.json").path
        try "{not-json".write(toFile: policyPath, atomically: true, encoding: .utf8)

        let runtimeConfig = RuntimeConfig(
            mcpServers: [],
            defaultApprovalMode: nil,
            defaultSandbox: nil,
            defaultDryRun: nil,
            defaultPolicyFile: "bad-policy.json",
            defaultAuditLogPath: nil
        )

        let payload = buildDoctorPayload(
            workspaceRoot: tempDir.path,
            runtimeConfig: runtimeConfig,
            cliMCPConfig: MCPClient.ServerConfig(name: "broken", command: "nope", endpointURL: "not-a-url", timeoutSeconds: 10)
        )

        XCTAssertGreaterThanOrEqual(payload.failCount, 2)
        XCTAssertTrue(payload.checks.contains { $0.name == "policy" && $0.status == .fail })
        XCTAssertTrue(payload.checks.contains { $0.name == "mcp" && $0.status == .fail })
    }

    func testDoctorPayloadFailsForMissingStdioCommand() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctor-tests-mcp-command-missing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let payload = buildDoctorPayload(
            workspaceRoot: tempDir.path,
            runtimeConfig: RuntimeConfig(),
            cliMCPConfig: MCPClient.ServerConfig(
                name: "stdio-missing",
                command: "missing-binary",
                endpointURL: nil,
                timeoutSeconds: 10
            ),
            commandAvailable: { _ in false }
        )

        XCTAssertTrue(payload.checks.contains {
            $0.name == "mcp" && $0.status == .fail && $0.message.contains("command not found")
        })
    }

    func testDoctorPayloadPassesForAvailableStdioCommand() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctor-tests-mcp-command-ok-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let payload = buildDoctorPayload(
            workspaceRoot: tempDir.path,
            runtimeConfig: RuntimeConfig(),
            cliMCPConfig: MCPClient.ServerConfig(
                name: "stdio-ok",
                command: "npx",
                endpointURL: nil,
                timeoutSeconds: 10
            ),
            commandAvailable: { _ in true }
        )

        XCTAssertTrue(payload.checks.contains { $0.name == "mcp" && $0.status == .pass })
    }

    func testDoctorPayloadPassesForValidPolicyIgnoreAndMCP() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctor-tests-valid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let ignorePath = tempDir.appendingPathComponent(".mlx-coder-ignore").path
        try "dist/*\n# comment\n**/*.generated.swift\n".write(toFile: ignorePath, atomically: true, encoding: .utf8)

        let policyPath = tempDir.appendingPathComponent("good-policy.json").path
        let policyJSON = """
        {
          "rules": [
            {
              "effect": "deny",
              "tools": ["bash"],
              "reason": "disabled"
            }
          ]
        }
        """
        try policyJSON.write(toFile: policyPath, atomically: true, encoding: .utf8)

        let runtimeConfig = RuntimeConfig(
            mcpServers: [],
            defaultApprovalMode: nil,
            defaultSandbox: nil,
            defaultDryRun: nil,
            defaultPolicyFile: "good-policy.json",
            defaultAuditLogPath: nil
        )

        let payload = buildDoctorPayload(
            workspaceRoot: tempDir.path,
            runtimeConfig: runtimeConfig,
            cliMCPConfig: MCPClient.ServerConfig(name: "docs", command: "http://127.0.0.1:8080", endpointURL: "http://127.0.0.1:8080", timeoutSeconds: 10)
        )

        XCTAssertEqual(payload.failCount, 0)
        XCTAssertTrue(payload.checks.contains { $0.name == "policy" && $0.status == .pass })
        XCTAssertTrue(payload.checks.contains { $0.name == "ignore" && $0.status == .pass })
        XCTAssertTrue(payload.checks.contains { $0.name == "mcp" && $0.status == .pass })
    }

    func testDoctorPayloadPassesWhenAuditDirectoryExists() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctor-tests-audit-pass-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logsDir = tempDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let runtimeConfig = RuntimeConfig(
            mcpServers: [],
            defaultApprovalMode: nil,
            defaultSandbox: nil,
            defaultDryRun: nil,
            defaultPolicyFile: nil,
            defaultAuditLogPath: "logs/audit.log.jsonl"
        )

        let payload = buildDoctorPayload(
            workspaceRoot: tempDir.path,
            runtimeConfig: runtimeConfig,
            cliMCPConfig: nil
        )

        XCTAssertTrue(payload.checks.contains { $0.name == "audit-log" && $0.status == .pass })
    }

    func testDoctorPayloadFailsWhenAuditParentIsFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctor-tests-audit-fail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileParentPath = tempDir.appendingPathComponent("not-a-dir").path
        try "content".write(toFile: fileParentPath, atomically: true, encoding: .utf8)

        let runtimeConfig = RuntimeConfig(
            mcpServers: [],
            defaultApprovalMode: nil,
            defaultSandbox: nil,
            defaultDryRun: nil,
            defaultPolicyFile: nil,
            defaultAuditLogPath: "not-a-dir/audit.log.jsonl"
        )

        let payload = buildDoctorPayload(
            workspaceRoot: tempDir.path,
            runtimeConfig: runtimeConfig,
            cliMCPConfig: nil
        )

        XCTAssertTrue(payload.checks.contains { $0.name == "audit-log" && $0.status == .fail })
    }
}
