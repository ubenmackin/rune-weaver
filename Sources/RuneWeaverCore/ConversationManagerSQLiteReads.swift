// Rune Weaver Core — SQLite session read support for conversation persistence.
// Decodes stored sessions and their ordered messages for the conversation manager.

import Foundation

#if canImport(SQLite3)
    import SQLite3

    /// Row decoding shared by full and single-session SQLite reads.
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
            guard sqlite3_prepare_v2(handle, selectSQL, -1, &statement, nil) == SQLITE_OK else {
                throw ConversationManagerError.persistenceFailed("Could not read sessions")
            }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idText = columnText(statement, index: 0),
                      let id = UUID(uuidString: idText)
                else { continue }
                let fields = sessionFields(from: statement)
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
        static func appendAllMessages(
            handle: OpaquePointer?,
            sessionsByID: inout [String: ConversationSession]
        ) throws {
            var statement: OpaquePointer?
            let messageSelectSQL = "SELECT id, session_id, role, content, tool_call_id, is_error, created_at "
                + "FROM messages ORDER BY created_at ASC, rowid ASC;"
            guard sqlite3_prepare_v2(handle, messageSelectSQL, -1, &statement, nil) == SQLITE_OK else {
                throw ConversationManagerError.persistenceFailed("Could not read messages")
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
                let outcome = messageOutcome(from: statement)
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
        static func loadSingleSessionBase(
            handle: OpaquePointer?,
            sessionID: UUID
        ) throws -> ConversationSession? {
            var statement: OpaquePointer?
            let sessionSQL = "SELECT id, title, summary, created_at, updated_at, source FROM sessions WHERE id = ?;"
            guard sqlite3_prepare_v2(handle, sessionSQL, -1, &statement, nil) == SQLITE_OK else {
                throw ConversationManagerError.persistenceFailed("Could not read session \(sessionID)")
            }
            defer { sqlite3_finalize(statement) }
            SQLiteHelpers.bindText(statement, index: 1, value: sessionID.uuidString)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }
            let fields = sessionFields(from: statement)
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
        static func appendSingleSessionMessages(
            handle: OpaquePointer?,
            session: inout ConversationSession
        ) throws {
            let sessionID = session.id
            var statement: OpaquePointer?
            let messageSQL = "SELECT id, session_id, role, content, tool_call_id, is_error, created_at FROM messages "
                + "WHERE session_id = ? ORDER BY created_at ASC, rowid ASC;"
            guard sqlite3_prepare_v2(handle, messageSQL, -1, &statement, nil) == SQLITE_OK else {
                throw ConversationManagerError.persistenceFailed("Could not read messages for session \(sessionID)")
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
                let outcome = messageOutcome(from: statement)
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
        struct SessionFields {
            let title: String?
            let summary: String?
            let createdAt: Date
            let updatedAt: Date
            let source: String?
        }

        /// Decodes session field columns for one stepped row.
        static func sessionFields(from statement: OpaquePointer?) -> SessionFields {
            let title = nonemptyText(statement, index: 1)
            let summary = nonemptyText(statement, index: 2)
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            let source = nonemptyText(statement, index: 5)
            return SessionFields(title: title, summary: summary, createdAt: createdAt, updatedAt: updatedAt, source: source)
        }

        /// Decodes error-flag and timestamp columns for one message row.
        /// - Parameter statement: Stepped statement positioned on a message row.
        /// - Returns: Decoded error flag and creation date.
        static func messageOutcome(from statement: OpaquePointer?) -> (isError: Bool?, createdAt: Date) {
            let isError: Bool? = if sqlite3_column_type(statement, 5) == SQLITE_NULL {
                nil
            } else {
                sqlite3_column_int64(statement, 5) != 0
            }
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
            return (isError, createdAt)
        }

        /// Reads a nullable text column, preserving nil for SQL NULL.
        static func columnText(_ statement: OpaquePointer?, index: Int32) -> String? {
            sqlite3_column_text(statement, index).map { String(cString: $0) }
        }

        /// Reads a text column, mapping empty strings to nil.
        static func nonemptyText(_ statement: OpaquePointer?, index: Int32) -> String? {
            let text = columnText(statement, index: index)
            return (text?.isEmpty == false) ? text : nil
        }
    }
#endif
