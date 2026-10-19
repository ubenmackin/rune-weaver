// Rune Weaver Core — SQLite session read support for conversation persistence.

import Foundation

#if canImport(SQLite3)
    import SQLite3

    /// Row decoding shared by full and single-session SQLite reads.
    enum SQLiteSessionReadSupport {
        /// Loads every session row without messages, preserving file order.
        static func loadAllSessions(
            handle: OpaquePointer?
        ) throws -> ([String: ConversationSession], [String]) {
            var sessionsByID: [String: ConversationSession] = [:]
            var order: [String] = []
            var statement: OpaquePointer?
            let selectSQL = "SELECT id, title, summary, created_at, updated_at, source, goal_id, parent_session_id, is_archived FROM sessions;"
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
                    source: fields.source,
                    goalID: fields.goalID,
                    parentSessionID: fields.parentSessionID,
                    isArchived: fields.isArchived
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
            let messageSelectSQL = "SELECT id, session_id, role, content, tool_call_id, is_error, created_at, error_kind, reasoning, exit_code "
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
                    errorKind: outcome.errorKind,
                    createdAt: outcome.createdAt,
                    reasoning: outcome.reasoning,
                    exitCode: outcome.exitCode
                ))
                sessionsByID[sessionIDText] = session
            }
        }

        /// Loads one session row without messages. The projection always selects
        /// `goal_id` and `parent_session_id`; tables predating those columns fail
        /// the lookup closed instead of decoding as unlinked.
        static func loadSingleSessionBase(
            handle: OpaquePointer?,
            sessionID: UUID
        ) throws -> ConversationSession? {
            var statement: OpaquePointer?
            let sessionSQL = "SELECT id, title, summary, created_at, updated_at, source, goal_id, parent_session_id, is_archived FROM sessions WHERE id = ?;"
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
                source: fields.source,
                goalID: fields.goalID,
                parentSessionID: fields.parentSessionID,
                isArchived: fields.isArchived
            )
        }

        /// Appends ordered message rows to one previously loaded session.
        static func appendSingleSessionMessages(
            handle: OpaquePointer?,
            session: inout ConversationSession
        ) throws {
            let sessionID = session.id
            var statement: OpaquePointer?
            let messageSQL = "SELECT id, session_id, role, content, tool_call_id, is_error, created_at, error_kind, reasoning, exit_code FROM messages "
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
                    errorKind: outcome.errorKind,
                    createdAt: outcome.createdAt,
                    reasoning: outcome.reasoning,
                    exitCode: outcome.exitCode
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
            /// Linked goal, nil for unlinked sessions. The static projection
            /// always selects `goal_id`.
            let goalID: UUID?
            /// Parent session, nil for unparented sessions. The static projection
            /// always selects `parent_session_id`.
            let parentSessionID: UUID?
            /// Whether this session is archived.
            let isArchived: Bool
        }

        /// Decodes session field columns for one stepped row. The static projection
        /// always selects `goal_id`, `parent_session_id`, and `is_archived`.
        static func sessionFields(from statement: OpaquePointer?) -> SessionFields {
            let title = nonemptyText(statement, index: 1)
            let summary = nonemptyText(statement, index: 2)
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            let source = nonemptyText(statement, index: 5)
            let goalID = columnText(statement, index: 6).flatMap { UUID(uuidString: $0) }
            let parentSessionID = columnText(statement, index: 7).flatMap { UUID(uuidString: $0) }
            let isArchived = sqlite3_column_int(statement, 8) != 0
            return SessionFields(
                title: title,
                summary: summary,
                createdAt: createdAt,
                updatedAt: updatedAt,
                source: source,
                goalID: goalID,
                parentSessionID: parentSessionID,
                isArchived: isArchived
            )
        }

        /// Decoded error-flag, timestamp, category, reasoning, and exit-code columns for one message row.
        /// A named shape keeps the decode result self-describing at the call sites.
        struct MessageOutcome {
            let isError: Bool?
            let createdAt: Date
            let errorKind: ToolErrorKind?
            let reasoning: String?
            let exitCode: Int32?
        }

        /// Decodes error-flag, timestamp, category, reasoning, and exit-code columns for one
        /// message row.
        static func messageOutcome(from statement: OpaquePointer?) -> MessageOutcome {
            let isError: Bool? = if sqlite3_column_type(statement, 5) == SQLITE_NULL {
                nil
            } else {
                sqlite3_column_int64(statement, 5) != 0
            }
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
            let errorKind = columnText(statement, index: 7).flatMap { ToolErrorKind(rawValue: $0) }
            let reasoning = nonemptyText(statement, index: 8)
            let exitCode: Int32? = if sqlite3_column_type(statement, 9) == SQLITE_NULL {
                nil
            } else {
                Int32(exactly: sqlite3_column_int64(statement, 9))
            }
            return MessageOutcome(
                isError: isError,
                createdAt: createdAt,
                errorKind: errorKind,
                reasoning: reasoning,
                exitCode: exitCode
            )
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
