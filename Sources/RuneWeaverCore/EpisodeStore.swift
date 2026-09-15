// Rune Weaver Core — SQLite-backed episodic memory with full-text search.
//
// Manages conversation turns in SQLite with FTS5 search, compaction, and
// JSON fallback when SQLite3 is unavailable. Funnels blocking I/O through
// SQLiteSerialIO to serialize disk access and keep actor methods suspension-friendly.

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
///
/// Blocking SQLite/JSON work runs off the actor executor via the shared
/// serial store queue (`SQLiteSerialIO`) so disk order matches actor call
/// order and shares ordering with the session, scheduler, and run stores
/// in `episodes.db`, keeping actor methods suspension-friendly.
public actor EpisodeStore {
    /// Filesystem path of the SQLite database (or JSON sidecar anchor).
    public let dbPath: String
    /// Summarizer applied when compacting old sessions.
    private let summarizer: EpisodeSummarizer
    /// Maximum rows returned per read.
    ///
    /// Bounds `episodes`, `recent`, and `search` so huge limits (e.g.
    /// `.max`) never materialize unbounded arrays; the SQLite layer
    /// additionally clamps to `Int32.max` at the bind boundary.
    private static let maxResults = 1000

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
    ///
    /// Blocking SQLite/JSON work runs off the actor executor via the
    /// shared serial store queue (`SQLiteSerialIO`) so the actor stays suspension-friendly.
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
    ///
    /// Audit path for cancelled turns: the caller is already cancelled when
    /// tools have executed, so a cancellable store would throw before dispatch
    /// and drop the mirror. Runs to completion on the shared serial store
    /// queue instead.
    /// - Parameters:
    ///   - sessionID: Owning session identifier.
    ///   - role: Who produced the content.
    ///   - content: Text content.
    ///   - metadata: Key/value annotations. Defaults to empty.
    /// - Returns: True when the write succeeded.
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
    ///
    /// Shares the cancelled-turn rationale above: audit writes issued while
    /// the task is already cancelled must still land.
    /// - Parameter episode: Episode to persist.
    /// - Returns: True when the write succeeded.
    @discardableResult
    public func storeUncancellable(_ episode: Episode) async -> Bool {
        let dbPath = self.dbPath
        let episodes = [episode]
        return await SQLiteSerialIO.runUncancellable {
            (try? EpisodeStoreIO.write(episodes: episodes, dbPath: dbPath, merge: true)) != nil
        }
    }

    // MARK: - Reads

    /// Returns episodes for one session, oldest first.
    ///
    /// When `limit` is set, returns the oldest `limit` episodes, not the
    /// newest. Use `recentEpisodes(for:limit:)` for resume hydration
    /// needing the newest turns. Storage order (`timestamp`, `rowid`) is
    /// preserved so rapid turns sharing a timestamp hydrate deterministically.
    /// The blocking read runs off the actor executor via the shared serial store queue (`SQLiteSerialIO`).
    /// - Parameters:
    ///   - sessionID: Owning session identifier.
    ///   - limit: Maximum episodes. Defaults to nil (all). When set,
    ///     the oldest `limit` rows are returned. Non-positive limits
    ///     return an empty list. Larger limits are capped.
    /// - Returns: Matching episodes in chronological order.
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
    ///
    /// Bounded resume path: fetches only the last `limit` turns instead
    /// of loading the whole session, then returns them in chronological
    /// order for direct history use. Storage order is preserved for
    /// deterministic hydration of same-timestamp turns. The blocking read
    /// runs off the actor executor via the shared serial store queue (`SQLiteSerialIO`).
    /// - Parameters:
    ///   - sessionID: Owning session identifier.
    ///   - limit: Maximum episodes. Non-positive limits return an empty list.
    ///     Larger limits are capped.
    /// - Returns: Newest episodes in chronological order.
    public func recentEpisodes(for sessionID: UUID, limit: Int) async throws -> [Episode] {
        guard limit > 0 else { return [] }
        let dbPath = self.dbPath
        let clamped = min(limit, Self.maxResults)
        return try await SQLiteSerialIO.run {
            try EpisodeStoreIO.recentEpisodes(sessionID: sessionID, dbPath: dbPath, limit: clamped)
        }
    }

    /// Returns the most recent episodes across all sessions.
    ///
    /// The blocking read runs off the actor executor via the shared serial store queue (`SQLiteSerialIO`).
    /// - Parameter limit: Maximum episodes. Defaults to 20. Non-positive
    ///   limits return an empty list. Larger limits are capped.
    /// - Returns: Episodes newest first.
    public func recent(limit: Int = 20) async throws -> [Episode] {
        guard limit > 0 else { return [] }
        let dbPath = self.dbPath
        let clamped = min(limit, Self.maxResults)
        return try await SQLiteSerialIO.run {
            try EpisodeStoreIO.recent(dbPath: dbPath, limit: clamped)
        }
    }

    /// Full-text search over episode content.
    ///
    /// Uses the FTS5 index (`porter` tokenizer, BM25 rank) when SQLite
    /// is available; otherwise falls back to case-insensitive token
    /// overlap scoring over the JSON sidecar. The blocking read runs off
    /// the actor executor via the shared serial store queue (`SQLiteSerialIO`).
    /// - Parameters:
    ///   - query: Search text.
    ///   - limit: Maximum results. Defaults to 10. Non-positive limits
    ///     return an empty list. Larger limits are capped.
    /// - Returns: Matching episodes, best first. Empty for blank queries.
    public func search(query: String, limit: Int = 10) async throws -> [Episode] {
        guard limit > 0 else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let dbPath = self.dbPath
        let clamped = min(limit, Self.maxResults)
        return try await SQLiteSerialIO.run {
            try EpisodeStoreIO.search(query: trimmed, dbPath: dbPath, limit: clamped)
        }
    }

    /// All session identifiers that have stored episodes.
    ///
    /// The blocking read runs off the actor executor via the shared serial store queue (`SQLiteSerialIO`).
    /// - Returns: Session identifiers.
    public func sessionIDs() async throws -> [UUID] {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run {
            try EpisodeStoreIO.sessionIDs(dbPath: dbPath)
        }
    }

    /// Total stored episode count.
    ///
    /// The blocking read runs off the actor executor via the shared serial store queue (`SQLiteSerialIO`).
    /// - Returns: Row count.
    public func count() async throws -> Int {
        let dbPath = self.dbPath
        return try await SQLiteSerialIO.run {
            try EpisodeStoreIO.count(dbPath: dbPath)
        }
    }

    // MARK: - Deletes

    /// Deletes one episode. Missing rows are a no-op.
    ///
    /// The blocking delete runs off the actor executor via the shared serial store queue (`SQLiteSerialIO`).
    /// - Parameter id: Episode identifier.
    public func delete(id: UUID) async throws {
        let dbPath = self.dbPath
        try await SQLiteSerialIO.run {
            try EpisodeStoreIO.delete(id: id, dbPath: dbPath)
        }
    }

    /// Deletes every episode for a session. Unknown sessions are a no-op.
    ///
    /// The blocking delete runs off the actor executor via the shared serial store queue (`SQLiteSerialIO`).
    /// - Parameter sessionID: Owning session identifier.
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

    // MARK: - Auto-summarization

    /// Summarizes sessions whose episodes are older than a cutoff.
    ///
    /// Non-destructive: the store is left untouched and the caller
    /// decides what to do with the returned summaries. The blocking read
    /// runs off the actor executor via the shared serial store queue (`SQLiteSerialIO`).
    /// - Parameters:
    ///   - olderThan: Episodes at or before this date are summarized.
    ///   - summarizer: Override summarizer. Defaults to the store's own.
    /// - Returns: One summary per session with old episodes.
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
    ///
    /// Each session with episodes at or before `olderThan` is summarized
    /// and its old rows are replaced by a single `system` episode
    /// carrying the summary, so keyword search keeps working while the
    /// table stays small. Each session compacts via `EpisodeStoreIO.compact`:
    /// SQLite runs delete plus insert atomically in one transaction while
    /// the JSON fallback writes the replacement first and then deletes so
    /// a crash never loses both. Blocking I/O runs off the actor executor
    /// via the shared serial store queue (`SQLiteSerialIO`).
    /// - Parameters:
    ///   - olderThan: Episodes at or before this date are compacted.
    ///   - summarizer: Override summarizer. Defaults to the store's own.
    /// - Returns: The summaries that replaced old rows.
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
    ///
    /// Useful after bulk imports or if the index ever drifts from the
    /// table. A no-op for the JSON fallback. The blocking rebuild runs
    /// off the actor executor via the shared serial store queue (`SQLiteSerialIO`).
    public func rebuildSearchIndex() async throws {
        let dbPath = self.dbPath
        try await SQLiteSerialIO.run {
            try EpisodeStoreIO.rebuildFTS(dbPath: dbPath)
        }
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
    ///
    /// When `limit` is set, returns the oldest `limit` rows. See
    /// `recentEpisodes(sessionID:dbPath:limit:)` for the newest window.
    /// - Parameters:
    ///   - sessionID: Owning session identifier.
    ///   - dbPath: SQLite path (or JSON sidecar anchor).
    ///   - limit: Maximum rows, nil for all. When set, the oldest rows
    ///     are returned.
    /// - Returns: Matching episodes.
    static func episodes(sessionID: UUID, dbPath: String, limit: Int?) throws -> [Episode] {
        #if canImport(SQLite3)
            return try SQLiteEpisodeStore.episodes(sessionID: sessionID, dbPath: dbPath, limit: limit)
        #else
            return try JSONEpisodeStore.episodes(sessionID: sessionID, dbPath: dbPath, limit: limit)
        #endif
    }

    /// Reads one session's newest episodes, oldest first.
    ///
    /// Bounded resume path returning the last `limit` turns in
    /// chronological order.
    /// - Parameters:
    ///   - sessionID: Owning session identifier.
    ///   - dbPath: SQLite path (or JSON sidecar anchor).
    ///   - limit: Maximum rows.
    /// - Returns: Newest episodes in chronological order.
    static func recentEpisodes(sessionID: UUID, dbPath: String, limit: Int) throws -> [Episode] {
        #if canImport(SQLite3)
            return try SQLiteEpisodeStore.recentEpisodes(sessionID: sessionID, dbPath: dbPath, limit: limit)
        #else
            return try JSONEpisodeStore.recentEpisodes(sessionID: sessionID, dbPath: dbPath, limit: limit)
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

    /// Replaces one session's old episodes with a summary episode.
    ///
    /// SQLite compacts in one transaction so a crash between delete and
    /// insert never loses both; the JSON fallback writes the replacement
    /// first and then deletes the old rows so a crash never loses both
    /// (at worst both remain).
    /// - Parameters:
    ///   - sessionID: Owning session identifier.
    ///   - beforeOrAt: Inclusive upper bound on `timestamp` for deleted rows.
    ///   - replacement: Summary episode to insert.
    ///   - dbPath: SQLite path (or JSON sidecar anchor).
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
            // Shared busy_timeout/WAL policy lives in `SQLiteHelpers.openHandle`.
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
                    INSERT INTO episodes_fts(episodes_fts, rowid, content) VALUES('delete', old.rowid, old.content);
                END;
                CREATE TRIGGER IF NOT EXISTS episodes_au AFTER UPDATE ON episodes BEGIN
                    INSERT INTO episodes_fts(episodes_fts, rowid, content) VALUES('delete', old.rowid, old.content);
                    INSERT INTO episodes_fts(rowid, content) VALUES(new.rowid, new.content);
                END;
                """,
                failure: EpisodeStoreError.persistenceFailed
            )
            return handle
        }

        /// Executes a multi-statement SQL string.
        /// - Parameters:
        ///   - handle: Open database handle.
        ///   - sql: SQL to execute.
        private static func exec(handle: OpaquePointer?, sql: String) throws {
            try SQLiteHelpers.exec(handle: handle, sql: sql, failure: EpisodeStoreError.persistenceFailed)
        }

        /// Binds optional text, mapping nil to NULL.
        /// - Parameters:
        ///   - statement: Prepared statement.
        ///   - index: One-based bind index.
        ///   - value: Text value, or nil for NULL.
        private static func bindText(_ statement: OpaquePointer?, index: Int32, value: String?) {
            SQLiteHelpers.bindText(statement, index: index, value: value)
        }

        /// Clamps a limit to the SQLite bind range.
        ///
        /// `sqlite3_bind_int` truncates wider values, so a large limit
        /// (e.g. `.max`) would wrap negative, which SQLite treats as
        /// unlimited. Clamping keeps `LIMIT` semantics identical across
        /// the SQLite and JSON stores.
        /// - Parameter limit: Requested maximum rows (positive).
        /// - Returns: Value safe for `sqlite3_bind_int`.
        private static func sqliteLimit(_ limit: Int) -> Int32 {
            Int32(min(limit, Int(Int32.max)))
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
            SQLiteHelpers.columnText(statement, index: index)
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

        /// Reads one session's episodes, oldest first.
        ///
        /// When `limit` is set, returns the oldest `limit` rows. See
        /// `recentEpisodes(sessionID:dbPath:limit:)` for the newest window.
        /// - Parameters:
        ///   - sessionID: Owning session identifier.
        ///   - dbPath: SQLite file path.
        ///   - limit: Maximum rows, nil for all. When set, the oldest rows
        ///     are returned. Non-positive limits return an empty list.
        /// - Returns: Matching episodes.
        static func episodes(sessionID: UUID, dbPath: String, limit: Int?) throws -> [Episode] {
            if let limit, limit <= 0 {
                return []
            }
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
                sqlite3_bind_int(statement, 2, sqliteLimit(limit))
            }
            var results: [Episode] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let episode = readEpisode(statement) {
                    results.append(episode)
                }
            }
            return results
        }

        /// Reads one session's newest episodes, oldest first.
        ///
        /// Bounded resume path: selects the last `limit` rows via
        /// `ORDER BY timestamp DESC LIMIT` then returns them in
        /// chronological order so hydration can use them directly.
        /// - Parameters:
        ///   - sessionID: Owning session identifier.
        ///   - dbPath: SQLite file path.
        ///   - limit: Maximum rows. Non-positive limits return an empty list.
        /// - Returns: Newest episodes in chronological order.
        static func recentEpisodes(sessionID: UUID, dbPath: String, limit: Int) throws -> [Episode] {
            guard limit > 0 else { return [] }
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return [] }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            let sql = "SELECT id, session_id, role, content, timestamp, metadata FROM episodes "
                + "WHERE session_id = ? ORDER BY timestamp DESC, rowid DESC LIMIT ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw EpisodeStoreError.persistenceFailed("Could not prepare recent episode read")
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, index: 1, value: sessionID.uuidString)
            sqlite3_bind_int(statement, 2, sqliteLimit(limit))
            var results: [Episode] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let episode = readEpisode(statement) {
                    results.append(episode)
                }
            }
            return Array(results.reversed())
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
            let sql = "SELECT id, session_id, role, content, timestamp, metadata FROM episodes "
                + "WHERE timestamp <= ? ORDER BY timestamp ASC, rowid ASC;"
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
        ///   - limit: Maximum rows. Non-positive limits return an empty list.
        /// - Returns: Episodes newest first.
        static func recent(dbPath: String, limit: Int) throws -> [Episode] {
            guard limit > 0 else { return [] }
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return [] }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            let sql = "SELECT id, session_id, role, content, timestamp, metadata FROM episodes "
                + "ORDER BY timestamp DESC, rowid DESC LIMIT ?;"
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw EpisodeStoreError.persistenceFailed("Could not prepare recent read")
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, sqliteLimit(limit))
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
        /// Runs the FTS5 `porter`/BM25 query first; when it succeeds with
        /// hits those are returned, and when it succeeds empty or fails
        /// the search falls back to a case-insensitive `LIKE` scan (SQLite
        /// `LIKE` is case-insensitive for ASCII, matching the JSON fallback;
        /// `%`, `_`, and `\` escaped) so literal queries still recall.
        /// The fallback matches the full phrase or any query token (`OR`)
        /// to mirror `Tokenization.keywordScore` token-overlap recall used
        /// by the JSON store. Patterns are capped to stay well under
        /// `SQLITE_MAX_VARIABLE_NUMBER` so long queries degrade
        /// gracefully instead of failing `prepare`.
        /// - Parameters:
        ///   - query: Search text.
        ///   - dbPath: SQLite file path.
        ///   - limit: Maximum results. Non-positive limits return an empty list.
        /// - Returns: Matching episodes, best first.
        static func search(query: String, dbPath: String, limit: Int) throws -> [Episode] {
            guard limit > 0 else { return [] }
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return [] }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            let ftsQuery = ftsEscaped(query)
            let sql = """
            SELECT e.id, e.session_id, e.role, e.content, e.timestamp, e.metadata
            FROM episodes_fts JOIN episodes e ON e.rowid = episodes_fts.rowid
            WHERE episodes_fts MATCH ? ORDER BY rank, e.rowid DESC LIMIT ?;
            """
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK {
                bindText(statement, index: 1, value: ftsQuery)
                sqlite3_bind_int(statement, 2, sqliteLimit(limit))
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
                if succeeded, !results.isEmpty {
                    return results
                }
                // Fall through to the LIKE scan when FTS succeeds empty
                // or errors after prepare, so stemming gaps and token
                // mismatches still recall literal matches.
            } else if statement != nil {
                sqlite3_finalize(statement)
            }
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
            let conditions = patterns.map { _ in "content LIKE ? ESCAPE '\\'" }.joined(separator: " OR ")
            let likeSQL = "SELECT id, session_id, role, content, timestamp, metadata FROM episodes "
                + "WHERE (\(conditions)) ORDER BY timestamp DESC, rowid DESC LIMIT ?;"
            var fallback: OpaquePointer?
            guard sqlite3_prepare_v2(handle, likeSQL, -1, &fallback, nil) == SQLITE_OK else {
                throw EpisodeStoreError.persistenceFailed("Could not prepare episode search")
            }
            defer { sqlite3_finalize(fallback) }
            for (index, pattern) in patterns.enumerated() {
                bindText(fallback, index: Int32(index + 1), value: pattern)
            }
            sqlite3_bind_int(fallback, Int32(patterns.count + 1), sqliteLimit(limit))
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
        ///
        /// Every whitespace-separated token becomes a quoted `OR` phrase
        /// (embedded quotes doubled) with no token-count truncation so
        /// long queries keep full recall.
        /// - Parameter query: Raw search text.
        /// - Returns: Quoted phrases joined by `OR`.
        private static func ftsEscaped(_ query: String) -> String {
            let tokens = query.split { $0.isWhitespace || $0.isNewline }.map { String($0) }.filter { !$0.isEmpty }
            guard !tokens.isEmpty else { return "\"\"" }
            let phrases = tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            return phrases.joined(separator: " OR ")
        }
    }

    // MARK: - SQLiteEpisodeStore Maintenance

    /// Session lookups and maintenance for the SQLite store.
    ///
    /// Split into an extension so the main store body stays within
    /// the `type_body_length` budget.
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

        /// Atomically replaces one session's old episodes with a summary episode.
        ///
        /// Deletes rows at or before `beforeOrAt` and inserts `replacement`
        /// in one `BEGIN IMMEDIATE`/`COMMIT` transaction so a failure rolls
        /// back both halves instead of losing history without a summary.
        /// - Parameters:
        ///   - sessionID: Owning session identifier.
        ///   - beforeOrAt: Inclusive upper bound on `timestamp` for deleted rows.
        ///   - replacement: Summary episode to insert.
        ///   - dbPath: SQLite file path.
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
        ///
        /// Ties on `timestamp` break by file creation order (the JSON
        /// equivalent of SQLite `rowid`), then by identifier, so rapid
        /// turns sharing a timestamp hydrate deterministically and in
        /// the same insertion order as the SQLite backend.
        /// - Parameter dbPath: Anchor path for the sidecar directory.
        /// - Returns: Stored episodes, empty when the directory is missing.
        private static func readAll(dbPath: String) throws -> [Episode] {
            try readEntries(dbPath: dbPath).sorted {
                if $0.episode.timestamp != $1.episode.timestamp {
                    return $0.episode.timestamp < $1.episode.timestamp
                }
                switch ($0.created, $1.created) {
                case let (lhs?, rhs?):
                    if lhs != rhs {
                        return lhs < rhs
                    }
                case (nil, _?):
                    return true
                case (_?, nil):
                    return false
                case (nil, nil):
                    break
                }
                return $0.episode.id.uuidString < $1.episode.id.uuidString
            }.map(\.episode)
        }

        /// Maximum JSON episode files retained or decoded simultaneously.
        static let maxJSONFiles = 2000

        /// Reads every stored episode with its file creation date.
        ///
        /// The creation date preserves insertion order for
        /// same-timestamp turns, mirroring SQLite `rowid` ordering.
        /// - Parameter dbPath: Anchor path for the sidecar directory.
        /// - Returns: Episodes paired with file creation dates (nil when
        ///   unavailable), empty when the directory is missing.
        private static func readEntries(dbPath: String) throws -> [(episode: Episode, created: Date?)] {
            let directoryURL = directory(dbPath: dbPath)
            guard FileManager.default.fileExists(atPath: directoryURL.path) else { return [] }
            do {
                let files = try FileManager.default.contentsOfDirectory(
                    at: directoryURL,
                    includingPropertiesForKeys: [.creationDateKey],
                    options: []
                )
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .secondsSince1970
                let jsonFiles = files.filter { $0.pathExtension == "json" }
                let candidateFiles = if jsonFiles.count > maxJSONFiles {
                    jsonFiles.sorted {
                        let creationDate1 = (try? $0.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                        let creationDate2 = (try? $1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                        return creationDate1 > creationDate2
                    }.prefix(maxJSONFiles).reversed()
                } else {
                    jsonFiles
                }
                var entries: [(episode: Episode, created: Date?)] = []
                entries.reserveCapacity(candidateFiles.count)
                for file in candidateFiles {
                    let episode = try decoder.decode(Episode.self, from: Data(contentsOf: file))
                    let created = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                    entries.append((episode: episode, created: created))
                }
                return entries
            } catch let error as EpisodeStoreError {
                throw error
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
                let allFiles = (try? FileManager.default.contentsOfDirectory(
                    at: directoryURL,
                    includingPropertiesForKeys: [.creationDateKey]
                ))?.filter { $0.pathExtension == "json" } ?? []
                if allFiles.count > maxJSONFiles {
                    let sorted = allFiles.sorted {
                        let creationDate1 = (try? $0.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                        let creationDate2 = (try? $1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                        return creationDate1 < creationDate2
                    }
                    let excess = sorted.prefix(allFiles.count - maxJSONFiles)
                    for file in excess {
                        try? FileManager.default.removeItem(at: file)
                    }
                }
            } catch let error as EpisodeStoreError {
                throw error
            } catch {
                throw EpisodeStoreError.persistenceFailed("Could not write episodes: \(error.localizedDescription)")
            }
        }

        /// Reads one session's episodes, oldest first.
        ///
        /// When `limit` is set, returns the oldest `limit` rows. See
        /// `recentEpisodes(sessionID:dbPath:limit:)` for the newest window.
        /// - Parameters:
        ///   - sessionID: Owning session identifier.
        ///   - dbPath: Anchor path for the sidecar directory.
        ///   - limit: Maximum rows, nil for all. When set, the oldest rows
        ///     are returned. Non-positive limits return an empty list.
        /// - Returns: Matching episodes.
        static func episodes(sessionID: UUID, dbPath: String, limit: Int?) throws -> [Episode] {
            if let limit, limit <= 0 {
                return []
            }
            let matching = try readAll(dbPath: dbPath).filter { $0.sessionID == sessionID }
            guard let limit else { return matching }
            return Array(matching.prefix(limit))
        }

        /// Reads one session's newest episodes, oldest first.
        ///
        /// Bounded resume path returning the last `limit` turns in
        /// chronological order.
        /// - Parameters:
        ///   - sessionID: Owning session identifier.
        ///   - dbPath: Anchor path for the sidecar directory.
        ///   - limit: Maximum rows. Non-positive limits return an empty list.
        /// - Returns: Newest episodes in chronological order.
        static func recentEpisodes(sessionID: UUID, dbPath: String, limit: Int) throws -> [Episode] {
            guard limit > 0 else { return [] }
            let matching = try readAll(dbPath: dbPath).filter { $0.sessionID == sessionID }
            return Array(matching.suffix(limit))
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
        ///
        /// Ties on `timestamp` break by file creation order descending
        /// (the JSON equivalent of SQLite `rowid DESC`), then by
        /// identifier, mirroring the SQLite backend.
        /// - Parameters:
        ///   - dbPath: Anchor path for the sidecar directory.
        ///   - limit: Maximum rows. Non-positive limits return an empty list.
        /// - Returns: Episodes newest first.
        static func recent(dbPath: String, limit: Int) throws -> [Episode] {
            guard limit > 0 else { return [] }
            let sorted = try readEntries(dbPath: dbPath).sorted {
                if $0.episode.timestamp != $1.episode.timestamp {
                    return $0.episode.timestamp > $1.episode.timestamp
                }
                switch ($0.created, $1.created) {
                case let (lhs?, rhs?):
                    if lhs != rhs {
                        return lhs > rhs
                    }
                case (nil, _?):
                    return false
                case (_?, nil):
                    return true
                case (nil, nil):
                    break
                }
                return $0.episode.id.uuidString > $1.episode.id.uuidString
            }.map(\.episode)
            return Array(sorted.prefix(limit))
        }

        /// Token-overlap search over episode content.
        /// - Parameters:
        ///   - query: Search text.
        ///   - dbPath: Anchor path for the sidecar directory.
        ///   - limit: Maximum results. Non-positive limits return an empty list.
        /// - Returns: Matching episodes, best first.
        static func search(query: String, dbPath: String, limit: Int) throws -> [Episode] {
            guard limit > 0 else { return [] }
            let all = try readAll(dbPath: dbPath)
            let queryTokens = Tokenization.tokenize(query)
            guard !queryTokens.isEmpty else { return [] }
            let scored = all.compactMap { episode -> (Episode, Int)? in
                let contentTokens = Tokenization.tokenize(episode.content)
                guard let raw = Tokenization.keywordScore(
                    queryTokens: queryTokens,
                    contentTokens: contentTokens,
                    content: episode.content,
                    query: query
                ) else { return nil }
                return (episode, raw)
            }
            return scored
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.timestamp > $1.0.timestamp }
                .prefix(limit)
                .map(\.0)
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

        /// Replaces one session's old episodes with a summary episode.
        ///
        /// Crash-safe for the file backend: writes the replacement first,
        /// then deletes the old rows, so a crash between the halves never
        /// loses both (at worst both remain). Unlike the SQLite backend,
        /// the two halves are separate file operations, not one transaction.
        /// The replacement is excluded by identifier so it survives even
        /// when its timestamp falls at or before `beforeOrAt`.
        /// - Parameters:
        ///   - sessionID: Owning session identifier.
        ///   - beforeOrAt: Inclusive upper bound on `timestamp` for deleted rows.
        ///   - replacement: Summary episode to insert.
        ///   - dbPath: Anchor path for the sidecar directory.
        static func compact(sessionID: UUID, beforeOrAt: Date, replacement: Episode, dbPath: String) throws {
            try write(episodes: [replacement], dbPath: dbPath, merge: true)
            for episode in try readAll(dbPath: dbPath)
                where episode.sessionID == sessionID && episode.timestamp <= beforeOrAt && episode.id != replacement.id
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
