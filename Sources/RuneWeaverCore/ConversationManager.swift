import Foundation

#if canImport(SQLite3)
    import SQLite3
#endif

/// A single conversation session owned by the manager.
///
/// Sessions group messages for one continuous interaction. When the
/// history outgrows the context window the oldest turns are folded
/// into `summary` so recent context stays intact.
public struct ConversationSession: Sendable, Codable, Equatable, Identifiable {
    /// Unique identifier for this session.
    public let id: UUID
    /// Messages in chronological order.
    public var messages: [Message]
    /// Rolling summary of truncated turns, if any.
    public var summary: String?
    /// Creation timestamp.
    public let createdAt: Date
    /// Last mutation timestamp.
    public var updatedAt: Date

    /// Creates a session.
    /// - Parameters:
    ///   - id: Session identifier. Defaults to a new UUID.
    ///   - messages: Initial messages. Defaults to empty.
    ///   - summary: Rolling summary. Defaults to nil.
    ///   - createdAt: Creation date. Defaults to now.
    ///   - updatedAt: Last mutation date. Defaults to now.
    public init(
        id: UUID = UUID(),
        messages: [Message] = [],
        summary: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.messages = messages
        self.summary = summary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Failures raised by ``ConversationManager`` persistence.
public enum ConversationManagerError: Error, Sendable, Equatable {
    /// The SQLite store could not be opened or migrated.
    case storeUnavailable(String)
    /// A read or write against the store failed.
    case persistenceFailed(String)
    /// No session exists for the given identifier.
    case unknownSession(String)
}

/// Summarizes dropped turns during truncation.
///
/// Takes the messages being evicted and returns a short summary that
/// is kept as session state. Callers may inject an LLM-backed
/// summarizer; the default is an extractive preview.
/// - Parameter messages: Messages being evicted.
/// - Returns: Summary text.
public typealias SessionSummarizer = @Sendable ([Message]) -> String

/// Default extractive summarizer used when no LLM is wired in.
///
/// Joins the first line of each evicted message, truncated to a
/// bounded length, so no data leaves the machine for summarization.
/// - Parameter messages: Messages being evicted.
/// - Returns: Summary preview.
public func defaultSessionSummarizer(_ messages: [Message]) -> String {
    let parts = messages.map { message -> String in
        let firstLine = message.content.split(separator: "\n").first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return "[\(message.role.rawValue)] \(trimmed)"
    }
    let joined = parts.joined(separator: "; ")
    if joined.count > 2000 {
        return String(joined.prefix(2000)) + "…"
    }
    return joined
}

/// Manages multiple concurrent conversation sessions.
///
/// The manager keeps per-session message history in memory, truncates
/// the context window via summarization when `maxMessages` is
/// exceeded, and persists sessions to SQLite (`episodesDBPath`, the
/// `episodes.db` file from `config.toml`). Where the SQLite3 module
/// is unavailable the manager falls back to JSON files beside the
/// configured database path so behavior stays identical.
public actor ConversationManager {
    /// Maximum messages retained per session before truncation.
    public let maxMessages: Int
    /// Filesystem path of the episodes database, if configured.
    public let episodesDBPath: String?
    /// Summarizer applied to evicted turns.
    private let summarizer: SessionSummarizer

    /// Sessions indexed by identifier.
    private var sessions: [UUID: ConversationSession] = [:]

    /// Creates a manager.
    /// - Parameters:
    ///   - maxMessages: Messages retained per session before
    ///     truncation. Defaults to 100.
    ///   - episodesDBPath: SQLite path for session persistence.
    ///     Defaults to nil (memory only until `load`/`save` with a path).
    ///   - summarizer: Summarizer for evicted turns. Defaults to
    ///     ``defaultSessionSummarizer``.
    public init(
        maxMessages: Int = 100,
        episodesDBPath: String? = nil,
        summarizer: SessionSummarizer? = nil
    ) {
        self.maxMessages = max(1, maxMessages)
        self.episodesDBPath = episodesDBPath
        self.summarizer = summarizer ?? defaultSessionSummarizer
    }

    // MARK: - Sessions

    /// Creates a new empty session and tracks it.
    /// - Returns: The new session.
    @discardableResult
    public func createSession() -> ConversationSession {
        let session = ConversationSession()
        sessions[session.id] = session
        persistBestEffort(session)
        return session
    }

    /// Returns the session with the given identifier.
    /// - Parameter id: Session identifier.
    /// - Returns: The session, or nil when unknown.
    public func session(id: UUID) -> ConversationSession? {
        sessions[id]
    }

    /// Returns the session, creating it when missing.
    /// - Parameter id: Session identifier.
    /// - Returns: The existing or newly created session.
    @discardableResult
    public func ensureSession(id: UUID) -> ConversationSession {
        if let existing = sessions[id] {
            return existing
        }
        let session = ConversationSession(id: id)
        sessions[id] = session
        return session
    }

    /// All tracked session identifiers.
    public var sessionIDs: [UUID] {
        Array(sessions.keys)
    }

    /// Removes a session from memory (and the store on next save).
    /// - Parameter id: Session identifier.
    public func removeSession(id: UUID) {
        sessions.removeValue(forKey: id)
        deletePersistedSessionBestEffort(id: id)
    }

    /// Removes all sessions from memory.
    public func removeAllSessions() {
        sessions.removeAll()
    }

    // MARK: - History

    /// Appends a message to a session, truncating when over budget.
    ///
    /// Missing sessions are created implicitly. Truncation folds the
    /// oldest turns into the session summary via the configured
    /// summarizer, keeping system messages and the most recent turns.
    /// - Parameters:
    ///   - message: Message to append.
    ///   - sessionID: Owning session identifier.
    public func append(_ message: Message, to sessionID: UUID) {
        var session = ensureSession(id: sessionID)
        session.messages.append(message)
        session.updatedAt = Date()
        truncateIfNeeded(sessionID: session.id, messages: &session.messages, summary: &session.summary)
        sessions[session.id] = session
        persistBestEffort(session)
    }

    /// Returns context-ready history for a session.
    ///
    /// When the session carries a summary of truncated turns it is
    /// prepended as a `system` message so the LLM retains the gist of
    /// evicted history.
    /// - Parameter sessionID: Session identifier.
    /// - Returns: Messages for the LLM, or empty when unknown.
    public func history(for sessionID: UUID) -> [Message] {
        guard let session = sessions[sessionID] else { return [] }
        guard let summary = session.summary, !summary.isEmpty else {
            return session.messages
        }
        let summaryMessage = Message(role: .system, content: "Earlier in this conversation: \(summary)")
        return [summaryMessage] + session.messages
    }

    /// Raw message count for a session.
    /// - Parameter sessionID: Session identifier.
    /// - Returns: Stored message count, or zero when unknown.
    public func messageCount(for sessionID: UUID) -> Int {
        sessions[sessionID]?.messages.count ?? 0
    }

    /// Clears messages (and summary) for one session.
    /// - Parameter sessionID: Session identifier.
    public func clear(sessionID: UUID) {
        guard var session = sessions[sessionID] else { return }
        session.messages.removeAll()
        session.summary = nil
        session.updatedAt = Date()
        sessions[sessionID] = session
        persistBestEffort(session)
    }

    // MARK: - Truncation

    /// Summarizes a session's oldest turns on demand.
    ///
    /// Keeps the newest `keeping` messages verbatim and folds the rest
    /// into the session summary.
    /// - Parameters:
    ///   - sessionID: Session identifier.
    ///   - keeping: Recent messages to keep. Defaults to `maxMessages`.
    /// - Returns: Summary text, or nil when the session is unknown
    ///   or already within budget.
    @discardableResult
    public func summarize(sessionID: UUID, keeping: Int? = nil) -> String? {
        guard var session = sessions[sessionID] else { return nil }
        let keep = max(1, keeping ?? maxMessages)
        guard session.messages.count > keep else { return session.summary }
        let evicted = Array(session.messages.prefix(session.messages.count - keep))
        let summary = summarizer(evicted)
        session.summary = [session.summary, summary]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: "\n")
        session.messages = Array(session.messages.suffix(keep))
        session.updatedAt = Date()
        sessions[sessionID] = session
        persistBestEffort(session)
        return session.summary
    }

    /// Evicts oldest non-system turns when over `maxMessages`.
    /// - Parameters:
    ///   - sessionID: Owning session, for persistence.
    ///   - messages: In-out message buffer to truncate.
    ///   - summary: In-out summary to extend with evicted turns.
    private func truncateIfNeeded(sessionID _: UUID, messages: inout [Message], summary: inout String?) {
        guard messages.count > maxMessages else { return }
        let overflow = messages.count - maxMessages
        var evicted: [Message] = []
        var kept: [Message] = []
        kept.reserveCapacity(maxMessages)
        var dropped = 0
        for message in messages {
            if dropped < overflow, message.role != .system {
                evicted.append(message)
                dropped += 1
            } else if dropped < overflow {
                kept.append(message)
            } else {
                kept.append(message)
            }
        }
        if dropped < overflow {
            let extra = overflow - dropped
            evicted.append(contentsOf: kept.prefix(extra))
            kept = Array(kept.dropFirst(extra))
        }
        guard !evicted.isEmpty else { return }
        let chunk = summarizer(evicted)
        if let existing = summary, !existing.isEmpty {
            summary = existing + "\n" + chunk
        } else {
            summary = chunk
        }
        messages = kept
    }

    // MARK: - Persistence (SQLite with JSON fallback)

    /// Saves all tracked sessions to the configured store.
    ///
    /// Uses SQLite at `episodesDBPath` when set; otherwise this is a
    /// no-op. Failures throw so schedulers can retry.
    public func saveAll() throws {
        guard let path = episodesDBPath else { return }
        let snapshot = Array(sessions.values)
        try SessionStoreIO.write(sessions: snapshot, dbPath: path)
    }

    /// Loads sessions from the configured store, replacing memory.
    ///
    /// Uses SQLite at `episodesDBPath` when set; otherwise this is a
    /// no-op. Missing files load as empty.
    public func loadAll() throws {
        guard let path = episodesDBPath else { return }
        let loaded = try SessionStoreIO.read(dbPath: path)
        sessions = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
    }

    /// Saves one session without throwing (used after every append).
    /// - Parameter session: Session to persist.
    private func persistBestEffort(_ session: ConversationSession) {
        guard let path = episodesDBPath else { return }
        try? SessionStoreIO.write(sessions: [session], dbPath: path, merge: true)
    }

    /// Deletes one persisted session without throwing.
    /// - Parameter id: Session identifier.
    private func deletePersistedSessionBestEffort(id: UUID) {
        guard let path = episodesDBPath else { return }
        try? SessionStoreIO.delete(sessionID: id, dbPath: path)
    }
}

// MARK: - Session store I/O

/// File and SQLite I/O for conversation sessions.
///
/// Prefers the SQLite `sessions` table when the SQLite3 module is
/// available; otherwise persists each session as JSON beside the
/// configured database path so Linux CI and hosts without SQLite
/// headers behave identically.
enum SessionStoreIO {
    /// Writes sessions to the store.
    /// - Parameters:
    ///   - sessions: Sessions to write.
    ///   - dbPath: SQLite path (or JSON sidecar anchor).
    ///   - merge: When true, upserts without dropping other rows.
    static func write(sessions: [ConversationSession], dbPath: String, merge: Bool = false) throws {
        #if canImport(SQLite3)
            try SQLiteSessionStore.write(sessions: sessions, dbPath: dbPath, merge: merge)
        #else
            try JSONSessionStore.write(sessions: sessions, dbPath: dbPath, merge: merge)
        #endif
    }

