// Sources/Memory/KnowledgeStore.swift
// SQLite-backed persistent storage for knowledge entries with FTS5 search.

import Foundation
import CSQLite
import CryptoKit

/// Thread-safe persistent store for knowledge entries using SQLite with WAL mode and FTS5.
public actor KnowledgeStore {
    
    /// Shared singleton instance.
    public static let shared = KnowledgeStore()
    
    private var db: OpaquePointer?
    private let dbPath: String
    
    /// Error types for KnowledgeStore operations.
    public enum StoreError: Error, CustomStringConvertible {
        case databaseNotOpen
        case sqliteError(String, Int32)
        case invalidData(String)
        case notFound
        
        public var description: String {
            switch self {
            case .databaseNotOpen:
                return "Database not open"
            case .sqliteError(let msg, let code):
                return "SQLite error (\(code)): \(msg)"
            case .invalidData(let msg):
                return "Invalid data: \(msg)"
            case .notFound:
                return "Entry not found"
            }
        }
    }
    
    public init(dbPath: String? = nil) {
        // Default to ~/.mlx-coder/knowledge.db
        if let dbPath {
            self.dbPath = dbPath
        } else {
            let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
            let mlxCoderDir = (homeDir as NSString).appendingPathComponent(".mlx-coder")
            try? FileManager.default.createDirectory(atPath: mlxCoderDir, withIntermediateDirectories: true)
            self.dbPath = (mlxCoderDir as NSString).appendingPathComponent("knowledge.db")
        }
    }
    
    /// Initialize the database connection and schema.
    public func initialize() throws {
        var db: OpaquePointer?
        
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(dbPath, &db, flags, nil)
        
        guard result == SQLITE_OK, let db else {
            throw StoreError.sqliteError("Failed to open database", result)
        }
        
        self.db = db
        
        // Enable WAL mode for better concurrency
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA synchronous=NORMAL;")
        
        // Create main table
        try execute("""
            CREATE TABLE IF NOT EXISTS knowledge (
                id TEXT PRIMARY KEY,
                type TEXT NOT NULL,
                content TEXT NOT NULL,
                tags TEXT NOT NULL,
                surface TEXT,
                branch TEXT,
                project_root TEXT NOT NULL,
                created_at REAL NOT NULL,
                expires_at REAL,
                content_hash TEXT NOT NULL
            );
        """)
        
        // Create FTS5 virtual table for full-text search
        try execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS knowledge_fts USING fts5(
                content,
                content=knowledge,
                content_rowid=rowid
            );
        """)
        
        // Create triggers to keep FTS5 in sync
        try execute("""
            CREATE TRIGGER IF NOT EXISTS knowledge_ai AFTER INSERT ON knowledge BEGIN
                INSERT INTO knowledge_fts(rowid, content) VALUES (new.rowid, new.content);
            END;
        """)
        
        try execute("""
            CREATE TRIGGER IF NOT EXISTS knowledge_ad AFTER DELETE ON knowledge BEGIN
                DELETE FROM knowledge_fts WHERE rowid = old.rowid;
            END;
        """)
        
        try execute("""
            CREATE TRIGGER IF NOT EXISTS knowledge_au AFTER UPDATE ON knowledge BEGIN
                DELETE FROM knowledge_fts WHERE rowid = old.rowid;
                INSERT INTO knowledge_fts(rowid, content) VALUES (new.rowid, new.content);
            END;
        """)
        
        // Create indices for common queries
        try execute("CREATE INDEX IF NOT EXISTS idx_project_root ON knowledge(project_root);")
        try execute("CREATE INDEX IF NOT EXISTS idx_type ON knowledge(type);")
        try execute("CREATE INDEX IF NOT EXISTS idx_created_at ON knowledge(created_at);")
        try execute("CREATE INDEX IF NOT EXISTS idx_expires_at ON knowledge(expires_at);")
        try execute("CREATE INDEX IF NOT EXISTS idx_surface ON knowledge(surface);")
        try execute("CREATE INDEX IF NOT EXISTS idx_branch ON knowledge(branch);")
        try execute("CREATE INDEX IF NOT EXISTS idx_content_hash ON knowledge(content_hash);")
    }
    
    /// Close the database connection.
    public func close() {
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
    }
    
    /// Execute a SQL statement with no results expected.
    private func execute(_ sql: String) throws {
        guard let db else {
            throw StoreError.databaseNotOpen
        }
        
        var errorMsg: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorMsg)
        
        if result != SQLITE_OK {
            let msg = errorMsg.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorMsg)
            throw StoreError.sqliteError(msg, result)
        }
    }
    
    /// Insert a knowledge entry, deduplicating by content_hash + type + project_root.
    public func insert(_ entry: KnowledgeEntry) throws {
        guard let db else {
            throw StoreError.databaseNotOpen
        }
        
        // Compute content hash for deduplication
        let contentHash = sha256(entry.content)
        
        // Check for duplicate
        let checkSQL = """
            SELECT id FROM knowledge 
            WHERE content_hash = ? AND type = ? AND project_root = ?
            LIMIT 1;
        """
        
        var checkStmt: OpaquePointer?
        defer { sqlite3_finalize(checkStmt) }
        
        guard sqlite3_prepare_v2(db, checkSQL, -1, &checkStmt, nil) == SQLITE_OK else {
            throw StoreError.sqliteError("Failed to prepare duplicate check", sqlite3_errcode(db))
        }
        
        sqlite3_bind_text(checkStmt, 1, contentHash, -1, _swift_sqlite_transient)
        sqlite3_bind_text(checkStmt, 2, entry.type.rawValue, -1, _swift_sqlite_transient)
        sqlite3_bind_text(checkStmt, 3, entry.projectRoot, -1, _swift_sqlite_transient)
        
        if sqlite3_step(checkStmt) == SQLITE_ROW {
            // Duplicate found, skip insertion
            return
        }
        
        // Insert new entry
        let insertSQL = """
            INSERT INTO knowledge (
                id, type, content, tags, surface, branch, project_root, 
                created_at, expires_at, content_hash
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        
        var insertStmt: OpaquePointer?
        defer { sqlite3_finalize(insertStmt) }
        
        guard sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK else {
            throw StoreError.sqliteError("Failed to prepare insert", sqlite3_errcode(db))
        }
        
        let tagsJSON = try JSONEncoder().encode(entry.tags)
        let tagsString = String(data: tagsJSON, encoding: .utf8) ?? "[]"
        
        sqlite3_bind_text(insertStmt, 1, entry.id.uuidString, -1, _swift_sqlite_transient)
        sqlite3_bind_text(insertStmt, 2, entry.type.rawValue, -1, _swift_sqlite_transient)
        sqlite3_bind_text(insertStmt, 3, entry.content, -1, _swift_sqlite_transient)
        sqlite3_bind_text(insertStmt, 4, tagsString, -1, _swift_sqlite_transient)
        
        if let surface = entry.surface {
            sqlite3_bind_text(insertStmt, 5, surface, -1, _swift_sqlite_transient)
        } else {
            sqlite3_bind_null(insertStmt, 5)
        }
        
        if let branch = entry.branch {
            sqlite3_bind_text(insertStmt, 6, branch, -1, _swift_sqlite_transient)
        } else {
            sqlite3_bind_null(insertStmt, 6)
        }
        
        sqlite3_bind_text(insertStmt, 7, entry.projectRoot, -1, _swift_sqlite_transient)
        sqlite3_bind_double(insertStmt, 8, entry.createdAt.timeIntervalSince1970)
        
        if let expiresAt = entry.expiresAt {
            sqlite3_bind_double(insertStmt, 9, expiresAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(insertStmt, 9)
        }
        
        sqlite3_bind_text(insertStmt, 10, contentHash, -1, _swift_sqlite_transient)
        
        guard sqlite3_step(insertStmt) == SQLITE_DONE else {
            throw StoreError.sqliteError("Failed to insert entry", sqlite3_errcode(db))
        }
    }
    
    /// Prune expired entries.
    public func pruneExpired() throws {
        guard let db else {
            throw StoreError.databaseNotOpen
        }
        
        let now = Date().timeIntervalSince1970
        let sql = "DELETE FROM knowledge WHERE expires_at IS NOT NULL AND expires_at < ?;"
        
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqliteError("Failed to prepare prune", sqlite3_errcode(db))
        }
        
        sqlite3_bind_double(stmt, 1, now)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.sqliteError("Failed to prune expired entries", sqlite3_errcode(db))
        }
    }
    
    /// FTS5 full-text search.
    public func search(query: String, projectRoot: String) throws -> [KnowledgeEntry] {
        guard let db else {
            throw StoreError.databaseNotOpen
        }
        
        let sql = """
            SELECT k.* FROM knowledge k
            INNER JOIN knowledge_fts fts ON k.rowid = fts.rowid
            WHERE fts.content MATCH ? AND k.project_root = ?
            ORDER BY fts.rank
            LIMIT 50;
        """
        
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqliteError("Failed to prepare search", sqlite3_errcode(db))
        }
        
        sqlite3_bind_text(stmt, 1, query, -1, _swift_sqlite_transient)
        sqlite3_bind_text(stmt, 2, projectRoot, -1, _swift_sqlite_transient)
        
        return try fetchEntries(from: stmt)
    }
    
    /// Get all entries for a project, optionally filtered by type.
    public func list(projectRoot: String, type: KnowledgeType? = nil, limit: Int = 100) throws -> [KnowledgeEntry] {
        guard let db else {
            throw StoreError.databaseNotOpen
        }
        
        let sql: String
        if let type {
            sql = """
                SELECT * FROM knowledge 
                WHERE project_root = ? AND type = ?
                ORDER BY created_at DESC
                LIMIT ?;
            """
        } else {
            sql = """
                SELECT * FROM knowledge 
                WHERE project_root = ?
                ORDER BY created_at DESC
                LIMIT ?;
            """
        }
        
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqliteError("Failed to prepare list", sqlite3_errcode(db))
        }
        
        sqlite3_bind_text(stmt, 1, projectRoot, -1, _swift_sqlite_transient)
        
        if let type {
            sqlite3_bind_text(stmt, 2, type.rawValue, -1, _swift_sqlite_transient)
            sqlite3_bind_int(stmt, 3, Int32(limit))
        } else {
            sqlite3_bind_int(stmt, 2, Int32(limit))
        }
        
        return try fetchEntries(from: stmt)
    }
    
    /// Delete an entry by ID.
    public func delete(id: UUID) throws {
        guard let db else {
            throw StoreError.databaseNotOpen
        }
        
        let sql = "DELETE FROM knowledge WHERE id = ?;"
        
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqliteError("Failed to prepare delete", sqlite3_errcode(db))
        }
        
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, _swift_sqlite_transient)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.sqliteError("Failed to delete entry", sqlite3_errcode(db))
        }
    }
    
    /// Get database statistics.
    public func stats() throws -> (entryCount: Int, dbSizeBytes: Int64) {
        guard let db else {
            throw StoreError.databaseNotOpen
        }
        
        // Count entries
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM knowledge;", -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqliteError("Failed to prepare count", sqlite3_errcode(db))
        }
        
        var count = 0
        if sqlite3_step(stmt) == SQLITE_ROW {
            count = Int(sqlite3_column_int(stmt, 0))
        }
        
        // Get file size
        let fileSize: Int64
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath),
           let size = attrs[.size] as? Int64 {
            fileSize = size
        } else {
            fileSize = 0
        }
        
        return (count, fileSize)
    }
    
    // MARK: - Private Helpers
    
    private func fetchEntries(from stmt: OpaquePointer?) throws -> [KnowledgeEntry] {
        var entries: [KnowledgeEntry] = []
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let entry = try parseEntry(from: stmt) else {
                continue
            }
            entries.append(entry)
        }
        
        return entries
    }
    
    private func parseEntry(from stmt: OpaquePointer?) throws -> KnowledgeEntry? {
        guard let stmt else { return nil }
        
        guard let idStr = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
              let id = UUID(uuidString: idStr),
              let typeStr = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
              let type = KnowledgeType(rawValue: typeStr),
              let content = sqlite3_column_text(stmt, 2).map({ String(cString: $0) }),
              let tagsJSON = sqlite3_column_text(stmt, 3).map({ String(cString: $0) }),
              let projectRoot = sqlite3_column_text(stmt, 6).map({ String(cString: $0) }) else {
            return nil
        }
        
        let tags = (try? JSONDecoder().decode([String].self, from: Data(tagsJSON.utf8))) ?? []
        let surface = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
        let branch = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
        
        let expiresAt: Date?
        if sqlite3_column_type(stmt, 8) == SQLITE_NULL {
            expiresAt = nil
        } else {
            expiresAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))
        }
        
        return KnowledgeEntry(
            id: id,
            type: type,
            content: content,
            tags: tags,
            surface: surface,
            branch: branch,
            projectRoot: projectRoot,
            createdAt: createdAt,
            expiresAt: expiresAt
        )
    }
    
    private func sha256(_ string: String) -> String {
        let data = Data(string.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}
