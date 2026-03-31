# mlx-coder

A Swift terminal agent for Apple Silicon that loads LLMs **in-process** via [MLX-Swift](https://github.com/ml-explore/mlx-swift) — no HTTP server, no external API calls.

mlx-coder is built to run local LLM workflows on macOS with a native MLX app architecture that minimizes runtime overhead. In many common setups, teams run both a separate inference API process (for example llama.cpp or LM Studio) and a separate Node.js agent process; mlx-coder keeps inference and agent orchestration in one process so more memory remains available for model weights and longer context windows.

## Why mlx-coder (Compared to Typical Hosted Coding Agents)

- **Local-first, in-process inference**: runs model execution directly in the app process via MLX instead of relying on a separate model service.
- **Smaller local AI runtime footprint**: by avoiding an always-on external inference server and extra API/network layers, more system memory remains available for the model weights and larger context windows.
- **Built-in sandbox + policy + approvals**: combines macOS seatbelt sandboxing, approval modes, and per-tool/per-path policy controls.
- **Audited tool lifecycle**: emits permission, pre-tool, post-tool, and compression events with audit-log visibility.
- **Delegated task isolation**: supports specialist task profiles, isolated work directories, cleanup controls, and strict delegated-input validation.
- **Operational diagnostics**: includes `doctor` and `list-tools --strict` for CI-friendly readiness checks.
- **Integrated tool transports**: supports MCP over HTTP and command-based stdio, plus built-in LSP tools including safe apply-mode rename flows.

## Requirements

- **macOS 14+** (Sonoma or later)
- **Apple Silicon** (M1 or later)
- **Swift 5.12+** / Xcode 16+
- A local MLX model directory (default: `~/models/Qwen/Qwen3.5-9B-4bit`)

## Building

Related docs:

- [Installation Guide](INSTALL.md)
- [Quick Start](docs/QUICK-START.md)
- [Release Build Guide](docs/RELEASE-BUILD-GUIDE.md)
- [GitHub Actions Guide](docs/GITHUB-ACTIONS-GUIDE.md)

Clone the repository and build the release binary:

```bash
git clone https://github.com/your-user/mlx-coder.git
cd mlx-coder
xcodebuild -scheme MLXCoder -configuration Release -destination 'platform=macOS' -derivedDataPath .build/xcode
```

> **⚠️ Important:** You must use `xcodebuild` instead of `swift build`. MLX-Swift depends on Metal shader compilation (`.metallib` files) which only Xcode's build system handles correctly. Using `swift build` will produce a binary that crashes at runtime with `Failed to load the default metallib`.

The compiled binary will be located at:

```
.build/xcode/Build/Products/Release/NativeAgent
```

> **Note:** The first build may take several minutes while Xcode fetches and compiles the dependencies (MLX, MLXLLM, ArgumentParser, Yams).

## Installing the Binary System-Wide

Copy the built binary **and its Metal shader bundle** to a directory in your `PATH`:

```bash
sudo cp .build/xcode/Build/Products/Release/MLXCoder /usr/local/bin/mlx-coder
sudo cp -R .build/xcode/Build/Products/Release/mlx-swift_Cmlx.bundle /usr/local/bin/
```

> **⚠️ Important:** The `mlx-swift_Cmlx.bundle` must live in the **same directory** as the binary. It contains the compiled Metal shaders (`default.metallib`) that MLX needs at runtime.

Verify the installation:

```bash
mlx-coder --version
```

You should see `0.1.0` printed to the terminal.

> **Tip:** If you prefer a user-local install without `sudo`, you can copy to `~/.local/bin/` instead (make sure it is in your `PATH`):
>
> ```bash
> mkdir -p ~/.local/bin
> cp .build/xcode/Build/Products/Release/MLXCoder ~/.local/bin/mlx-coder
> cp -R .build/xcode/Build/Products/Release/mlx-swift_Cmlx.bundle ~/.local/bin/
> ```

## Usage

mlx-coder provides six subcommands: **chat** (interactive REPL), **run** (single prompt), **list-tools** (tool discovery), **show-audit** (audit log inspection), **show-config** (merged runtime settings), and **doctor** (environment and configuration checks).

### Interactive Chat

Start an interactive session:

```bash
mlx-coder chat
```

With custom options:

```bash
mlx-coder chat \
  --model ~/models/Qwen/Qwen3.5-9B-4bit \
  --workspace ~/my-project \
  --max-tokens 8192 \
  --temperature 0.7 \
  --verbose
```

Type `exit` or `quit` to end the session.

### Single Prompt

Run a one-shot prompt and exit:

```bash
mlx-coder run --prompt "Explain the main function in src/app.swift"
```

### Tool Discovery

List built-in tools without loading a model:

```bash
mlx-coder list-tools
```

Machine-readable output:

```bash
mlx-coder list-tools --json
```

CI-friendly strict mode (non-zero exit if MCP discovery fails):

```bash
mlx-coder list-tools --strict --json
```

`list-tools` now includes discovered skills metadata and explicit `task` capabilities (supported profiles and isolation options).

### Audit Log Inspection

Show the latest audit events:

```bash
mlx-coder show-audit --tail 100
```

### Config Inspection

Show the merged runtime config (user + workspace):

```bash
mlx-coder show-config --json
```

### Environment Checks

Run diagnostics for workspace readiness, runtime config, policy, ignore file, workspace skills discovery, and MCP endpoint configuration:

```bash
mlx-coder doctor
```

Machine-readable report:

```bash
mlx-coder doctor --json
```

`doctor` also reports LSP readiness: whether the workspace is .NET and whether `csharp-ls` is available on `PATH`.

For command-based MCP servers, `doctor` validates that the configured executable is available (absolute path executable or discoverable on `PATH`).

Use `--strict` to return a non-zero exit code for warnings (useful in CI):

```bash
mlx-coder doctor --strict --json
```

### Options Reference

| Option | Default | Description |
| --- | --- | --- |
| `--model` | `~/models/Qwen/Qwen3.5-9B-4bit` | Path to the local MLX model directory |
| `--workspace` | `.` (current directory) | Workspace root for tool operations |
| `--max-tokens` | `4096` | Maximum tokens to generate per turn |
| `--temperature` | `0.6` | Sampling temperature |
| `--top-p` | `1.0` | Top-p (nucleus) sampling |
| `--kv-bits` | Auto (per chip profile) | KV cache quantization bits |
| `--sandbox/--no-sandbox` | `--sandbox` | Enable/disable macOS seatbelt sandboxing |
| `--approval-mode` | `default` | Destructive tool approvals: `default`, `auto-edit`, `yolo` |
| `--dry-run` | `false` | Skip execution of destructive tools while showing intended actions |
| `--policy-file` | `.mlx-coder-policy.json` in workspace | Optional per-tool/per-path allow/deny policy document |
| `--audit-log-path` | `~/.mlx-coder/audit.log.jsonl` | Optional audit log file location |
| `--mcp-endpoint` | unset | Optional MCP HTTP JSON-RPC endpoint |
| `--mcp-name` | `remote` | MCP tool prefix namespace |
| `--mcp-timeout` | `30` | MCP request timeout in seconds |
| `--verbose` | `false` | Show verbose output including thinking blocks |

## Interactive Commands

Inside `mlx-coder chat`, these session commands are available:

- `/clear` clears conversation history and KV cache
- `/undo` or `/revert` removes the last conversation turn
- `/context` prints estimated context token usage by role
- `/skills` lists discovered skills metadata from workspace skill directories
- `/hooks` lists active hook pipeline entries
- `/save-history [path]` exports the current transcript to Markdown (default: `session-history.md`)
- `/save-history-json [path]` exports a resumable JSON transcript (default: `session-history.json`)
- `/load-history-json [path]` loads a JSON transcript into the current session
- `/plan` and `/agent` switch working modes
- `/sandbox` toggles sandbox mode for shell tools

### Run Mode Exports

For one-shot execution, you can persist transcripts directly from `run`:

```bash
mlx-coder run \
  --prompt "Summarize this repository" \
  --save-history run-history.md \
  --save-history-json run-history.json
```

For interactive sessions, you can auto-save on exit:

```bash
mlx-coder chat \
  --auto-save-history session-final.md \
  --auto-save-history-json session-final.json
```

JSON transcripts are now exported as a versioned envelope (`version` + `messages`) and remain backward-compatible when loading older array-only transcripts.

## Permission Policy File

You can constrain tools with `.mlx-coder-policy.json` (or pass a custom file via `--policy-file`).

Example:

```json
{
  "rules": [
    {
      "effect": "deny",
      "tools": ["write_*", "patch"],
      "paths": ["/Users/me/project/secrets/*"],
      "reason": "Writes to secrets are blocked"
    },
    {
      "effect": "deny",
      "tools": ["bash"],
      "reason": "Shell commands are disabled in this workspace"
    }
  ]
}
```

## Runtime Config Hierarchy

mlx-coder now loads runtime defaults from:

- User config: `~/.mlx-coder/config.json`
- Workspace config: `.mlx-coder-config.json`

Workspace values override user values by key, and MCP servers override by `name`.

Example:

```json
{
  "defaultApprovalMode": "auto-edit",
  "defaultSandbox": true,
  "defaultDryRun": false,
  "defaultPolicyFile": ".mlx-coder-policy.json",
  "defaultAuditLogPath": ".mlx-coder/audit.log.jsonl",
  "mcpServers": [
    {
      "name": "docs",
      "endpoint": "http://127.0.0.1:8080",
      "timeoutSeconds": 20,
      "enabled": true
    },
    {
      "name": "local-mcp",
      "command": "npx",
      "arguments": ["-y", "@modelcontextprotocol/server-filesystem", "."],
      "environment": {
        "NODE_ENV": "production"
      },
      "timeoutSeconds": 30,
      "enabled": true
    }
  ]
}
```

`mcpServers` entries support either:

- `endpoint` for HTTP JSON-RPC MCP servers
- `command` (+ optional `arguments` and `environment`) for stdio MCP servers

## Ignore File

Search tools (`glob`, `grep`, `code_search`) honor `.mlx-coder-ignore` in the workspace root.

Example:

```text
# Ignore generated outputs
**/*.generated.swift
dist/*
vendor/*
```

## Built-in Tools

mlx-coder registers **14 tools** that the LLM can invoke autonomously:

| Category   | Tools                                                    |
| ---------- | -------------------------------------------------------- |
| Filesystem | `ReadFile`, `WriteFile`, `EditFile`, `Patch`, `ListDir`, `ReadMany` |
| Search     | `Glob`, `Grep`, `CodeSearch`                             |
| Shell      | `Bash`                                                   |
| Agents     | `Task`, `Todo`                                           |
| Web        | `WebFetch`, `WebSearch`                                  |
| LSP (.NET) | `LSPDiagnostics`, `LSPHover`, `LSPReferences`, `LSPDefinition`, `LSPCompletion`, `LSPSignatureHelp`, `LSPDocumentSymbols`, `LSPRename` (`apply=true` writes edits) |

All filesystem operations are constrained to `--workspace`, and shell behavior is governed by sandbox + approval + policy settings.

### Task Tool Profiles

The `task` tool supports specialist profiles via the optional `profile` argument:

- `general` (default)
- `codebase_research`
- `test_engineering`
- `security_review`
- `docs`

This helps delegated sub-agents adopt purpose-specific behavior while retaining isolated context and depth limits.

The `task` tool also supports optional execution isolation:

- `isolate: true` creates/uses an isolated sub-agent workspace directory
- `isolation_directory: "relative/path"` pins isolation to a specific workspace-relative directory
- `cleanup_isolation: true` removes auto-created isolation directories after completion

When isolation is enabled, unknown dynamic tools are rejected unless they can be rebuilt with isolated permissions.
For safety, `cleanup_isolation` is only allowed when `isolation_directory` is not explicitly provided.
`isolation_directory` requires `isolate: true`.
When provided, `isolation_directory` must be non-empty (whitespace-only values are rejected).

Additional delegated input validation:

- `tools` must contain at least one entry
- `tools` is capped at 32 delegated tool names
- `tools` cannot include `task` (sub-agent depth is capped at 1)
- tool-name deduplication is case-insensitive while preserving provided names for delegation compatibility
- `description` is trimmed, must be non-empty, and is capped to 4000 characters
- optional arguments are type-checked (`profile` string, `isolate` boolean, `isolation_directory` string, `cleanup_isolation` boolean)

## License

See [LICENSE](LICENSE) for details.
