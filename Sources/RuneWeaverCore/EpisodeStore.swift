import Foundation

#if canImport(SQLite3)
    import SQLite3
#endif

/// SQLite-backed episodic memory with FTS5 full-text search.
///
/// Schema (`episodes.db` under `~/.runeweaver/memory/`):
/// `episodes(id TEXT PRIMARY KEY, session_id TEXT NOT NULL, role TEXT NOT NULL,
/// content TEXT NOT NULL, timestamp REAL NOT NULL, metadata TEXT)`
/// plus the `episodes_fts` FTS5 index over `content`, kept in sync via
/// triggers. Where the SQLite3 module is unavailable the store falls
/// back to JSON files beside the configured database path so behavior
/// stays identical.
public actor EpisodeStore {
    /// Filesystem path of the SQLite database (or JSON sidecar anchor).
    public let dbPath: String
    /// Summarizer applied when compacting old sessions.
    private let summarizer: EpisodeSummarizer

    /// Creates a store, migrating the schema on first use.
    /// - Parameters:
    ///   - dbPath: SQLite file path. `~` is expanded.
    ///   - summarizer: Summarizer for compaction. Defaults to
    ///     ``defaultEpisodeSummarizer``.
    public init(dbPath: String, summarizer: EpisodeSummarizer? = nil) {
        self.dbPath = dbPath
        self.summarizer = summarizer ?? defaultEpisodeSummarizer
    }

    // MARK: - Writes

    /// Stores one conversation turn.
    /// - Parameters:
    ///   - sessionID: Owning session identifier.
    ///   - role: Who produced the content.
    ///   - content: Text content.
    ///   - metadata: Key/value annotations. Defaults to empty.
    /// - Returns: The stored episode.
    @discardableResult
    public func store(
        sessionID: UUID,
        role: Message.Role,
        content: String,
        metadata: [String: String] = [:]
    ) throws -> Episode {
        let episode = Episode(sessionID: sessionID, role: role, content: content, metadata: metadata)
        try store(episode)
        return episode
    }

    /// Stores an already-constructed episode (upsert by `id`).
    /// - Parameter episode: Episode to persist.
    public func store(_ episode: Episode) throws {
        try EpisodeStoreIO.write(episodes: [episode], dbPath: dbPath, merge: true)
    }

    /// Stores a batch of episodes (upsert by `id`).
    /// - Parameter episodes: Episodes to persist.
    public func store(_ episodes: [Episode]) throws {
        guard !episodes.isEmpty else { return }
        try EpisodeStoreIO.write(episodes: episodes, dbPath: dbPath, merge: true)
    }

    // MARK: - Reads

    /// Returns episodes for one session, oldest first.
    /// - Parameters:
    ///   - sessionID: Owning session identifier.
    ///   - limit: Maximum episodes. Defaults to nil (all).
    /// - Returns: Matching episodes in chronological order.
    public func episodes(for sessionID: UUID, limit: Int? = nil) throws -> [Episode] {
        let all = try EpisodeStoreIO.episodes(sessionID: sessionID, dbPath: dbPath, limit: limit)
        return all.sorted { $0.timestamp < $1.timestamp }
    }

    /// Returns the most recent episodes across all sessions.
    /// - Parameter limit: Maximum episodes. Defaults to 20.
    /// - Returns: Episodes newest first.
    public func recent(limit: Int = 20) throws -> [Episode] {
        try EpisodeStoreIO.recent(dbPath: dbPath, limit: max(1, limit))
    }

    /// Full-text search over episode content.
    ///
    /// Uses the FTS5 index (`porter` tokenizer, BM25 rank) when SQLite
    /// is available; otherwise falls back to case-insensitive token
    /// overlap scoring over the JSON sidecar.
    /// - Parameters:
    ///   - query: Search text.
    ///   - limit: Maximum results. Defaults to 10.
    /// - Returns: Matching episodes, best first. Empty for blank queries.
    public func search(query: String, limit: Int = 10) throws -> [Episode] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try EpisodeStoreIO.search(query: trimmed, dbPath: dbPath, limit: max(1, limit))
    }

    /// All session identifiers that have stored episodes.
    /// - Returns: Session identifiers.
    public func sessionIDs() throws -> [UUID] {
        try EpisodeStoreIO.sessionIDs(dbPath: dbPath)
    }

    /// Total stored episode count.
    /// - Returns: Row count.
    public func count() throws -> Int {
        try EpisodeStoreIO.count(dbPath: dbPath)
    }

    // MARK: - Deletes

    /// Deletes one episode. Missing rows are a no-op.
    /// - Parameter id: Episode identifier.
    public func delete(id: UUID) throws {
        try EpisodeStoreIO.delete(id: id, dbPath: dbPath)
    }

    /// Deletes every episode for a session. Unknown sessions are a no-op.
    /// - Parameter sessionID: Owning session identifier.
    public func deleteSession(_ sessionID: UUID) throws {
        try EpisodeStoreIO.deleteSession(sessionID, dbPath: dbPath)
    }

    /// Deletes all episodes.
    public func clear() throws {
        try EpisodeStoreIO.clear(dbPath: dbPath)
    }

    // MARK: - Auto-summarization

    /// Summarizes sessions whose episodes are older than a cutoff.
    ///
    /// Non-destructive: the store is left untouched and the caller
    /// decides what to do with the returned summaries.
    /// - Parameters:
    ///   - olderThan: Episodes at or before this date are summarized.
    ///   - summarizer: Override summarizer. Defaults to the store's own.
    /// - Returns: One summary per session with old episodes.
    public func summarizeSessions(
        olderThan: Date,
        summarizer: EpisodeSummarizer? = nil
    ) throws -> [EpisodeSummary] {
        let summarize = summarizer ?? self.summarizer
        let old = try EpisodeStoreIO.episodes(olderThan: olderThan, dbPath: dbPath)
        guard !old.isEmpty else { return [] }
        let grouped = Dictionary(grouping: old) { $0.sessionID }
        return grouped.map { sessionID, episodes in
            let sorted = episodes.sorted { $0.timestamp < $1.timestamp }
            let timestamps = sorted.map(\.timestamp)
            return EpisodeSummary(
                sessionID: sessionID,
                summary: summarize(sorted),
                messageCount: sorted.count,
                oldest: timestamps.first ?? olderThan,
                newest: timestamps.last ?? olderThan
            )
        }
        .sorted { $0.oldest < $1.oldest }
    }

    /// Compacts old sessions: summarizes then replaces old rows.
    ///
    /// Each session with episodes at or before `olderThan` is summarized
    /// and its old rows are replaced by a single `system` episode
    /// carrying the summary, so keyword search keeps working while the
    /// table stays small.
    /// - Parameters:
    ///   - olderThan: Episodes at or before this date are compacted.
    ///   - summarizer: Override summarizer. Defaults to the store's own.
    /// - Returns: The summaries that replaced old rows.
    @discardableResult
    public func compactSessions(
        olderThan: Date,
        summarizer: EpisodeSummarizer? = nil
    ) throws -> [EpisodeSummary] {
        let summaries = try summarizeSessions(olderThan: olderThan, summarizer: summarizer)
        guard !summaries.isEmpty else { return [] }
        for summary in summaries {
            try EpisodeStoreIO.deleteSession(beforeOrAt: olderThan, sessionID: summary.sessionID, dbPath: dbPath)
            let replacement = Episode(
                sessionID: summary.sessionID,
                role: .system,
                content: "Summary of \(summary.messageCount) earlier messages: \(summary.summary)",
                metadata: ["compacted": "true"]
            )
            try store(replacement)
        }
        return summaries
    }

    /// Rebuilds the FTS5 index from the `episodes` table.
    ///
    /// Useful after bulk imports or if the index ever drifts from the
    /// table. A no-op for the JSON fallback.
    public func rebuildSearchIndex() throws {
        try EpisodeStoreIO.rebuildFTS(dbPath: dbPath)
    }
}

