# Plan: Auto-Recorded Code Graph for mlx-coder

Status: **IMPLEMENTED — M1–M5 (M5-Phase-D infra only), Opus-reviewed, fixes applied** · Owner: agent team · Target module: `Sources/CodeGraph/`

> **Final review outcome (post-implementation Opus audit):** architecture sound; the flagged spots (Package.swift C-target wiring, byte-identical C# LSP path, cross-extractor `symbol_key` alignment, download ordering, inert nil-graph path) held up against source. Fixes applied to the working tree:
> - **#1 (must)** — re-index gate now folds an extraction fingerprint (`SymbolExtractor.extractionVersion` + `callEnrichment`) into the content hash, so toggling `treeSitter`/`callEnrichment` re-indexes already-indexed files instead of silently mixing extractor formats.
> - **#2** — detached enrichment tagged with the source hash; `applyEnrichment` drops a superseded pass instead of clobbering fresh `calls` edges.
> - **#3** — `grammarDownload` documented as RESERVED / not-yet-active (Phase-D downloader not wired into live extraction).
> - **#4** — cached grammar dylib re-verified against a sidecar sha256 before `dlopen`; force-unwrapped download URL replaced with a throwing guard.
> **Product decision:** C# grammar kept vendored/compiled-in (all four tier-1 languages work offline; ~62MB footprint accepted). Verified: `scripts/release.sh -b` green, `sync-grammars.sh --check` green (67 files), CodeGraph suite 84/84.

> Revision note: §2, §3, §4, §5, §7 and §10 were rewritten after an Opus source-audit. Key changes: hook the existing per-turn `modifiedFilePaths` + detached-reflect seam (not a per-call hook); v1 drops unreliable lexical `calls` edges and adjusts the token-win claim; cross-store keys use a **stable symbol-key string**, never the autoincrement id; FTS uses the plain (non-external-content) form to match `HybridSchema`; reconciliation folds into the end-of-turn block because `.sessionEnd` is **not** emitted today.

## 1. Motivation

mlx-coder has two knowledge stacks, both storing **natural-language facts**:

- **v1 `KnowledgeStore`** — typed entries (`decision`/`gotcha`/`pattern`/…), FTS5, deterministic tiered restore.
- **v2 `HybridKnowledgeStore`** — episodic/semantic/working docs, FTS5 + embeddings, RRF fusion, reranker, driven by the `Reflector`.

Neither stores the **structural shape of the code as it exists right now**. codegraph does exactly that: a derived, deterministic, re-derivable index of symbols (nodes) and relationships (edges). It is complementary, not competitive:

> **Graph = structure** (deterministic, re-derivable, driven by our own edit events).
> **Hybrid memory = rationale** (learned, fuzzy, driven by the Reflector).
> Join them on symbol IDs; expose one `explore` tool for the token win.

This plan adds a **third layer** — a deterministic code graph — in the same `~/.mlx-coder/` SQLite family, kept fresh **by the agent's own file-mutation events** (not an OS watcher), and fused into the existing pre-turn retrieval and memory stores.

## 2. What we steal from codegraph — and what we deliberately don't

**Steal:**
1. Node/edge **data model** (functions/methods/classes/enums/structs/protocols/routes). **v1 edge kinds: `imports`, `extends`, `implements`/`conforms`, `references` (by-name).** `calls` is **deferred** — see §2.1.
2. **Two-phase resolution**: extract symbols per file, then resolve references across files as a separate join.
3. **Content-hash-keyed incremental sync** — re-index a file only when its hash changed (no-op otherwise).
4. **Staleness banners + connect-time reconciliation** — surface "N files pending sync"; reconcile lazily.
5. The single **`code_graph_explore` tool** — one call returns named symbols' **source + type hierarchy + import/reference neighbors + blast-radius-by-name**. This collapses grep→read→grep loops. NB: because v1 has no `calls` edges, this is **not** a true call graph (see §2.1); the doc must not sell it as one.
6. **Impact / `affected` traversal** — blast-radius-by-name before an edit; test-file selection by import dependency.

### 2.1 Why `calls` is deferred (v1 scope honesty)

Lexical regex for Swift **call** edges is unreliable — trailing closures, method chains, `self.`, operators, free-function vs. method ambiguity, and shadowing all defeat it, producing a noisy graph that would undermine trust in the tool. So v1 extracts only the **lexically robust** relationships: `import X` statements and the `: Base, Proto` clause in a type header. True `calls` edges are deferred to **M5** via LSP `references`/`definition` or SwiftSyntax. The headline "call paths" token-win therefore arrives with M5, not v1 — v1's win is deterministic symbol lookup + type hierarchy + import blast-radius, which is already meaningfully better than grep loops.

**Do NOT steal:**
- **The OS file-watcher + debounce daemon.** We already know the exact instant a file is mutated from *inside* the agent (`AgentLoop+ToolExecution.isFileModificationToolName:137`, `EditFileTool`/`WriteFileTool`/`PatchTool`, `GitStateTracker`). Event-driven from tool success = no daemon, no debounce, no missed edits, no FSEvents/inotify platform code. **This is the single most important adaptation.**
- **The Rust + tree-sitter 20-language kernel.** Violates the zero-new-SPM-dependency rule; overkill for v1. Compose existing extraction sources instead.
- **Cross-language ObjC/RN bridging** — until actually needed.

## 3. Architecture

New module `Sources/CodeGraph/`:

| File | Role |
|------|------|
| `CodeGraphSchema.swift` | DDL for `cg_symbols`, `cg_edges`, `cg_files` (idempotent, mirrors `HybridSchema` style) |
| `CodeGraphStore.swift` | `actor` owning the SQLite connection; `upsertFile`, `symbolsIn`, `neighbors`, `resolveRefs`, `staleFiles`, `stats` |
| `SymbolExtractor.swift` | `protocol SymbolExtractor { func extract(path:source:) -> [RawSymbol] }` + per-language impls |
| `LexicalSymbolExtractor.swift` | zero-dep regex/heuristic extractor (nodes + import/hierarchy edges) — the v1 path |
| `ReferenceResolver.swift` | phase-2 join: unresolved refs (`dst_name`) → symbol keys |
| `CodeGraphIndexer.swift` | **serializing actor** with a coalescing `pending: Set<path>` work-set and a single drain loop; extract→store→resolve; content-hash gated |
| `CodeGraphExploreTool.swift` | the single agent-facing tool |

### 3.1 Storage

**Sibling `~/.mlx-coder/codegraph.db`** — separate file, not the memory DB. The graph is fully re-derivable, so it must be droppable/rebuildable without touching durable memory. WAL mode, `synchronous=NORMAL`, plain (non-external-content) FTS5 over symbol names, content-hash columns like `HybridSchema`. A **`PRAGMA user_version`** stamps the schema version so an incompatible format change triggers an automatic drop + rebuild (safe precisely because the data is derived).

### 3.2 Stable symbol keys (cross-store invariant)

`cg_symbols.id INTEGER PRIMARY KEY AUTOINCREMENT` **changes on every re-index/rebuild** and MUST NOT be used as a cross-store or durable key. All joins — the memory `entities_json` link, edge targets, external references — use a **stable symbol-key string**:

```
<repo-relative-path>::<Qualified.Name(signature-arity)>
e.g.  Sources/AgentCore/AgentLoop.swift::AgentLoop.handleStreamedToolCall(_:)
```

`cg_edges.dst_id` MAY cache the numeric id for traversal speed, but MUST always be re-derivable from `dst_name` (the schema keeps `dst_name`, so a rebuild re-resolves). This is a hard invariant, not an optimization detail.

### 3.3 Schema sketch

```sql
CREATE TABLE cg_files (
  path         TEXT PRIMARY KEY,
  content_hash TEXT NOT NULL,      -- SHA-256; re-index gate
  language     TEXT NOT NULL,
  indexed_at   INTEGER NOT NULL,
  symbol_count INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE cg_symbols (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,   -- NOT a durable/cross-store key (§3.2)
  symbol_key TEXT NOT NULL UNIQUE,                -- stable key: path::Qualified.name(arity)
  path       TEXT NOT NULL REFERENCES cg_files(path) ON DELETE CASCADE,
  name       TEXT NOT NULL,
  kind       TEXT NOT NULL,        -- function|method|class|struct|enum|protocol|route|…
  parent     TEXT,                 -- enclosing symbol name (nullable)
  start_line INTEGER NOT NULL,
  end_line   INTEGER NOT NULL,
  signature  TEXT
);

CREATE TABLE cg_edges (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  src_id    INTEGER NOT NULL REFERENCES cg_symbols(id) ON DELETE CASCADE,
  dst_id    INTEGER REFERENCES cg_symbols(id) ON DELETE SET NULL,  -- cache; re-derivable from dst_name
  dst_name  TEXT NOT NULL,         -- unresolved target name (kept for re-resolution)
  kind      TEXT NOT NULL          -- v1: imports|extends|implements|references  (calls deferred, §2.1)
);

-- Plain (non-external-content) FTS5 to match HybridSchema.swift:74 — avoids the
-- 'delete' sync dance and won't desync on symbol delete. Text is duplicated;
-- keep it in sync via AFTER INSERT/UPDATE/DELETE triggers on cg_symbols.
CREATE VIRTUAL TABLE cg_symbols_fts USING fts5(symbol_key UNINDEXED, name, signature, tokenize='unicode61');
```

`PRAGMA user_version = <N>;` set at open; on mismatch → drop all `cg_*` tables + rebuild.
Indices on `cg_symbols(path)`, `cg_symbols(name)`, `cg_symbols(symbol_key)`, `cg_edges(src_id)`, `cg_edges(dst_id)`, `cg_edges(dst_name)`. The dangling-in-edge re-resolution query is `SELECT ... FROM cg_edges WHERE dst_id IS NULL AND dst_name = ?` (indexed).

### 3.4 Extraction sources (composed, zero new deps)

1. **LSP where available** — reuse `LSPTools` (`documentSymbols`/`references`/`definition`). Accurate but today `DotnetLSPService`-only; treated as an optional enrichment, not a requirement.
2. **`LexicalSymbolExtractor`** — regex/heuristic per language (same spirit as `ContextRetriever.parseSearchLines`). Covers nodes + import edges everywhere. This is v1's backbone.
3. *(Later, optional)* SwiftSyntax for first-class Swift accuracy — explicit dependency decision, out of scope for v1.

## 4. The auto-record hook (the core of the ask)

**Hook the existing per-turn machinery — do not invent a per-call hook.** The turn loop already accumulates `modifiedFilePaths: Set<String>` (`AgentLoop.swift:432`, mirrored to `turnModifiedFiles` at `:437`) and already runs a detached end-of-turn side-effect for memory reflection:

```swift
// AgentLoop.swift:784 — existing seam
Task.detached(priority: .utility) { [provider] in
    await provider.reflect(snapshot)
}
```

1. **Enqueue graph indexing co-located with that block**, fed by `modifiedFilePaths`. Per-**turn** coalescing (one enqueue of the turn's whole changed-set) is simpler and more correct than per-call. Guard on the `codeGraph.enabled` flag; when the memory provider is absent the block still runs for the graph.
2. **`CodeGraphIndexer` is a serializing actor** owning `pending: Set<path>` + a single drain loop. Enqueues are cheap and idempotent; **never** spawn N overlapping detached indexers racing SQLite writes on the same files. Content-hash gate makes unchanged repeats free.
3. **Reconciliation folds into the same end-of-turn block.** `.sessionEnd` exists as a `ReflectionTrigger` case (`Reflector.swift:18`) but is **not emitted** from `AgentLoop` today (only `.turnCompleted`, `:779`) — so do NOT depend on it. Reconcile stale files opportunistically in the detached drain instead.
4. **Initial full scan**: detached low-priority scan kicked at session start when `enabled` (does not block first query — the staleness banner covers the window). Walk the workspace respecting `PermissionEngine.isPathIgnored` (`PermissionEngine.swift:244`); skip files >1 MB. Also expose `doctor --rebuild-graph` for a forced rebuild.
5. **Deletions/renames**: a changed path whose file no longer exists cascade-deletes its symbols (`ON DELETE CASCADE`); in-edges pointing at deleted symbols drop `dst_id` to NULL and re-resolve from `dst_name` when a matching symbol reappears.

Indexing must **never throw into the turn** — every failure degrades to "graph slightly stale," surfaced via the staleness banner (same discipline as `ContextRetriever`).

## 5. Retrieval / where it pays off

1. **`code_graph_explore` tool** — args `{ symbols: [String], depth: Int }`. Returns, per symbol: source region, its type hierarchy (`extends`/`implements`), import/reference neighbors, and a blast-radius-by-name count. Prepends a staleness banner if files are pending. (No callers/callees in v1 — `calls` deferred, §2.1.)
2. **`ContextRetriever` Stage 2 extension** — the seam is `gatherCandidates` (`ContextRetriever.swift:245`, constructed at `AgentLoop.swift:1004`). After lexical candidate gathering, also pull *graph neighbors* (import/hierarchy/reference neighbors of symbols named in the request) deterministically, no extra LLM call. Directly strengthens the pre-turn RAG that currently ships off.
3. **Memory join** — write graph **stable symbol keys** (§3.2), not numeric ids, into `memory_metadata.entities_json` (`HybridSchema.swift:63`) so hybrid memory + graph answer joint queries ("what do I know about symbol X"). No `memory_metadata` schema change needed.

## 6. Config & flags

Add a `codeGraph` block to `RuntimeConfig` (lenient decode, mirrors `ContextRetrievalConfig`):

```
enabled: Bool = false          // ships OFF until validated live
maxFileBytes: Int = 1_000_000
indexOnMutation: Bool = true
exploreDepth: Int = 1
```

Feature ships **disabled by default**; no behavior change until opted in.

## 7. Determinism, performance, safety

- Content-hash gate ⇒ idempotent re-index; same tree ⇒ same graph.
- All indexing async/detached through the single indexer actor; the turn never blocks on it, and writes are serialized (no concurrent-writer race).
- Respect `.gitignore` + `PermissionEngine.isPathIgnored`; skip >1 MB files.
- Sibling DB is droppable — `PRAGMA user_version` mismatch auto-drops + rebuilds; `doctor --rebuild-graph` forces it.

## 8. Testing (`Tests/CodeGraphTests/`)

- `LexicalSymbolExtractorTests` — per-language node/edge extraction golden cases.
- `CodeGraphStoreTests` — upsert, content-hash no-op, cascade delete, FTS.
- `ReferenceResolverTests` — unresolved→resolved join, rename re-resolution.
- `CodeGraphIndexerTests` — changed-path incremental, ignore rules, size cap.
- `CodeGraphExploreToolTests` — output shape, staleness banner.
- Integration: mutating-tool event → graph updated.

## 9. Milestones

1. **M1 — Store + schema + lexical extractor (Swift only)** behind `enabled:false`. Tests green. ✅ **DONE**
2. **M2 — Indexer + mutation hook + initial scan + staleness.** ✅ **DONE**
3. **M3 — `code_graph_explore` tool + `doctor` check.** ✅ **DONE**
4. **M4 — ContextRetriever fusion + memory `entities_json` join.** → spec §12
5. **M5 — Tree-sitter base + LSP `calls` enrichment + on-demand grammars.** → spec §13
   - **Phase B (M5a base tier)** ✅ **DONE** — vendored tree-sitter runtime + Swift/C#/JS/TS grammars as SPM C targets, `TreeSitterExtractor`, `LanguageServerRegistry` (base-extractor half), `scripts/sync-grammars.sh` (+ `--check` wired into `scripts/release.sh`). Behind `treeSitter:false`.
   - **Phase C (M5b LSP enrichment)** ✅ **DONE** — `SemanticEdgeEnricher` protocol + `LSPCallHierarchyEnricher`, `LSPBridge` generalized beyond csharp-ls (sourcekit-lsp/typescript-language-server specs added), indexer wiring off the critical path (`CodeGraphIndexer.enqueueEnrichment`), `calls` re-enabled. Behind `callEnrichment:false`.
   - **Phase D (M5c on-demand grammars)** ⚠️ **PARTIAL** — `RuntimeGrammarManager` (consent → fetch → sha256 verify → clang compile → cache-by-hash → dlopen, all mock-tested per §13.5) is implemented and green, with one real tier-2 manifest entry (`lua`). **Not yet wired into `CodeGraphIndexer`'s live extraction path** — there is no generic/heuristic symbol extractor consuming an on-demand-loaded `TSLanguage*` for an arbitrary tier-2 grammar (that's effectively unbounded scope — a bespoke node-vocabulary walker per long-tail language). The safety-critical download pipeline is done and tested; turning a loaded tier-2 grammar into `RawSymbol`/`RawEdge`s is future work.

Each milestone: `scripts/release.sh -b` green before ending the turn (per project rule).

## 10. Resolved decisions (were open questions)

1. **Storage** → sibling `codegraph.db` + `PRAGMA user_version` auto drop/rebuild. (§3.1)
2. **Edge scope** → v1 = nodes + `imports`/`extends`/`implements`/`references` only; **`calls` deferred to M5**; token-win claim adjusted to not promise a call graph. (§2.1, §5.1)
3. **Re-resolution** → only the changed file's out-edges, plus re-resolve dangling *in-*edges whose `dst_name` matches a newly-added symbol (`WHERE dst_id IS NULL AND dst_name = ?`, indexed). Not the whole graph. (§3.3, §4.5)
4. **Initial scan** → detached low-priority at session start; staleness banner covers the window; `doctor --rebuild-graph` for forced rebuild. Never blocks first query. (§4.4)
5. **Memory join** → reuse `entities_json` with the **stable symbol key**, not a numeric id and not a new column. (§3.2, §5.3)

## 11. Non-negotiable invariants (for the implementer)

- Numeric `cg_symbols.id` is **never** a durable/cross-store key. Use `symbol_key`.
- One `CodeGraphIndexer` actor serializes all writes. No overlapping detached indexers.
- Indexing failures degrade to "stale," never throw into the turn.
- Feature ships `enabled:false`; zero behavior change until opted in.
- `scripts/release.sh -b` green before ending any turn that changed source.

---

## 12. M4 spec — retrieval fusion + memory join

Goal: make the graph *pay off* in the two places that consume it, with **zero new LLM calls** on the hot path.

### 12.1 ContextRetriever Stage-2 fusion
- Seam: `ContextRetriever.gatherCandidates` (`ContextRetriever.swift:245`), constructed at `AgentLoop.swift:1004`. `ContextRetriever` gains an optional `graphStore: CodeGraphStore?` (nil ⇒ today's behavior exactly).
- After lexical candidate gathering, for each symbol name appearing in the subqueries, pull **graph neighbors** (`CodeGraphStore.neighbors` / `findSymbols`): the symbol's file plus the files of its `imports`/`extends`/`implements`/`references` (and, once M5 lands, `calls`) neighbors. Deterministic, no LLM.
- Merge neighbor paths into the existing candidate set *before* the relevance filter, deduped by path, respecting `maxCandidates` and `isPathIgnored`. Graph hits get a small ranking boost but still pass through Stage-3 relevance so noise is filtered.
- Gate on `codeGraph.enabled && graph non-empty`; degrade to current behavior otherwise. Never block the turn on graph I/O — wrap store reads in the same budget discipline as the rest of the pipeline.

### 12.2 Memory `entities_json` join
- When `Reflector`/`HybridKnowledgeStore.write` persists a doc whose content references known symbols, tag `memory_metadata.entities_json` with **stable `symbol_key` strings** (§3.2) — never numeric ids, no schema change (`HybridSchema.swift:63`).
- Add a read path: given a `symbol_key`, `HybridKnowledgeStore` can return memory docs whose `entities_json` contains it → powers "what do I know about symbol X" and lets `code_graph_explore` optionally attach logged rationale to a symbol.
- Symbol detection for tagging is best-effort and deterministic (match doc tokens against `cg_symbols.name`/`symbol_key`); no LLM required, and a miss just means no tag.

### 12.3 M4 tests
- Fusion: graph neighbors appear as candidates; disabled/empty-graph ⇒ byte-identical to pre-M4 output; ignored paths excluded; budget respected.
- Join: write-with-entities round-trips; `symbol_key` lookup returns the doc; rename (new `symbol_key`) doesn't resurrect stale tags.

---

## 13. M5 spec — tree-sitter base + LSP enrichment + on-demand grammars

Goal: the real token-win — accurate multi-language symbols and **semantically-resolved `calls` edges** — via a two-tier extractor design behind a per-language registry. All of it degrades cleanly to the M1 lexical extractor.

### 13.1 Two tiers behind one registry
- **Base tier (in-process, always available, sync).** Fits the existing `SymbolExtractor` protocol. Backends, best-available per language:
  - `TreeSitterExtractor` — nodes + `imports`/`extends`/`implements`/`references` **and syntactic `calls` sites** for C#, TS/JS, Swift, and the on-demand long tail. Uses tree-sitter's error recovery (robust on half-edited files).
  - `LexicalSymbolExtractor` (M1) — universal fallback when no grammar is available.
- **Enrichment tier (LSP, async, optional).** New sibling protocol — do **not** overload the sync `SymbolExtractor`:
  ```swift
  protocol SemanticEdgeEnricher: Sendable {
      func enrichCalls(path: String, symbols: [RawSymbol]) async -> [RawEdge]  // resolved `calls`
  }
  ```
  Backed by LSP call-hierarchy (`textDocument/prepareCallHierarchy` + `callHierarchy/incoming|outgoingCalls`), which supersedes tree-sitter's syntactic call sites when a server is present. Absent/timeout ⇒ keep the syntactic edges, mark them lower-confidence.
- **`LanguageServerRegistry`** — generalizes the currently C#-hardcoded launch (`LSPBridge.makeServerProcess:756`) + routing (`DotnetLSPService`) into per-language entries: file-extension → { base extractor, optional LSP server spec (binary, args, install hint) }. csharp-ls stays; add `sourcekit-lsp` (Swift) and `typescript-language-server`/`vtsls` (Node/TS). The generic JSON-RPC transport/framing/handshake/location-parsing in `LSPBridge` is **reused**, not rewritten.
- **Indexer flow becomes:** base-extract (sync) → store → resolve; then, when an enricher exists and `codeGraph.callEnrichment` is on, `await enrichCalls` off the critical path and upsert resolved `calls` edges. `calls` re-enabled in `EdgeKind` (drop the "not emitted" reservation once a producer exists).

### 13.2 Grammar management — one hash manifest, two moments
- **`grammars/manifest.json`** is the single source of truth: per language → upstream repo, **pinned commit**, per-file **sha256**, and the required tree-sitter `LANGUAGE_VERSION` (ABI) range.
- **Tier-1 (compiled-in / vendored):** core set only — **Swift, C#, TS/JS**. Vendor upstream `src/parser.c` + `src/scanner.c` + `tree_sitter/*.h` (already generated upstream — **no `tree-sitter generate` / Node toolchain needed**). Each becomes a small C SPM target (`CTreeSitter<Lang>`); plus the tree-sitter runtime as a vendored C target.
- **`scripts/sync-grammars.sh`** — deliberate update: fetch pinned commit, verify sha256, copy in, rewrite manifest. `--check` mode: hash vendored files against the manifest, **fail on drift** — this mode (fast, offline, no network) is what wires into `scripts/release.sh`. Never auto-fetch newer upstream at build time (hermetic/deterministic builds).
- **Tier-2 (runtime on-demand / long tail):** Lua, Kotlin, Scala, Dart, Go, Ruby, … not compiled in. When the indexer meets an unsupported language, the agent **asks** (reuse `AgentLoop+ToolApproval` / `InteractiveInput` consent; persist `ask`/`always`/`never`). On yes: fetch the manifest-pinned source over HTTPS, **verify sha256**, compile locally with `clang` to `~/.mlx-coder/grammars/<lang>-<hash>.dylib` (mirrors the existing model-download pattern under `~/.mlx-coder`; keep source for reproducibility), then `dlopen` + `ts_parser_set_language`. Cache keyed by name+hash; recompile on pin change.

### 13.3 Safety rails (loading native code — non-negotiable)
1. **Consent always** — never auto-download; reuse the existing approval prompt; persist the choice.
2. **Pin + verify** — only the manifest's exact commit over HTTPS; verify sha256 before compiling. No "latest."
3. **ABI pin** — grammar `LANGUAGE_VERSION` must be within the linked runtime's supported range (recorded in the manifest) or the download is refused.
4. **Cache by name+hash**, recompile on pin change, keep source.
5. **Graceful degrade** — missing grammar / declined / no clang / LSP absent ⇒ fall back (tree-sitter→lexical; LSP→syntactic calls). **Never** an error into the turn.

### 13.4 Config additions (`CodeGraphConfig`, lenient decode, all default off/conservative)
```
treeSitter: Bool = false          // enable tree-sitter base tier
callEnrichment: Bool = false      // enable LSP calls enrichment
grammarDownload: String = "ask"   // ask | always | never  (runtime long-tail)
```

### 13.5 M5 tests
- `TreeSitterExtractorTests` — golden node/edge/syntactic-call cases for Swift, C#, TS; error-recovery on truncated source.
- `LanguageServerRegistryTests` — extension→server/extractor resolution; unknown language → lexical.
- `SemanticEdgeEnricherTests` — call-hierarchy parse → resolved `calls`; server-absent ⇒ syntactic fallback, no throw.
- `GrammarManifestTests` — `--check` fails on drift; sha256/ABI verification; declined/no-clang ⇒ lexical, never throws.
- Determinism: same source + same pinned grammars ⇒ same graph.

### 13.6 Dependency note
Tier-1 grammars + the tree-sitter runtime are **vendored C sources compiled as SPM C targets** (not SPM package deps) — consistent with the "no new SPM *package* dependencies" spirit; document this explicitly in the PR. LSP servers are external binaries (like csharp-ls today), not deps.
