// Sources/CodeGraph/CodeGraphIndexer.swift
// Serializing actor: coalesces modified paths, extracts, writes, resolves.

import Foundation

/// The **single** actor that serializes every write to the code graph (plan
/// §4, §11 invariant #2). Owns a coalescing `pending: Set<String>` work-set
/// drained by exactly one in-flight loop at a time — callers (the end-of-turn
/// hook, the session-start scan, `doctor --rebuild-graph`) all just enqueue or
/// await a synchronous drive; none of them spawn a second overlapping indexer.
///
/// Every failure inside `indexOne` is swallowed and recorded as `lastError` —
/// indexing must never throw into the agent turn (plan §4, §11 invariant #3).
/// Staleness (files not yet reflected in the graph) is exposed via `status()`
/// for the explore tool's banner and `doctor`.
public actor CodeGraphIndexer {

    public struct Status: Sendable {
        public let enabled: Bool
        public let pendingCount: Int
        public let totalIndexed: Int
        public let lastError: String?
    }

    public let store: CodeGraphStore
    private let permissions: PermissionEngine
    private let config: CodeGraphConfig
    /// Extension → extractor routing (plan §13.1). Defaults to
    /// `.standard`; overridable for tests that want a scoped-down table.
    private let registry: LanguageServerRegistry
    /// M5b LSP enrichment (plan §13.1). `nil` ⇒ enrichment never runs
    /// regardless of `config.callEnrichment` (production callers that want
    /// it construct an `LSPCallHierarchyEnricher`; most tests leave this
    /// nil so they never touch a real language server).
    private let enricher: SemanticEdgeEnricher?

    private var pending: Set<String> = []
    private var draining = false
    private var initialized = false
    private var totalIndexed = 0
    private var lastError: String?
    /// Count of enrichment passes completed (successfully reached the
    /// store, whether or not they found any calls) — exposed for tests that
    /// need to await the detached enrichment `Task` deterministically.
    private var enrichmentCompleted = 0

    public init(
        store: CodeGraphStore,
        permissions: PermissionEngine,
        config: CodeGraphConfig,
        registry: LanguageServerRegistry = .standard,
        enricher: SemanticEdgeEnricher? = nil
    ) {
        self.store = store
        self.permissions = permissions
        self.config = config
        self.registry = registry
        self.enricher = enricher
    }

    // MARK: - Lifecycle

    /// Opens the sibling DB. Best-effort: on failure the indexer stays
    /// permanently disabled for this process rather than throwing (invariant
    /// #3) — every subsequent `enqueue`/`scanWorkspace` call becomes a no-op.
    public func bootstrap() async {
        guard config.enabled, !initialized else { return }
        do {
            try await store.initialize()
            initialized = true
        } catch {
            lastError = "bootstrap failed: \(error)"
        }
    }

    public func status() -> Status {
        Status(enabled: config.enabled, pendingCount: pending.count, totalIndexed: totalIndexed, lastError: lastError)
    }

    /// Testing seam: populates `pending` directly, without spawning a drain
    /// task, so callers (namely `CodeGraphExploreToolTests`) can deterministically
    /// exercise the staleness banner without racing the real background drain
    /// loop (whose `pending.popFirst()` happens before any `await`, making the
    /// real `enqueue()` a near-instant, timing-dependent window otherwise).
    public func debugMarkPending(_ paths: Set<String>) {
        pending.formUnion(paths)
    }

    // MARK: - Enqueue / drain

    /// Coalescing enqueue — safe to call once per turn with the turn's whole
    /// modified-file set (plan §4.1: per-turn coalescing, not per-call).
    /// Non-Swift / ignored / oversized paths are silently dropped rather than
    /// counted as permanently "pending" (v1 only extracts Swift — plan §9 M1).
    public func enqueue(paths: Set<String>) {
        guard config.enabled, initialized, !paths.isEmpty else { return }
        addToPending(paths)
        guard !pending.isEmpty, !draining else { return }
        Task { await drain() }
    }

    /// Enqueues and drains synchronously — no detached `Task`, so the
    /// caller's `await` only returns once every path has actually been
    /// processed. Used by tests (and any caller that needs a deterministic
    /// result) instead of the fire-and-forget `enqueue`.
    public func indexAndWait(paths: Set<String>) async {
        guard config.enabled, initialized, !paths.isEmpty else { return }
        addToPending(paths)
        await drain()
    }

    private func addToPending(_ paths: Set<String>) {
        for raw in paths {
            let rel = relativePath(for: raw)
            guard registry.language(forPath: rel) != nil else { continue }
            guard !isIgnored(rel) else { continue }
            pending.insert(rel)
        }
    }

    /// Detached, low-priority initial full workspace scan (plan §4.4). Never
    /// blocks the caller's first query — the staleness banner covers the
    /// window while this runs.
    public func scanWorkspace(root: String) async {
        guard config.enabled else { return }
        if !initialized { await bootstrap() }
        guard initialized else { return }
        let paths = Self.discoverSourceFiles(root: root, permissions: permissions, maxFileBytes: config.maxFileBytes)
        enqueue(paths: Set(paths))
    }

    /// Drop + recreate the schema, then scan and index the whole workspace
    /// **synchronously** (returns only once every discovered file has been
    /// processed). Used by `doctor --rebuild-graph`, where — unlike the
    /// low-priority session-start scan — the caller wants to wait for and
    /// report the result.
    public func rebuildSynchronously(root: String) async -> Status {
        guard config.enabled else { return status() }
        do {
            try await store.dropAndRecreate()
            initialized = true
            lastError = nil
        } catch {
            lastError = "rebuild failed: \(error)"
            return status()
        }
        let paths = Self.discoverSourceFiles(root: root, permissions: permissions, maxFileBytes: config.maxFileBytes)
        for path in paths {
            await indexOne(path: path)
        }
        pending.removeAll()
        return status()
    }

    private func drain() async {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while let path = pending.popFirst() {
            await indexOne(path: path)
        }
    }

    // MARK: - Per-file indexing

    private func indexOne(path: String) async {
        do {
            let absPath = permissions.resolveAbsolutePath(path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: absPath, isDirectory: &isDirectory), !isDirectory.boolValue else {
                // Deleted (or never existed) — cascade-remove any prior rows.
                try await store.removeFile(path: path)
                totalIndexed += 1
                return
            }
            let attrs = try FileManager.default.attributesOfItem(atPath: absPath)
            if let size = attrs[.size] as? Int, size > config.maxFileBytes {
                return // skip silently — never counted as an index failure
            }
            guard let language = registry.language(forPath: path),
                  let extractor = registry.extractor(forPath: path, treeSitterEnabled: config.treeSitter) else {
                return
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: absPath))
            guard let source = String(data: data, encoding: .utf8) else { return }
            // Fold the extraction fingerprint (which extractor + whether call
            // enrichment is on) into the content-hash gate so toggling
            // `treeSitter`/`callEnrichment` — or an extractor format bump —
            // forces already-indexed files to re-index instead of silently
            // keeping stale-format symbols (Opus review #1).
            let fingerprint = "\(extractor.extractionVersion)|calls=\(config.callEnrichment)"
            let hash = CodeGraphHasher.sha256(source + "\u{1}" + fingerprint)

            let result = extractor.extract(path: path, source: source)
            let outcome = try await store.upsertFile(
                path: path, contentHash: hash, language: language,
                symbols: result.symbols, edges: result.edges
            )
            if case .indexed(let newSymbols) = outcome {
                _ = try await ReferenceResolver.resolveNewSymbols(newSymbols, in: store)
                enqueueEnrichment(path: path, symbols: result.symbols, sourceHash: hash)
            }
            totalIndexed += 1
            lastError = nil
        } catch {
            // Degrade to "stale" — never throw into the turn (invariant #3).
            // The file simply stays absent/out-of-date in the graph until a
            // later enqueue or rebuild succeeds.
            lastError = "index failed for \(path): \(error)"
        }
    }

    // MARK: - M5b LSP enrichment (plan §13.1) — off the critical path

    /// Fires an unstructured, detached-from-`indexOne` `Task` that runs
    /// `SemanticEdgeEnricher.enrichCalls` and, on success, upserts the
    /// resolved `calls` edges — `indexOne` does **not** await this, so a
    /// slow/unavailable language server never blocks the turn or the
    /// drain loop (plan §4, §13.1). The `Task` still only ever touches the
    /// store through this same actor's isolation (`applyEnrichment`), so
    /// invariant #2 (one serializing indexer) holds even though the I/O
    /// itself runs concurrently with other work.
    private func enqueueEnrichment(path: String, symbols: [RawSymbol], sourceHash: String) {
        guard config.callEnrichment, let enricher else { return }
        Task { [weak self] in
            let edges = await enricher.enrichCalls(path: path, symbols: symbols)
            await self?.applyEnrichment(path: path, edges: edges, sourceHash: sourceHash)
        }
    }

    private func applyEnrichment(path: String, edges: [RawEdge], sourceHash: String) async {
        guard initialized else { return }
        do {
            // Drop a stale, superseded pass: if the file was re-indexed while
            // this enricher was in flight, its stored hash no longer matches
            // the one these edges were computed against, and a newer pass has
            // run (or is queued). Applying now would clobber fresh calls edges
            // with old ones (Opus review #2). Ordering guard only — actor
            // isolation already prevents a data race (invariant #2).
            let current = try await store.fileContentHash(path: path)
            guard current == sourceHash else { enrichmentCompleted += 1; return }
            try await store.replaceCallEdges(path: path, edges: edges)
        } catch {
            // Degrade to "stale calls edges" — never throw into the turn
            // (invariant #3). The prior (syntactic) calls edges for this
            // file simply remain as-is.
            lastError = "enrichment failed for \(path): \(error)"
        }
        enrichmentCompleted += 1
    }

    /// Deterministic test seam: runs extraction + enrichment +
    /// `CodeGraphStore.replaceCallEdges` **synchronously** for `paths` (no
    /// detached `Task`), so tests can assert on enrichment results without
    /// racing `indexOne`'s fire-and-forget background pass. Production code
    /// never calls this — `indexOne`'s `enqueueEnrichment` is the real,
    /// off-critical-path flow.
    public func indexAndEnrichSynchronously(paths: Set<String>) async {
        guard config.enabled, initialized, config.callEnrichment, let enricher else { return }
        for raw in paths {
            let path = relativePath(for: raw)
            guard let extractor = registry.extractor(forPath: path, treeSitterEnabled: config.treeSitter) else { continue }
            let absPath = permissions.resolveAbsolutePath(path)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: absPath)),
                  let source = String(data: data, encoding: .utf8) else { continue }
            let result = extractor.extract(path: path, source: source)
            let edges = await enricher.enrichCalls(path: path, symbols: result.symbols)
            try? await store.replaceCallEdges(path: path, edges: edges)
            enrichmentCompleted += 1
        }
    }

    /// Test seam: number of enrichment passes (`applyEnrichment` /
    /// `indexAndEnrichSynchronously`) completed so far — lets a test `await`
    /// a detached enrichment `Task` deterministically without a raw sleep.
    public func enrichmentCompletedCount() -> Int { enrichmentCompleted }

    // MARK: - Path helpers

    private func relativePath(for path: String) -> String {
        let abs = permissions.resolveAbsolutePath(path)
        let root = permissions.workspaceRoot
        if abs == root { return "." }
        if abs.hasPrefix(root + "/") { return String(abs.dropFirst(root.count + 1)) }
        return abs
    }

    private func isIgnored(_ relativePath: String) -> Bool {
        permissions.isPathIgnored(relativePath) || BuildOutputFilter.isBuildOutput(path: relativePath)
    }

    // MARK: - Static helpers (no actor state — usable from `discoverSourceFiles`)

    /// Walks `root`, pruning `.git` and known build-output directories,
    /// returning repo-relative paths to every file with a
    /// `LanguageServerRegistry.standard`-known extension within
    /// `maxFileBytes` that `permissions` doesn't ignore. Discovery is
    /// deliberately "generous" about which extensions it surfaces (every
    /// extension the registry knows, tree-sitter-backed or not) — whether a
    /// discovered path is actually indexed still depends on
    /// `CodeGraphConfig.treeSitter` at extract time (`indexOne`), same as
    /// any other `enqueue`d path. This keeps M1's Swift-only-by-default
    /// invariant intact (only `.swift` had a working extractor before M5;
    /// now every other known extension still no-ops until `treeSitter` is
    /// turned on).
    static func discoverSourceFiles(root: String, permissions: PermissionEngine, maxFileBytes: Int) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let knownExtensions = LanguageServerRegistry.standard.knownExtensions
        let normalizedRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
        var results: [String] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let name = url.lastPathComponent
            if values?.isDirectory == true {
                if name == ".git" || BuildOutputFilter.ignoredNames.contains(name) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard knownExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let absPath = url.path
            let relPath = absPath.hasPrefix(normalizedRoot + "/")
                ? String(absPath.dropFirst(normalizedRoot.count + 1))
                : absPath
            if permissions.isPathIgnored(relPath) { continue }
            if let size = values?.fileSize, size > maxFileBytes { continue }
            results.append(relPath)
        }
        return results
    }
}