    /// Reads all sessions from the store.
    /// - Parameter dbPath: SQLite path (or JSON sidecar anchor).
    /// - Returns: Stored sessions, empty when the store is missing.
    static func read(dbPath: String) throws -> [ConversationSession] {
        #if canImport(SQLite3)
            return try SQLiteSessionStore.read(dbPath: dbPath)
        #else
            return try JSONSessionStore.read(dbPath: dbPath)
        #endif
    }

    /// Deletes one session from the store. Missing rows are a no-op.
    /// - Parameters:
    ///   - sessionID: Session identifier.
    ///   - dbPath: SQLite path (or JSON sidecar anchor).
    static func delete(sessionID: UUID, dbPath: String) throws {
        #if canImport(SQLite3)
            try SQLiteSessionStore.delete(sessionID: sessionID, dbPath: dbPath)
        #else
            try JSONSessionStore.delete(sessionID: sessionID, dbPath: dbPath)
        #endif
    }
}

#if canImport(SQLite3)
    /// Minimal SQLite store for sessions and their messages.
    ///
    /// Schema:
    /// `sessions(id TEXT PRIMARY KEY, summary TEXT, created_at REAL, updated_at REAL)`
    /// `messages(id TEXT PRIMARY KEY, session_id TEXT, role TEXT, content TEXT, tool_call_id TEXT, created_at REAL)`
    enum SQLiteSessionStore {
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
                throw ConversationManagerError.storeUnavailable("Could not open SQLite store at \(dbPath)")
            }
            try exec(
                handle: handle,
                sql: """
                CREATE TABLE IF NOT EXISTS sessions(
                    id TEXT PRIMARY KEY,
                    summary TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS messages(
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL,
                    role TEXT NOT NULL,
                    content TEXT NOT NULL,
                    tool_call_id TEXT,
                    created_at REAL NOT NULL,
                    FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE
                );
                CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id);
                """
            )
            try exec(handle: handle, sql: "PRAGMA foreign_keys = ON;")
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
                throw ConversationManagerError.persistenceFailed(detail)
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

