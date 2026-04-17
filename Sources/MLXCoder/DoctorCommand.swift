// Sources/MLXCoder/DoctorCommand.swift
// Workspace diagnostics subcommand — validates config, policy, skills, MCP, etc.

import ArgumentParser
import Foundation

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Validate workspace, config, policy, ignore patterns, skills discovery, and MCP endpoint settings"
    )

    @Option(name: .long, help: "Workspace root used for resolving workspace checks")
    var workspace: String = "."

    @Option(name: .long, help: "Optional MCP server HTTP endpoint (JSON-RPC) override")
    var mcpEndpoint: String?

    @Option(name: .long, help: "Logical MCP server name used with --mcp-endpoint")
    var mcpName: String = "remote"

    @Option(name: .long, help: "MCP request timeout in seconds")
    var mcpTimeout: Int = 30

    @Flag(name: .long, help: "Emit machine-readable JSON output")
    var json: Bool = false

    @Flag(name: .long, help: "Treat warnings as failures (non-zero exit code when warn/fail checks exist)")
    var strict: Bool = false

    @OptionGroup var testAbsorber: TestAbsorber

    mutating func run() async throws {
        guard !testAbsorber.isTestInvocation else { return }

        let workspacePath = NSString(string: workspace).expandingTildeInPath
        let rawWorkspace = workspacePath.hasPrefix("/")
            ? workspacePath
            : FileManager.default.currentDirectoryPath + "/" + workspacePath
        let absWorkspace = NSString(string: rawWorkspace).standardizingPath

        let runtimeConfig = RuntimeConfigLoader.loadMerged(workspaceRoot: absWorkspace)
        var payload = buildDoctorPayload(
            workspaceRoot: absWorkspace,
            runtimeConfig: runtimeConfig,
            cliMCPConfig: {
                guard let endpoint = mcpEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines), !endpoint.isEmpty else {
                    return nil
                }
                return MCPClient.ServerConfig(
                    name: mcpName,
                    command: endpoint,
                    endpointURL: endpoint,
                    timeoutSeconds: max(1, mcpTimeout)
                )
            }()
        )

        let detector = DotnetWorkspaceDetector()
        let isDotnet = await detector.isDotnetWorkspace(absWorkspace)
        let lspCheck = lspDoctorCheck(
            isDotnetWorkspace: isDotnet,
            csharpLSAvailable: isCommandAvailable("csharp-ls")
        )
        payload = appendDoctorCheck(payload, check: lspCheck)

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)
            print(String(decoding: data, as: UTF8.self))
            if doctorShouldFail(payload: payload, strict: strict) {
                throw ExitCode.failure
            }
            return
        }

        print("Workspace: \(payload.workspace)")
        for check in payload.checks {
            switch check.status {
            case .pass:
                print("[PASS] \(check.name): \(check.message)")
            case .warn:
                print("[WARN] \(check.name): \(check.message)")
            case .fail:
                print("[FAIL] \(check.name): \(check.message)")
            }
        }
        print("")
        print("Summary: pass=\(payload.passCount), warn=\(payload.warnCount), fail=\(payload.failCount)")

        if doctorShouldFail(payload: payload, strict: strict) {
            throw ExitCode.failure
        }
    }
}

// MARK: - Doctor Types

enum DoctorStatus: String, Codable, Sendable {
    case pass
    case warn
    case fail
}

struct DoctorCheck: Codable, Sendable {
    let name: String
    let status: DoctorStatus
    let message: String
}

struct DoctorPayload: Codable, Sendable {
    let workspace: String
    let checks: [DoctorCheck]
    let passCount: Int
    let warnCount: Int
    let failCount: Int
}

// MARK: - Doctor Helpers

