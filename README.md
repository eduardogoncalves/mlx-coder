# mlx-coder

A Swift terminal agent for Apple Silicon that loads LLMs **in-process** via [MLX-Swift](https://github.com/ml-explore/mlx-swift) — no HTTP server, no external API calls for local models.

mlx-coder is built to run local LLM workflows on macOS with a native MLX app architecture that minimizes runtime overhead. In many common setups, teams run both a separate inference API process (for example llama.cpp or LM Studio) and a separate Node.js agent process; mlx-coder keeps inference and agent orchestration in one process so more memory remains available for model weights and longer context windows. Remote OpenAI-compatible providers (OpenRouter, LM Studio, vLLM, mlx-lm.server, …) are also supported and can be mixed with local models in the same session.

## Why mlx-coder (Compared to Typical Hosted Coding Agents)

- **Local-first, in-process inference**: runs model execution directly in the app process via MLX instead of relying on a separate model service.
- **Smaller local AI runtime footprint**: by avoiding an always-on external inference server and extra API/network layers, more system memory remains available for the model weights and larger context windows.
- **Provider-agnostic remote models**: connect any OpenAI-compatible endpoint (OpenRouter, LM Studio, vLLM, …) alongside local models; switch with `/model` during a session.
- **Persistent KV (prompt) cache**: cross-turn KV cache reuse avoids re-prefilling the full prompt on every turn, cutting latency on long conversations.
- **Built-in sandbox + policy + approvals**: combines macOS seatbelt sandboxing, approval modes, and per-tool/per-path policy controls.
- **Audited tool lifecycle**: emits permission, pre-tool, post-tool, compression, steering-injection, follow-up, and context-transform events with audit-log visibility.
- **Delegated task isolation**: supports specialist task profiles, isolated work directories, cleanup controls, and strict delegated-input validation.
- **Operational diagnostics**: includes `doctor` and `list-tools --strict` for CI-friendly readiness checks.
- **Integrated tool transports**: supports MCP over HTTP and command-based stdio, plus built-in LSP tools including safe apply-mode rename flows.
- **Agent memory**: SQLite-backed knowledge store persists facts, plans, and decisions across sessions and injects them deterministically at session start.

## Requirements

- **macOS 15+** (Sequoia or later)
- **Apple Silicon** (M1 or later)
- **Swift 6.3.1** / Xcode 16.4+
- A local MLX model or a configured remote provider (default local model: `mlx-community/Qwen3.5-9B-5bit` — downloaded automatically from Hugging Face Hub on first use)

## Install

The simplest, trust-warning-free way to install on macOS is Homebrew — a
`brew`-installed CLI is not quarantined, so Gatekeeper stays out of the way:

```bash
brew install eduardogoncalves/tap/mlx-coder
mlx-coder --version
```

Prefer building it yourself, or downloading a `.pkg`/`.tar.gz` from
[Releases](https://github.com/eduardogoncalves/mlx-coder/releases)? See the
[Installation Guide](INSTALL.md) — note that direct downloads need a one-time
`xattr -d com.apple.quarantine` step because the artifacts are not yet
Apple-signed/notarized.

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
scripts/release.sh -b
```

Alternatively, build directly with xcodebuild:

```bash
xcodebuild -scheme MLXCoder -configuration Release -destination 'platform=macOS' -derivedDataPath .build/xcode
```

> **⚠️ Important:** You must use `xcodebuild` instead of `swift build`. MLX-Swift depends on Metal shader compilation (`.metallib` files) which only Xcode's build system handles correctly. Using `swift build` will produce a binary that crashes at runtime with `Failed to load the default metallib`.

The compiled binary will be located at:

```
.build/xcode/Build/Products/Release/MLXCoder
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

> **Tip:** If you prefer a user-local install without `sudo`, you can copy to `~/.local/bin/` instead (make sure it is in your `PATH`):
>
> ```bash
> mkdir -p ~/.local/bin
> cp .build/xcode/Build/Products/Release/MLXCoder ~/.local/bin/mlx-coder
> cp -R .build/xcode/Build/Products/Release/mlx-swift_Cmlx.bundle ~/.local/bin/
> ```

## Updating

Check for a newer release and optionally install it in one step:

```bash
mlx-coder update
```

Options:

```bash
mlx-coder update --check           # check for updates without downloading
mlx-coder update --yes             # skip the confirmation prompt
mlx-coder update --json            # machine-readable output
```

## Usage

mlx-coder provides seven subcommands: **chat** (interactive REPL), **run** (single prompt), **list-tools** (tool discovery), **show-audit** (audit log inspection), **show-config** (merged runtime settings), **doctor** (environment and configuration checks), and **update** (self-update).

### Interactive Chat

Start an interactive session (opens the SwiftCoderTUI interface by default):

```bash
mlx-coder chat
```

The legacy line-based renderer is still available:

```bash
mlx-coder chat --ui legacy
```

With custom options:

```bash
mlx-coder chat \
  --model mlx-community/Qwen3.5-9B-5bit \
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

Dictate the prompt via microphone instead of typing:

```bash
mlx-coder run --voice
```

The `--voice` flag uses Apple's Speech Recognition framework (macOS only). The model loads after recording finishes, so you don't need to pre-type the prompt. Optional tuning flags apply to both `run` and `chat`:

| Flag | Default | Description |
| --- | --- | --- |
| `--voice-silence-timeout` | `2.0` | Seconds of silence before recording stops automatically |
| `--voice-locale` | device locale → en-US | BCP 47 locale tag for recognition, e.g. `fr-FR`, `ja-JP` |

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

Filter or exclude specific MCP servers:

```bash
mlx-coder list-tools --mcp-include docs,local-mcp
mlx-coder list-tools --mcp-exclude staging
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
| `--model` | `mlx-community/Qwen3.5-9B-5bit` | Local MLX model directory or Hub ID, or `<providerID>:<modelID>` for remote |
| `--draft-model` | auto (paired with default model) | Draft model for speculative decoding (MTP). Set to empty string to disable. |
| `--num-draft-tokens` | `2` | Tokens proposed per speculative decoding round |
| `--workspace` | `.` (current directory) | Workspace root for tool operations |
| `--max-tokens` | `4096` | Maximum tokens to generate per turn |
| `--temperature` | `0.6` | Sampling temperature |
| `--top-p` | `1.0` | Top-p (nucleus) sampling |
| `--kv-bits` | Auto (per chip profile) | KV cache quantization bits |
| `--kv-group-size` | Auto (per chip profile) | KV cache quantization group size |
| `--quantized-kv-start` | `0` | First transformer layer to apply KV quantization |
| `--turbo-quant-bits` | unset | TurboQuant KV cache compression bits (mutually exclusive with `--kv-bits`) |
| `--sandbox/--no-sandbox` | `--sandbox` | Enable/disable macOS seatbelt sandboxing |
| `--shadow-context/--no-shadow-context` | `--shadow-context` | Summarize large tool outputs before storing them in history |
| `--approval-mode` | `default` | Destructive tool approvals: `default`, `auto-edit`, `yolo` |
| `--dry-run` | `false` | Skip execution of destructive tools while showing intended actions |
| `--mode` | `plan` | Initial working mode: `plan` or `agent` |
| `--policy-file` | `.mlx-coder-policy.json` in workspace | Optional per-tool/per-path allow/deny policy document |
| `--audit-log-path` | `~/.mlx-coder/audit.log.jsonl` | Optional audit log file location |
| `--mcp-endpoint` | unset | Optional MCP HTTP JSON-RPC endpoint |
| `--mcp-name` | `remote` | MCP tool prefix namespace |
| `--mcp-timeout` | `30` | MCP request timeout in seconds |
| `--mcp-include` | unset | Comma-separated MCP server names to include (overrides config allow list) |
| `--mcp-exclude` | unset | Comma-separated MCP server names to exclude |
| `--verbose` | `false` | Show verbose output including thinking blocks |
| `--prompt-cache-stats` | `false` | Show per-turn KV cache reuse statistics |
| `--auto-save-history` | unset | Auto-save markdown transcript on exit |
| `--auto-save-history-json` | unset | Auto-save JSON transcript on exit |
| `--voice` | `false` | (`run` only) Record voice prompt via Speech Recognition instead of `--prompt` |
| `--voice-silence-timeout` | `2.0` | Seconds of silence before voice recording stops automatically |
| `--voice-locale` | device locale | BCP 47 locale tag for speech recognition, e.g. `en-US`, `fr-FR` |

### Sandbox default profile (balanced)

When sandbox mode is enabled, shell commands run with:

- default write deny (`deny file-write*`)
- explicit write allows for workspace, temp dirs, and common package/tool caches
- explicit device access for `/dev/null` and `/dev/tty` (required by git and many CLIs)
- network allowed by default (can be disabled via `SandboxEngine(networkPolicy: .deny)`)

Common cache/tool paths covered include NuGet, npm/pnpm/yarn, cargo, Maven/Gradle, Go module/bin dirs, SwiftPM, and Python pip/uv caches.

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
- `/model` opens the model chooser (local and remote); `/model <name|id|#>` switches directly
- `/model free` shows only free OpenRouter models in the picker; `/model all` clears the filter
- `/effort [level]` sets the reasoning (thinking) level: `off`, `minimal`, `low`, `medium`, `high`
- `/login` adds or updates a remote provider in `~/.mlx-coder/config.json` via a multi-step wizard
- `/logout [id]` removes a configured remote provider
- `/memory` opens the memory subsystem (see [Agent Memory](#agent-memory))
- `/caffeinate [on|off|busy|<duration>]` prevents the system from sleeping (e.g. `/caffeinate 2h`)
- `/steer [msg]` queues a steering message to be injected before the next generation round; `/steer` alone lists queued messages
- `/followup [msg]` queues a follow-up prompt for after the current turn completes
- `! <cmd>` runs a shell command and adds output to the transcript/context
- `!! <cmd>` runs a shell command without adding output to the transcript

### Voice Input (macOS only)

mlx-coder includes speech-to-text dictation powered by Apple's `SFSpeechRecognizer` framework. Two activation paths are available inside `chat`:

- **`/voice`** — starts recording immediately and sends the transcription directly to the agent on Enter or after the configured silence timeout.
- **`Ctrl+V`** — records and inserts the transcription into the input box so you can review and edit it before pressing Enter.

Both paths stream live partial transcriptions to the terminal while recording. Recording stops on:
- The silence timeout (default 2 s, configurable with `--voice-silence-timeout`)
- The user pressing **Enter**
- **Ctrl-C** / **Ctrl-D**

On first use, macOS will display a system permission dialog for **Speech Recognition** and **Microphone** access. These permissions are granted to the host terminal application. You can check and reset the authorization status at any time with:

```bash
mlx-coder doctor
```

The `doctor` command reports a `voice` check showing whether Speech Recognition is authorized, not yet prompted, or denied.

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

JSON transcripts are exported as a versioned envelope (`version` + `messages`) and remain backward-compatible when loading older array-only transcripts.

## Remote Models

mlx-coder supports any OpenAI-compatible inference endpoint alongside local MLX models. Examples: OpenRouter, LM Studio, vLLM, mlx-lm.server, or an internal gateway.

### Configuring providers

Providers are stored in `~/.mlx-coder/config.json` under a `providers` array. This file is created automatically on first run with a commented-out sample. Edit it manually or use `/login` inside a `chat` session:

```json
{
  "providers": [
    {
      "name": "OpenRouter",
      "baseURL": "https://openrouter.ai/api/v1",
      "apiKey": "sk-or-your-key-here"
    },
    {
      "name": "LM Studio",
      "baseURL": "http://127.0.0.1:1234/v1"
    }
  ]
}
```

`apiKey` is optional — omit it for keyless local servers. The `name` field is slugified into a stable `id` (e.g. `"LM Studio"` → `lm-studio`) used in model carrier strings and cache paths.

The file is JSONC-compatible: `//` line comments and `/* */` block comments are stripped before parsing.

### Using a remote model

Pass a `<providerID>:<modelID>` carrier to `--model`:

```bash
mlx-coder chat --model openrouter:qwen/qwen3-235b
mlx-coder run --model lm-studio:lmstudio-community/Qwen2.5-7B-Instruct-GGUF --prompt "Hello"
```

Or switch interactively with `/model` inside a session:

```bash
/model              # open the local / remote chooser
/model remote       # browse providers
/model remote openrouter          # list cached OpenRouter models
/model remote openrouter refresh  # fetch the latest model list from the API
```

### Managing providers interactively

```bash
/login              # multi-step wizard: name → URL → API key
/logout             # opens a picker to choose a provider to remove
/logout openrouter  # remove directly by id
```

## Prompt Caching

mlx-coder maintains a persistent KV cache across turns. On each turn the prompt token sequence is diffed against the previous turn's cached tokens; the matching prefix is reused and only the new suffix is prefilled. This eliminates most redundant prefill work on long conversations.

To monitor cache effectiveness, pass `--prompt-cache-stats`:

```bash
mlx-coder chat --prompt-cache-stats
```

Each turn will display a cache indicator showing the number of tokens reused versus freshly prefilled.

The cache is invalidated automatically when the model is switched, the conversation is cleared, or the token sequence diverges beyond recovery. Mamba hybrid models are also supported via a checkpoint-based fallback that sidesteps the non-trimmable KV state constraint.

## Agent Memory

mlx-coder includes a SQLite-backed knowledge store (`~/.mlx-coder/knowledge.db`) that persists facts, plans, decisions, patterns, and gotchas across sessions. At session start, the most relevant entries are injected into the system prompt so the agent can resume without losing context.

### Entry types

| Type | Description | TTL |
| --- | --- | --- |
| `session_state` | In-progress work, current focus | 48 h |
| `plan` | Multi-step plans and roadmaps | permanent |
| `decision` | Architecture or approach decisions | permanent |
| `gotcha` | Pitfalls and non-obvious constraints | permanent |
| `pattern` | Recurring code patterns or conventions | permanent |

### Restore algorithm

On startup the retriever fills up to a ~2000-token budget across five tiers:
1. `session_state` entries from the last 48 h (surface-match preferred)
2. `plan` entries (up to 2)
3. `decision` entries (up to 3)
4. `gotcha` + `pattern` entries (up to 4 combined)
5. Cross-project entries from other workspace roots (up to 2)

Within each tier, entries are ranked by surface match → branch match → recency → id.

### LLM tools

The agent can manage the knowledge store autonomously:

- `log_knowledge` — add, update, or remove an entry (actions: `add`, `update`, `remove`)
- `search_knowledge` — full-text and tag search across stored entries

### `/memory` commands

Inside `mlx-coder chat` you can inspect and edit memory directly:

```
/memory             open the memory command palette
/memory save        persist the current session state
/memory log         log a new entry (opens an inline form)
/memory search      search entries by keyword or tag
/memory list        list all entries
/memory status      show database stats and storage path
/memory snippet     generate a snippet from current context
/memory undo        delete the last logged entry
/memory remove      remove a specific entry by id
/memory edit        edit an existing entry's content
```

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

## Workspace Environment Variables

Project-scoped environment variables can be declared in a dotenv-style file at the workspace root: `.mlx-coder.env`. They are loaded automatically every time the agent starts in the project, exported to the agent process, and injected into every `bash` tool subprocess.

```bash
# .mlx-coder.env
DOTNET_CLI_HOME=.dotnet
NUGET_PACKAGES=packages/nuget
PATH=/Users/me/.dotnet/tools
```

Rules:

- `KEY=VALUE` lines, `#` comments, optional `export ` prefix, and optional quotes around values.
- Loader/shell-behavior variables (`DYLD_*`, `LD_*`, `IFS`, `PS4`, `ENV`, `BASH_ENV`, `ZDOTDIR`, `SHELLOPTS`, `PROMPT_COMMAND`) are ignored for safety.
- `PATH` entries are appended after the secure base PATH, never replace it.
- With the sandbox enabled, `DOTNET_CLI_HOME` defaults to `<workspace>/.dotnet` (the Seatbelt profile blocks dotnet's home-directory detection); set it in `.mlx-coder.env` to override.

## Runtime Config Hierarchy

mlx-coder loads runtime defaults from:

- User config: `~/.mlx-coder/config.json`
- Workspace config: `.mlx-coder-config.json`

Workspace values override user values by key; MCP servers merge by `name`; approval mode and sandbox flags always pick the **more restrictive** of the two. The user config also stores `providers` (remote model endpoints) in the same file.

Example `~/.mlx-coder/config.json`:

```json
{
  "providers": [
    {
      "name": "OpenRouter",
      "baseURL": "https://openrouter.ai/api/v1",
      "apiKey": "sk-or-your-key-here"
    }
  ],
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

mlx-coder registers **28 tools** that the LLM can invoke autonomously:

| Category | Tools |
| --- | --- |
| Filesystem | `read_file`, `read_many`, `write_file`, `edit_file`, `append_file`, `patch`, `list_dir` |
| Planning | `plan_file` |
| Search | `glob`, `grep`, `code_search` |
| Shell | `bash` |
| Agents | `task`, `todo` |
| Skills | `read_skill` |
| Web | `web_fetch`, `web_search` |
| Memory | `log_knowledge`, `search_knowledge` |
| LoRA | `project_expert_lora` |
| LSP (.NET) | `lsp_diagnostics`, `lsp_hover`, `lsp_references`, `lsp_definition`, `lsp_completion`, `lsp_signature_help`, `lsp_document_symbols`, `lsp_rename` (`apply=true` writes edits) |

All filesystem operations are constrained to `--workspace`, and shell behavior is governed by sandbox + approval + policy settings.

`web_fetch` supports paginated reading via an `offset` parameter — when a page exceeds the output limit, the result includes a continuation marker with the next offset to pass on the following call. Continuation reads are served from an in-process disk cache, so the page is only fetched once.

### Task Tool Profiles

The `task` tool supports specialist profiles via the optional `profile` argument:

- `general` (default)
- `codebase_research`
- `test_engineering`
- `security_review`
- `docs`

This helps delegated sub-agents adopt purpose-specific behavior while retaining isolated context and depth limits.

Sub-agents share the orchestrator's own workspace by default — including its active git worktree, if the
orchestrator switched into one — rather than a synthetic sandbox directory. The `task` tool also supports
optional scoping to a specific subdirectory of that workspace:

- `isolate: true` + `isolation_directory: "relative/path"` scopes the sub-agent to that specific
  workspace-relative directory instead of the full workspace
- `isolation_directory` requires `isolate: true`; when provided it must be non-empty (whitespace-only
  values are rejected)
- `isolate: true` alone (no `isolation_directory`) has no effect — sub-agents already share the
  orchestrator's real workspace, so there is nothing to isolate to

When scoped to a subdirectory, unknown dynamic tools are rejected unless they can be rebuilt with the
scoped permissions.

Additional delegated input validation:

- `tools` must contain at least one entry
- `tools` is capped at 32 delegated tool names
- `tools` cannot include `task` (sub-agent depth is capped at 1)
- tool-name deduplication is case-insensitive while preserving provided names for delegation compatibility
- `description` is trimmed, must be non-empty, and is capped to 4000 characters
- optional arguments are type-checked (`profile` string, `isolate` boolean, `isolation_directory` string)

### Code Mode (`execute_code`)

Sub-agents with the `executor` or `general` profile (or any profile explicitly given `execute_code` in its
`tools` list) can also call `execute_code` instead of emitting tool calls one at a time. It runs a model-written JavaScript program — with the sub-agent's own other tools exposed as
`await tools.<name>({...})` — in an isolated `CodeModeWorker` subprocess (no filesystem/network access of
its own). Every `tools.*` call the script makes is proxied back and dispatched through the exact same
permission/approval/watchdog/audit pipeline a direct tool call gets, so a script cannot use code mode to
bypass an approval prompt or a permission denial; a denied or failed call surfaces as a thrown JavaScript
exception. This is useful for batch/looping work (e.g. "read every file matching X and report which ones
fail to parse") that would otherwise cost one model round trip per tool call. `execute_code` is never
available to the top-level orchestrator and can never call itself.

### Tool Call Dialects

mlx-coder auto-detects the tool call format from the model path:

- **Qwen** (default): XML-style `<tool_call>…</tool_call>` blocks
- **LFM2** (Liquid AI): Python-style `<|tool_call_start|>[name(arg='value')]<|tool_call_end|>` blocks

Detection is based on the model path or Hub ID. The correct dialect is selected automatically; no configuration is required.

## License

See [LICENSE](LICENSE) for details.
