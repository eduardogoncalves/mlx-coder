// Sources/Memory/Hybrid/HybridKnowledgeStore.swift
// SQLite + FTS5 + embedding hybrid memory store with self-improvement hooks.

import Foundation
import CSQLite
import CryptoKit

/// Thread-safe hybrid memory store.
///
/// Provides:
///  - structured `memory_documents` table with confidence/version/supersedes lineage,
///  - FTS5 lexical index (`memory_fts`),
///  - cosine-similarity vector search backed by a BLOB column compatible
///    with `sqlite-vec`'s `vec0` packing (so future migration is a no-op),
///  - hybrid retrieval (FTS + vec → RRF → reranker),
///  - consolidation (exact + near-duplicate merge) and decay/pruning.
///
/// Designed for **edge / MLX context**: zero new SPM dependencies, uses only
/// system-linked SQLite via `CSQLite`. The embedding provider is pluggable.
public actor HybridKnowledgeStore {

    // MARK: - Configuration

    public struct Config: Sendable {
        public var topNLexical: Int
        public var topNSemantic: Int
        public var rerankK: Int
        public var weightLexical: Double
        public var weightSemantic: Double
        public var rrfK: Double
        public var rerankBudget: TimeInterval
        public var nearDuplicateCosineThreshold: Double
        public var nearDuplicateTokenJaccardThreshold: Double

        public init(
            topNLexical: Int = 40,
            topNSemantic: Int = 40,
            rerankK: Int = 20,
            weightLexical: Double = 0.45,
            weightSemantic: Double = 0.55,
            rrfK: Double = 60,
            // 120 ms keeps the pipeline interactive (well under the agent
            // turn budget) while leaving headroom for a heavier reranker if
            // one is plugged in later. The default `LexicalReranker` runs
            // far below this; the budget is a ceiling, not a target.
            rerankBudget: TimeInterval = 0.12,
            nearDuplicateCosineThreshold: Double = 0.85,
            nearDuplicateTokenJaccardThreshold: Double = 0.7
        ) {
            self.topNLexical = topNLexical
            self.topNSemantic = topNSemantic
            self.rerankK = rerankK
            self.weightLexical = weightLexical
            self.weightSemantic = weightSemantic
            self.rrfK = rrfK
            self.rerankBudget = rerankBudget
            self.nearDuplicateCosineThreshold = nearDuplicateCosineThreshold
            self.nearDuplicateTokenJaccardThreshold = nearDuplicateTokenJaccardThreshold
        }

        public static let `default` = Config()
    }

    public enum StoreError: Error, CustomStringConvertible {
        case databaseNotOpen
        case sqliteError(String, Int32)
        case invalidData(String)

        public var description: String {
            switch self {
            case .databaseNotOpen:
                return "Database not open"
            case .sqliteError(let msg, let code):
                return "SQLite error (\(code)): \(msg)"
            case .invalidData(let msg):
                return "Invalid data: \(msg)"
            }
        }
    }

    /// Outcome of a `write` call.
    public enum WriteOutcome: Sendable, Equatable {
        /// New document inserted at `id`.
        case inserted(id: Int64, uuid: UUID)
        /// Existing document `id` updated; new revision at `newID`.
        case superseded(oldID: Int64, newID: Int64, uuid: UUID)
        /// Exact duplicate found (by content_hash); existing `id` retained.
        case duplicate(id: Int64, uuid: UUID)
    }

    // MARK: - State

    private let dbPath: String
    private let embedder: EmbeddingProvider
    private let reranker: Reranker
    public let config: Config
    private var db: OpaquePointer?

    public init(
        dbPath: String? = nil,
        embedder: EmbeddingProvider = HashEmbeddingProvider(),
        reranker: Reranker = LexicalReranker(),
        config: Config = .default
    ) {
        if let dbPath {
            self.dbPath = dbPath
        } else {
            let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
            let mlxCoderDir = (homeDir as NSString).appendingPathComponent(".mlx-coder")
            try? FileManager.default.createDirectory(
                atPath: mlxCoderDir, withIntermediateDirectories: true)
            self.dbPath = (mlxCoderDir as NSString).appendingPathComponent("hybrid_memory.db")
        }
        self.embedder = embedder
        self.reranker = reranker
        self.config = config
    }

    // MARK: - Lifecycle

    /// Open the database connection and apply the schema.
    public func initialize() throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(dbPath, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            throw StoreError.sqliteError("Failed to open database", rc)
        }
        self.db = handle

        for pragma in HybridSchema.pragmas { try exec(pragma) }
        for stmt in HybridSchema.statements { try exec(stmt) }
    }

    public func close() {
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    /// Look up a document's UUID by its row id. Returns `nil` if the id is
    /// unknown. Provided so external callers (notably `Reflector`) can report
    /// accurate provenance after a `superseded` outcome.
    public func documentUUID(forID id: Int64) throws -> UUID? {
        guard db != nil else { throw StoreError.databaseNotOpen }
        return try? fetchUUID(id: id)
    }

    // MARK: - Public API

    /// Persist a document, optionally superseding a near-duplicate.
    @discardableResult
    public func write(_ input: DocumentInput) async throws -> WriteOutcome {
        guard db != nil else { throw StoreError.databaseNotOpen }

        let normalizedContent = HashEmbeddingProvider.normalize(input.content)
        let contentHash = sha256(normalizedContent)

        // 1) exact-dedup short-circuit
        if let existing = try findExactDuplicate(
            projectRoot: input.projectRoot,
            memoryType: input.memoryType,
            knowledgeKind: input.knowledgeKind,
            contentHash: contentHash
        ) {
            try touch(id: existing.id)
            return .duplicate(id: existing.id, uuid: existing.uuid)
        }

        // 2) compute embedding and search for near-duplicate to potentially supersede
        let embedding = try await embedder.embed(input.content)
        let scope = RetrievalScope(
            projectRoot: input.projectRoot,
            memoryTypes: [input.memoryType],
            knowledgeKinds: [input.knowledgeKind]
        )
        let nearDup = try await findNearDuplicate(
            queryEmbedding: embedding,
            queryContent: input.content,
            scope: scope
        )

        let now = Date()
        let expiresAt: Date? = input.ttl.map { now.addingTimeInterval($0) }

        if let near = nearDup, input.confidence >= near.confidence {
            // Supersede: insert new version pointing at old, mark old superseded.
            let newID = try insertDocument(
                input: input,
                normalizedContent: normalizedContent,
                contentHash: contentHash,
                supersedesID: near.id,
                version: near.version + 1,
                createdAt: now,
                expiresAt: expiresAt
            )
            try writeMetadata(docID: newID, input: input)
            try insertFTS(rowID: newID, content: input.content,
                          tags: input.tags, entities: input.entities)
            try writeEmbedding(docID: newID, vector: embedding)
            try setStatus(id: near.id, status: .superseded)
            let uuid = try fetchUUID(id: newID)
            return .superseded(oldID: near.id, newID: newID, uuid: uuid)
        }

        // 3) plain append
        let newID = try insertDocument(
            input: input,
            normalizedContent: normalizedContent,
            contentHash: contentHash,
            supersedesID: nil,
            version: 1,
            createdAt: now,
            expiresAt: expiresAt
        )
        try writeMetadata(docID: newID, input: input)
        try insertFTS(rowID: newID, content: input.content,
                      tags: input.tags, entities: input.entities)
        try writeEmbedding(docID: newID, vector: embedding)
        let uuid = try fetchUUID(id: newID)
        return .inserted(id: newID, uuid: uuid)
    }

    /// Hybrid retrieval: FTS5 + vector → RRF → reranker.
    public func retrieve(
        query: String,
        scope: RetrievalScope,
        limit: Int = 10
    ) async throws -> [ScoredDocument] {
        guard db != nil else { throw StoreError.databaseNotOpen }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Lexical
        let lexicalIDs = (try? ftsSearch(query: trimmed, scope: scope,
                                         limit: config.topNLexical)) ?? []

        // Semantic
        let queryVec = try await embedder.embed(trimmed)
        let semanticHits = try vectorSearch(queryEmbedding: queryVec,
                                            scope: scope,
                                            limit: config.topNSemantic)
        let semanticIDs = semanticHits.map(\.0)
        let semanticScoreByID = Dictionary(uniqueKeysWithValues: semanticHits)

        // Fusion
        let fusedIDs = RankFusion.fuseTop(
            lexical: lexicalIDs,
            semantic: semanticIDs,
            weightLexical: config.weightLexical,
            weightSemantic: config.weightSemantic,
            k: config.rrfK,
            topN: config.rerankK
        )
        guard !fusedIDs.isEmpty else { return [] }

        // Hydrate full docs and assemble scored candidates
        let docs = try fetchDocuments(ids: fusedIDs)
        let lexRankByID: [Int64: Int] = Dictionary(
            uniqueKeysWithValues: lexicalIDs.enumerated().map { ($1, $0) })

        var candidates: [ScoredDocument] = []
        candidates.reserveCapacity(docs.count)
        for doc in docs {
            let lexRank = lexRankByID[doc.id]
            let lexScore: Double? = lexRank.map { 1.0 / Double($0 + 1) }
            let semScore: Double? = semanticScoreByID[doc.id]
            // We compute the fused score from per-source *scores*, not ranks;
            // the rank dictionaries above are only needed for lexScore (BM25
            // rank is opaque, so we approximate with reciprocal-rank score).
            let fused: Double = (lexScore ?? 0) * config.weightLexical
                              + (semScore ?? 0) * config.weightSemantic
            candidates.append(ScoredDocument(
                document: doc,
                lexicalScore: lexScore,
                semanticScore: semScore,
                fusedScore: fused
            ))
        }

        // Rerank
        let reranked = await reranker.rerank(
            query: trimmed,
            candidates: candidates,
            timeBudget: config.rerankBudget
        )

        // Touch access counters for the final winners
        let winners = Array(reranked.prefix(limit))
        for w in winners {
            try? touch(id: w.document.id)
        }
        return winners
    }

    /// Mark expired or low-value documents.
    /// Returns the number of rows affected.
    @discardableResult
    public func prune(now: Date = Date()) throws -> Int {
        guard let db else { throw StoreError.databaseNotOpen }
        let nowEpoch = Int64(now.timeIntervalSince1970)

        // Hard-delete working memory whose TTL has lapsed.
        let workingDeleted = try execWithBoundEpoch(
            sql: """
                DELETE FROM memory_documents
                WHERE memory_type = 'working'
                  AND expires_at IS NOT NULL
                  AND expires_at < ?;
            """,
            epoch: nowEpoch
        )

        // Archive episodic memory whose TTL has lapsed (preserve history).
        let episodicArchived = try execWithBoundEpoch(
            sql: """
                UPDATE memory_documents
                SET status = 'archived', updated_at = ?
                WHERE memory_type = 'episodic'
                  AND status = 'active'
                  AND expires_at IS NOT NULL
                  AND expires_at < ?;
            """,
            epochs: [nowEpoch, nowEpoch]
        )

        return workingDeleted + episodicArchived
    }

    /// Single-binding convenience for `prune`'s parameterized statements.
    private func execWithBoundEpoch(sql: String, epoch: Int64) throws -> Int {
        try execWithBoundEpoch(sql: sql, epochs: [epoch])
    }

    /// Multi-binding variant for `prune`'s parameterized statements.
    private func execWithBoundEpoch(sql: String, epochs: [Int64]) throws -> Int {
        guard let db else { throw StoreError.databaseNotOpen }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqliteError("prune prepare", sqlite3_errcode(db))
        }
        for (i, epoch) in epochs.enumerated() {
            sqlite3_bind_int64(stmt, Int32(i + 1), epoch)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.sqliteError("prune step", sqlite3_errcode(db))
        }
        return Int(sqlite3_changes(db))
    }

    /// Run a consolidation pass: find near-duplicates within scope and
    /// supersede the lower-confidence sibling. Returns the number of merges.
    @discardableResult
    public func consolidate(scope: RetrievalScope) async throws -> Int {
        guard db != nil else { throw StoreError.databaseNotOpen }
        let docs = try fetchActiveDocuments(scope: scope, limit: 500)
        var embeddings: [Int64: [Float]] = [:]
        for doc in docs {
            if let vec = try fetchEmbedding(docID: doc.id) {
                embeddings[doc.id] = vec
            }
        }

        var merged = 0
        var supersededIDs = Set<Int64>()
        // O(n^2) scan — acceptable for n<=500; callers should scope.
        outer: for i in 0..<docs.count {
            let a = docs[i]
            if supersededIDs.contains(a.id) { continue }
            guard let va = embeddings[a.id] else { continue }
            for j in (i + 1)..<docs.count {
                let b = docs[j]
                if supersededIDs.contains(b.id) { continue }
                guard let vb = embeddings[b.id] else { continue }
                let cos = HashEmbeddingProvider.cosine(va, vb)
                guard cos >= config.nearDuplicateCosineThreshold else { continue }

                let aTokens = LexicalReranker.tokens(in: a.content)
                let bTokens = LexicalReranker.tokens(in: b.content)
                let jacc = LexicalReranker.jaccard(aTokens, bTokens)
                guard jacc >= config.nearDuplicateTokenJaccardThreshold else { continue }

                // Higher confidence (then newer) survives.
                let aWins = (a.confidence > b.confidence) ||
                            (a.confidence == b.confidence && a.updatedAt >= b.updatedAt)
                let winner = aWins ? a : b
                let loser  = aWins ? b : a
                try linkSupersede(winnerID: winner.id, loserID: loser.id)
                supersededIDs.insert(loser.id)
                merged += 1
                // If `a` lost, stop comparing it further: its vector is now
                // defunct and any further pair (a, k) would be invalid.
                if !aWins { continue outer }
            }
        }
        return merged
    }

    // MARK: - Diagnostics

    public struct Stats: Sendable {
        public let activeCount: Int
        public let supersededCount: Int
        public let archivedCount: Int
        public let embeddingCount: Int
        public let dbSizeBytes: Int64
    }

    public func stats() throws -> Stats {
        guard let db else { throw StoreError.databaseNotOpen }
        func count(_ where_: String) throws -> Int {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT COUNT(*) FROM memory_documents \(where_);"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw StoreError.sqliteError("count prepare", sqlite3_errcode(db))
            }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
        }
        var embStmt: OpaquePointer?
        defer { sqlite3_finalize(embStmt) }
        guard sqlite3_prepare_v2(db,
            "SELECT COUNT(*) FROM memory_embeddings;", -1, &embStmt, nil) == SQLITE_OK else {
            throw StoreError.sqliteError("emb count prepare", sqlite3_errcode(db))
        }
        let embCount = sqlite3_step(embStmt) == SQLITE_ROW ? Int(sqlite3_column_int(embStmt, 0)) : 0

        let fileSize: Int64 =
            (try? FileManager.default.attributesOfItem(atPath: dbPath)[.size] as? Int64) ?? 0

        return Stats(
            activeCount: try count("WHERE status = 'active'"),
            supersededCount: try count("WHERE status = 'superseded'"),
            archivedCount: try count("WHERE status = 'archived'"),
            embeddingCount: embCount,
            dbSizeBytes: fileSize
        )
    }

    // MARK: - Internal SQL helpers

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

    private func sha256(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private struct DupHit {
        let id: Int64
        let uuid: UUID
        let confidence: Double
        let version: Int
    }

    private func findExactDuplicate(
        projectRoot: String,
        memoryType: MemoryType,
        knowledgeKind: KnowledgeKind,
        contentHash: String
    ) throws -> DupHit? {
        guard let db else { throw StoreError.databaseNotOpen }
        let sql = """
            SELECT id, doc_uuid, confidence, version
            FROM memory_documents
            WHERE project_root = ? AND memory_type = ? AND knowledge_kind = ?
              AND content_hash = ? AND status = 'active'
            LIMIT 1;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqliteError("dup prepare", sqlite3_errcode(db))
        }
        sqlite3_bind_text(stmt, 1, projectRoot, -1, _swift_sqlite_transient)
        sqlite3_bind_text(stmt, 2, memoryType.rawValue, -1, _swift_sqlite_transient)
        sqlite3_bind_text(stmt, 3, knowledgeKind.rawValue, -1, _swift_sqlite_transient)
        sqlite3_bind_text(stmt, 4, contentHash, -1, _swift_sqlite_transient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let uuidStr = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
              let uuid = UUID(uuidString: uuidStr) else { return nil }
        return DupHit(
            id: sqlite3_column_int64(stmt, 0),
            uuid: uuid,
            confidence: sqlite3_column_double(stmt, 2),
            version: Int(sqlite3_column_int(stmt, 3))
        )
    }

    private func findNearDuplicate(
        queryEmbedding: [Float],
        queryContent: String,
        scope: RetrievalScope
    ) async throws -> DupHit? {
        // Pull active candidates within scope and run cosine + jaccard gates.
        let docs = try fetchActiveDocuments(scope: scope, limit: 200)
        let queryTokens = LexicalReranker.tokens(in: queryContent)
        for doc in docs {
            guard let vec = try fetchEmbedding(docID: doc.id) else { continue }
            let cos = HashEmbeddingProvider.cosine(queryEmbedding, vec)
            guard cos >= config.nearDuplicateCosineThreshold else { continue }
            let jacc = LexicalReranker.jaccard(
                queryTokens, LexicalReranker.tokens(in: doc.content))
            guard jacc >= config.nearDuplicateTokenJaccardThreshold else { continue }
            return DupHit(
                id: doc.id, uuid: doc.uuid,
                confidence: doc.confidence, version: doc.version
            )
        }
        return nil
    }

    private func insertDocument(
        input: DocumentInput,
        normalizedContent: String,
        contentHash: String,
        supersedesID: Int64?,
        version: Int,
        createdAt: Date,
        expiresAt: Date?
    ) throws -> Int64 {
        guard let db else { throw StoreError.databaseNotOpen }
        let sql = """
            INSERT INTO memory_documents (
                doc_uuid, memory_type, knowledge_kind,
                content, content_norm, content_hash,
                source, project_root, branch, surface,
                confidence, importance, status, version,
                supersedes_id, created_at, updated_at, expires_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqliteError("insert prepare", sqlite3_errcode(db))
        }
        let uuid = UUID().uuidString
        let createdEpoch = Int64(createdAt.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 1, uuid, -1, _swift_sqlite_transient)
        sqlite3_bind_text(stmt, 2, input.memoryType.rawValue, -1, _swift_sqlite_transient)
        sqlite3_bind_text(stmt, 3, input.knowledgeKind.rawValue, -1, _swift_sqlite_transient)
        sqlite3_bind_text(stmt, 4, input.content, -1, _swift_sqlite_transient)
        sqlite3_bind_text(stmt, 5, normalizedContent, -1, _swift_sqlite_transient)
        sqlite3_bind_text(stmt, 6, contentHash, -1, _swift_sqlite_transient)
        sqlite3_bind_text(stmt, 7, input.source.rawValue, -1, _swift_sqlite_transient)
        sqlite3_bind_text(stmt, 8, input.projectRoot, -1, _swift_sqlite_transient)
        if let branch = input.branch {
            sqlite3_bind_text(stmt, 9, branch, -1, _swift_sqlite_transient)
        } else { sqlite3_bind_null(stmt, 9) }
        if let surface = input.surface {
            sqlite3_bind_text(stmt, 10, surface, -1, _swift_sqlite_transient)
        } else { sqlite3_bind_null(stmt, 10) }
        sqlite3_bind_double(stmt, 11, input.confidence)
        sqlite3_bind_double(stmt, 12, input.importance)
        sqlite3_bind_int(stmt, 13, Int32(version))
        if let supersedesID {
            sqlite3_bind_int64(stmt, 14, supersedesID)
        } else { sqlite3_bind_null(stmt, 14) }
        sqlite3_bind_int64(stmt, 15, createdEpoch)
        sqlite3_bind_int64(stmt, 16, createdEpoch)
        if let expiresAt {
            sqlite3_bind_int64(stmt, 17, Int64(expiresAt.timeIntervalSince1970))
        } else { sqlite3_bind_null(stmt, 17) }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.sqliteError("insert step", sqlite3_errcode(db))
        }
        return sqlite3_last_insert_rowid(db)
    }

    private func writeMetadata(docID: Int64, input: DocumentInput) throws {
        guard let db else { throw StoreError.databaseNotOpen }
        let tagsJSON = jsonString(from: input.tags) ?? "[]"
        let entitiesJSON = jsonString(from: input.entities) ?? "[]"
        let sql = """
            INSERT INTO memory_metadata
                (doc_id, tags_json, entities_json, task_id, session_id, extra_json)
            VALUES (?, ?, ?, ?, ?, '{}')
            ON CONFLICT(doc_id) DO UPDATE SET
                tags_json = excluded.tags_json,
                entities_json = excluded.entities_json,
                task_id = excluded.task_id,
                session_id = excluded.session_id;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqliteError("meta prepare", sqlite3_errcode(db))
        }
        sqlite3_bind_int64(stmt, 1, docID)
        sqlite3_bind_text(stmt, 2, tagsJSON, -1, _swift_sqlite_transient)
        sqlite3_bind_text(stmt, 3, entitiesJSON, -1, _swift_sqlite_transient)
        if let task = input.taskID {
            sqlite3_bind_text(stmt, 4, task, -1, _swift_sqlite_transient)
        } else { sqlite3_bind_null(stmt, 4) }
        if let session = input.sessionID {
            sqlite3_bind_text(stmt, 5, session, -1, _swift_sqlite_transient)
        } else { sqlite3_bind_null(stmt, 5) }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.sqliteError("meta step", sqlite3_errcode(db))
        }
    }

    private func insertFTS(
        rowID: Int64, content: String, tags: [String], entities: [String]
    ) throws {
        guard let db else { throw StoreError.databaseNotOpen }
        let sql = """
            INSERT INTO memory_fts(rowid, content, tags, entities)
            VALUES (?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqliteError("fts prepare", sqlite3_errcode(db))
        }
        sqlite3_bind_int64(stmt, 1, rowID)
        sqlite3_bind_text(stmt, 2, content, -1, _swift_sqlite_transient)
        sqlite3_bind_text(stmt, 3, tags.joined(separator: " "), -1, _swift_sqlite_transient)
        sqlite3_bind_text(stmt, 4, entities.joined(separator: " "), -1, _swift_sqlite_transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.sqliteError("fts step", sqlite3_errcode(db))
        }
    }

    private func writeEmbedding(docID: Int64, vector: [Float]) throws {
        guard let db else { throw StoreError.databaseNotOpen }
        let blob = EmbeddingBlob.encode(vector)
        let sql = """
            INSERT INTO memory_embeddings (doc_id, model, dim, embedding, created_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(doc_id) DO UPDATE SET
                model = excluded.model,
                dim = excluded.dim,
                embedding = excluded.embedding,
                created_at = excluded.created_at;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqliteError("emb prepare", sqlite3_errcode(db))
        }
        sqlite3_bind_int64(stmt, 1, docID)
        sqlite3_bind_text(stmt, 2, embedder.modelID, -1, _swift_sqlite_transient)
        sqlite3_bind_int(stmt, 3, Int32(embedder.dimension))
        _ = blob.withUnsafeBytes { raw in
            sqlite3_bind_blob(stmt, 4, raw.baseAddress, Int32(blob.count), _swift_sqlite_transient)
        }
        sqlite3_bind_int64(stmt, 5, Int64(Date().timeIntervalSince1970))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.sqliteError("emb step", sqlite3_errcode(db))
        }
    }

    private func ftsSearch(
        query: String, scope: RetrievalScope, limit: Int
    ) throws -> [Int64] {
        guard let db else { throw StoreError.databaseNotOpen }
        let typesIn = scope.memoryTypes.map { "'\($0.rawValue)'" }.joined(separator: ",")
        let kindsIn = scope.knowledgeKinds.map { "'\($0.rawValue)'" }.joined(separator: ",")
        let statusClause = scope.includeSuperseded ? "" : "AND d.status = 'active'"
        let sql = """
            SELECT d.id FROM memory_documents d
            JOIN memory_fts f ON f.rowid = d.id
            WHERE f.content MATCH ?
              AND d.project_root = ?
              AND d.memory_type IN (\(typesIn))
              AND d.knowledge_kind IN (\(kindsIn))
              \(statusClause)
            ORDER BY f.rank
            LIMIT ?;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqliteError("fts search prepare", sqlite3_errcode(db))
        }
        let escapedQuery = HybridKnowledgeStore.escapeFTS(query)
        sqlite3_bind_text(stmt, 1, escapedQuery, -1, _swift_sqlite_transient)
        sqlite3_bind_text(stmt, 2, scope.projectRoot, -1, _swift_sqlite_transient)
        sqlite3_bind_int(stmt, 3, Int32(limit))
        var ids: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            ids.append(sqlite3_column_int64(stmt, 0))
        }
        return ids
    }

    /// Escape a free-form query for FTS5 by wrapping each token in double
    /// quotes — neutralises operator characters (`-`, `:`, `*`, `(`, `)`)
    /// that would otherwise be interpreted as syntax and can cause
    /// `SQLITE_ERROR: malformed MATCH expression`.
    static func escapeFTS(_ query: String) -> String {
        let parts = query
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return "\"\"" }
        return parts.map { "\"\($0)\"" }.joined(separator: " OR ")
    }

    private func vectorSearch(
        queryEmbedding: [Float], scope: RetrievalScope, limit: Int
    ) throws -> [(Int64, Double)] {
        // Pull all in-scope embeddings into memory and compute cosine.
        // For large corpora this is the migration boundary to sqlite-vec.
        guard let db else { throw StoreError.databaseNotOpen }
        let typesIn = scope.memoryTypes.map { "'\($0.rawValue)'" }.joined(separator: ",")
        let kindsIn = scope.knowledgeKinds.map { "'\($0.rawValue)'" }.joined(separator: ",")
        let statusClause = scope.includeSuperseded ? "" : "AND d.status = 'active'"
        let sql = """
            SELECT d.id, e.dim, e.embedding
            FROM memory_documents d
            JOIN memory_embeddings e ON e.doc_id = d.id
            WHERE d.project_root = ?
              AND d.memory_type IN (\(typesIn))
              AND d.knowledge_kind IN (\(kindsIn))
              \(statusClause);
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqliteError("vec search prepare", sqlite3_errcode(db))
        }
        sqlite3_bind_text(stmt, 1, scope.projectRoot, -1, _swift_sqlite_transient)

        var hits: [(Int64, Double)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let dim = Int(sqlite3_column_int(stmt, 1))
            let blobLen = Int(sqlite3_column_bytes(stmt, 2))
            guard let blobPtr = sqlite3_column_blob(stmt, 2) else { continue }
            let data = Data(bytes: blobPtr, count: blobLen)
            guard let vec = EmbeddingBlob.decode(data, dimension: dim) else { continue }
            let score = HashEmbeddingProvider.cosine(queryEmbedding, vec)
            hits.append((id, score))
        }
        hits.sort { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0 < rhs.0
        }
        return Array(hits.prefix(limit))
    }

    private func fetchEmbedding(docID: Int64) throws -> [Float]? {
        guard let db else { throw StoreError.databaseNotOpen }
        let sql = "SELECT dim, embedding FROM memory_embeddings WHERE doc_id = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqliteError("emb fetch prepare", sqlite3_errcode(db))
        }
        sqlite3_bind_int64(stmt, 1, docID)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let dim = Int(sqlite3_column_int(stmt, 0))
        let blobLen = Int(sqlite3_column_bytes(stmt, 1))
        guard let blobPtr = sqlite3_column_blob(stmt, 1) else { return nil }
        let data = Data(bytes: blobPtr, count: blobLen)
        return EmbeddingBlob.decode(data, dimension: dim)
    }

    private func fetchUUID(id: Int64) throws -> UUID {
        guard let db else { throw StoreError.databaseNotOpen }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(
            db, "SELECT doc_uuid FROM memory_documents WHERE id = ?;", -1, &stmt, nil
        ) == SQLITE_OK else {
            throw StoreError.sqliteError("uuid prepare", sqlite3_errcode(db))
        }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let str = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
              let uuid = UUID(uuidString: str) else {
            throw StoreError.invalidData("missing uuid for id \(id)")
        }
        return uuid
    }

    private func fetchDocuments(ids: [Int64]) throws -> [MemoryDocument] {
        guard !ids.isEmpty else { return [] }
        guard let db else { throw StoreError.databaseNotOpen }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT d.id, d.doc_uuid, d.memory_type, d.knowledge_kind,
                   d.content, d.content_hash, d.source, d.project_root,
                   d.branch, d.surface, d.confidence, d.importance,
                   d.status, d.version, d.supersedes_id,
                   d.created_at, d.updated_at, d.expires_at,
                   d.last_access_at, d.access_count,
                   m.tags_json, m.entities_json, m.session_id, m.task_id, m.feedback_score
            FROM memory_documents d
            LEFT JOIN memory_metadata m ON m.doc_id = d.id
            WHERE d.id IN (\(placeholders));
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqliteError("hydrate prepare", sqlite3_errcode(db))
        }
        for (i, id) in ids.enumerated() {
            sqlite3_bind_int64(stmt, Int32(i + 1), id)
        }
        var byID: [Int64: MemoryDocument] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let doc = parseDocument(stmt: stmt) {
                byID[doc.id] = doc
            }
        }
        // Preserve fused order
        return ids.compactMap { byID[$0] }
    }

    private func fetchActiveDocuments(scope: RetrievalScope, limit: Int) throws -> [MemoryDocument] {
        guard let db else { throw StoreError.databaseNotOpen }
        let typesIn = scope.memoryTypes.map { "'\($0.rawValue)'" }.joined(separator: ",")
        let kindsIn = scope.knowledgeKinds.map { "'\($0.rawValue)'" }.joined(separator: ",")
        let sql = """
            SELECT d.id, d.doc_uuid, d.memory_type, d.knowledge_kind,
                   d.content, d.content_hash, d.source, d.project_root,
                   d.branch, d.surface, d.confidence, d.importance,
                   d.status, d.version, d.supersedes_id,
                   d.created_at, d.updated_at, d.expires_at,
                   d.last_access_at, d.access_count,
                   m.tags_json, m.entities_json, m.session_id, m.task_id, m.feedback_score
            FROM memory_documents d
            LEFT JOIN memory_metadata m ON m.doc_id = d.id
            WHERE d.project_root = ?
              AND d.status = 'active'
              AND d.memory_type IN (\(typesIn))
              AND d.knowledge_kind IN (\(kindsIn))
            ORDER BY d.updated_at DESC
            LIMIT ?;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqliteError("active prepare", sqlite3_errcode(db))
        }
        sqlite3_bind_text(stmt, 1, scope.projectRoot, -1, _swift_sqlite_transient)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var docs: [MemoryDocument] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let doc = parseDocument(stmt: stmt) { docs.append(doc) }
        }
        return docs
    }

    private func parseDocument(stmt: OpaquePointer?) -> MemoryDocument? {
        guard let stmt else { return nil }
        guard
            let uuidStr = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
            let uuid = UUID(uuidString: uuidStr),
            let typeStr = sqlite3_column_text(stmt, 2).map({ String(cString: $0) }),
            let memoryType = MemoryType(rawValue: typeStr),
            let kindStr = sqlite3_column_text(stmt, 3).map({ String(cString: $0) }),
            let kind = KnowledgeKind(rawValue: kindStr),
            let content = sqlite3_column_text(stmt, 4).map({ String(cString: $0) }),
            let hashStr = sqlite3_column_text(stmt, 5).map({ String(cString: $0) }),
            let sourceStr = sqlite3_column_text(stmt, 6).map({ String(cString: $0) }),
            let source = DocumentSource(rawValue: sourceStr),
            let projectRoot = sqlite3_column_text(stmt, 7).map({ String(cString: $0) }),
            let statusStr = sqlite3_column_text(stmt, 12).map({ String(cString: $0) }),
            let status = DocumentStatus(rawValue: statusStr)
        else { return nil }

        let branch = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
        let surface = sqlite3_column_text(stmt, 9).map { String(cString: $0) }
        let supersedesID: Int64? =
            sqlite3_column_type(stmt, 14) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 14)
        let expiresAt: Date? =
            sqlite3_column_type(stmt, 17) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 17)))
        let lastAccess: Date? =
            sqlite3_column_type(stmt, 18) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 18)))

        let tagsJSON = sqlite3_column_text(stmt, 20).map { String(cString: $0) } ?? "[]"
        let entitiesJSON = sqlite3_column_text(stmt, 21).map { String(cString: $0) } ?? "[]"
        let sessionID = sqlite3_column_text(stmt, 22).map { String(cString: $0) }
        let taskID = sqlite3_column_text(stmt, 23).map { String(cString: $0) }
        let feedback: Double? =
            sqlite3_column_type(stmt, 24) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 24)

        let tags = (try? JSONDecoder().decode([String].self, from: Data(tagsJSON.utf8))) ?? []
        let entities = (try? JSONDecoder().decode([String].self, from: Data(entitiesJSON.utf8))) ?? []

        return MemoryDocument(
            id: sqlite3_column_int64(stmt, 0),
            uuid: uuid,
            memoryType: memoryType,
            knowledgeKind: kind,
            content: content,
            contentHash: hashStr,
            source: source,
            projectRoot: projectRoot,
            branch: branch,
            surface: surface,
            confidence: sqlite3_column_double(stmt, 10),
            importance: sqlite3_column_double(stmt, 11),
            status: status,
            version: Int(sqlite3_column_int(stmt, 13)),
            supersedesID: supersedesID,
            createdAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 15))),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 16))),
            expiresAt: expiresAt,
            lastAccessAt: lastAccess,
            accessCount: Int(sqlite3_column_int(stmt, 19)),
            tags: tags,
            entities: entities,
            sessionID: sessionID,
            taskID: taskID,
            feedbackScore: feedback
        )
    }

    private func touch(id: Int64) throws {
        guard let db else { throw StoreError.databaseNotOpen }
        let now = Int64(Date().timeIntervalSince1970)
        let sql = """
            UPDATE memory_documents
            SET last_access_at = ?, access_count = access_count + 1
            WHERE id = ?;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqliteError("touch prepare", sqlite3_errcode(db))
        }
        sqlite3_bind_int64(stmt, 1, now)
        sqlite3_bind_int64(stmt, 2, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.sqliteError("touch step", sqlite3_errcode(db))
        }
    }

    private func setStatus(id: Int64, status: DocumentStatus) throws {
        guard let db else { throw StoreError.databaseNotOpen }
        let now = Int64(Date().timeIntervalSince1970)
        let sql = """
            UPDATE memory_documents SET status = ?, updated_at = ? WHERE id = ?;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqliteError("status prepare", sqlite3_errcode(db))
        }
        sqlite3_bind_text(stmt, 1, status.rawValue, -1, _swift_sqlite_transient)
        sqlite3_bind_int64(stmt, 2, now)
        sqlite3_bind_int64(stmt, 3, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.sqliteError("status step", sqlite3_errcode(db))
        }
    }

    private func linkSupersede(winnerID: Int64, loserID: Int64) throws {
        // Mark loser superseded; point the winner at it for lineage tracking.
        // We deliberately overwrite an existing supersedes_id on the winner —
        // in a multi-merge round the winner ends up linked to its most-recent
        // predecessor; older predecessors are still recoverable via their own
        // supersedes_id chain (each row carries its own pointer).
        try setStatus(id: loserID, status: .superseded)
        guard let db else { throw StoreError.databaseNotOpen }
        let sql = "UPDATE memory_documents SET supersedes_id = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqliteError("link prepare", sqlite3_errcode(db))
        }
        sqlite3_bind_int64(stmt, 1, loserID)
        sqlite3_bind_int64(stmt, 2, winnerID)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.sqliteError("link step", sqlite3_errcode(db))
        }
    }

    private func jsonString<T: Encodable>(from value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
