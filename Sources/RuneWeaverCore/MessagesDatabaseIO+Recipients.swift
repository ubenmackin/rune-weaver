// Rune Weaver Core — Handle aggregates and outgoing evidence read from an opened Messages snapshot.

import Foundation

#if canImport(SQLite3)
    import SQLite3

    extension MessagesDatabaseIO {
        /// Aggregate message history for one handle in a direct (one-participant) chat.
        public struct MessageHandleStats: Sendable, Equatable {
            /// Canonical handle identifier as stored in `handle.id`.
            public let handle: String
            /// Messaging service label (`handle.service`), or nil when the row carries none.
            public let service: String?
            /// Instant of the newest message exchanged with this handle; nil when all rows are undated.
            public let lastMessageAt: Date?
            /// Number of messages exchanged with this handle in direct chats.
            public let messageCount: Int

            /// Creates a handle stats snapshot. handle: Canonical handle
            /// identifier.
            public init(handle: String, service: String?, lastMessageAt: Date?, messageCount: Int) {
                self.handle = handle
                self.service = service
                self.lastMessageAt = lastMessageAt
                self.messageCount = messageCount
            }
        }

        /// Reads per-handle message aggregates for every one-to-one chat.
        public static func recentDirectHandleStats(handle: OpaquePointer?, limit: Int) throws -> [MessageHandleStats] {
            guard limit > 0 else { return [] }
            let sql = """
            SELECT h.id, h.service, MAX(m.date) AS last_date, COUNT(m.ROWID) AS message_count
            FROM chat c
            JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
            JOIN handle h ON h.ROWID = chj.handle_id
            JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
            JOIN message m ON m.ROWID = cmj.message_id
            WHERE c.ROWID IN (
                SELECT chat_id FROM chat_handle_join GROUP BY chat_id HAVING COUNT(*) = 1
            )
            GROUP BY h.id, h.service
            ORDER BY last_date DESC
            LIMIT ?;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                return []
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, SQLiteHelpers.sqliteLimit(limit))
            var stats: [MessageHandleStats] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                // A handle row without an identifier has no recipient identity,
                // so it is skipped rather than surfaced as an empty handle.
                guard let handleID = SQLiteHelpers.columnText(statement, index: 0), !handleID.isEmpty else { continue }
                stats.append(
                    MessageHandleStats(
                        handle: handleID,
                        service: SQLiteHelpers.columnText(statement, index: 1),
                        lastMessageAt: SQLiteHelpers.columnInt64(statement, index: 2).map(TemporalFilter.date(fromMacEpoch:)),
                        messageCount: Int(SQLiteHelpers.columnInt64(statement, index: 3) ?? 0)
                    )
                )
            }
            return stats
        }

        /// One outgoing message observed in the owner's own send history. Only the two fields
        /// confirmation needs are carried: the handle the message went to and when it was sent.
        public struct MessageOutgoingRow: Sendable, Equatable {
            /// Handle identifier as stored in `handle.id`.
            public let handle: String
            /// Instant the outgoing message was recorded.
            public let sentAt: Date

            /// Creates an outgoing-message row. handle: Handle identifier as stored
            /// in `handle.id`.
            public init(handle: String, sentAt: Date) {
                self.handle = handle
                self.sentAt = sentAt
            }
        }

        /// Reads the owner's outgoing messages at or after `since`, newest first.
        public static func recentOutgoingHandles(handle: OpaquePointer?, since: Date, limit: Int) throws -> [MessageOutgoingRow] {
            guard limit > 0 else { return [] }
            let macEpochSeconds = TemporalFilter.macEpochSecondsExpression(column: "m.date")
            let sql = """
            SELECT h.id, m.date FROM message m JOIN handle h ON h.ROWID = m.handle_id
            WHERE m.is_from_me = 1 AND (\(macEpochSeconds)) >= ?
            ORDER BY \(macEpochSeconds) DESC LIMIT ?;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw MessagesIndexError.databaseUnavailable("Could not read the Messages snapshot.")
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, TemporalFilter.macEpochValue(for: since))
            sqlite3_bind_int(statement, 2, SQLiteHelpers.sqliteLimit(limit))
            var rows: [MessageOutgoingRow] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                // A row without a handle or a date cannot be attributed to a
                // recipient, so it is skipped rather than surfaced as empty.
                guard let handleID = SQLiteHelpers.columnText(statement, index: 0), !handleID.isEmpty else { continue }
                guard let rawDate = SQLiteHelpers.columnInt64(statement, index: 1) else { continue }
                rows.append(
                    MessageOutgoingRow(
                        handle: handleID,
                        sentAt: TemporalFilter.date(fromMacEpoch: rawDate)
                    )
                )
            }
            return rows
        }
    }

    /// Top-level aliases so call sites can spell the aggregates without the owner prefix.
    public typealias MessageHandleStats = MessagesDatabaseIO.MessageHandleStats
    public typealias MessageOutgoingRow = MessagesDatabaseIO.MessageOutgoingRow
#endif