        /// Writes sessions, optionally preserving existing rows.
        /// - Parameters:
        ///   - sessions: Sessions to upsert.
        ///   - dbPath: SQLite file path.
        ///   - merge: When false, replaces the whole store atomically.
        static func write(sessions: [ConversationSession], dbPath: String, merge: Bool) throws {
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            try exec(handle: handle, sql: "BEGIN IMMEDIATE;")
            do {
                if !merge {
                    try exec(handle: handle, sql: "DELETE FROM messages; DELETE FROM sessions;")
                }
                for session in sessions {
                    try upsert(session: session, handle: handle)
                }
                try exec(handle: handle, sql: "COMMIT;")
            } catch {
                try? exec(handle: handle, sql: "ROLLBACK;")
                throw error
            }
        }

        /// Upserts one session and rewrites its messages.
        /// - Parameters:
        ///   - session: Session to store.
        ///   - handle: Open database handle.
        private static func upsert(session: ConversationSession, handle: OpaquePointer?) throws {
            var sessionStatement: OpaquePointer?
            let sessionSQL = "INSERT INTO sessions(id, summary, created_at, updated_at) VALUES(?, ?, ?, ?) "
                + "ON CONFLICT(id) DO UPDATE SET summary=excluded.summary, updated_at=excluded.updated_at;"
            guard sqlite3_prepare_v2(handle, sessionSQL, -1, &sessionStatement, nil) == SQLITE_OK else {
                throw ConversationManagerError.persistenceFailed("Could not prepare session upsert")
            }
            defer { sqlite3_finalize(sessionStatement) }
            bindText(sessionStatement, index: 1, value: session.id.uuidString)
            bindText(sessionStatement, index: 2, value: session.summary)
            sqlite3_bind_double(sessionStatement, 3, session.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(sessionStatement, 4, session.updatedAt.timeIntervalSince1970)
            guard sqlite3_step(sessionStatement) == SQLITE_DONE else {
                throw ConversationManagerError.persistenceFailed("Could not write session \(session.id)")
            }
            var deleteStatement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "DELETE FROM messages WHERE session_id = ?;", -1, &deleteStatement, nil) == SQLITE_OK else {
                throw ConversationManagerError.persistenceFailed("Could not prepare message cleanup")
            }
            defer { sqlite3_finalize(deleteStatement) }
            bindText(deleteStatement, index: 1, value: session.id.uuidString)
            guard sqlite3_step(deleteStatement) == SQLITE_DONE else {
                throw ConversationManagerError.persistenceFailed("Could not rewrite messages for \(session.id)")
            }
            let messageSQL = "INSERT INTO messages(id, session_id, role, content, tool_call_id, created_at) VALUES(?, ?, ?, ?, ?, ?);"
            for message in session.messages {
                var messageStatement: OpaquePointer?
                guard sqlite3_prepare_v2(handle, messageSQL, -1, &messageStatement, nil) == SQLITE_OK else {
                    throw ConversationManagerError.persistenceFailed("Could not prepare message insert")
                }
                defer { sqlite3_finalize(messageStatement) }
                bindText(messageStatement, index: 1, value: message.id.uuidString)
                bindText(messageStatement, index: 2, value: session.id.uuidString)
                bindText(messageStatement, index: 3, value: message.role.rawValue)
                bindText(messageStatement, index: 4, value: message.content)
                bindText(messageStatement, index: 5, value: message.toolCallID)
                sqlite3_bind_double(messageStatement, 6, message.createdAt.timeIntervalSince1970)
                guard sqlite3_step(messageStatement) == SQLITE_DONE else {
                    throw ConversationManagerError.persistenceFailed("Could not write message \(message.id)")
                }
            }
        }

