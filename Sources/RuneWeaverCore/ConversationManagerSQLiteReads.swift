// Rune Weaver Core — SQLite session read support for conversation persistence.
// Decodes stored sessions and their ordered messages for the conversation manager.

import Foundation

#if canImport(SQLite3)
    import SQLite3

    /// Row decoding shared by full and single-session SQLite reads.
    enum SQLiteSessionReadSupport {
        /// Loads every session row without messages, preserving file order.
        /// Databases whose link migrations have not landed carry no `goal_id`
        /// or `parent_session_id` column; those rows decode as unlinked and
        /// unparented instead of failing the read.
        /// - Parameter handle: Open database handle.
        /// - Returns: Sessions keyed by string identifier plus file order.
        static func loadAllSessions(
            handle: OpaquePointer?
        ) throws -> ([String: ConversationSession], [String]) {
            var sessionsByID: [String: ConversationSession] = [:]
            var order: [String] = []
            var statement: OpaquePointer?
            // The probe keeps the projection honest when the additive migrations
            // have not landed: selecting a missing column would fail the whole
            // read, while appending each link column only when present keeps old
            // indices stable and decodes absent links as nil.
            let sessionColumns = SQLiteHelpers.columnNames(handle: handle, table: .sessions)
            let hasGoalID = sessionColumns.contains("goal_id")
            let hasParent = sessionColumns.contains("parent_session_id")
            let hasArchived = sessionColumns.contains("is_archived")
            // Link columns append in migration order, so the parent link always
            // trails the goal link and the decode indices stay derivable from
            // the two probes.
            var selectColumns = "id, title, summary, created_at, updated_at, source"
            if hasGoalID {
                selectColumns += ", goal_id"
            }
            if hasParent {
                selectColumns += ", parent_session_id"
            }
            if hasArchived {
                selectColumns += ", is_archived"
            }
            let selectSQL = "SELECT \(selectColumns) FROM sessions;"
            guard sqlite3_prepare_v2(handle, selectSQL, -1, &statement, nil) == SQLITE_OK else {
                throw ConversationManagerError.persistenceFailed("Could not read sessions")
            }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idText = columnText(statement, index: 0),
                      let id = UUID(uuidString: idText)
                else { continue }
                let fields = sessionFields(from: statement, hasGoalID: hasGoalID, hasParentLink: hasParent, hasArchived: hasArchived)
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
            let messageSelectSQL = "SELECT id, session_id, role, content, tool_call_id, is_error, created_at, error_kind "
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
                    createdAt: outcome.createdAt
                ))
                sessionsByID[sessionIDText] = session
            }
        }

        /// Loads one session row without messages.
        /// A missing `goal_id` or `parent_session_id` column (pre-migration
        /// database) decodes as unlinked and unparented rather than failing the
        /// lookup.
        static func loadSingleSessionBase(
            handle: OpaquePointer?,
            sessionID: UUID
        ) throws -> ConversationSession? {
            var statement: OpaquePointer?
            let sessionColumns = SQLiteHelpers.columnNames(handle: handle, table: .sessions)
            let hasGoalID = sessionColumns.contains("goal_id")
            let hasParent = sessionColumns.contains("parent_session_id")
            let hasArchived = sessionColumns.contains("is_archived")
            // Same migration-order projection as the all-sessions read, so the
            // parent link trails the goal link in both statements.
            var selectColumns = "id, title, summary, created_at, updated_at, source"
            if hasGoalID {
                selectColumns += ", goal_id"
            }
            if hasParent {
                selectColumns += ", parent_session_id"
            }
            if hasArchived {
                selectColumns += ", is_archived"
            }
            let sessionSQL = "SELECT \(selectColumns) FROM sessions WHERE id = ?;"
            guard sqlite3_prepare_v2(handle, sessionSQL, -1, &statement, nil) == SQLITE_OK else {
                throw ConversationManagerError.persistenceFailed("Could not read session \(sessionID)")
            }
            defer { sqlite3_finalize(statement) }
            SQLiteHelpers.bindText(statement, index: 1, value: sessionID.uuidString)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }
            let fields = sessionFields(from: statement, hasGoalID: hasGoalID, hasParentLink: hasParent, hasArchived: hasArchived)
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
            let messageSQL = "SELECT id, session_id, role, content, tool_call_id, is_error, created_at, error_kind FROM messages "
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
            /// Linked goal, nil for unlinked sessions and for rows read from
            /// tables that predate the goal-link column.
            let goalID: UUID?
            /// Parent session, nil for unparented sessions and for rows read
            /// from tables that predate the parent-link column.
            let parentSessionID: UUID?
            /// Whether this session is archived.
            let isArchived: Bool
        }

        /// Decodes session field columns for one stepped row.
        /// Link columns are only read when the projection includes them; older
        /// tables decode as unlinked and unparented. Malformed link text
        /// degrades to nil so one bad row cannot fail the whole history load.
        /// - Parameters:
        ///   - statement: Stepped statement positioned on a session row.
        ///   - hasGoalID: Whether the projection selected the goal-link column.
        ///   - hasParentLink: Whether the projection selected the parent-link column.
        ///   - hasArchived: Whether the projection selected the is_archived column.
        /// - Returns: Decoded session fields.
        static func sessionFields(
            from statement: OpaquePointer?,
            hasGoalID: Bool = false,
            hasParentLink: Bool = false,
            hasArchived: Bool = false
        ) -> SessionFields {
            let title = nonemptyText(statement, index: 1)
            let summary = nonemptyText(statement, index: 2)
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            let source = nonemptyText(statement, index: 5)
            var nextIndex: Int32 = 6
            let goalID: UUID?
            if hasGoalID {
                goalID = columnText(statement, index: nextIndex).flatMap { UUID(uuidString: $0) }
                nextIndex += 1
            } else {
                goalID = nil
            }
            // The parent link trails the goal link in the projection, so its
            // index shifts with the goal column; gating on the probe keeps a
            // pre-migration table from reading the wrong column.
            let parentSessionID: UUID?
            if hasParentLink {
                parentSessionID = columnText(statement, index: nextIndex).flatMap { UUID(uuidString: $0) }
                nextIndex += 1
            } else {
                parentSessionID = nil
            }
            let isArchived: Bool = if hasArchived {
                sqlite3_column_int(statement, nextIndex) != 0
            } else {
                false
            }
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

        /// Decoded error-flag, timestamp, and category columns for one message row.
        /// A named shape keeps the decode result self-describing at the call sites.
        struct MessageOutcome {
            let isError: Bool?
            let createdAt: Date
            let errorKind: ToolErrorKind?
        }

        /// Decodes error-flag, timestamp, and category columns for one message row.
        /// An absent or unrecognized category decodes to nil so legacy rows and future
        /// values both fall back to the generic client badge instead of failing the read.
        /// - Parameter statement: Stepped statement positioned on a message row.
        /// - Returns: Decoded error flag, creation date, and failure category.
        static func messageOutcome(from statement: OpaquePointer?) -> MessageOutcome {
            let isError: Bool? = if sqlite3_column_type(statement, 5) == SQLITE_NULL {
                nil
            } else {
                sqlite3_column_int64(statement, 5) != 0
            }
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
            let errorKind = columnText(statement, index: 7).flatMap { ToolErrorKind(rawValue: $0) }
            return MessageOutcome(isError: isError, createdAt: createdAt, errorKind: errorKind)
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
