// Sources/MLXCoder/MLXCoderCLI.swift
// Entry point for the mlx-coder terminal agent.
//
// This file defines the CLI entry point and shared argument types.
// Subcommands and helpers are decomposed across:
//   - ChatCommand.swift          — Interactive REPL
//   - RunCommand.swift           — Single-prompt mode
//   - ListToolsCommand.swift     — Tool listing + payload types
//   - ShowAuditCommand.swift     — Audit log viewer
//   - ShowConfigCommand.swift    — Config viewer
//   - DoctorCommand.swift        — Workspace diagnostics + types
//   - FoundationModelFallback.swift — Apple Foundation model integration
//   - ModelSelectionHelpers.swift — Model discovery, download, loading
//   - CLIConfigHelpers.swift     — Permissions, MCP, policy helpers
//   - ToolRegistration.swift     — Built-in tool registration

import ArgumentParser
import Foundation

@main
struct MLXCoderCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mlx-coder",
        abstract: "Swift terminal agent for Apple Silicon — loads LLM in-process via MLX-Swift",
        version: "0.1.0.202604091520",
        subcommands: [ChatCommand.self, RunCommand.self, ListToolsCommand.self, ShowAuditCommand.self, ShowConfigCommand.self, DoctorCommand.self],
        defaultSubcommand: ChatCommand.self
    )

    @OptionGroup var testAbsorber: TestAbsorber
}

// MARK: - Test flags absorber

struct TestAbsorber: ParsableArguments, Sendable {
    // Silently absorb flags that the XCTest harness passes when it
    // re-invokes the binary after running tests.  Without this, ArgumentParser
    // exits with code 1 and `swift test` reports failure even if all tests pass.
    
    @Option(name: .customLong("test-bundle-path"), help: .hidden)
    var testBundlePath: String?

    @Option(name: .customLong("configuration"), help: .hidden)
    var testConfiguration: String?

    @Option(name: .customLong("testing-library"), help: .hidden)
    var testLibrary: String?

    var isTestInvocation: Bool {
        testBundlePath != nil || testConfiguration != nil || testLibrary != nil
    }
}

// MARK: - Shared model arguments

struct ModelArguments: ParsableArguments, Sendable {
    @Option(name: .long, help: "Path to the model directory")
    var model: String = "~/models/Qwen/Qwen3.5-9B-4bit"

    @Option(name: .long, help: "Workspace root directory for tool operations")
    var workspace: String = "."

    @Option(name: .long, help: "Maximum number of tokens to generate per turn")
    var maxTokens: Int = 4096

    @Option(name: .long, help: "Sampling temperature")
    var temperature: Float = 0.6

    @Option(name: .long, help: "Top-p sampling")
    var topP: Float = 1.0

    @Option(name: .long, help: "KV cache quantization bits (nil = no quantization)")
    var kvBits: Int?

    @Option(name: .long, help: "KV cache quantization group size (default: chip profile value, typically 64)")
    var kvGroupSize: Int?

    @Option(name: .long, help: "First transformer layer to apply KV cache quantization (0 = all layers)")
    var quantizedKVStart: Int?

    @Option(name: .long, help: "Enable TurboQuant KV cache compression. Specify bits per element (e.g. 3). Mutually exclusive with --kv-bits.")
    var turboQuantBits: Int?

    @Flag(name: .long, inversion: .prefixedNo, help: "Enable macOS seatbelt sandboxing for shell commands")
    var sandbox: Bool = true

    @Option(name: .long, help: "Approval mode for destructive tools: default, auto-edit, yolo")
    var approvalMode: String = "default"

    @Option(name: .long, help: "Optional audit log file path for tool decisions/executions (default: ~/.mlx-coder/audit.log.jsonl)")
    var auditLogPath: String?

    @Option(name: .long, help: "Optional JSON policy file for per-tool/per-path allow/deny rules")
    var policyFile: String?

    @Flag(name: .long, help: "Enable dry-run mode for destructive tools (write/edit/patch/bash/task).")
    var dryRun: Bool = false

    @Option(name: .long, help: "Optional path to auto-save markdown history when chat exits")
    var autoSaveHistory: String?

    @Option(name: .long, help: "Optional path to auto-save JSON history when chat exits")
    var autoSaveHistoryJSON: String?

    @Option(name: .long, help: "Optional MCP server HTTP endpoint (JSON-RPC)")
    var mcpEndpoint: String?

    @Option(name: .long, help: "Logical MCP server name used in tool prefixes")
    var mcpName: String = "remote"

    @Option(name: .long, help: "MCP request timeout in seconds")
    var mcpTimeout: Int = 30

    @Option(name: .long, help: "Comma-separated MCP server names to include (overrides config allow list)")
    var mcpInclude: String?

    @Option(name: .long, help: "Comma-separated MCP server names to exclude (applied after include)")
    var mcpExclude: String?

    @Flag(name: .long, help: "Show verbose output including thinking blocks")
    var verbose: Bool = false

    @Option(name: .long, help: "Initial working mode (agent or plan)")
    var mode: String = "plan"

    @OptionGroup var testAbsorber: TestAbsorber
}
