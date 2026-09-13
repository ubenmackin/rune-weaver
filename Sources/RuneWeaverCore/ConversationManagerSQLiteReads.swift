// Rune Weaver Core — SQLite session read support for conversation persistence.
//
// Decodes stored sessions and their ordered messages for the conversation
// manager. Keeps row parsing and legacy-column fallbacks beside the store
// so the main SQLite store stays within readability budgets while reads
// keep tolerating databases written before newer columns existed.

import Foundation

#if canImport(SQLite3)
    import SQLite3

    /// Row decoding shared by full and single-session SQLite reads.
    ///
    /// Exists so the session store keeps one short entry point per read
    /// while the longer legacy-tolerant selects and per-row field mapping
    /// live here. Every helper preserves the store's contract: full column
    /// selects first with a minimal-column fallback, empty strings read as
    /// nil, and missing files are handled by the caller before a handle
    /// ever opens.
    enum SQLiteSessionReadSupport {
        /// Loads every session row without messages, preserving file order.
        /// - Parameter handle: Open database handle.
        /// - Returns: Sessions keyed by string identifier plus file order.
        static func loadAllSessions(
            handle: OpaquePointer?
        ) throws -> ([String: ConversationSession], [String]) {
            var sessionsByID: [String: ConversationSession] = [:]
            var order: [String] = []
            var statement: OpaquePointer?
            let selectSQL = "SELECT id, title, summary, created_at, updated_at, source FROM sessions;"
            let legacySelectSQL = "SELECT id, summary, created_at, updated_at FROM sessions;"
            var legacySessions = false
            if sqlite3_prepare_v2(handle, selectSQL, -1, &statement, nil) != SQLITE_OK {
                sqlite3_finalize(statement)
                statement = nil
                guard sqlite3_prepare_v2(handle, legacySelectSQL, -1, &statement, nil) == SQLITE_OK else {
                    throw ConversationManagerError.persistenceFailed("Could not read sessions")
                }
                legacySessions = true
            }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idText = columnText(statement, index: 0),
                      let id = UUID(uuidString: idText)
                else { continue }
                let fields = sessionFields(from: statement, legacy: legacySessions)
                sessionsByID[idText] = ConversationSession(
                    id: id,
                    title: fields.title,
                    messages: [],
                    summary: fields.summary,
                    createdAt: fields.createdAt,
                    updatedAt: fields.updatedAt,
                    source: fields.source
                )
                order.append(idText)
            }
            return (sessionsByID, order)
        }

        /// Appends every message row to its owning session in stored order.
        /// - Parameters:
        ///   - handle: Open database handle.
        ///   - sessionsByID: In-out sessions receiving their messages.
        static func appendAllMessages(
            handle: OpaquePointer?,
            sessionsByID: inout [String: ConversationSession]
        ) throws {
            var statement: OpaquePointer?
            var legacyMessages = false
            let messageSelectSQL = "SELECT id, session_id, role, content, tool_call_id, is_error, created_at "
                + "FROM messages ORDER BY created_at ASC, rowid ASC;"
            let legacyMessageSelectSQL = "SELECT id, session_id, role, content, tool_call_id, created_at "
                + "FROM messages ORDER BY created_at ASC, rowid ASC;"
            if sqlite3_prepare_v2(handle, messageSelectSQL, -1, &statement, nil) != SQLITE_OK {
                sqlite3_finalize(statement)
                statement = nil
                guard sqlite3_prepare_v2(handle, legacyMessageSelectSQL, -1, &statement, nil) == SQLITE_OK else {
                    throw ConversationManagerError.persistenceFailed("Could not read messages")
                }
                legacyMessages = true
            }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let messageIDText = columnText(statement, index: 0),
                      let messageID = UUID(uuidString: messageIDText),
                      let sessionIDText = columnText(statement, index: 1),
                      var session = sessionsByID[sessionIDText],
                      let roleText = columnText(statement, index: 2),
                      let role = Message.Role(rawValue: roleText),
                      let contentText = columnText(statement, index: 3)
                else { continue }
                let toolCallID = columnText(statement, index: 4)
                let outcome = messageOutcome(from: statement, legacy: legacyMessages)
                session.messages.append(Message(
                    id: messageID,
                    role: role,
                    content: contentText,
                    toolCallID: toolCallID,
                    isError: outcome.isError,
                    createdAt: outcome.createdAt
                ))
                sessionsByID[sessionIDText] = session
            }
        }

        /// Loads one session row without messages.
        /// - Parameters:
        ///   - handle: Open database handle.
        ///   - sessionID: Session identifier.
        /// - Returns: Session with empty messages, or nil when missing.
        static func loadSingleSessionBase(
            handle: OpaquePointer?,
            sessionID: UUID
        ) throws -> ConversationSession? {
            var statement: OpaquePointer?
            let sessionSQL = "SELECT id, title, summary, created_at, updated_at, source FROM sessions WHERE id = ?;"
            let legacySessionSQL = "SELECT id, summary, created_at, updated_at FROM sessions WHERE id = ?;"
            var legacySession = false
            if sqlite3_prepare_v2(handle, sessionSQL, -1, &statement, nil) != SQLITE_OK {
                sqlite3_finalize(statement)
                statement = nil
                guard sqlite3_prepare_v2(handle, legacySessionSQL, -1, &statement, nil) == SQLITE_OK else {
                    throw ConversationManagerError.persistenceFailed("Could not read session \(sessionID)")
                }
                legacySession = true
            }
            defer { sqlite3_finalize(statement) }
            SQLiteHelpers.bindText(statement, index: 1, value: sessionID.uuidString)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }
            let fields = sessionFields(from: statement, legacy: legacySession)
            return ConversationSession(
                id: sessionID,
                title: fields.title,
                messages: [],
                summary: fields.summary,
                createdAt: fields.createdAt,
                updatedAt: fields.updatedAt,
                source: fields.source
            )
        }

        /// Appends ordered message rows to one previously loaded session.
        /// - Parameters:
        ///   - handle: Open database handle.
        ///   - session: In-out session receiving its messages.
        static func appendSingleSessionMessages(
            handle: OpaquePointer?,
            session: inout ConversationSession
        ) throws {
            let sessionID = session.id
            var statement: OpaquePointer?
            let messageSQL = "SELECT id, session_id, role, content, tool_call_id, is_error, created_at FROM messages "
                + "WHERE session_id = ? ORDER BY created_at ASC, rowid ASC;"
            let legacyMessageSQL = "SELECT id, session_id, role, content, tool_call_id, created_at FROM messages "
                + "WHERE session_id = ? ORDER BY created_at ASC, rowid ASC;"
            var legacyMessages = false
            if sqlite3_prepare_v2(handle, messageSQL, -1, &statement, nil) != SQLITE_OK {
                sqlite3_finalize(statement)
                statement = nil
                guard sqlite3_prepare_v2(handle, legacyMessageSQL, -1, &statement, nil) == SQLITE_OK else {
                    throw ConversationManagerError.persistenceFailed("Could not read messages for session \(sessionID)")
                }
                legacyMessages = true
            }
            defer { sqlite3_finalize(statement) }
            SQLiteHelpers.bindText(statement, index: 1, value: sessionID.uuidString)
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let messageIDText = columnText(statement, index: 0),
                      let messageID = UUID(uuidString: messageIDText),
                      let roleText = columnText(statement, index: 2),
                      let role = Message.Role(rawValue: roleText),
                      let contentText = columnText(statement, index: 3)
                else { continue }
                let toolCallID = columnText(statement, index: 4)
                let outcome = messageOutcome(from: statement, legacy: legacyMessages)
                session.messages.append(Message(
                    id: messageID,
                    role: role,
                    content: contentText,
                    toolCallID: toolCallID,
                    isError: outcome.isError,
                    createdAt: outcome.createdAt
                ))
            }
        }

        /// Decoded session columns for one stepped row.
        ///
        /// Groups the five session columns so row decoding stays within the
        /// two-member tuple budget while keeping one call site per read.
        struct SessionFields {
            let title: String?
            let summary: String?
            let createdAt: Date
            let updatedAt: Date
            let source: String?
        }

        /// Decodes session field columns for one stepped row.
        ///
        /// Treats empty strings as nil so titles, summaries, and sources
        /// written as empty text read back as absent, matching the store's
        /// write path.
        /// - Parameters:
        ///   - statement: Stepped statement positioned on a session row.
        ///   - legacy: Whether the row uses the minimal-column fallback.
        /// - Returns: Decoded title, summary, timestamps, and source.
        static func sessionFields(
            from statement: OpaquePointer?,
            legacy: Bool
        ) -> SessionFields {
            if legacy {
                let summary = nonemptyText(statement, index: 1)
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
                let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
                return SessionFields(title: nil, summary: summary, createdAt: createdAt, updatedAt: updatedAt, source: nil)
            }
            let title = nonemptyText(statement, index: 1)
            let summary = nonemptyText(statement, index: 2)
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            let source = nonemptyText(statement, index: 5)
            return SessionFields(title: title, summary: summary, createdAt: createdAt, updatedAt: updatedAt, source: source)
        }

        /// Decodes error-flag and timestamp columns for one message row.
        ///
        /// Legacy rows predate the error flag, so they always decode as no
        /// error with the earlier timestamp column.
        /// - Parameters:
        ///   - statement: Stepped statement positioned on a message row.
        ///   - legacy: Whether the row uses the minimal-column fallback.
        /// - Returns: Decoded error flag and creation date.
        static func messageOutcome(
            from statement: OpaquePointer?,
            legacy: Bool
        ) -> (isError: Bool?, createdAt: Date) {
            if legacy {
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
                return (nil, createdAt)
            }
            let isError: Bool? = if sqlite3_column_type(statement, 5) == SQLITE_NULL {
                nil
            } else {
                sqlite3_column_int64(statement, 5) != 0
            }
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
            return (isError, createdAt)
        }

        /// Reads a nullable text column, preserving nil for SQL NULL.
        /// - Parameters:
        ///   - statement: Stepped statement.
        ///   - index: Zero-based column index.
        /// - Returns: Column text, or nil when NULL.
        static func columnText(_ statement: OpaquePointer?, index: Int32) -> String? {
            sqlite3_column_text(statement, index).map { String(cString: $0) }
        }

        /// Reads a text column, mapping empty strings to nil.
        /// - Parameters:
        ///   - statement: Stepped statement.
        ///   - index: Zero-based column index.
        /// - Returns: Non-empty text, or nil when NULL or empty.
        static func nonemptyText(_ statement: OpaquePointer?, index: Int32) -> String? {
            let text = columnText(statement, index: index)
            return (text?.isEmpty == false) ? text : nil
        }
    }
#endif