func appendDoctorCheck(_ payload: DoctorPayload, check: DoctorCheck) -> DoctorPayload {
    let checks = payload.checks + [check]
    let passCount = checks.filter { $0.status == .pass }.count
    let warnCount = checks.filter { $0.status == .warn }.count
    let failCount = checks.filter { $0.status == .fail }.count
    return DoctorPayload(
        workspace: payload.workspace,
        checks: checks,
        passCount: passCount,
        warnCount: warnCount,
        failCount: failCount
    )
}

func doctorShouldFail(payload: DoctorPayload, strict: Bool) -> Bool {
    if payload.failCount > 0 {
        return true
    }
    if strict && payload.warnCount > 0 {
        return true
    }
    return false
}

func lspDoctorCheck(isDotnetWorkspace: Bool, csharpLSAvailable: Bool) -> DoctorCheck {
    if !isDotnetWorkspace {
        return DoctorCheck(name: "lsp", status: .pass, message: "Workspace is not .NET; LSP readiness check skipped.")
    }

    if csharpLSAvailable {
        return DoctorCheck(name: "lsp", status: .pass, message: "Detected .NET workspace and csharp-ls is available.")
    }

    return DoctorCheck(name: "lsp", status: .warn, message: "Detected .NET workspace but csharp-ls is not in PATH.")
}