        /// Reads all sessions with their messages in order.
        /// - Parameter dbPath: SQLite file path.
        /// - Returns: Stored sessions, empty when the file is missing.
        static func read(dbPath: String) throws -> [ConversationSession] {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return [] }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            var sessionsByID: [String: ConversationSession] = [:]
            var order: [String] = []
            var sessionStatement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "SELECT id, summary, created_at, updated_at FROM sessions;", -1, &sessionStatement, nil) == SQLITE_OK else {
                throw ConversationManagerError.persistenceFailed("Could not read sessions")
            }
            defer { sqlite3_finalize(sessionStatement) }
            while sqlite3_step(sessionStatement) == SQLITE_ROW {
                guard let idText = sqlite3_column_text(sessionStatement, 0).map({ String(cString: $0) }),
                      let id = UUID(uuidString: idText)
                else { continue }
                let summaryText = sqlite3_column_text(sessionStatement, 1).map { String(cString: $0) }
                let summary = (summaryText?.isEmpty == false) ? summaryText : nil
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(sessionStatement, 2))
                let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(sessionStatement, 3))
                sessionsByID[idText] = ConversationSession(id: id, messages: [], summary: summary, createdAt: createdAt, updatedAt: updatedAt)
                order.append(idText)
            }
            var messageStatement: OpaquePointer?
            guard sqlite3_prepare_v2(
                handle,
                "SELECT id, session_id, role, content, tool_call_id, created_at FROM messages ORDER BY created_at ASC, rowid ASC;",
                -1,
                &messageStatement,
                nil
            ) == SQLITE_OK else {
                throw ConversationManagerError.persistenceFailed("Could not read messages")
            }
            defer { sqlite3_finalize(messageStatement) }
            while sqlite3_step(messageStatement) == SQLITE_ROW {
                guard let messageIDText = sqlite3_column_text(messageStatement, 0).map({ String(cString: $0) }),
                      let messageID = UUID(uuidString: messageIDText),
                      let sessionIDText = sqlite3_column_text(messageStatement, 1).map({ String(cString: $0) }),
                      var session = sessionsByID[sessionIDText],
                      let roleText = sqlite3_column_text(messageStatement, 2).map({ String(cString: $0) }),
                      let role = Message.Role(rawValue: roleText),
                      let contentText = sqlite3_column_text(messageStatement, 3).map({ String(cString: $0) })
                else { continue }
                let toolCallID = sqlite3_column_text(messageStatement, 4).map { String(cString: $0) }
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(messageStatement, 5))
                session.messages.append(Message(id: messageID, role: role, content: contentText, toolCallID: toolCallID, createdAt: createdAt))
                sessionsByID[sessionIDText] = session
            }
            return order.compactMap { sessionsByID[$0] }
        }

        /// Deletes one session and its messages. Missing rows are a no-op.
        /// - Parameters:
        ///   - sessionID: Session identifier.
        ///   - dbPath: SQLite file path.
        static func delete(sessionID: UUID, dbPath: String) throws {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "DELETE FROM sessions WHERE id = ?;", -1, &statement, nil) == SQLITE_OK else {
                throw ConversationManagerError.persistenceFailed("Could not prepare session delete")
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, index: 1, value: sessionID.uuidString)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw ConversationManagerError.persistenceFailed("Could not delete session \(sessionID)")
            }
        }
    }
