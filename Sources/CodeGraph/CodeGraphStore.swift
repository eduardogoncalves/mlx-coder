// Sources/CodeGraph/CodeGraphStore.swift
// SQLite-backed structural code graph store — sibling `~/.mlx-coder/codegraph.db`.

import Foundation
import CSQLite
import CryptoKit

/// Thread-safe store for the deterministic, re-derivable code graph.
///
/// Owns the `~/.mlx-coder/codegraph.db` SQLite connection (WAL,
/// `synchronous=NORMAL`), separate from the durable memory DBs so it can be
/// dropped and rebuilt freely — see `CodeGraphSchema` for the DDL and the
/// `PRAGMA user_version` auto-rebuild contract.
///
/// **Hard invariant** (plan §3.2, §11): `cg_symbols.id` is an autoincrement
/// integer that is NOT stable across a drop+rebuild. Every public API that
/// crosses an actor boundary should prefer `symbolKey` for anything that
/// needs to survive a rebuild; the numeric `id` returned here is only a
/// same-process traversal convenience.
public actor CodeGraphStore {

    // MARK: - Errors

    public enum StoreError: Error, CustomStringConvertible {
        case databaseNotOpen
        case sqliteError(String, Int32)

        public var description: String {
            switch self {
            case .databaseNotOpen: return "Code graph database not open"
            case .sqliteError(let msg, let code): return "SQLite error (\(code)): \(msg)"
            }
        }
    }

    // MARK: - Rows

    public struct SymbolRow: Sendable, Equatable {
        public let id: Int64
        public let symbolKey: String
        public let path: String
        public let name: String
        public let kind: String
        public let parent: String?
        public let startLine: Int
        public let endLine: Int
        public let signature: String?
    }

    public struct EdgeRow: Sendable, Equatable {
        public let id: Int64
        public let srcId: Int64
        public let dstId: Int64?
        public let dstName: String
        public let kind: String
    }

    /// Combined outgoing/incoming neighbor view for `code_graph_explore`.
    public struct NeighborBundle: Sendable {
        public let symbol: SymbolRow
        public let outgoing: [EdgeRow]
        public let incoming: [EdgeRow]
        /// Distinct source symbols referencing this one by id-or-name —
        /// the "blast radius by name" count (plan §5.1).
        public var blastRadiusCount: Int { Set(incoming.map(\.srcId)).count }
    }

    public enum UpsertOutcome: Sendable, Equatable {
        /// The file's on-disk content hash matched what was already stored —
        /// no write happened.
        case unchanged
        /// The file was (re)indexed; carries the freshly-inserted rows so the
        /// caller (`CodeGraphIndexer`) can drive phase-2 dangling-edge
        /// re-resolution (`ReferenceResolver`) without a second query.
        case indexed([SymbolRow])
    }

    public struct Stats: Sendable {
        public let fileCount: Int
        public let symbolCount: Int
        public let edgeCount: Int
        public let unresolvedEdgeCount: Int
        public let dbSizeBytes: Int64
    }

    // MARK: - State

    private let dbPath: String
    private var db: OpaquePointer?

    public init(dbPath: String? = nil) {
        if let dbPath {
            self.dbPath = dbPath
        } else {
            let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
            let mlxCoderDir = (homeDir as NSString).appendingPathComponent(".mlx-coder")
            try? FileManager.default.createDirectory(atPath: mlxCoderDir, withIntermediateDirectories: true)
            self.dbPath = (mlxCoderDir as NSString).appendingPathComponent("codegraph.db")
        }
    }

    // MARK: - Lifecycle

    public func initialize() throws {
        guard db == nil else { return } // already open — idempotent
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(dbPath, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            throw StoreError.sqliteError("Failed to open code graph database", rc)
        }
        self.db = handle

        for pragma in CodeGraphSchema.pragmas { try exec(pragma) }

        let storedVersion = try readUserVersion()
        if storedVersion != 0, storedVersion != CodeGraphSchema.schemaVersion {
            // Incompatible shape change — safe to drop, the graph is fully
            // re-derivable from source on disk (plan §3.1, §7).
            try dropAllTables()
        }
        for stmt in CodeGraphSchema.statements { try exec(stmt) }
        try exec("PRAGMA user_version = \(CodeGraphSchema.schemaVersion);")
    }

    /// Force a full drop + recreate, regardless of the stored schema version.
    /// Used by `doctor --rebuild-graph`; the indexer then re-scans the
    /// workspace from scratch.
    public func dropAndRecreate() throws {
        guard db != nil else { try initialize(); return }
        try dropAllTables()
        for stmt in CodeGraphSchema.statements { try exec(stmt) }
        try exec("PRAGMA user_version = \(CodeGraphSchema.schemaVersion);")
    }

    public func close() {
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    private func dropAllTables() throws {
        for stmt in CodeGraphSchema.dropStatements { try exec(stmt) }
    }

    private func readUserVersion() throws -> Int32 {
        guard let db else { throw StoreError.databaseNotOpen }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqliteError("user_version prepare", sqlite3_errcode(db))
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int(stmt, 0)
    }

    // MARK: - Write path

    /// Replace a file's symbols/edges with a freshly-extracted set, gated by
    /// content hash (a no-op when unchanged). On write, cascades delete the
    /// file's previous symbols (which cascades their edges + FTS rows via
    /// `ON DELETE`/triggers), inserts the new symbols/edges, and — for each
    /// newly (re)created symbol — re-resolves any dangling in-edge elsewhere
    /// in the graph whose `dst_name` now matches it (plan §10.3).
    @discardableResult
    public func upsertFile(
        path: String,
        contentHash: String,
        language: String,
        symbols: [RawSymbol],
        edges: [RawEdge],
        force: Bool = false
    ) throws -> UpsertOutcome {
        guard db != nil else { throw StoreError.databaseNotOpen }
        if !force, let existing = try fileContentHash(path: path), existing == contentHash {
            return .unchanged
        }

        try exec("BEGIN IMMEDIATE;")
        do {
            try upsertFileRow(path: path, contentHash: contentHash, language: language, symbolCount: symbols.count)
            try deleteSymbols(forPath: path)

            var idByQualifiedName: [String: Int64] = [:]
            idByQualifiedName.reserveCapacity(symbols.count)
            for sym in symbols {
                let key = "\(path)::\(sym.qualifiedName)"
                let id = try insertSymbol(
                    symbolKey: key, path: path, name: sym.name, kind: sym.kind.rawValue,
                    parent: sym.parent, startLine: sym.startLine, endLine: sym.endLine, signature: sym.signature
                )
                idByQualifiedName[sym.qualifiedName] = id
            }

            for edge in edges {
                guard let srcId = idByQualifiedName[edge.srcQualifiedName] else { continue }
                let dstId = try lookupSymbolID(byName: edge.dstName, preferPath: path)
                try insertEdge(srcId: srcId, dstId: dstId, dstName: edge.dstName, kind: edge.kind.rawValue)
            }

            var inserted: [SymbolRow] = []
            inserted.reserveCapacity(symbols.count)
            for sym in symbols {
                guard let id = idByQualifiedName[sym.qualifiedName] else { continue }
                inserted.append(SymbolRow(
                    id: id, symbolKey: "\(path)::\(sym.qualifiedName)", path: path, name: sym.name,
                    kind: sym.kind.rawValue, parent: sym.parent, startLine: sym.startLine,
                    endLine: sym.endLine, signature: sym.signature
                ))
            }

            try exec("COMMIT;")
            return .indexed(inserted)
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Re-resolve dangling in-edges (`dst_id IS NULL`) whose `dst_name`
    /// matches `name`, pointing them at `resolvedSymbolID`. Called by
    /// `ReferenceResolver` after `upsertFile` for each newly (re)created
    /// symbol — this is what lets a reference recorded while file A was
    /// indexed resolve once file B (defining the symbol) is indexed later,
    /// and what makes renames re-resolve automatically without a full rebuild.
    @discardableResult
    public func resolveDanglingEdges(matchingName name: String, resolvedSymbolID: Int64) throws -> Int {
        guard let db else { throw StoreError.databaseNotOpen }
        let sql = "UPDATE cg_edges SET dst_id = ? WHERE dst_id IS NULL AND dst_name = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqliteError("resolve prepare", sqlite3_errcode(db))
        }
        sqlite3_bind_int64(stmt, 1, resolvedSymbolID)
        sqlite3_bind_text(stmt, 2, name, -1, _swift_sqlite_transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.sqliteError("resolve step", sqlite3_errcode(db))
        }
        return Int(sqlite3_changes(db))
    }

    /// Remove a file (and cascade its symbols/edges) — called when a
    /// previously-indexed path no longer exists on disk (delete/rename). Any
    /// in-edges elsewhere pointing at the removed symbols drop `dst_id` to
    /// NULL (`ON DELETE SET NULL`) but keep `dst_name`, so they re-resolve
    /// automatically if a same-named symbol reappears.
    public func removeFile(path: String) throws {
        guard let db else { throw StoreError.databaseNotOpen }
        try deleteSymbols(forPath: path)
        let sql = "DELETE FROM cg_files WHERE path = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqliteError("removeFile prepare", sqlite3_errcode(db))
        }
        sqlite3_bind_text(stmt, 1, path, -1, _swift_sqlite_transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.sqliteError("removeFile step", sqlite3_errcode(db))
        }
    }

    /// Replaces a file's `calls` edges with a freshly-enriched set from a
    /// `SemanticEdgeEnricher` (plan §13.1, M5b). Unlike `upsertFile`'s
    /// per-file symbol replacement, this only touches `kind = 'calls'`
    /// edges whose source symbol belongs to `path` — it deletes the prior
    /// set (syntactic `calls` from `TreeSitterExtractor`, or a stale
    /// enrichment) and inserts `edges` in the same transaction. Symbols not
    /// currently indexed for `path` are silently skipped (the file may have
    /// changed between extraction and enrichment landing, since enrichment
    /// runs off the critical path — plan §4, §13.1) rather than treated as
    /// an error.
    public func replaceCallEdges(path: String, edges: [RawEdge]) throws {
        guard db != nil else { throw StoreError.databaseNotOpen }
        let rows = try symbolsIn(path: path)
        let prefix = "\(path)::"
        var idByQualifiedName: [String: Int64] = [:]
        idByQualifiedName.reserveCapacity(rows.count)
        for row in rows where row.symbolKey.hasPrefix(prefix) {
            idByQualifiedName[String(row.symbolKey.dropFirst(prefix.count))] = row.id
        }

        try exec("BEGIN IMMEDIATE;")
        do {
            try deleteCallEdges(srcIds: Array(idByQualifiedName.values))
            for edge in edges {
                guard edge.kind == .calls, let srcId = idByQualifiedName[edge.srcQualifiedName] else { continue }
                let dstId = try lookupSymbolID(byName: edge.dstName, preferPath: path)
                try insertEdge(srcId: srcId, dstId: dstId, dstName: edge.dstName, kind: edge.kind.rawValue)
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private func deleteCallEdges(srcIds: [Int64]) throws {
        guard let db else { throw StoreError.databaseNotOpen }
        guard !srcIds.isEmpty else { return }
        let placeholders = srcIds.map { _ in "?" }.joined(separator: ",")
        let sql = "DELETE FROM cg_edges WHERE kind = 'calls' AND src_id IN (\(placeholders));"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqliteError("replaceCallEdges delete prepare", sqlite3_errcode(db))
        }
        for (i, id) in srcIds.enumerated() {
            sqlite3_bind_int64(stmt, Int32(i + 1), id)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.sqliteError("replaceCallEdges delete step", sqlite3_errcode(db))
        }
    }

    // MARK: - Read path

    public func fileContentHash(path: String) throws -> String? {
        guard let db else { throw StoreError.databaseNotOpen }
        let sql = "SELECT content_hash FROM cg_files WHERE path = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqliteError("hash prepare", sqlite3_errcode(db))
        }
        sqlite3_bind_text(stmt, 1, path, -1, _swift_sqlite_transient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(stmt, 0).map { String(cString: $0) }
    }

    public func indexedFilePaths() throws -> Set<String> {
        guard let db else { throw StoreError.databaseNotOpen }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT path FROM cg_files;", -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqliteError("paths prepare", sqlite3_errcode(db))
        }
        var paths = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let p = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }) { paths.insert(p) }
        }
        return paths
    }

    public func symbolsIn(path: String) throws -> [SymbolRow] {
        try querySymbols(sql: "SELECT \(Self.symbolColumns) FROM cg_symbols WHERE path = ? ORDER BY start_line;", bind: [.text(path)])
    }

    public func symbol(key: String) throws -> SymbolRow? {
        try querySymbols(sql: "SELECT \(Self.symbolColumns) FROM cg_symbols WHERE symbol_key = ? LIMIT 1;", bind: [.text(key)]).first
    }

    public func symbol(id: Int64) throws -> SymbolRow? {
        try querySymbols(sql: "SELECT \(Self.symbolColumns) FROM cg_symbols WHERE id = ? LIMIT 1;", bind: [.int64(id)]).first
    }

    /// Exact (case-sensitive) bare-name lookup, same-file-first is not
    /// meaningful here (no anchor file) so results are ordered by id for
    /// determinism, most-recently-indexed last.
    public func findSymbols(named name: String, limit: Int = 20) throws -> [SymbolRow] {
        try querySymbols(
            sql: "SELECT \(Self.symbolColumns) FROM cg_symbols WHERE name = ? ORDER BY id LIMIT ?;",
            bind: [.text(name), .int(limit)]
        )
    }

    /// Plain FTS5 prefix-ish search over symbol name/signature.
    public func searchSymbols(query: String, limit: Int = 20) throws -> [SymbolRow] {
        guard let db else { throw StoreError.databaseNotOpen }
        let escaped = Self.escapeFTSPrefix(query)
        guard !escaped.isEmpty else { return [] }
        // NB: FTS5's `MATCH`/`rank` must reference the bare virtual-table name,
        // not the `f` alias used in the JOIN below (aliasing `MATCH`'s LHS is a
        // parse error: "no such column: f") — verified against sqlite3 directly.
        let sql = """
            SELECT s.id, s.symbol_key, s.path, s.name, s.kind, s.parent, s.start_line, s.end_line, s.signature
            FROM cg_symbols_fts f
            JOIN cg_symbols s ON s.id = f.rowid
            WHERE cg_symbols_fts MATCH ?
            ORDER BY rank
            LIMIT ?;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqliteError(String(cString: sqlite3_errmsg(db)), sqlite3_errcode(db))
        }
        sqlite3_bind_text(stmt, 1, escaped, -1, _swift_sqlite_transient)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var rows: [SymbolRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let row = Self.parseSymbolRow(stmt) { rows.append(row) }
        }
        return rows
    }

    public func outgoingEdges(symbolID: Int64) throws -> [EdgeRow] {
        try queryEdges(sql: "SELECT \(Self.edgeColumns) FROM cg_edges WHERE src_id = ? ORDER BY id;", bind: [.int64(symbolID)])
    }

    /// Edges elsewhere pointing at this symbol, either resolved (`dst_id`) or
    /// still by-name (`dst_name`) — the union is intentional: it is the
    /// "blast radius by name" (plan §5.1).
    public func incomingEdges(symbolID: Int64, name: String) throws -> [EdgeRow] {
        try queryEdges(
            sql: "SELECT \(Self.edgeColumns) FROM cg_edges WHERE dst_id = ? OR dst_name = ? ORDER BY id;",
            bind: [.int64(symbolID), .text(name)]
        )
    }

    public func neighbors(symbolID: Int64) throws -> NeighborBundle? {
        guard let sym = try symbol(id: symbolID) else { return nil }
        let outgoing = try outgoingEdges(symbolID: symbolID)
        let incoming = try incomingEdges(symbolID: symbolID, name: sym.name)
        return NeighborBundle(symbol: sym, outgoing: outgoing, incoming: incoming)
    }

    public func stats() throws -> Stats {
        guard let db else { throw StoreError.databaseNotOpen }
        func count(_ sql: String) throws -> Int {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw StoreError.sqliteError("count prepare", sqlite3_errcode(db))
            }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
        }
        let fileSize: Int64 = (try? FileManager.default.attributesOfItem(atPath: dbPath)[.size] as? Int64) ?? 0
        return Stats(
            fileCount: try count("SELECT COUNT(*) FROM cg_files;"),
            symbolCount: try count("SELECT COUNT(*) FROM cg_symbols;"),
            edgeCount: try count("SELECT COUNT(*) FROM cg_edges;"),
            unresolvedEdgeCount: try count("SELECT COUNT(*) FROM cg_edges WHERE dst_id IS NULL;"),
            dbSizeBytes: fileSize
        )
    }

    // MARK: - Internal SQL helpers

    private static let symbolColumns = "id, symbol_key, path, name, kind, parent, start_line, end_line, signature"
    private static let edgeColumns = "id, src_id, dst_id, dst_name, kind"

    private enum Bind { case text(String); case int(Int); case int64(Int64) }

    private func bind(_ stmt: OpaquePointer?, _ values: [Bind]) {
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, _swift_sqlite_transient)
            case .int(let n): sqlite3_bind_int(stmt, idx, Int32(n))
            case .int64(let n): sqlite3_bind_int64(stmt, idx, n)
            }
        }
    }

    private func querySymbols(sql: String, bind values: [Bind]) throws -> [SymbolRow] {
        guard let db else { throw StoreError.databaseNotOpen }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqliteError("query prepare", sqlite3_errcode(db))
        }
        bind(stmt, values)
        var rows: [SymbolRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let row = Self.parseSymbolRow(stmt) { rows.append(row) }
        }
        return rows
    }

    private func queryEdges(sql: String, bind values: [Bind]) throws -> [EdgeRow] {
        guard let db else { throw StoreError.databaseNotOpen }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqliteError("edge query prepare", sqlite3_errcode(db))
        }
        bind(stmt, values)
        var rows: [EdgeRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(EdgeRow(
                id: sqlite3_column_int64(stmt, 0),
                srcId: sqlite3_column_int64(stmt, 1),
                dstId: sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 2),
                dstName: sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "",
                kind: sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            ))
        }
        return rows
    }

    private static func parseSymbolRow(_ stmt: OpaquePointer?) -> SymbolRow? {
        guard let stmt else { return nil }
        guard let symbolKey = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
              let path = sqlite3_column_text(stmt, 2).map({ String(cString: $0) }),
              let name = sqlite3_column_text(stmt, 3).map({ String(cString: $0) }),
              let kind = sqlite3_column_text(stmt, 4).map({ String(cString: $0) })
        else { return nil }
        let parent = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
        let signature = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
        return SymbolRow(
            id: sqlite3_column_int64(stmt, 0), symbolKey: symbolKey, path: path, name: name, kind: kind,
            parent: parent, startLine: Int(sqlite3_column_int64(stmt, 6)), endLine: Int(sqlite3_column_int64(stmt, 7)),
            signature: signature
        )
    }

    private func exec(_ sql: String) throws {
        guard let db else { throw StoreError.databaseNotOpen }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw StoreError.sqliteError(msg, rc)
        }
    }

    private func upsertFileRow(path: String, contentHash: String, language: String, symbolCount: Int) throws {
        guard let db else { throw StoreError.databaseNotOpen }
        let sql = """
            INSERT INTO cg_files (path, content_hash, language, indexed_at, symbol_count)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET
                content_hash = excluded.content_hash,
                language = excluded.language,
                indexed_at = excluded.indexed_at,
                symbol_count = excluded.symbol_count;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqliteError("file upsert prepare", sqlite3_errcode(db))
        }
        sqlite3_bind_text(stmt, 1, path, -1, _swift_sqlite_transient)
        sqlite3_bind_text(stmt, 2, contentHash, -1, _swift_sqlite_transient)
        sqlite3_bind_text(stmt, 3, language, -1, _swift_sqlite_transient)
        sqlite3_bind_int64(stmt, 4, Int64(Date().timeIntervalSince1970))
        sqlite3_bind_int(stmt, 5, Int32(symbolCount))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.sqliteError("file upsert step", sqlite3_errcode(db))
        }
    }

    private func deleteSymbols(forPath path: String) throws {
        guard let db else { throw StoreError.databaseNotOpen }
        let sql = "DELETE FROM cg_symbols WHERE path = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqliteError("delete symbols prepare", sqlite3_errcode(db))
        }
        sqlite3_bind_text(stmt, 1, path, -1, _swift_sqlite_transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.sqliteError("delete symbols step", sqlite3_errcode(db))
        }
    }

    /// Inserts (or, on a `symbol_key` collision — e.g. two overloads that
    /// happen to lexically resolve to the same arity — updates) one symbol
    /// row, then reads back its id explicitly rather than trusting
    /// `sqlite3_last_insert_rowid()` (which is not reliable across an
    /// `ON CONFLICT DO UPDATE` path).
    private func insertSymbol(
        symbolKey: String, path: String, name: String, kind: String,
        parent: String?, startLine: Int, endLine: Int, signature: String?
    ) throws -> Int64 {
        guard let db else { throw StoreError.databaseNotOpen }
        let sql = """
            INSERT INTO cg_symbols (symbol_key, path, name, kind, parent, start_line, end_line, signature)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(symbol_key) DO UPDATE SET
                path = excluded.path, name = excluded.name, kind = excluded.kind,
                parent = excluded.parent, start_line = excluded.start_line,
                end_line = excluded.end_line, signature = excluded.signature;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqliteError("symbol insert prepare", sqlite3_errcode(db))
        }
        sqlite3_bind_text(stmt, 1, symbolKey, -1, _swift_sqlite_transient)
        sqlite3_bind_text(stmt, 2, path, -1, _swift_sqlite_transient)
        sqlite3_bind_text(stmt, 3, name, -1, _swift_sqlite_transient)
        sqlite3_bind_text(stmt, 4, kind, -1, _swift_sqlite_transient)
        if let parent { sqlite3_bind_text(stmt, 5, parent, -1, _swift_sqlite_transient) } else { sqlite3_bind_null(stmt, 5) }
        sqlite3_bind_int64(stmt, 6, Int64(startLine))
        sqlite3_bind_int64(stmt, 7, Int64(endLine))
        if let signature { sqlite3_bind_text(stmt, 8, signature, -1, _swift_sqlite_transient) } else { sqlite3_bind_null(stmt, 8) }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.sqliteError("symbol insert step", sqlite3_errcode(db))
        }

        var idStmt: OpaquePointer?
        defer { sqlite3_finalize(idStmt) }
        guard sqlite3_prepare_v2(db, "SELECT id FROM cg_symbols WHERE symbol_key = ?;", -1, &idStmt, nil) == SQLITE_OK else {
            throw StoreError.sqliteError("symbol id prepare", sqlite3_errcode(db))
        }
        sqlite3_bind_text(idStmt, 1, symbolKey, -1, _swift_sqlite_transient)
        guard sqlite3_step(idStmt) == SQLITE_ROW else {
            throw StoreError.sqliteError("symbol id missing after insert", 0)
        }
        return sqlite3_column_int64(idStmt, 0)
    }

    private func insertEdge(srcId: Int64, dstId: Int64?, dstName: String, kind: String) throws {
        guard let db else { throw StoreError.databaseNotOpen }
        let sql = "INSERT INTO cg_edges (src_id, dst_id, dst_name, kind) VALUES (?, ?, ?, ?);"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqliteError("edge insert prepare", sqlite3_errcode(db))
        }
        sqlite3_bind_int64(stmt, 1, srcId)
        if let dstId { sqlite3_bind_int64(stmt, 2, dstId) } else { sqlite3_bind_null(stmt, 2) }
        sqlite3_bind_text(stmt, 3, dstName, -1, _swift_sqlite_transient)
        sqlite3_bind_text(stmt, 4, kind, -1, _swift_sqlite_transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.sqliteError("edge insert step", sqlite3_errcode(db))
        }
    }

    /// Best-effort immediate resolution at insert time: prefers a symbol in
    /// the same file (the common case — a type referencing a sibling defined
    /// earlier/later in the same file), else the first match by id. This is a
    /// documented heuristic, not a type-checked resolution — see
    /// `LexicalSymbolExtractor`'s doc comment and plan §2.1. Unmatched names
    /// stay `nil` (dangling) and are retried by `resolveDanglingEdges` as new
    /// symbols are indexed elsewhere.
    private func lookupSymbolID(byName name: String, preferPath path: String) throws -> Int64? {
        guard let db else { throw StoreError.databaseNotOpen }
        let sql = "SELECT id FROM cg_symbols WHERE name = ? ORDER BY (path = ?) DESC, id ASC LIMIT 1;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqliteError("lookup prepare", sqlite3_errcode(db))
        }
        sqlite3_bind_text(stmt, 1, name, -1, _swift_sqlite_transient)
        sqlite3_bind_text(stmt, 2, path, -1, _swift_sqlite_transient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    /// Escape a free-form query for FTS5 by wrapping each token in double
    /// quotes — mirrors `HybridKnowledgeStore.escapeFTS`.
    static func escapeFTS(_ query: String) -> String {
        let parts = query
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return "\"\"" }
        return parts.map { "\"\($0)\"" }.joined(separator: " ")
    }

    /// Prefix-query variant for `searchSymbols`: each token becomes `token*`
    /// (an FTS5 prefix match) instead of an exact phrase, so a partial name
    /// like "Repository" finds `RepositoryManager`. Falls back to a quoted
    /// phrase for tokens with no alphanumeric characters (avoids emitting a
    /// bare `*`, which FTS5 rejects).
    static func escapeFTSPrefix(_ query: String) -> String {
        let parts = query
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return "" }
        return parts.map { token -> String in
            let sanitized = token.filter { $0.isLetter || $0.isNumber || $0 == "_" }
            return sanitized.isEmpty ? "\"\(token)\"" : "\(sanitized)*"
        }.joined(separator: " ")
    }
}

/// SHA-256 content hash, shared by `CodeGraphIndexer` (extracted here so the
/// store's file-hash comparisons and the indexer's disk-read hashing always
/// agree on the exact same algorithm).
public enum CodeGraphHasher {
    public static func sha256(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
