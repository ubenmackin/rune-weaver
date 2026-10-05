// Rune Weaver Core — SQLite-backed episodic memory with full-text search.

import Foundation

#if canImport(SQLite3)
    import SQLite3
#endif

/// SQLite-backed episodic memory with FTS5 full-text search.
public actor EpisodeStore {
    /// Filesystem path of the SQLite database (or JSON sidecar anchor).
    public let dbPath: String
    /// Summarizer applied when compacting old sessions.
    private let summarizer: EpisodeSummarizer
    /// Maximum rows returned per read.
    private static let maxResults = 1000

    /// Creates a store, migrating the schema on first use.
    public init(dbPath: String, summarizer: EpisodeSummarizer? = nil) {
        self.dbPath = dbPath
        self.summarizer = summarizer ?? defaultEpisodeSummarizer
    }

    // MARK: - Writes

    /// Stores one conversation turn.
    @discardableResult
    public func store(
        sessionID: UUID,
        role: Message.Role,
        content: String,
        metadata: [String: String] = [:]
    ) async throws -> Episode {
        let episode = Episode(sessionID: sessionID, role: role, content: content, metadata: metadata)
        try await store(episode)
        return episode
    }

    /// Stores an already-constructed episode (upsert by `id`).
    /// - Parameter episode: Episode to persist.
    public func store(_ episode: Episode) async throws {
        let dbPath = self.dbPath
        try await SQLiteSerialIO.run {
            try EpisodeStoreIO.write(episodes: [episode], dbPath: dbPath, merge: true)
        }
    }

    /// Stores a batch of episodes (upsert by `id`).
    /// - Parameter episodes: Episodes to persist.
    public func store(_ episodes: [Episode]) async throws {
        guard !episodes.isEmpty else { return }
        let dbPath = self.dbPath
        try await SQLiteSerialIO.run {
            try EpisodeStoreIO.write(episodes: episodes, dbPath: dbPath, merge: true)
        }
    }

    /// Stores one conversation turn without observing cancellation.
    @discardableResult
    public func storeUncancellable(
        sessionID: UUID,
        role: Message.Role,
        content: String,
        metadata: [String: String] = [:]
    ) async -> Bool {
        let episode = Episode(sessionID: sessionID, role: role, content: content, metadata: metadata)
        return await storeUncancellable(episode)
    }

    /// Stores an already-constructed episode without observing cancellation.
    @discardableResult
    public func storeUncancellable(_ episode: Episode) async -> Bool {
        let dbPath = self.dbPath
        let episodes = [episode]
        return await SQLiteSerialIO.runUncancellable {
            do {
                try EpisodeStoreIO.write(episodes: episodes, dbPath: dbPath, merge: true)
                return true
            } catch {
                RuneWeaverLog.stores.error("EpisodeStore: storeUncancellable failed: \(error.localizedDescription)")
                return false
            }
        }
    }

    // MARK: - Reads

    /// Returns episodes for one session, oldest first.
    public func episodes(for sessionID: UUID, limit: Int? = nil) async throws -> [Episode] {
        if let limit, limit <= 0 {
            return []
        }
        let clamped = limit.map { min($0, Self.maxResults) }
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run {
            try EpisodeStoreIO.episodes(sessionID: sessionID, dbPath: dbPath, limit: clamped)
        }
    }

    /// Returns the newest episodes for one session, oldest first.
    public func recentEpisodes(for sessionID: UUID, limit: Int) async throws -> [Episode] {
        guard limit > 0 else { return [] }
        let dbPath = self.dbPath
        let clamped = min(limit, Self.maxResults)
        return try await SQLiteSerialIO.run {
            try EpisodeStoreIO.recentEpisodes(sessionID: sessionID, dbPath: dbPath, limit: clamped)
        }
    }

    /// Returns the most recent episodes across all sessions.
    public func recent(limit: Int = 20) async throws -> [Episode] {
        guard limit > 0 else { return [] }
        let dbPath = self.dbPath
        let clamped = min(limit, Self.maxResults)
        return try await SQLiteSerialIO.run {
            try EpisodeStoreIO.recent(dbPath: dbPath, limit: clamped)
        }
    }

    /// Full-text search over episode content, optionally restricted to a dated window.
    public func search(query: String, limit: Int = 10, since: Date? = nil, until: Date? = nil) async throws -> [Episode] {
        guard limit > 0 else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let dbPath = self.dbPath
        let clamped = min(limit, Self.maxResults)
        return try await SQLiteSerialIO.run {
            try EpisodeStoreIO.search(query: trimmed, dbPath: dbPath, limit: clamped, since: since, until: until)
        }
    }

    /// All session identifiers that have stored episodes.
    public func sessionIDs() async throws -> [UUID] {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run {
            try EpisodeStoreIO.sessionIDs(dbPath: dbPath)
        }
    }

    /// Total stored episode count.
    public func count() async throws -> Int {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run {
            try EpisodeStoreIO.count(dbPath: dbPath)
        }
    }

    // MARK: - Deletes

    /// Deletes one episode. Missing rows are a no-op.
    public func delete(id: UUID) async throws {
        let dbPath = self.dbPath
        try await SQLiteSerialIO.run {
            try EpisodeStoreIO.delete(id: id, dbPath: dbPath)
        }
    }

    /// Deletes every episode for a session. Unknown sessions are a no-op.
    public func deleteSession(_ sessionID: UUID) async throws {
        let dbPath = self.dbPath
        try await SQLiteSerialIO.run {
            try EpisodeStoreIO.deleteSession(sessionID, dbPath: dbPath)
        }
    }

    /// Deletes all episodes.
    ///
    /// The blocking delete runs off the actor executor via the shared serial store queue (`SQLiteSerialIO`).
    public func clear() async throws {
        let dbPath = self.dbPath
        try await SQLiteSerialIO.run {
            try EpisodeStoreIO.clear(dbPath: dbPath)
        }
    }

    /// Atomically counts then deletes all episodes in one store operation.
    ///
    /// `SELECT COUNT(*)` and `DELETE FROM episodes` run in one `BEGIN IMMEDIATE`/
    /// `COMMIT` transaction inside one `SQLiteSerialIO.run`, so a concurrent
    /// `store`/`delete` on the same engine cannot interleave between the measure
    /// and the delete and the returned count always names what was removed.
    /// - Returns: Episode count measured in the same transaction before deleting.
    public func clearReturningCount() async throws -> Int {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run {
            try EpisodeStoreIO.clearReturningCount(dbPath: dbPath)
        }
    }

    // MARK: - Auto-summarization

    /// Summarizes sessions whose episodes are older than a cutoff.
    public func summarizeSessions(
        olderThan: Date,
        summarizer: EpisodeSummarizer? = nil
    ) async throws -> [EpisodeSummary] {
        let summarize = summarizer ?? self.summarizer
        let dbPath = self.dbPath
        let old = try await SQLiteSerialIO.run {
            try EpisodeStoreIO.episodes(olderThan: olderThan, dbPath: dbPath)
        }
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
    @discardableResult
    public func compactSessions(
        olderThan: Date,
        summarizer: EpisodeSummarizer? = nil
    ) async throws -> [EpisodeSummary] {
        let summaries = try await summarizeSessions(olderThan: olderThan, summarizer: summarizer)
        guard !summaries.isEmpty else { return [] }
        let dbPath = self.dbPath
        for summary in summaries {
            let replacement = Episode(
                sessionID: summary.sessionID,
                role: .system,
                content: "Summary of \(summary.messageCount) earlier messages: \(summary.summary)",
                metadata: ["compacted": "true"]
            )
            try await SQLiteSerialIO.run {
                try EpisodeStoreIO.compact(
                    sessionID: summary.sessionID,
                    beforeOrAt: olderThan,
                    replacement: replacement,
                    dbPath: dbPath
                )
            }
        }
        return summaries
    }

    /// Rebuilds the FTS5 index from the `episodes` table.
    public func rebuildSearchIndex() async throws {
        let dbPath = self.dbPath
        try await SQLiteSerialIO.run {
            try EpisodeStoreIO.rebuildFTS(dbPath: dbPath)
        }
    }
}

// MARK: - Store I/O

/// File and SQLite I/O for episodes.
enum EpisodeStoreIO {
    /// Writes episodes (upsert by `id`).
    static func write(episodes: [Episode], dbPath: String, merge: Bool = true) throws {
        #if canImport(SQLite3)
            try SQLiteEpisodeStore.write(episodes: episodes, dbPath: dbPath, merge: merge)
        #else
            try JSONEpisodeStore.write(episodes: episodes, dbPath: dbPath, merge: merge)
        #endif
    }

    /// Reads one session's episodes, oldest first.
    static func episodes(sessionID: UUID, dbPath: String, limit: Int?) throws -> [Episode] {
        #if canImport(SQLite3)
            return try SQLiteEpisodeStore.episodes(sessionID: sessionID, dbPath: dbPath, limit: limit)
        #else
            return try JSONEpisodeStore.episodes(sessionID: sessionID, dbPath: dbPath, limit: limit)
        #endif
    }

    /// Reads one session's newest episodes, oldest first.
    static func recentEpisodes(sessionID: UUID, dbPath: String, limit: Int) throws -> [Episode] {
        #if canImport(SQLite3)
            return try SQLiteEpisodeStore.recentEpisodes(sessionID: sessionID, dbPath: dbPath, limit: limit)
        #else
            return try JSONEpisodeStore.recentEpisodes(sessionID: sessionID, dbPath: dbPath, limit: limit)
        #endif
    }

    /// Reads episodes at or before a cutoff, oldest first.
    static func episodes(olderThan: Date, dbPath: String) throws -> [Episode] {
        #if canImport(SQLite3)
            return try SQLiteEpisodeStore.episodes(olderThan: olderThan, dbPath: dbPath)
        #else
            return try JSONEpisodeStore.episodes(olderThan: olderThan, dbPath: dbPath)
        #endif
    }

    /// Reads the newest episodes across all sessions.
    static func recent(dbPath: String, limit: Int) throws -> [Episode] {
        #if canImport(SQLite3)
            return try SQLiteEpisodeStore.recent(dbPath: dbPath, limit: limit)
        #else
            return try JSONEpisodeStore.recent(dbPath: dbPath, limit: limit)
        #endif
    }

    /// Full-text search over episode content.
    static func search(query: String, dbPath: String, limit: Int, since: Date? = nil, until: Date? = nil) throws -> [Episode] {
        #if canImport(SQLite3)
            return try SQLiteEpisodeStore.search(query: query, dbPath: dbPath, limit: limit, since: since, until: until)
        #else
            return try JSONEpisodeStore.search(query: query, dbPath: dbPath, limit: limit, since: since, until: until)
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
    static func delete(id: UUID, dbPath: String) throws {
        #if canImport(SQLite3)
            try SQLiteEpisodeStore.delete(id: id, dbPath: dbPath)
        #else
            try JSONEpisodeStore.delete(id: id, dbPath: dbPath)
        #endif
    }

    /// Deletes every episode for a session.
    static func deleteSession(_ sessionID: UUID, dbPath: String) throws {
        #if canImport(SQLite3)
            try SQLiteEpisodeStore.deleteSession(sessionID, dbPath: dbPath)
        #else
            try JSONEpisodeStore.deleteSession(sessionID, dbPath: dbPath)
        #endif
    }

    /// Deletes one session's episodes at or before a cutoff.
    static func deleteSession(beforeOrAt: Date, sessionID: UUID, dbPath: String) throws {
        #if canImport(SQLite3)
            try SQLiteEpisodeStore.deleteSession(beforeOrAt: beforeOrAt, sessionID: sessionID, dbPath: dbPath)
        #else
            try JSONEpisodeStore.deleteSession(beforeOrAt: beforeOrAt, sessionID: sessionID, dbPath: dbPath)
        #endif
    }

    /// Replaces one session's old episodes with a summary episode.
    static func compact(sessionID: UUID, beforeOrAt: Date, replacement: Episode, dbPath: String) throws {
        #if canImport(SQLite3)
            try SQLiteEpisodeStore.compact(sessionID: sessionID, beforeOrAt: beforeOrAt, replacement: replacement, dbPath: dbPath)
        #else
            try JSONEpisodeStore.compact(sessionID: sessionID, beforeOrAt: beforeOrAt, replacement: replacement, dbPath: dbPath)
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

    /// Atomically counts then deletes all episodes in one transaction.
    /// - Parameter dbPath: SQLite path (or JSON sidecar anchor).
    /// - Returns: Episode count measured in the same transaction before deleting.
    static func clearReturningCount(dbPath: String) throws -> Int {
        #if canImport(SQLite3)
            return try SQLiteEpisodeStore.clearReturningCount(dbPath: dbPath)
        #else
            return try JSONEpisodeStore.clearReturningCount(dbPath: dbPath)
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
    enum SQLiteEpisodeStore {
        /// Opens (creating parent directories) and migrates the database.
        /// - Parameter dbPath: SQLite file path. `~` is expanded.
        /// - Returns: Open database handle. Caller must close it.
        private static func open(dbPath: String) throws -> OpaquePointer? {
            // Shared busy_timeout/WAL policy lives in `SQLiteHelpers.openHandle`.
            // Episodic FTS is a plain contentful table, so row removal uses a direct
            // DELETE by rowid: the FTS5 'delete' command only serves external-content
            // and contentless tables and fails on recent macOS SQLite.
            let handle = try SQLiteHelpers.openHandle(dbPath: dbPath, unavailable: EpisodeStoreError.storeUnavailable)
            try SQLiteHelpers.exec(
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
                    DELETE FROM episodes_fts WHERE rowid = old.rowid;
                END;
                CREATE TRIGGER IF NOT EXISTS episodes_au AFTER UPDATE ON episodes BEGIN
                    DELETE FROM episodes_fts WHERE rowid = old.rowid;
                    INSERT INTO episodes_fts(rowid, content) VALUES(new.rowid, new.content);
                END;
                """,
                failure: EpisodeStoreError.persistenceFailed
            )
            // One-time repair for databases created with the earlier broken
            // VALUES('delete', ...) triggers. Steady-state opens stay read-only
            // (`IF NOT EXISTS` is a no-op once triggers exist) and idempotent
            // cross-process; legacy bodies are replaced exactly once.
            try repairLegacyTriggersIfNeeded(handle: handle)
            return handle
        }

        /// Replaces legacy FTS5 delete-command triggers exactly once.
        ///
        /// Probes `sqlite_master` (read-only) for the old `VALUES('delete', ...)`
        /// trigger body and only rewrites `episodes_ad`/`episodes_au` when present,
        /// so steady-state opens perform no schema write and concurrent serve +
        /// CLI runners cannot interleave unconditional `DROP`/`CREATE` into a
        /// `trigger already exists` failure.
        /// - Parameter handle: Open database handle being migrated.
        private static func repairLegacyTriggersIfNeeded(handle: OpaquePointer?) throws {
            guard hasLegacyDeleteTrigger(handle: handle) else { return }
            try SQLiteHelpers.exec(
                handle: handle,
                sql: """
                DROP TRIGGER IF EXISTS episodes_ad;
                CREATE TRIGGER IF NOT EXISTS episodes_ad AFTER DELETE ON episodes BEGIN
                    DELETE FROM episodes_fts WHERE rowid = old.rowid;
                END;
                DROP TRIGGER IF EXISTS episodes_au;
                CREATE TRIGGER IF NOT EXISTS episodes_au AFTER UPDATE ON episodes BEGIN
                    DELETE FROM episodes_fts WHERE rowid = old.rowid;
                    INSERT INTO episodes_fts(rowid, content) VALUES(new.rowid, new.content);
                END;
                """,
                failure: EpisodeStoreError.persistenceFailed
            )
        }

        /// Whether `episodes_ad`/`episodes_au` still carry the legacy delete-command body.
        ///
        /// The broken triggers used the FTS5 `VALUES('delete', ...)` command syntax,
        /// which fails on plain contentful tables; the repaired triggers contain no
        /// quoted `'delete'` literal (only `DELETE FROM`), so a quoted-literal probe
        /// distinguishes legacy from repaired without a schema write.
        /// - Parameter handle: Open database handle to probe.
        /// - Returns: True when a legacy trigger body is present.
        private static func hasLegacyDeleteTrigger(handle: OpaquePointer?) -> Bool {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                handle,
                "SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name IN ('episodes_ad', 'episodes_au');",
                -1,
                &statement,
                nil
            ) == SQLITE_OK else {
                return false
            }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                if let sql = SQLiteHelpers.columnText(statement, index: 0) {
                    let lowered = sql.lowercased()
                    if lowered.contains("'delete'") || lowered.contains("\"delete\"") {
                        return true
                    }
                }
            }
            return false
        }

        /// Executes a multi-statement SQL string.
        private static func exec(handle: OpaquePointer?, sql: String) throws {
            try SQLiteHelpers.exec(handle: handle, sql: sql, failure: EpisodeStoreError.persistenceFailed)
        }

        /// Binds optional text, mapping nil to NULL.
        private static func bindText(_ statement: OpaquePointer?, index: Int32, value: String?) {
            SQLiteHelpers.bindText(statement, index: index, value: value)
        }

        /// Encodes metadata as a JSON object string.
        /// - Parameter metadata: Key/value annotations.
        /// - Returns: JSON string, or nil when empty.
        private static func encodeMetadata(_ metadata: [String: String]) -> String? {
            guard !metadata.isEmpty else { return nil }
            do {
                let data = try JSONEncoder().encode(metadata)
                return String(data: data, encoding: .utf8)
            } catch {
                RuneWeaverLog.memory.error("EpisodeStore: failed to encode metadata: \(error.localizedDescription)")
                return nil
            }
        }

        /// Decodes a JSON metadata string back to a dictionary.
        /// - Parameter text: JSON string from the `metadata` column.
        /// - Returns: Decoded dictionary, or empty on any failure.
        private static func decodeMetadata(_ text: String?) -> [String: String] {
            guard let text, !text.isEmpty, let data = text.data(using: .utf8) else { return [:] }
            do {
                return try JSONDecoder().decode([String: String].self, from: data)
            } catch {
                RuneWeaverLog.memory.warning("EpisodeStore: failed to decode metadata: \(error.localizedDescription)")
                return [:]
            }
        }

        /// Column-text helper returning nil for NULL columns.
        private static func columnText(_ statement: OpaquePointer?, index: Int32) -> String? {
            SQLiteHelpers.columnText(statement, index: index)
        }

        /// Reads the episode at the statement's current row.
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
                    do {
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
                }
                try exec(handle: handle, sql: "COMMIT;")
            } catch {
                try? exec(handle: handle, sql: "ROLLBACK;")
                throw error
            }
        }

        /// Reads one session's episodes in insertion order.
        ///
        /// Row order preserves replay: turns return in the sequence they were
        /// stored, so a reloaded session replays identically even when clocks collide.
        static func episodes(sessionID: UUID, dbPath: String, limit: Int?) throws -> [Episode] {
            if let limit, limit <= 0 {
                return []
            }
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return [] }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            var sql = "SELECT id, session_id, role, content, timestamp, metadata FROM episodes WHERE session_id = ? ORDER BY rowid ASC"
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
                sqlite3_bind_int(statement, 2, SQLiteHelpers.sqliteLimit(limit))
            }
            var results: [Episode] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let episode = readEpisode(statement) {
                    results.append(episode)
                }
            }
            return results
        }

        /// Reads one session's newest episodes, oldest first with a stable identifier tie-break.
        ///
        /// The window selects the newest rows by timestamp then identifier so the
        /// set matches the global newest-first contract; the returned order is
        /// oldest first within that window for session replay.
        static func recentEpisodes(sessionID: UUID, dbPath: String, limit: Int) throws -> [Episode] {
            guard limit > 0 else { return [] }
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return [] }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            let sql = "SELECT id, session_id, role, content, timestamp, metadata FROM episodes "
                + "WHERE session_id = ? ORDER BY timestamp DESC, id ASC LIMIT ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw EpisodeStoreError.persistenceFailed("Could not prepare recent episode read")
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, index: 1, value: sessionID.uuidString)
            sqlite3_bind_int(statement, 2, SQLiteHelpers.sqliteLimit(limit))
            var results: [Episode] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let episode = readEpisode(statement) {
                    results.append(episode)
                }
            }
            return results.sorted {
                if $0.timestamp != $1.timestamp {
                    return $0.timestamp < $1.timestamp
                }
                return $0.id.uuidString < $1.id.uuidString
            }
        }

        /// Reads episodes at or before a cutoff in insertion order.
        ///
        /// Row order keeps compaction deterministic: sessions summarize the same
        /// rows in the same sequence regardless of equal timestamps.
        static func episodes(olderThan: Date, dbPath: String) throws -> [Episode] {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return [] }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            let sql = "SELECT id, session_id, role, content, timestamp, metadata FROM episodes "
                + "WHERE timestamp <= ? ORDER BY rowid ASC;"
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

        /// Reads the newest episodes across all sessions, newest first with a stable identifier tie-break.
        ///
        /// Ordering by timestamp then identifier keeps repeated reads identical
        /// and matches the engine-owned listing contract instead of leaving
        /// equal timestamps to insertion chance.
        static func recent(dbPath: String, limit: Int) throws -> [Episode] {
            guard limit > 0 else { return [] }
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return [] }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            let sql = "SELECT id, session_id, role, content, timestamp, metadata FROM episodes "
                + "ORDER BY timestamp DESC, id ASC LIMIT ?;"
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw EpisodeStoreError.persistenceFailed("Could not prepare recent read")
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, SQLiteHelpers.sqliteLimit(limit))
            var results: [Episode] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let episode = readEpisode(statement) {
                    results.append(episode)
                }
            }
            return results
        }

        /// Full-text search over episode content (FTS5 with LIKE fallback).
        ///
        /// A dated window filters on `timestamp` before ranking: `since` is
        /// inclusive and `until` is exclusive, so adjacent day windows tile
        /// without overlap. Both the FTS5 path and the LIKE fallback carry
        /// the same predicates so stemming gaps cannot dodge the window.
        static func search(query: String, dbPath: String, limit: Int, since: Date? = nil, until: Date? = nil) throws -> [Episode] {
            guard limit > 0 else { return [] }
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return [] }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            if let ftsResults = searchFTS(handle: handle, query: query, limit: limit, since: since, until: until), !ftsResults.isEmpty {
                return ftsResults
            }
            return try searchLike(handle: handle, query: query, limit: limit, since: since, until: until)
        }
    }

    // MARK: - SQLiteEpisodeStore Search

    /// FTS5 and LIKE search helpers for the SQLite episode store.
    extension SQLiteEpisodeStore {
        private static func searchFTS(handle: OpaquePointer?, query: String, limit: Int, since: Date?, until: Date?) -> [Episode]? {
            let ftsQuery = ftsEscaped(query)
            var sql = "SELECT e.id, e.session_id, e.role, e.content, e.timestamp, e.metadata "
                + "FROM episodes_fts JOIN episodes e ON e.rowid = episodes_fts.rowid "
                + "WHERE episodes_fts MATCH ?"
            if since != nil {
                sql += " AND e.timestamp >= ?"
            }
            if until != nil {
                sql += " AND e.timestamp < ?"
            }
            sql += " ORDER BY rank, e.rowid DESC LIMIT ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                if statement != nil {
                    sqlite3_finalize(statement)
                }
                return nil
            }
            defer { sqlite3_finalize(statement) }
            var bindIndex: Int32 = 1
            bindText(statement, index: bindIndex, value: ftsQuery)
            bindIndex += 1
            let range = TemporalRange(since: since, until: until)
            let bounds = TemporalFilter.unixBounds(for: range)
            if let lower = bounds.since {
                sqlite3_bind_double(statement, bindIndex, lower)
                bindIndex += 1
            }
            if let upper = bounds.until {
                sqlite3_bind_double(statement, bindIndex, upper)
                bindIndex += 1
            }
            sqlite3_bind_int(statement, bindIndex, SQLiteHelpers.sqliteLimit(limit))
            var results: [Episode] = []
            var step = sqlite3_step(statement)
            while step == SQLITE_ROW {
                if let episode = readEpisode(statement) {
                    results.append(episode)
                }
                step = sqlite3_step(statement)
            }
            let succeeded = (step == SQLITE_DONE)
            if succeeded, !results.isEmpty {
                return results
            }
            return nil
        }

        private static func likePatterns(for query: String) -> [String] {
            let maxLikePatterns = 50
            let tokens = Array(Tokenization.tokenize(query).sorted().prefix(maxLikePatterns - 1))
            guard !tokens.isEmpty else { return [] }
            var patterns = ["%\(likeEscaped(query))%"]
            for token in tokens {
                let pattern = "%\(likeEscaped(token))%"
                let duplicated = patterns.contains { $0.caseInsensitiveCompare(pattern) == .orderedSame }
                if !duplicated {
                    patterns.append(pattern)
                }
                guard patterns.count < maxLikePatterns else { break }
            }
            return patterns
        }

        private static func searchLike(handle: OpaquePointer?, query: String, limit: Int, since: Date?, until: Date?) throws -> [Episode] {
            let patterns = likePatterns(for: query)
            guard !patterns.isEmpty else { return [] }
            let conditions = patterns.map { _ in "content LIKE ? ESCAPE '\\'" }.joined(separator: " OR ")
            var likeSQL = "SELECT id, session_id, role, content, timestamp, metadata FROM episodes "
                + "WHERE (\(conditions))"
            if since != nil {
                likeSQL += " AND timestamp >= ?"
            }
            if until != nil {
                likeSQL += " AND timestamp < ?"
            }
            likeSQL += " ORDER BY timestamp DESC, rowid DESC LIMIT ?;"
            var fallback: OpaquePointer?
            guard sqlite3_prepare_v2(handle, likeSQL, -1, &fallback, nil) == SQLITE_OK else {
                throw EpisodeStoreError.persistenceFailed("Could not prepare episode search")
            }
            defer { sqlite3_finalize(fallback) }
            var fallbackIndex: Int32 = 1
            for pattern in patterns {
                bindText(fallback, index: fallbackIndex, value: pattern)
                fallbackIndex += 1
            }
            let likeRange = TemporalRange(since: since, until: until)
            let likeBounds = TemporalFilter.unixBounds(for: likeRange)
            if let lower = likeBounds.since {
                sqlite3_bind_double(fallback, fallbackIndex, lower)
                fallbackIndex += 1
            }
            if let upper = likeBounds.until {
                sqlite3_bind_double(fallback, fallbackIndex, upper)
                fallbackIndex += 1
            }
            sqlite3_bind_int(fallback, fallbackIndex, SQLiteHelpers.sqliteLimit(limit))
            var results: [Episode] = []
            while sqlite3_step(fallback) == SQLITE_ROW {
                if let episode = readEpisode(fallback) {
                    results.append(episode)
                }
            }
            return results
        }

        /// Escapes LIKE metacharacters so literal text never acts as a wildcard.
        /// - Parameter query: Raw search text.
        /// - Returns: Text with `\`, `%`, and `_` backslash-escaped.
        private static func likeEscaped(_ query: String) -> String {
            var escaped = query.replacingOccurrences(of: "\\", with: "\\\\")
            escaped = escaped.replacingOccurrences(of: "%", with: "\\%")
            escaped = escaped.replacingOccurrences(of: "_", with: "\\_")
            return escaped
        }

        /// Escapes user text into a safe FTS5 phrase query.
        private static func ftsEscaped(_ query: String) -> String {
            let tokens = query.split { $0.isWhitespace || $0.isNewline }.map { String($0) }.filter { !$0.isEmpty }
            guard !tokens.isEmpty else { return "\"\"" }
            let phrases = tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            return phrases.joined(separator: " OR ")
        }
    }

    // MARK: - SQLiteEpisodeStore Maintenance

    /// Session lookups and maintenance for the SQLite store.
    extension SQLiteEpisodeStore {
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

        /// Atomically replaces one session's old episodes with a summary episode.
        static func compact(sessionID: UUID, beforeOrAt: Date, replacement: Episode, dbPath: String) throws {
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            try exec(handle: handle, sql: "BEGIN IMMEDIATE;")
            do {
                var deleteStatement: OpaquePointer?
                guard sqlite3_prepare_v2(
                    handle,
                    "DELETE FROM episodes WHERE session_id = ? AND timestamp <= ?;",
                    -1,
                    &deleteStatement,
                    nil
                ) == SQLITE_OK else {
                    throw EpisodeStoreError.persistenceFailed("Could not prepare cutoff delete")
                }
                defer { sqlite3_finalize(deleteStatement) }
                bindText(deleteStatement, index: 1, value: sessionID.uuidString)
                sqlite3_bind_double(deleteStatement, 2, beforeOrAt.timeIntervalSince1970)
                guard sqlite3_step(deleteStatement) == SQLITE_DONE else {
                    throw EpisodeStoreError.persistenceFailed("Could not compact session \(sessionID)")
                }
                let insertSQL = "INSERT INTO episodes(id, session_id, role, content, timestamp, metadata) VALUES(?, ?, ?, ?, ?, ?) "
                    + "ON CONFLICT(id) DO UPDATE SET session_id=excluded.session_id, role=excluded.role, "
                    + "content=excluded.content, timestamp=excluded.timestamp, metadata=excluded.metadata;"
                var insertStatement: OpaquePointer?
                guard sqlite3_prepare_v2(handle, insertSQL, -1, &insertStatement, nil) == SQLITE_OK else {
                    throw EpisodeStoreError.persistenceFailed("Could not prepare compaction insert")
                }
                defer { sqlite3_finalize(insertStatement) }
                bindText(insertStatement, index: 1, value: replacement.id.uuidString)
                bindText(insertStatement, index: 2, value: replacement.sessionID.uuidString)
                bindText(insertStatement, index: 3, value: replacement.role.rawValue)
                bindText(insertStatement, index: 4, value: replacement.content)
                sqlite3_bind_double(insertStatement, 5, replacement.timestamp.timeIntervalSince1970)
                bindText(insertStatement, index: 6, value: encodeMetadata(replacement.metadata))
                guard sqlite3_step(insertStatement) == SQLITE_DONE else {
                    throw EpisodeStoreError.persistenceFailed("Could not write compaction summary \(replacement.id)")
                }
                try exec(handle: handle, sql: "COMMIT;")
            } catch {
                try? exec(handle: handle, sql: "ROLLBACK;")
                throw error
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

        /// Atomically counts then deletes all episodes in one transaction.
        ///
        /// `SELECT COUNT(*)` and `DELETE FROM episodes` run in one `BEGIN IMMEDIATE`/
        /// `COMMIT` transaction on the already-open handle, so a concurrent writer in
        /// another process cannot interleave between the measure and the delete.
        /// - Parameter dbPath: SQLite file path.
        /// - Returns: Episode count measured in the same transaction before deleting.
        static func clearReturningCount(dbPath: String) throws -> Int {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return 0 }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            try exec(handle: handle, sql: "BEGIN IMMEDIATE;")
            do {
                var countStatement: OpaquePointer?
                guard sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM episodes;", -1, &countStatement, nil) == SQLITE_OK else {
                    throw EpisodeStoreError.persistenceFailed("Could not count episodes")
                }
                let deleted: Int
                if sqlite3_step(countStatement) == SQLITE_ROW {
                    deleted = Int(sqlite3_column_int(countStatement, 0))
                } else {
                    sqlite3_finalize(countStatement)
                    throw EpisodeStoreError.persistenceFailed("Could not count episodes")
                }
                sqlite3_finalize(countStatement)
                try exec(handle: handle, sql: "DELETE FROM episodes; INSERT INTO episodes_fts(episodes_fts) VALUES('rebuild');")
                try exec(handle: handle, sql: "COMMIT;")
                return deleted
            } catch {
                try? exec(handle: handle, sql: "ROLLBACK;")
                throw error
            }
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
#endif
// JSON-file fallback lives in EpisodeStoreTypes.swift.
