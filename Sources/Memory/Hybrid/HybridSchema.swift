// Sources/Memory/Hybrid/HybridSchema.swift
// DDL for the hybrid SQLite memory schema.

import Foundation

/// Centralised schema definition for `HybridKnowledgeStore`.
///
/// Lives in its own file so the schema can be inspected/diffed in isolation
/// from the actor that owns the connection. All statements are idempotent
/// (`IF NOT EXISTS`) so the schema is safe to re-apply at every open.
enum HybridSchema {
    /// PRAGMAs applied at connection open.
    static let pragmas: [String] = [
        "PRAGMA journal_mode=WAL;",
        "PRAGMA synchronous=NORMAL;",
        "PRAGMA foreign_keys=ON;",
    ]

    /// All `CREATE TABLE` / `CREATE INDEX` / `CREATE TRIGGER` statements,
    /// applied in order.
    static let statements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS memory_documents (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            doc_uuid        TEXT NOT NULL UNIQUE,
            memory_type     TEXT NOT NULL CHECK (memory_type IN ('episodic','semantic','working')),
            knowledge_kind  TEXT NOT NULL,
            content         TEXT NOT NULL,
            content_norm    TEXT NOT NULL,
            content_hash    TEXT NOT NULL,
            source          TEXT NOT NULL,
            project_root    TEXT NOT NULL,
            branch          TEXT,
            surface         TEXT,
            confidence      REAL NOT NULL DEFAULT 0.5 CHECK (confidence BETWEEN 0 AND 1),
            importance      REAL NOT NULL DEFAULT 0.5 CHECK (importance BETWEEN 0 AND 1),
            status          TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','superseded','archived','deleted')),
            version         INTEGER NOT NULL DEFAULT 1,
            supersedes_id   INTEGER REFERENCES memory_documents(id) ON DELETE SET NULL,
            created_at      INTEGER NOT NULL,
            updated_at      INTEGER NOT NULL,
            expires_at      INTEGER,
            last_access_at  INTEGER,
            access_count    INTEGER NOT NULL DEFAULT 0
        );
        """,
        """
        CREATE UNIQUE INDEX IF NOT EXISTS idx_mem_dedup
        ON memory_documents(project_root, memory_type, knowledge_kind, content_hash, status);
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_mem_scope
        ON memory_documents(project_root, memory_type, knowledge_kind, created_at DESC);
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_mem_decay
        ON memory_documents(status, expires_at, last_access_at);
        """,
        """
        CREATE TABLE IF NOT EXISTS memory_metadata (
            doc_id          INTEGER PRIMARY KEY REFERENCES memory_documents(id) ON DELETE CASCADE,
            tags_json       TEXT NOT NULL DEFAULT '[]',
            entities_json   TEXT NOT NULL DEFAULT '[]',
            feedback_score  REAL,
            task_id         TEXT,
            session_id      TEXT,
            extra_json      TEXT NOT NULL DEFAULT '{}'
        );
        """,
        // Regular (non-contentless) FTS5 table: content is duplicated, but
        // standard INSERT/DELETE/UPDATE syntax works inside triggers without
        // the awkward `INSERT INTO fts(fts, rowid, ...) VALUES('delete', …)`
        // shape that contentless FTS5 forces on us.
        """
        CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(
            content,
            tags,
            entities,
            tokenize='porter unicode61'
        );
        """,
        """
        CREATE TRIGGER IF NOT EXISTS memory_documents_ad
        AFTER DELETE ON memory_documents BEGIN
            DELETE FROM memory_fts WHERE rowid = old.id;
        END;
        """,
        """
        CREATE TRIGGER IF NOT EXISTS memory_documents_au
        AFTER UPDATE OF content ON memory_documents BEGIN
            UPDATE memory_fts SET content = new.content WHERE rowid = new.id;
        END;
        """,
        // Embeddings stored as BLOBs in a regular table.
        // Layout matches sqlite-vec's float32 little-endian packing so the
        // column can be migrated to a `vec0` virtual table later without
        // re-encoding any data.
        """
        CREATE TABLE IF NOT EXISTS memory_embeddings (
            doc_id      INTEGER PRIMARY KEY REFERENCES memory_documents(id) ON DELETE CASCADE,
            model       TEXT NOT NULL,
            dim         INTEGER NOT NULL,
            embedding   BLOB NOT NULL,
            created_at  INTEGER NOT NULL
        );
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_mem_emb_model
        ON memory_embeddings(model, dim);
        """,
    ]
}