func buildDoctorPayload(
    workspaceRoot: String,
    runtimeConfig: RuntimeConfig,
    cliMCPConfig: MCPClient.ServerConfig?,
    commandAvailable: (String) -> Bool = isCommandAvailable
) -> DoctorPayload {
    var checks: [DoctorCheck] = []
    let fileManager = FileManager.default

    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: workspaceRoot, isDirectory: &isDirectory), isDirectory.boolValue {
        checks.append(DoctorCheck(name: "workspace", status: .pass, message: "Workspace root exists."))
    } else {
        checks.append(DoctorCheck(name: "workspace", status: .fail, message: "Workspace root does not exist or is not a directory."))
    }

    let userConfigPath = fileManager.homeDirectoryForCurrentUser.path + "/.mlx-coder/config.json"
    let workspaceConfigPath = workspaceRoot + "/.mlx-coder-config.json"
    let userExists = fileManager.fileExists(atPath: userConfigPath)
    let workspaceExists = fileManager.fileExists(atPath: workspaceConfigPath)
    if userExists || workspaceExists {
        checks.append(
            DoctorCheck(
                name: "runtime-config",
                status: .pass,
                message: "Loaded merged config from \(userExists ? "user" : "")\(userExists && workspaceExists ? " + " : "")\(workspaceExists ? "workspace" : "") files."
            )
        )
    } else {
        checks.append(DoctorCheck(name: "runtime-config", status: .warn, message: "No runtime config files found (using built-in defaults)."))
    }

    let ignorePath = workspaceRoot + "/.mlx-coder-ignore"
    if fileManager.fileExists(atPath: ignorePath) {
        if let text = try? String(contentsOfFile: ignorePath, encoding: .utf8) {
            let patterns = text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .filter { !$0.hasPrefix("#") }

            if patterns.isEmpty {
                checks.append(DoctorCheck(name: "ignore", status: .warn, message: ".mlx-coder-ignore exists but has no active patterns."))
            } else {
                checks.append(DoctorCheck(name: "ignore", status: .pass, message: "Loaded \(patterns.count) ignore pattern(s)."))
            }
        } else {
            checks.append(DoctorCheck(name: "ignore", status: .fail, message: "Failed to read .mlx-coder-ignore."))
        }
    } else {
        checks.append(DoctorCheck(name: "ignore", status: .warn, message: "No .mlx-coder-ignore file found."))
    }

    let discoveredSkills = discoverSkillFiles(workspaceRoot: workspaceRoot)
    if discoveredSkills.isEmpty {
        checks.append(DoctorCheck(name: "skills", status: .warn, message: "No workspace skills discovered under .github/skills or skills."))
    } else {
        checks.append(DoctorCheck(name: "skills", status: .pass, message: "Discovered \(discoveredSkills.count) skill definition file(s)."))
    }

    let configuredPolicyPath = runtimeConfig.defaultPolicyFile.map { resolveDoctorPath($0, workspaceRoot: workspaceRoot) }
        ?? (workspaceRoot + "/.mlx-coder-policy.json")
    if fileManager.fileExists(atPath: configuredPolicyPath) {
        do {
            let data = try Data(contentsOf: URL(filePath: configuredPolicyPath))
            _ = try JSONDecoder().decode(PermissionEngine.PolicyDocument.self, from: data)
            checks.append(DoctorCheck(name: "policy", status: .pass, message: "Policy file is valid JSON and decodes correctly."))
        } catch {
            checks.append(DoctorCheck(name: "policy", status: .fail, message: "Policy file is invalid: \(error.localizedDescription)"))
        }
    } else {
        checks.append(DoctorCheck(name: "policy", status: .warn, message: "No policy file found at \(configuredPolicyPath)."))
    }

    let configuredAuditPath = runtimeConfig.defaultAuditLogPath
        .map { resolveDoctorPath($0, workspaceRoot: workspaceRoot) }
        ?? (FileManager.default.homeDirectoryForCurrentUser.path + "/.mlx-coder/audit.log.jsonl")
    let auditDir = (configuredAuditPath as NSString).deletingLastPathComponent
    var auditDirIsDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: auditDir, isDirectory: &auditDirIsDirectory) {
        if auditDirIsDirectory.boolValue {
            checks.append(DoctorCheck(name: "audit-log", status: .pass, message: "Audit log directory is present (\(auditDir))."))
        } else {
            checks.append(DoctorCheck(name: "audit-log", status: .fail, message: "Audit log parent path exists but is not a directory: \(auditDir)."))
        }
    } else {
        checks.append(DoctorCheck(name: "audit-log", status: .warn, message: "Audit log directory is missing: \(auditDir)."))
    }

    let runtimeMCPConfigs = runtimeMCPServerConfigs(from: runtimeConfig)
    let allMCPConfigs = mergedMCPConfigs(runtimeConfigs: runtimeMCPConfigs, cliConfig: cliMCPConfig)
    if allMCPConfigs.isEmpty {
        checks.append(DoctorCheck(name: "mcp", status: .warn, message: "No MCP servers configured."))
    } else {
        var invalidEndpoints: [String] = []
        for config in allMCPConfigs {
            if let endpoint = config.endpointURL, !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let url = URL(string: endpoint), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                    invalidEndpoints.append("\(config.name): invalid endpoint '\(endpoint)'")
                    continue
                }
            } else {
                let command = config.command.trimmingCharacters(in: .whitespacesAndNewlines)
                if command.isEmpty {
                    invalidEndpoints.append("\(config.name): missing endpoint/command")
                    continue
                }

                if !commandAvailable(command) {
                    invalidEndpoints.append("\(config.name): command not found '\(command)'")
                    continue
                }
            }

            if config.timeoutSeconds < 1 {
                invalidEndpoints.append("\(config.name): timeout must be >= 1")
            }
        }

        if invalidEndpoints.isEmpty {
            checks.append(DoctorCheck(name: "mcp", status: .pass, message: "Validated \(allMCPConfigs.count) MCP configuration(s)."))
        } else {
            checks.append(DoctorCheck(name: "mcp", status: .fail, message: invalidEndpoints.joined(separator: " | ")))
        }
    }

    let passCount = checks.filter { $0.status == .pass }.count
    let warnCount = checks.filter { $0.status == .warn }.count
    let failCount = checks.filter { $0.status == .fail }.count
    return DoctorPayload(
        workspace: workspaceRoot,
        checks: checks,
        passCount: passCount,
        warnCount: warnCount,
        failCount: failCount
    )
}

private func resolveDoctorPath(_ value: String, workspaceRoot: String) -> String {
    let expanded = NSString(string: value).expandingTildeInPath
    if expanded.hasPrefix("/") {
        return expanded
    }
    return workspaceRoot + "/" + expanded
}