// MARK: - Store I/O

/// File and SQLite I/O for episodes.
///
/// Prefers the SQLite `episodes` table plus the `episodes_fts` FTS5
/// index when the SQLite3 module is available; otherwise persists each
/// episode as JSON beside the configured database path.
enum EpisodeStoreIO {
    /// Writes episodes (upsert by `id`).
    /// - Parameters:
    ///   - episodes: Episodes to write.
    ///   - dbPath: SQLite path (or JSON sidecar anchor).
    ///   - merge: When false, replaces the whole store atomically.
    ///     Defaults to true for episodic appends.
    static func write(episodes: [Episode], dbPath: String, merge: Bool = true) throws {
        #if canImport(SQLite3)
            try SQLiteEpisodeStore.write(episodes: episodes, dbPath: dbPath, merge: merge)
        #else
            try JSONEpisodeStore.write(episodes: episodes, dbPath: dbPath, merge: merge)
        #endif
    }

    /// Reads one session's episodes, oldest first.
    /// - Parameters:
    ///   - sessionID: Owning session identifier.
    ///   - dbPath: SQLite path (or JSON sidecar anchor).
    ///   - limit: Maximum rows, nil for all.
    /// - Returns: Matching episodes.
    static func episodes(sessionID: UUID, dbPath: String, limit: Int?) throws -> [Episode] {
        #if canImport(SQLite3)
            return try SQLiteEpisodeStore.episodes(sessionID: sessionID, dbPath: dbPath, limit: limit)
        #else
            return try JSONEpisodeStore.episodes(sessionID: sessionID, dbPath: dbPath, limit: limit)
        #endif
    }