#else
    /// JSON-file fallback used where the SQLite3 module is unavailable.
    ///
    /// Each session is stored as `<anchor>.sessions/<id>.json` so hosts
    /// without SQLite headers (e.g. Linux CI) persist identically.
    enum JSONSessionStore {
        /// Directory holding one JSON file per session.
        /// - Parameter dbPath: Configured database path used as anchor.
        /// - Returns: Sidecar directory URL.
        private static func directory(dbPath: String) -> URL {
            let expanded = (dbPath as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded + ".sessions", isDirectory: true)
        }

        /// Writes sessions as JSON files.
        /// - Parameters:
        ///   - sessions: Sessions to write.
        ///   - dbPath: Anchor path for the sidecar directory.
        ///   - merge: Ignored (files are always upserted); present for
        ///     API parity with the SQLite store.
        static func write(sessions: [ConversationSession], dbPath: String, merge _: Bool = false) throws {
            let directoryURL = directory(dbPath: dbPath)
            do {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .secondsSince1970
                for session in sessions {
                    let data = try encoder.encode(session)
                    try data.write(to: directoryURL.appendingPathComponent("\(session.id.uuidString).json"), options: .atomic)
                }
            } catch {
                throw ConversationManagerError.persistenceFailed("Could not write sessions: \(error.localizedDescription)")
            }
        }

        /// Reads all JSON session files.
        /// - Parameter dbPath: Anchor path for the sidecar directory.
        /// - Returns: Stored sessions, empty when the directory is missing.
        static func read(dbPath: String) throws -> [ConversationSession] {
            let directoryURL = directory(dbPath: dbPath)
            guard FileManager.default.fileExists(atPath: directoryURL.path) else { return [] }
            do {
                let files = try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .secondsSince1970
                return try files
                    .filter { $0.pathExtension == "json" }
                    .map { try decoder.decode(ConversationSession.self, from: Data(contentsOf: $0)) }
            } catch {
                throw ConversationManagerError.persistenceFailed("Could not read sessions: \(error.localizedDescription)")
            }
        }

        /// Deletes one JSON session file. Missing files are a no-op.
        /// - Parameters:
        ///   - sessionID: Session identifier.
        ///   - dbPath: Anchor path for the sidecar directory.
        static func delete(sessionID: UUID, dbPath: String) throws {
            let fileURL = directory(dbPath: dbPath).appendingPathComponent("\(sessionID.uuidString).json")
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                throw ConversationManagerError.persistenceFailed("Could not delete session: \(error.localizedDescription)")
            }
        }
    }
#endif
