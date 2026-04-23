# Memory Module — Deterministic State Recovery

The Memory module implements **Deterministic State Recovery** for mlx-coder, allowing the agent to persist and restore knowledge across sessions.

## Overview

When a session ends, is cleared (`/clear`), or context overflows, all relevant knowledge is persisted locally in a SQLite database. On the next session start, the agent automatically recovers its working state deterministically — same inputs always yield the same restored context.

## Architecture

### Data Model

**KnowledgeEntry** — The core data structure representing a single knowledge item:
- **type**: `session_state`, `plan`, `decision`, `gotcha`, or `pattern`
- **content**: The knowledge text (max 2000 chars for LLM tool)
- **tags**: Normalized (lowercase, sorted, deduplicated) tags for categorization
- **surface**: Inferred subsystem (e.g., "tests", "server", "ios")
- **branch**: Git branch at time of logging
- **projectRoot**: Absolute path for cross-project queries
- **createdAt / expiresAt**: Timestamps (session_state entries expire in 48h)

### Storage

**KnowledgeStore** — SQLite-backed persistent storage with:
- WAL mode for better concurrency
- FTS5 full-text search
- Automatic deduplication by content hash + type + project root
- Default location: `~/.mlx-coder/knowledge.db`

### Restore Algorithm

**KnowledgeRetriever** — 5-tier deterministic restore with token budget:

```
Token Budget: 2000 tokens (estimated as content.count / 4)

Tier 1 — session_state:  up to 4 (surface-match) + 2 (other), within 48h
Tier 2 — plan:           up to 2, all time
Tier 3 — decision:       up to 3, all time
Tier 4 — gotcha+pattern: up to 4 combined, all time
Tier 5 — cross-project:  up to 2 from OTHER project roots, all time
```

**Sorting within tiers:**
1. Surface match (current surface first)
2. Branch match (current branch first)
3. Recency (most recent first)
4. ID (tie-breaker for determinism)

Never truncates mid-entry — either includes fully or skips.

### Surface Detection

**SurfaceDetector** — Infers current "surface" from workspace paths:
- `Tests/` or `*.test.swift` → "tests"
- `Sources/Server` → "server"
- `Sources/iOS` → "ios"
- `docs/` → "docs"
- `scripts/` → "scripts"
- etc.

Also detects current git branch via `git rev-parse --abbrev-ref HEAD`.

## Integration Points

### Session Start

Memory restoration happens automatically at session start in `ChatCommand`:

```swift
let memorySection = await restoreMemorySection(workspaceRoot: absWorkspace, renderer: renderer)
let promptComposition = await AgentLoop.buildSystemPromptComposition(
    ...,
    memorySection: memorySection,
    ...
)
```

The restored context is injected into the system prompt as a structured markdown block.

### /clear Command

Before clearing conversation history, `AgentLoop.clearHistoryWithCheckpoint()` automatically:
1. Synthesizes a checkpoint from recent assistant messages
2. Stores it as a `sessionState` entry with 48h TTL
3. Clears history and KV cache

### Interactive Commands

| Command | Description |
|---------|-------------|
| `/memory save "<msg>"` | Save a session state checkpoint |
| `/memory log "<msg>" --type <type>` | Log typed knowledge (decision\|gotcha\|plan\|pattern) |
| `/memory search "<query>"` | FTS5 keyword search |
| `/memory list [--type <type>]` | Browse recent entries |
| `/memory undo` | Delete last entry |
| `/memory status` | Entry counts, DB size, last checkpoint age |
| `/memory snippet [--today\|--week]` | Generate work summary |

### LLM Tool: log_knowledge

The agent can proactively log important findings during a session:

```json
{
  "name": "log_knowledge",
  "arguments": {
    "type": "decision",
    "content": "Always use xcodebuild instead of swift build for this project",
    "tags": ["build", "xcode"]
  }
}
```

### Doctor Command

`mlx-coder doctor` includes a memory subsystem health check:

```
[PASS] memory: Memory store accessible: 42 entries, 0.12 MB
```

## Usage Examples

### Manual Checkpoint

```
/memory save "Implemented auth layer, next: add UI components"
```

### Log a Gotcha

```
/memory log "API requires X-Custom-Header, not Authorization" --type gotcha
```

### Search Past Knowledge

```
/memory search "authentication"
```

### Generate Work Summary

```
/memory snippet --today
```

Output:
```markdown
# Work Summary — mlx-coder

Generated: Apr 22, 2026

### Accomplished
- Implemented deterministic state recovery for mlx-coder
- Added SQLite-backed knowledge store with FTS5 search
- Integrated memory restoration at session start

### Decisions Made
- Use WAL mode for better SQLite concurrency
- Enforce 2000-token budget for restored context
- Auto-expire session_state entries after 48h

### Patterns Discovered
- Test files follow the pattern Foo.test.swift in Tests/
- Use snake_case for FTS5 table names

### Gotchas Logged
- SQLite3 import requires CSQLite module map on Linux
```

## Testing

Comprehensive test coverage in `Tests/MemoryTests/`:
- `KnowledgeStoreTests`: CRUD, deduplication, expiry, search
- `KnowledgeRetrieverTests`: Tier logic, token budget, deterministic ordering
- `SurfaceDetectorTests`: Path-based surface detection

Run tests:
```bash
swift test --filter MemoryTests
```

## Design Constraints

- **Zero new SPM dependencies** — Uses only system-linked SQLite3, Foundation, CryptoKit
- **No network calls** — Everything is local (`~/.mlx-coder/knowledge.db`)
- **Thread-safe** — WAL mode + Swift actor for concurrent access
- **Deterministic** — Same DB state + context always returns identical results
- **Token-aware** — Never exceeds 2000-token budget; never truncates mid-entry
- **Backward compatible** — Existing `/save-history-json` workflows unaffected

## Future Enhancements

1. **Cross-project tier** — Implement tier 5 to pull relevant knowledge from other projects
2. **AGENT.md sync** — Add doctor check comparing memory entries against README/AGENT.md
3. **Tag-based filtering** — Allow `/memory list --tags build,xcode`
4. **Export/import** — `/memory export memory-backup.json` for portability
5. **Summarization** — Use LLM to condense verbose session_state entries

## References

- Inspired by [Momento](https://github.com/TheTom/momento)
- Uses SQLite3 with [FTS5](https://www.sqlite.org/fts5.html) for full-text search
- Implements deterministic restore similar to Reth's pruning algorithm