    /// Reads episodes at or before a cutoff, oldest first.
    /// - Parameters:
    ///   - olderThan: Inclusive upper bound on `timestamp`.
    ///   - dbPath: SQLite path (or JSON sidecar anchor).
    /// - Returns: Matching episodes.
    static func episodes(olderThan: Date, dbPath: String) throws -> [Episode] {
        #if canImport(SQLite3)
            return try SQLiteEpisodeStore.episodes(olderThan: olderThan, dbPath: dbPath)
        #else
            return try JSONEpisodeStore.episodes(olderThan: olderThan, dbPath: dbPath)
        #endif
    }

    /// Reads the newest episodes across all sessions.
    /// - Parameters:
    ///   - dbPath: SQLite path (or JSON sidecar anchor).
    ///   - limit: Maximum rows.
    /// - Returns: Episodes newest first.
    static func recent(dbPath: String, limit: Int) throws -> [Episode] {
        #if canImport(SQLite3)
            return try SQLiteEpisodeStore.recent(dbPath: dbPath, limit: limit)
        #else
            return try JSONEpisodeStore.recent(dbPath: dbPath, limit: limit)
        #endif
    }

    /// Full-text search over episode content.
    /// - Parameters:
    ///   - query: Search text.
    ///   - dbPath: SQLite path (or JSON sidecar anchor).
    ///   - limit: Maximum results.
    /// - Returns: Matching episodes, best first.
    static func search(query: String, dbPath: String, limit: Int) throws -> [Episode] {
        #if canImport(SQLite3)
            return try SQLiteEpisodeStore.search(query: query, dbPath: dbPath, limit: limit)
        #else
            return try JSONEpisodeStore.search(query: query, dbPath: dbPath, limit: limit)
        #endif
    }

    /// All session identifiers with stored episodes.
    /// - Parameter dbPath: SQLite path (or JSON sidecar anchor).
    /// - Returns: Session identifiers.
    static func sessionIDs(dbPath: String) throws -> [UUID] {
        #if canImport(SQLite3)
            return try SQLiteEpisodeStore.sessionIDs(dbPath: dbPath)
        #else
            return try JSONEpisodeStore.sessionIDs(dbPath: dbPath)
        #endif
    }

    /// Total stored episode count.
    /// - Parameter dbPath: SQLite path (or JSON sidecar anchor).
    /// - Returns: Row count.
    static func count(dbPath: String) throws -> Int {
        #if canImport(SQLite3)
            return try SQLiteEpisodeStore.count(dbPath: dbPath)
        #else
            return try JSONEpisodeStore.count(dbPath: dbPath)
        #endif
    }

    /// Deletes one episode. Missing rows are a no-op.
    /// - Parameters:
    ///   - id: Episode identifier.
    ///   - dbPath: SQLite path (or JSON sidecar anchor).
    static func delete(id: UUID, dbPath: String) throws {
        #if canImport(SQLite3)
            try SQLiteEpisodeStore.delete(id: id, dbPath: dbPath)
        #else
            try JSONEpisodeStore.delete(id: id, dbPath: dbPath)
        #endif
    }

    /// Deletes every episode for a session.
    /// - Parameters:
    ///   - sessionID: Owning session identifier.
    ///   - dbPath: SQLite path (or JSON sidecar anchor).
    static func deleteSession(_ sessionID: UUID, dbPath: String) throws {
        #if canImport(SQLite3)
            try SQLiteEpisodeStore.deleteSession(sessionID, dbPath: dbPath)
        #else
            try JSONEpisodeStore.deleteSession(sessionID, dbPath: dbPath)
        #endif
    }

    /// Deletes one session's episodes at or before a cutoff.
    /// - Parameters:
    ///   - beforeOrAt: Inclusive upper bound on `timestamp`.
    ///   - sessionID: Owning session identifier.
    ///   - dbPath: SQLite path (or JSON sidecar anchor).
    static func deleteSession(beforeOrAt: Date, sessionID: UUID, dbPath: String) throws {
        #if canImport(SQLite3)
            try SQLiteEpisodeStore.deleteSession(beforeOrAt: beforeOrAt, sessionID: sessionID, dbPath: dbPath)
        #else
            try JSONEpisodeStore.deleteSession(beforeOrAt: beforeOrAt, sessionID: sessionID, dbPath: dbPath)
        #endif
    }

    /// Deletes all episodes.
    /// - Parameter dbPath: SQLite path (or JSON sidecar anchor).
    static func clear(dbPath: String) throws {
        #if canImport(SQLite3)
            try SQLiteEpisodeStore.clear(dbPath: dbPath)
        #else
            try JSONEpisodeStore.clear(dbPath: dbPath)
        #endif
    }

