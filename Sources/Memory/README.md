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

## Hybrid Memory Stack (`Hybrid/`)

The lexical-only `KnowledgeStore` above is the **stable v1**. A second-generation
**hybrid retrieval + reflection** stack lives alongside it under
`Sources/Memory/Hybrid/` and is intended to evolve mlx-coder into a
self-improving agent without breaking existing tools.

### Components

| File | Role |
|------|------|
| `HybridSchema.swift` | DDL for `memory_documents`, `memory_metadata`, `memory_fts`, `memory_embeddings` (FTS5 + cosine over BLOBs) |
| `HybridDocument.swift` | Data model: `MemoryType` (episodic / semantic / working), `KnowledgeKind`, `DocumentStatus`, `MemoryDocument`, `ScoredDocument`, `RetrievalScope` |
| `EmbeddingProvider.swift` | `EmbeddingProvider` protocol + zero-dependency `HashEmbeddingProvider` (deterministic SHA-256 trigram hashing). Pluggable for an MLX-backed encoder later. `EmbeddingBlob` packs Float32 little-endian to stay compatible with `sqlite-vec`'s `vec0` format |
| `RankFusion.swift` | Reciprocal Rank Fusion + weighted top-N over multiple ranked lists |
| `Reranker.swift` | `Reranker` protocol + `LexicalReranker` (token Jaccard + entity overlap + freshness + confidence − length penalty), with a time-budget guard |
| `HybridKnowledgeStore.swift` | `actor` orchestrating `write`, `retrieve`, `consolidate`, `prune`, `stats` |
| `Reflector.swift` | Self-improvement loop: `ReflectionTrigger` (turn / cadence / failure / userFeedback / sessionEnd) → `CandidateExtractor` → `HybridKnowledgeStore.write` (append vs supersede) |

### Retrieval pipeline

```
query
  ├── FTS5 top-N        (BM25, scoped to project_root + memory_type + kind)
  ├── vec cosine top-N  (in-process; sqlite-vec drop-in via the BLOB layout)
  ├── RRF / weighted fusion
  └── Reranker top-K (with time budget)
```

Tuning knobs live on `HybridKnowledgeStore.Config`
(`weightLexical`, `weightSemantic`, `rrfK`, `rerankK`, `rerankBudget`,
`nearDuplicateCosineThreshold`, `nearDuplicateTokenJaccardThreshold`).

### Self-improvement loop

`Reflector.reflect(_:)` is the entry point. The default `ReflectionCadence`
mirrors Hermes' `memory.nudge_interval`:

- `turnCompleted` is gated (no-op).
- `cadence(everyN, currentCount)` fires when `currentCount % everyN == 0`.
- `failure`, `userFeedback`, `sessionEnd` always fire.

For each candidate, `HybridKnowledgeStore.write` decides:

- **exact duplicate** (same `content_hash`) → no-op, refresh access counters,
- **near-duplicate** (cosine ≥ 0.85 *and* Jaccard ≥ 0.7) and the new
  candidate has *higher or equal* confidence → **supersede** (the older
  doc's `status` becomes `superseded`, the new doc's `version` is bumped
  and `supersedes_id` is linked),
- otherwise → **append**.

`sessionEnd` additionally runs a best-effort `consolidate` (cluster-level
near-dup merge) and `prune` (working-memory TTL deletion + episodic
archive).

### Why no `sqlite-vec` SPM dep yet

The plan calls out `sqlite-vec` as the canonical vector backend. The
existing repo constraint is *zero new SPM dependencies*; pulling
`sqlite-vec` requires either a runtime extension load or a vendored C
build. The current implementation stores embeddings as Float32
little-endian BLOBs in a regular SQLite table — exactly the layout
`vec0` uses — so swapping the table type for `vec0` is a localized
migration in `HybridSchema.swift` + the `vectorSearch` helper.

### Tests

`Tests/MemoryTests/Hybrid/` covers:

- write / exact-dup / near-dup supersede paths,
- FTS5 token escaping (so operator chars like `=` don't crash MATCH),
- prune (working TTL) + consolidate (cluster merge),
- RRF semantics + tiebreak determinism,
- reranker token-overlap ordering + time-budget guard,
- reflector cadence gating + always-on triggers + write-through.

Run with `swift test --filter MemoryTests`.

## References

- Inspired by [Momento](https://github.com/TheTom/momento)
- Uses SQLite3 with [FTS5](https://www.sqlite.org/fts5.html) for full-text search
- Implements deterministic restore similar to Reth's pruning algorithm
