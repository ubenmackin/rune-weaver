// Rune Weaver Core — File and SQLite session store implementations.

import Foundation
import os

#if canImport(SQLite3)
    import SQLite3
#endif

// MARK: - Session store I/O

/// File and SQLite I/O for conversation sessions.
enum SessionStoreIO {
    /// Writes sessions to the store.
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
            try SQLiteSessionStore.read(dbPath: dbPath)
        #else
            try JSONSessionStore.read(dbPath: dbPath)
        #endif
    }

    /// Reads a single session from the store.
    static func readSingle(sessionID: UUID, dbPath: String) throws -> ConversationSession? {
        #if canImport(SQLite3)
            try SQLiteSessionStore.readSingle(sessionID: sessionID, dbPath: dbPath)
        #else
            try JSONSessionStore.readSingle(sessionID: sessionID, dbPath: dbPath)
        #endif
    }

    /// Deletes one session from the store. Missing rows are a no-op.
    static func delete(sessionID: UUID, dbPath: String) throws {
        #if canImport(SQLite3)
            try SQLiteSessionStore.delete(sessionID: sessionID, dbPath: dbPath)
        #else
            try JSONSessionStore.delete(sessionID: sessionID, dbPath: dbPath)
        #endif
    }

    /// Deletes all sessions from the store. Missing stores are a no-op.
    /// - Parameter dbPath: SQLite path (or JSON sidecar anchor).
    static func deleteAll(dbPath: String) throws {
        #if canImport(SQLite3)
            try SQLiteSessionStore.deleteAll(dbPath: dbPath)
        #else
            try JSONSessionStore.deleteAll(dbPath: dbPath)
        #endif
    }
}

#if canImport(SQLite3)
    /// Minimal SQLite store for sessions and their messages.
    enum SQLiteSessionStore {
        /// Opens the database, creating parent directories and ensuring the schema.
        /// - Parameter dbPath: SQLite file path. `~` is expanded.
        /// - Returns: Open database handle. Caller must close it.
        private static func open(dbPath: String) throws -> OpaquePointer? {
            // Shared busy_timeout/WAL policy lives in `SQLiteHelpers.openHandle`.
            let handle = try SQLiteHelpers.openHandle(dbPath: dbPath, unavailable: ConversationManagerError.storeUnavailable)
            try SQLiteHelpers.exec(
                handle: handle,
                sql: """
                CREATE TABLE IF NOT EXISTS sessions(
                    id TEXT PRIMARY KEY,
                    title TEXT,
                    summary TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    source TEXT,
                    goal_id TEXT,
                    parent_session_id TEXT,
                    is_archived INTEGER DEFAULT 0
                );
                CREATE TABLE IF NOT EXISTS messages(
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL,
                    role TEXT NOT NULL,
                    content TEXT NOT NULL,
                    tool_call_id TEXT,
                    is_error INTEGER,
                    created_at REAL NOT NULL,
                    error_kind TEXT,
                    reasoning TEXT,
                    exit_code INTEGER,
                    FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE
                );
                CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id);
                """,
                failure: ConversationManagerError.persistenceFailed
            )
            try SQLiteHelpers.exec(handle: handle, sql: "PRAGMA foreign_keys = ON;", failure: ConversationManagerError.persistenceFailed)
            return handle
        }

        /// Executes a multi-statement SQL string.
        private static func exec(handle: OpaquePointer?, sql: String) throws {
            try SQLiteHelpers.exec(handle: handle, sql: sql, failure: ConversationManagerError.persistenceFailed)
        }

        /// Binds optional text, mapping nil to NULL.
        private static func bindText(_ statement: OpaquePointer?, index: Int32, value: String?) {
            SQLiteHelpers.bindText(statement, index: index, value: value)
        }

        /// Writes sessions, optionally preserving existing rows.
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
        /// The parent link trails the goal link here and in the read projection,
        /// so both sides stay index-aligned; an absent parent binds as SQL NULL.
        private static func upsert(session: ConversationSession, handle: OpaquePointer?) throws {
            var sessionStatement: OpaquePointer?
            let sessionSQL = "INSERT INTO sessions(id, title, summary, created_at, updated_at, source, goal_id, parent_session_id, is_archived) "
                + "VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?) "
                + "ON CONFLICT(id) DO UPDATE SET title=excluded.title, summary=excluded.summary, "
                + "updated_at=excluded.updated_at, source=excluded.source, goal_id=excluded.goal_id, "
                + "parent_session_id=excluded.parent_session_id, is_archived=excluded.is_archived;"
            guard sqlite3_prepare_v2(handle, sessionSQL, -1, &sessionStatement, nil) == SQLITE_OK else {
                let code = sqlite3_errcode(handle)
                throw ConversationManagerError.persistenceFailed("Could not prepare session upsert (code \(code))")
            }
            defer { sqlite3_finalize(sessionStatement) }
            bindText(sessionStatement, index: 1, value: session.id.uuidString)
            bindText(sessionStatement, index: 2, value: session.title)
            bindText(sessionStatement, index: 3, value: session.summary)
            sqlite3_bind_double(sessionStatement, 4, session.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(sessionStatement, 5, session.updatedAt.timeIntervalSince1970)
            bindText(sessionStatement, index: 6, value: session.source)
            bindText(sessionStatement, index: 7, value: session.goalID?.uuidString)
            bindText(sessionStatement, index: 8, value: session.parentSessionID?.uuidString)
            sqlite3_bind_int(sessionStatement, 9, session.isArchived ? 1 : 0)
            guard sqlite3_step(sessionStatement) == SQLITE_DONE else {
                throw ConversationManagerError.persistenceFailed("Could not write session \(session.id)")
            }
            try rewriteMessages(for: session, handle: handle)
        }

        /// Rewrites all message rows for one session.
        private static func rewriteMessages(for session: ConversationSession, handle: OpaquePointer?) throws {
            var deleteStatement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "DELETE FROM messages WHERE session_id = ?;", -1, &deleteStatement, nil) == SQLITE_OK else {
                throw ConversationManagerError.persistenceFailed("Could not prepare message cleanup")
            }
            defer { sqlite3_finalize(deleteStatement) }
            bindText(deleteStatement, index: 1, value: session.id.uuidString)
            guard sqlite3_step(deleteStatement) == SQLITE_DONE else {
                throw ConversationManagerError.persistenceFailed("Could not rewrite messages for \(session.id)")
            }
            for message in session.messages {
                try insertMessage(message, sessionID: session.id, handle: handle)
            }
        }

        /// Inserts one message row.
        private static func insertMessage(_ message: Message, sessionID: UUID, handle: OpaquePointer?) throws {
            let messageSQL = "INSERT INTO messages(id, session_id, role, content, tool_call_id, is_error, created_at, error_kind, reasoning, exit_code) "
                + "VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?);"
            var messageStatement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, messageSQL, -1, &messageStatement, nil) == SQLITE_OK else {
                let code = sqlite3_errcode(handle)
                throw ConversationManagerError.persistenceFailed("Could not prepare message insert (code \(code))")
            }
            defer { sqlite3_finalize(messageStatement) }
            bindText(messageStatement, index: 1, value: message.id.uuidString)
            bindText(messageStatement, index: 2, value: sessionID.uuidString)
            bindText(messageStatement, index: 3, value: message.role.rawValue)
            bindText(messageStatement, index: 4, value: message.content)
            bindText(messageStatement, index: 5, value: message.toolCallID)
            if let isError = message.isError {
                sqlite3_bind_int64(messageStatement, 6, isError ? 1 : 0)
            } else {
                sqlite3_bind_null(messageStatement, 6)
            }
            sqlite3_bind_double(messageStatement, 7, message.createdAt.timeIntervalSince1970)
            bindText(messageStatement, index: 8, value: message.errorKind?.rawValue)
            bindText(messageStatement, index: 9, value: message.reasoning)
            if let exitCode = message.exitCode {
                sqlite3_bind_int64(messageStatement, 10, Int64(exitCode))
            } else {
                sqlite3_bind_null(messageStatement, 10)
            }
            guard sqlite3_step(messageStatement) == SQLITE_DONE else {
                throw ConversationManagerError.persistenceFailed("Could not write message \(message.id)")
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
            let (loadedByID, order) = try SQLiteSessionReadSupport.loadAllSessions(handle: handle)
            var sessionsByID = loadedByID
            try SQLiteSessionReadSupport.appendAllMessages(handle: handle, sessionsByID: &sessionsByID)
            return order.compactMap { sessionsByID[$0] }
        }

        /// Reads a single session with its messages.
        static func readSingle(sessionID: UUID, dbPath: String) throws -> ConversationSession? {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return nil }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            guard var session = try SQLiteSessionReadSupport.loadSingleSessionBase(
                handle: handle,
                sessionID: sessionID
            ) else {
                return nil
            }
            try SQLiteSessionReadSupport.appendSingleSessionMessages(handle: handle, session: &session)
            return session
        }

        /// Deletes one session and its messages. Missing rows are a no-op.
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

        /// Deletes all sessions and their messages. Missing files are a no-op.
        /// - Parameter dbPath: SQLite file path.
        static func deleteAll(dbPath: String) throws {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            try exec(handle: handle, sql: "DELETE FROM messages; DELETE FROM sessions;")
        }
    }