    /// Rebuilds the FTS5 index. A no-op for the JSON fallback.
    /// - Parameter dbPath: SQLite path (or JSON sidecar anchor).
    static func rebuildFTS(dbPath: String) throws {
        #if canImport(SQLite3)
            try SQLiteEpisodeStore.rebuildFTS(dbPath: dbPath)
        #else
            return
        #endif
    }
}

#if canImport(SQLite3)
    /// Minimal SQLite store for episodes with an FTS5 search index.
    ///
    /// Schema:
    /// `episodes(id TEXT PRIMARY KEY, session_id TEXT NOT NULL, role TEXT NOT NULL,
    /// content TEXT NOT NULL, timestamp REAL NOT NULL, metadata TEXT)`
    /// `episodes_fts(content)` virtual table synced via triggers.
    enum SQLiteEpisodeStore {
        /// Opens (creating parent directories) and migrates the database.
        /// - Parameter dbPath: SQLite file path. `~` is expanded.
        /// - Returns: Open database handle. Caller must close it.
        private static func open(dbPath: String) throws -> OpaquePointer? {
            let expanded = (dbPath as NSString).expandingTildeInPath
            let directory = (expanded as NSString).deletingLastPathComponent
            if !directory.isEmpty {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            }
            var handle: OpaquePointer?
            let status = expanded.withCString { sqlite3_open($0, &handle) }
            guard status == SQLITE_OK, handle != nil else {
                if let handle {
                    sqlite3_close(handle)
                }
                throw EpisodeStoreError.storeUnavailable("Could not open SQLite store at \(dbPath)")
            }
            try exec(
                handle: handle,
                sql: """
                CREATE TABLE IF NOT EXISTS episodes(
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL,
                    role TEXT NOT NULL,
                    content TEXT NOT NULL,
                    timestamp REAL NOT NULL,
                    metadata TEXT
                );
                CREATE INDEX IF NOT EXISTS idx_episodes_session ON episodes(session_id);
                CREATE INDEX IF NOT EXISTS idx_episodes_timestamp ON episodes(timestamp);
                CREATE VIRTUAL TABLE IF NOT EXISTS episodes_fts USING fts5(content, tokenize='porter');
                CREATE TRIGGER IF NOT EXISTS episodes_ai AFTER INSERT ON episodes BEGIN
                    INSERT INTO episodes_fts(rowid, content) VALUES(new.rowid, new.content);
                END;
                CREATE TRIGGER IF NOT EXISTS episodes_ad AFTER DELETE ON episodes BEGIN
                    INSERT INTO episodes_fts(episodes_fts, rowid, content) VALUES('delete', old.rowid, old.content);
                END;
                CREATE TRIGGER IF NOT EXISTS episodes_au AFTER UPDATE ON episodes BEGIN
                    INSERT INTO episodes_fts(episodes_fts, rowid, content) VALUES('delete', old.rowid, old.content);
                    INSERT INTO episodes_fts(rowid, content) VALUES(new.rowid, new.content);
                END;
                """
            )
            return handle
        }

        /// Executes a multi-statement SQL string.
        /// - Parameters:
        ///   - handle: Open database handle.
        ///   - sql: SQL to execute.
        private static func exec(handle: OpaquePointer?, sql: String) throws {
            var errorMessage: UnsafeMutablePointer<CChar>?
            let status = sql.withCString { sqlite3_exec(handle, $0, nil, nil, &errorMessage) }
            defer { sqlite3_free(errorMessage) }
            guard status == SQLITE_OK else {
                let detail = errorMessage.map { String(cString: $0) } ?? "unknown error"
                throw EpisodeStoreError.persistenceFailed(detail)
            }
        }

        /// Binds optional text, mapping nil to NULL.
        /// - Parameters:
        ///   - statement: Prepared statement.
        ///   - index: One-based bind index.
        ///   - value: Text value, or nil for NULL.
        private static func bindText(_ statement: OpaquePointer?, index: Int32, value: String?) {
            if let value {
                _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            } else {
                sqlite3_bind_null(statement, index)
            }
        }

        /// Encodes metadata as a JSON object string.
        /// - Parameter metadata: Key/value annotations.
        /// - Returns: JSON string, or nil when empty.
        private static func encodeMetadata(_ metadata: [String: String]) -> String? {
            guard !metadata.isEmpty else { return nil }
            guard let data = try? JSONEncoder().encode(metadata) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        /// Decodes a JSON metadata string back to a dictionary.
        /// - Parameter text: JSON string from the `metadata` column.
        /// - Returns: Decoded dictionary, or empty on any failure.
        private static func decodeMetadata(_ text: String?) -> [String: String] {
            guard let text, !text.isEmpty, let data = text.data(using: .utf8) else { return [:] }
            return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }

        /// Column-text helper returning nil for NULL columns.
        /// - Parameters:
        ///   - statement: Stepped statement positioned on a row.
        ///   - index: Zero-based column index.
        /// - Returns: Column text, or nil when NULL.
        private static func columnText(_ statement: OpaquePointer?, index: Int32) -> String? {
            sqlite3_column_text(statement, index).map { String(cString: $0) }
        }

        /// Reads the episode at the statement's current row.
        /// - Parameter statement: Statement selecting full episode columns
        ///   (`id, session_id, role, content, timestamp, metadata`).
        /// - Returns: The episode, or nil when the row is malformed.
        private static func readEpisode(_ statement: OpaquePointer?) -> Episode? {
            guard let idText = columnText(statement, index: 0),
                  let id = UUID(uuidString: idText),
                  let sessionText = columnText(statement, index: 1),
                  let sessionID = UUID(uuidString: sessionText),
                  let roleText = columnText(statement, index: 2),
                  let role = Message.Role(rawValue: roleText),
                  let content = columnText(statement, index: 3)
            else { return nil }
            let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            let metadata = decodeMetadata(columnText(statement, index: 5))
            return Episode(id: id, sessionID: sessionID, role: role, content: content, timestamp: timestamp, metadata: metadata)
        }

        /// Writes episodes, optionally preserving existing rows.
        /// - Parameters:
        ///   - episodes: Episodes to upsert.
        ///   - dbPath: SQLite file path.
        ///   - merge: When false, replaces the whole store atomically.
        static func write(episodes: [Episode], dbPath: String, merge: Bool) throws {
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            try exec(handle: handle, sql: "BEGIN IMMEDIATE;")
            do {
                if !merge {
                    try exec(handle: handle, sql: "DELETE FROM episodes;")
                }
                let sql = "INSERT INTO episodes(id, session_id, role, content, timestamp, metadata) VALUES(?, ?, ?, ?, ?, ?) "
                    + "ON CONFLICT(id) DO UPDATE SET session_id=excluded.session_id, role=excluded.role, "
                    + "content=excluded.content, timestamp=excluded.timestamp, metadata=excluded.metadata;"
                for episode in episodes {
                    var statement: OpaquePointer?
                    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                        throw EpisodeStoreError.persistenceFailed("Could not prepare episode upsert")
                    }
                    defer { sqlite3_finalize(statement) }
                    bindText(statement, index: 1, value: episode.id.uuidString)
                    bindText(statement, index: 2, value: episode.sessionID.uuidString)
                    bindText(statement, index: 3, value: episode.role.rawValue)
                    bindText(statement, index: 4, value: episode.content)
                    sqlite3_bind_double(statement, 5, episode.timestamp.timeIntervalSince1970)
                    bindText(statement, index: 6, value: encodeMetadata(episode.metadata))
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw EpisodeStoreError.persistenceFailed("Could not write episode \(episode.id)")
                    }
                }
                try exec(handle: handle, sql: "COMMIT;")
            } catch {
                try? exec(handle: handle, sql: "ROLLBACK;")
                throw error
            }
        }

        /// Reads one session's episodes, oldest first.
        /// - Parameters:
        ///   - sessionID: Owning session identifier.
        ///   - dbPath: SQLite file path.
        ///   - limit: Maximum rows, nil for all.
        /// - Returns: Matching episodes.
        static func episodes(sessionID: UUID, dbPath: String, limit: Int?) throws -> [Episode] {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return [] }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            var sql = "SELECT id, session_id, role, content, timestamp, metadata FROM episodes WHERE session_id = ? ORDER BY timestamp ASC, rowid ASC"
            if limit != nil {
                sql += " LIMIT ?"
            }
            sql += ";"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw EpisodeStoreError.persistenceFailed("Could not prepare episode read")
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, index: 1, value: sessionID.uuidString)
            if let limit {
                sqlite3_bind_int(statement, 2, Int32(max(1, limit)))
            }
            var results: [Episode] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let episode = readEpisode(statement) {
                    results.append(episode)
                }
            }
            return results
        }

        /// Reads episodes at or before a cutoff, oldest first.
        /// - Parameters:
        ///   - olderThan: Inclusive upper bound on `timestamp`.
        ///   - dbPath: SQLite file path.
        /// - Returns: Matching episodes.
        static func episodes(olderThan: Date, dbPath: String) throws -> [Episode] {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return [] }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            let sql = "SELECT id, session_id, role, content, timestamp, metadata FROM episodes WHERE timestamp <= ? ORDER BY timestamp ASC, rowid ASC;"
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw EpisodeStoreError.persistenceFailed("Could not prepare cutoff read")
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, olderThan.timeIntervalSince1970)
            var results: [Episode] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let episode = readEpisode(statement) {
                    results.append(episode)
                }
            }
            return results
        }

        /// Reads the newest episodes across all sessions.
        /// - Parameters:
        ///   - dbPath: SQLite file path.
        ///   - limit: Maximum rows.
        /// - Returns: Episodes newest first.
        static func recent(dbPath: String, limit: Int) throws -> [Episode] {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return [] }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            let sql = "SELECT id, session_id, role, content, timestamp, metadata FROM episodes ORDER BY timestamp DESC, rowid DESC LIMIT ?;"
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw EpisodeStoreError.persistenceFailed("Could not prepare recent read")
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(max(1, limit)))
            var results: [Episode] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let episode = readEpisode(statement) {
                    results.append(episode)
                }
            }
            return results
        }

        /// Full-text search over episode content (FTS5 with LIKE fallback).
        /// - Parameters:
        ///   - query: Search text.
        ///   - dbPath: SQLite file path.
        ///   - limit: Maximum results.
        /// - Returns: Matching episodes, best first.
        static func search(query: String, dbPath: String, limit: Int) throws -> [Episode] {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return [] }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            let ftsQuery = ftsEscaped(query)
            let sql = """
            SELECT e.id, e.session_id, e.role, e.content, e.timestamp, e.metadata
            FROM episodes_fts JOIN episodes e ON e.rowid = episodes_fts.rowid
            WHERE episodes_fts MATCH ? ORDER BY rank LIMIT ?;
            """
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK {
                bindText(statement, index: 1, value: ftsQuery)
                sqlite3_bind_int(statement, 2, Int32(max(1, limit)))
                var results: [Episode] = []
                var step = sqlite3_step(statement)
                while step == SQLITE_ROW {
                    if let episode = readEpisode(statement) {
                        results.append(episode)
                    }
                    step = sqlite3_step(statement)
                }
                let succeeded = (step == SQLITE_DONE)
                sqlite3_finalize(statement)
                if succeeded {
                    return results
                }
            } else if statement != nil {
                sqlite3_finalize(statement)
            }
            var fallback: OpaquePointer?
            let likeSQL = "SELECT id, session_id, role, content, timestamp, metadata FROM episodes WHERE content LIKE ? ORDER BY timestamp DESC LIMIT ?;"
            guard sqlite3_prepare_v2(handle, likeSQL, -1, &fallback, nil) == SQLITE_OK else {
                throw EpisodeStoreError.persistenceFailed("Could not prepare episode search")
            }
            defer { sqlite3_finalize(fallback) }
            bindText(fallback, index: 1, value: "%\(query)%")
            sqlite3_bind_int(fallback, 2, Int32(max(1, limit)))
            var results: [Episode] = []
            while sqlite3_step(fallback) == SQLITE_ROW {
                if let episode = readEpisode(fallback) {
                    results.append(episode)
                }
            }
            return results
        }

        /// Escapes user text into a safe FTS5 phrase query.
        /// - Parameter query: Raw search text.
        /// - Returns: Quoted phrase with embedded quotes doubled.
        private static func ftsEscaped(_ query: String) -> String {
            let tokens = query.split { $0.isWhitespace || $0.isNewline }.map { String($0) }.filter { !$0.isEmpty }
            guard !tokens.isEmpty else { return "\"\"" }
            let phrases = tokens.prefix(10).map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            return phrases.joined(separator: " OR ")
        }

        /// All session identifiers with stored episodes.
        /// - Parameter dbPath: SQLite file path.
        /// - Returns: Session identifiers.
        static func sessionIDs(dbPath: String) throws -> [UUID] {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return [] }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "SELECT DISTINCT session_id FROM episodes;", -1, &statement, nil) == SQLITE_OK else {
                throw EpisodeStoreError.persistenceFailed("Could not read session ids")
            }
            defer { sqlite3_finalize(statement) }
            var results: [UUID] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let text = columnText(statement, index: 0), let id = UUID(uuidString: text) {
                    results.append(id)
                }
            }
            return results
        }

        /// Total stored episode count.
        /// - Parameter dbPath: SQLite file path.
        /// - Returns: Row count.
        static func count(dbPath: String) throws -> Int {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return 0 }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM episodes;", -1, &statement, nil) == SQLITE_OK else {
                throw EpisodeStoreError.persistenceFailed("Could not count episodes")
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(statement, 0))
        }

        /// Deletes one episode and its index entry. Missing rows are a no-op.
        /// - Parameters:
        ///   - id: Episode identifier.
        ///   - dbPath: SQLite file path.
        static func delete(id: UUID, dbPath: String) throws {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "DELETE FROM episodes WHERE id = ?;", -1, &statement, nil) == SQLITE_OK else {
                throw EpisodeStoreError.persistenceFailed("Could not prepare episode delete")
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, index: 1, value: id.uuidString)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw EpisodeStoreError.persistenceFailed("Could not delete episode \(id)")
            }
        }

        /// Deletes every episode for a session.
        /// - Parameters:
        ///   - sessionID: Owning session identifier.
        ///   - dbPath: SQLite file path.
        static func deleteSession(_ sessionID: UUID, dbPath: String) throws {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "DELETE FROM episodes WHERE session_id = ?;", -1, &statement, nil) == SQLITE_OK else {
                throw EpisodeStoreError.persistenceFailed("Could not prepare session delete")
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, index: 1, value: sessionID.uuidString)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw EpisodeStoreError.persistenceFailed("Could not delete session \(sessionID)")
            }
        }

        /// Deletes one session's episodes at or before a cutoff.
        /// - Parameters:
        ///   - beforeOrAt: Inclusive upper bound on `timestamp`.
        ///   - sessionID: Owning session identifier.
        ///   - dbPath: SQLite file path.
        static func deleteSession(beforeOrAt: Date, sessionID: UUID, dbPath: String) throws {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                handle,
                "DELETE FROM episodes WHERE session_id = ? AND timestamp <= ?;",
                -1,
                &statement,
                nil
            ) == SQLITE_OK else {
                throw EpisodeStoreError.persistenceFailed("Could not prepare cutoff delete")
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, index: 1, value: sessionID.uuidString)
            sqlite3_bind_double(statement, 2, beforeOrAt.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw EpisodeStoreError.persistenceFailed("Could not compact session \(sessionID)")
            }
        }

        /// Deletes all episodes and rebuilds the empty index.
        /// - Parameter dbPath: SQLite file path.
        static func clear(dbPath: String) throws {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            try exec(handle: handle, sql: "DELETE FROM episodes; INSERT INTO episodes_fts(episodes_fts) VALUES('rebuild');")
        }

        /// Rebuilds the FTS5 index from the `episodes` table.
        /// - Parameter dbPath: SQLite file path.
        static func rebuildFTS(dbPath: String) throws {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            try exec(handle: handle, sql: "INSERT INTO episodes_fts(episodes_fts) VALUES('rebuild');")
        }
    }
