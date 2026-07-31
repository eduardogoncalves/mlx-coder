// Sources/CodeGraph/CodeGraphSchema.swift
// DDL for the sibling `codegraph.db` SQLite schema.

import Foundation

/// Centralised schema definition for `CodeGraphStore`.
///
/// Lives in its own file so the schema can be inspected/diffed in isolation
/// from the actor that owns the connection — mirrors `HybridSchema`. All
/// `CREATE` statements are idempotent (`IF NOT EXISTS`) so the schema is safe
/// to re-apply at every open.
///
/// The graph is fully **re-derivable** from source on disk (it is never a
/// system of record), so unlike `HybridSchema` an incompatible shape change
/// doesn't need a migration path: `CodeGraphStore` stamps `PRAGMA user_version`
/// with `schemaVersion` at open and, on mismatch, drops every `cg_*` object and
/// rebuilds from these statements (see plan §3.1, §7).
enum CodeGraphSchema {
    /// Bump whenever the DDL below changes shape (new column, renamed table,
    /// etc.). `CodeGraphStore.initialize()` compares this against the DB's
    /// stored `PRAGMA user_version` and auto drop+rebuilds on mismatch.
    static let schemaVersion: Int32 = 1

    /// PRAGMAs applied at connection open.
    static let pragmas: [String] = [
        "PRAGMA journal_mode=WAL;",
        "PRAGMA synchronous=NORMAL;",
        "PRAGMA foreign_keys=ON;",
    ]

    /// All `CREATE TABLE` / `CREATE INDEX` / `CREATE TRIGGER` statements,
    /// applied in order. Safe to re-run (all idempotent).
    static let statements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS cg_files (
            path         TEXT PRIMARY KEY,
            content_hash TEXT NOT NULL,
            language     TEXT NOT NULL,
            indexed_at   INTEGER NOT NULL,
            symbol_count INTEGER NOT NULL DEFAULT 0
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS cg_symbols (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            symbol_key TEXT NOT NULL UNIQUE,
            path       TEXT NOT NULL REFERENCES cg_files(path) ON DELETE CASCADE,
            name       TEXT NOT NULL,
            kind       TEXT NOT NULL,
            parent     TEXT,
            start_line INTEGER NOT NULL,
            end_line   INTEGER NOT NULL,
            signature  TEXT
        );
        """,
        "CREATE INDEX IF NOT EXISTS idx_cg_symbols_path ON cg_symbols(path);",
        "CREATE INDEX IF NOT EXISTS idx_cg_symbols_name ON cg_symbols(name);",
        "CREATE INDEX IF NOT EXISTS idx_cg_symbols_key ON cg_symbols(symbol_key);",
        """
        CREATE TABLE IF NOT EXISTS cg_edges (
            id       INTEGER PRIMARY KEY AUTOINCREMENT,
            src_id   INTEGER NOT NULL REFERENCES cg_symbols(id) ON DELETE CASCADE,
            dst_id   INTEGER REFERENCES cg_symbols(id) ON DELETE SET NULL,
            dst_name TEXT NOT NULL,
            kind     TEXT NOT NULL
        );
        """,
        "CREATE INDEX IF NOT EXISTS idx_cg_edges_src ON cg_edges(src_id);",
        "CREATE INDEX IF NOT EXISTS idx_cg_edges_dst ON cg_edges(dst_id);",
        // Powers the dangling-in-edge re-resolution query:
        // `SELECT ... FROM cg_edges WHERE dst_id IS NULL AND dst_name = ?`.
        "CREATE INDEX IF NOT EXISTS idx_cg_edges_dst_name ON cg_edges(dst_name);",
        // Plain (non-external-content) FTS5 over symbol names — matches
        // HybridSchema.swift's `memory_fts` shape (§3.3 of the plan): text is
        // duplicated into the FTS table, but standard INSERT/UPDATE/DELETE
        // syntax works inside triggers without the contentless-FTS5 dance, and
        // the index can't desync from `cg_symbols` on delete.
        """
        CREATE VIRTUAL TABLE IF NOT EXISTS cg_symbols_fts USING fts5(
            symbol_key UNINDEXED, name, signature, tokenize='unicode61'
        );
        """,
        """
        CREATE TRIGGER IF NOT EXISTS cg_symbols_ai
        AFTER INSERT ON cg_symbols BEGIN
            INSERT INTO cg_symbols_fts(rowid, symbol_key, name, signature)
            VALUES (new.id, new.symbol_key, new.name, coalesce(new.signature, ''));
        END;
        """,
        """
        CREATE TRIGGER IF NOT EXISTS cg_symbols_ad
        AFTER DELETE ON cg_symbols BEGIN
            DELETE FROM cg_symbols_fts WHERE rowid = old.id;
        END;
        """,
        """
        CREATE TRIGGER IF NOT EXISTS cg_symbols_au
        AFTER UPDATE ON cg_symbols BEGIN
            UPDATE cg_symbols_fts
            SET symbol_key = new.symbol_key, name = new.name, signature = coalesce(new.signature, '')
            WHERE rowid = new.id;
        END;
        """,
    ]

    /// Drops every `cg_*` object (children first, to respect the FK/trigger
    /// dependency order). Used both by the `PRAGMA user_version` mismatch path
    /// in `CodeGraphStore.initialize()` and by `doctor --rebuild-graph`. Safe
    /// because the graph is fully re-derivable from source on disk.
    static let dropStatements: [String] = [
        "DROP TABLE IF EXISTS cg_edges;",
        "DROP TABLE IF EXISTS cg_symbols;",
        "DROP TABLE IF EXISTS cg_symbols_fts;",
        "DROP TABLE IF EXISTS cg_files;",
    ]
}