#else
    /// JSON-file fallback used where the SQLite3 module is unavailable.
    enum JSONSessionStore {
        /// Directory holding one JSON file per session.
        /// - Parameter dbPath: Configured database path used as anchor.
        /// - Returns: Sidecar directory URL.
        private static func directory(dbPath: String) -> URL {
            let expanded = (dbPath as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded + ".sessions", isDirectory: true)
        }

        /// Writes sessions as JSON files.
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

        /// Reads a single JSON session file.
        static func readSingle(sessionID: UUID, dbPath: String) throws -> ConversationSession? {
            let fileURL = directory(dbPath: dbPath).appendingPathComponent("\(sessionID.uuidString).json")
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .secondsSince1970
                return try decoder.decode(ConversationSession.self, from: Data(contentsOf: fileURL))
            } catch {
                throw ConversationManagerError.persistenceFailed("Could not read session \(sessionID): \(error.localizedDescription)")
            }
        }

        /// Deletes one JSON session file. Missing files are a no-op.
        static func delete(sessionID: UUID, dbPath: String) throws {
            let fileURL = directory(dbPath: dbPath).appendingPathComponent("\(sessionID.uuidString).json")
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                throw ConversationManagerError.persistenceFailed("Could not delete session: \(error.localizedDescription)")
            }
        }

        /// Deletes all JSON session files. Missing directories are a no-op.
        /// - Parameter dbPath: Anchor path for the sidecar directory.
        static func deleteAll(dbPath: String) throws {
            let directoryURL = directory(dbPath: dbPath)
            guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
            do {
                let files = try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
                for file in files where file.pathExtension == "json" {
                    try FileManager.default.removeItem(at: file)
                }
            } catch {
                throw ConversationManagerError.persistenceFailed("Could not delete sessions: \(error.localizedDescription)")
            }
        }
    }
#endif