#else
    /// JSON-file fallback used where the SQLite3 module is unavailable.
    ///
    /// Each episode is stored as `<anchor>.episodes/<id>.json` so hosts
    /// without SQLite headers (e.g. Linux CI) persist identically. Search
    /// uses case-insensitive token overlap scoring.
    enum JSONEpisodeStore {
        /// Directory holding one JSON file per episode.
        /// - Parameter dbPath: Configured database path used as anchor.
        /// - Returns: Sidecar directory URL.
        private static func directory(dbPath: String) -> URL {
            let expanded = (dbPath as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded + ".episodes", isDirectory: true)
        }

        /// Reads every stored episode, oldest first.
        /// - Parameter dbPath: Anchor path for the sidecar directory.
        /// - Returns: Stored episodes, empty when the directory is missing.
        private static func readAll(dbPath: String) throws -> [Episode] {
            let directoryURL = directory(dbPath: dbPath)
            guard FileManager.default.fileExists(atPath: directoryURL.path) else { return [] }
            do {
                let files = try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .secondsSince1970
                let episodes = try files
                    .filter { $0.pathExtension == "json" }
                    .map { try decoder.decode(Episode.self, from: Data(contentsOf: $0)) }
                return episodes.sorted { $0.timestamp < $1.timestamp }
            } catch {
                throw EpisodeStoreError.persistenceFailed("Could not read episodes: \(error.localizedDescription)")
            }
        }

        /// Writes episodes as JSON files (upsert by `id`).
        /// - Parameters:
        ///   - episodes: Episodes to write.
        ///   - dbPath: Anchor path for the sidecar directory.
        ///   - merge: When false, clears existing files first.
        static func write(episodes: [Episode], dbPath: String, merge: Bool) throws {
            let directoryURL = directory(dbPath: dbPath)
            do {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                if !merge {
                    for file in (try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)) ?? [] {
                        try? FileManager.default.removeItem(at: file)
                    }
                }
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .secondsSince1970
                for episode in episodes {
                    let data = try encoder.encode(episode)
                    try data.write(to: directoryURL.appendingPathComponent("\(episode.id.uuidString).json"), options: .atomic)
                }
            } catch let error as EpisodeStoreError {
                throw error
            } catch {
                throw EpisodeStoreError.persistenceFailed("Could not write episodes: \(error.localizedDescription)")
            }
        }

        /// Reads one session's episodes, oldest first.
        /// - Parameters:
        ///   - sessionID: Owning session identifier.
        ///   - dbPath: Anchor path for the sidecar directory.
        ///   - limit: Maximum rows, nil for all.
        /// - Returns: Matching episodes.
        static func episodes(sessionID: UUID, dbPath: String, limit: Int?) throws -> [Episode] {
            let matching = try readAll(dbPath: dbPath).filter { $0.sessionID == sessionID }
            guard let limit else { return matching }
            return Array(matching.prefix(max(1, limit)))
        }

        /// Reads episodes at or before a cutoff, oldest first.
        /// - Parameters:
        ///   - olderThan: Inclusive upper bound on `timestamp`.
        ///   - dbPath: Anchor path for the sidecar directory.
        /// - Returns: Matching episodes.
        static func episodes(olderThan: Date, dbPath: String) throws -> [Episode] {
            try readAll(dbPath: dbPath).filter { $0.timestamp <= olderThan }
        }

        /// Reads the newest episodes across all sessions.
        /// - Parameters:
        ///   - dbPath: Anchor path for the sidecar directory.
        ///   - limit: Maximum rows.
        /// - Returns: Episodes newest first.
        static func recent(dbPath: String, limit: Int) throws -> [Episode] {
            let sorted = try readAll(dbPath: dbPath).sorted { $0.timestamp > $1.timestamp }
            return Array(sorted.prefix(max(1, limit)))
        }

        /// Token-overlap search over episode content.
        /// - Parameters:
        ///   - query: Search text.
        ///   - dbPath: Anchor path for the sidecar directory.
        ///   - limit: Maximum results.
        /// - Returns: Matching episodes, best first.
        static func search(query: String, dbPath: String, limit: Int) throws -> [Episode] {
            let all = try readAll(dbPath: dbPath)
            let queryTokens = tokenize(query)
            guard !queryTokens.isEmpty else { return [] }
            let scored = all.compactMap { episode -> (Episode, Int)? in
                let contentTokens = Set(tokenize(episode.content))
                let overlap = queryTokens.intersection(contentTokens).count
                let substring = episode.content.range(of: query, options: .caseInsensitive) != nil
                guard overlap > 0 || substring else { return nil }
                return (episode, overlap * 2 + (substring ? 1 : 0))
            }
            return scored
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.timestamp > $1.0.timestamp }
                .prefix(max(1, limit))
                .map(\.0)
        }

        /// Lowercased alphanumeric tokens for overlap scoring.
        /// - Parameter text: Text to tokenize.
        /// - Returns: Token set.
        private static func tokenize(_ text: String) -> Set<String> {
            Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map { String($0) }.filter { !$0.isEmpty })
        }

        /// All session identifiers with stored episodes.
        /// - Parameter dbPath: Anchor path for the sidecar directory.
        /// - Returns: Session identifiers.
        static func sessionIDs(dbPath: String) throws -> [UUID] {
            try Array(Set(readAll(dbPath: dbPath).map(\.sessionID)))
        }

        /// Total stored episode count.
        /// - Parameter dbPath: Anchor path for the sidecar directory.
        /// - Returns: Episode count.
        static func count(dbPath: String) throws -> Int {
            try readAll(dbPath: dbPath).count
        }

        /// Deletes one episode file. Missing files are a no-op.
        /// - Parameters:
        ///   - id: Episode identifier.
        ///   - dbPath: Anchor path for the sidecar directory.
        static func delete(id: UUID, dbPath: String) throws {
            let fileURL = directory(dbPath: dbPath).appendingPathComponent("\(id.uuidString).json")
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                throw EpisodeStoreError.persistenceFailed("Could not delete episode: \(error.localizedDescription)")
            }
        }

        /// Deletes every episode file for a session.
        /// - Parameters:
        ///   - sessionID: Owning session identifier.
        ///   - dbPath: Anchor path for the sidecar directory.
        static func deleteSession(_ sessionID: UUID, dbPath: String) throws {
            for episode in try readAll(dbPath: dbPath) where episode.sessionID == sessionID {
                try delete(id: episode.id, dbPath: dbPath)
            }
        }

        /// Deletes one session's episodes at or before a cutoff.
        /// - Parameters:
        ///   - beforeOrAt: Inclusive upper bound on `timestamp`.
        ///   - sessionID: Owning session identifier.
        ///   - dbPath: Anchor path for the sidecar directory.
        static func deleteSession(beforeOrAt: Date, sessionID: UUID, dbPath: String) throws {
            for episode in try readAll(dbPath: dbPath)
                where episode.sessionID == sessionID && episode.timestamp <= beforeOrAt
            {
                try delete(id: episode.id, dbPath: dbPath)
            }
        }

        /// Deletes all episode files.
        /// - Parameter dbPath: Anchor path for the sidecar directory.
        static func clear(dbPath: String) throws {
            let directoryURL = directory(dbPath: dbPath)
            guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
            do {
                try FileManager.default.removeItem(at: directoryURL)
            } catch {
                throw EpisodeStoreError.persistenceFailed("Could not clear episodes: \(error.localizedDescription)")
            }
        }
    }
#endif
