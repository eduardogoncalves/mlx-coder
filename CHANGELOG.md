# Changelog

All notable changes to mlx-coder are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-03-30

### ✅ Initial Public Release

### Added
- Swift terminal agent for Apple Silicon with in-process MLX model execution.
- Interactive REPL (`chat`) and one-shot prompt mode (`run`).
- Built-in tooling for filesystem, search, shell, web, and delegated task workflows.
- LSP integration for .NET workspaces, including diagnostics, hover/references/definition, completion, symbols, signature help, and rename support.
- Runtime diagnostics and discovery commands (`doctor`, `list-tools`, `show-config`, `show-audit`).
- Workspace and user runtime config loading with MCP server support for HTTP and command-based stdio transports.
- Hook lifecycle support with audit-backed hook events.
- Task delegation profiles with optional isolated execution directories and cleanup controls.
- Conversation history export/import for Markdown and JSON transcript formats.

### Security
- Security hardening fixes across path validation, symlink handling, environment inheritance, strict JSON parsing, glob matching, and error sanitization.
- Seatbelt sandbox integration and approval/policy controls for tool execution.