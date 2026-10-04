// Rune Weaver Core — Handle aggregates and outgoing evidence read from an opened Messages snapshot.
//
// Purpose: recipient history needs two things from `chat.db` — which handles
// belong to one-to-one conversations, when each last exchanged a message, and
// how many messages moved; plus which messages the owner actually sent to a
// handle, which is the only honest confirmation that a send became visible to
// Messages. This extension owns exactly those reads so the SQL sits beside the
// other snapshot queries instead of inside a caller that also has to snapshot,
// open, and close the database.
//
// Scope: reads over an already-open snapshot handle. Direct chats are
// identified structurally from `chat_handle_join`, not from `chat.style` or a
// user-editable display name, so a group's messages can never inflate a direct
// contact's count even when that handle also belongs to the group. Outgoing
// evidence is the owner's own `is_from_me` rows joined to their handle. A
// database without the direct-chat join table degrades to an empty aggregate —
// absent history is a legitimate empty result — while the outgoing read
// surfaces a prepare failure as `databaseUnavailable`, because `message` and
// `handle` exist in every Messages store and their absence means the snapshot
// cannot serve as delivery evidence.
//
// Architectural role: the read half of the recipient history and send
// confirmation surfaces. The history source owns snapshot lifetime, this file
// owns the shapes, and the resolver and confirmation loop consume the value
// types without touching SQLite.

import Foundation

#if canImport(SQLite3)
    import SQLite3

    extension MessagesDatabaseIO {
        /// Aggregate message history for one handle in a direct (one-participant) chat.
        ///
        /// A stats value is a read-only snapshot: `lastMessageAt` reflects the
        /// newest dated message and is nil when every message is undated, while
        /// `messageCount` counts only messages joined to direct chats. Because
        /// the aggregate joins through the chat tables, a direct chat with no
        /// messages contributes nothing at all.
        public struct MessageHandleStats: Sendable, Equatable {
            /// Canonical handle identifier as stored in `handle.id`.
            public let handle: String
            /// Messaging service label (`handle.service`), or nil when the row carries none.
            public let service: String?
            /// Instant of the newest message exchanged with this handle; nil when all rows are undated.
            public let lastMessageAt: Date?
            /// Number of messages exchanged with this handle in direct chats.
            public let messageCount: Int

            /// Creates a handle stats snapshot.
            /// - Parameters:
            ///   - handle: Canonical handle identifier.
            ///   - service: Messaging service label, or nil when absent.
            ///   - lastMessageAt: Newest exchange instant, or nil when undated.
            ///   - messageCount: Messages exchanged in direct chats.
            public init(handle: String, service: String?, lastMessageAt: Date?, messageCount: Int) {
                self.handle = handle
                self.service = service
                self.lastMessageAt = lastMessageAt
                self.messageCount = messageCount
            }
        }

        /// Reads per-handle message aggregates for every one-to-one chat.
        ///
        /// A chat counts as direct exactly when `chat_handle_join` holds one
        /// participant row for it, which keeps the classification independent
        /// of chat style and display names a caller could edit. The outer joins
        /// run through `chat_message_join`, so messages sent in a group never
        /// enter a handle's aggregate even when that handle also belongs to a
        /// direct chat. A statement that cannot be prepared — for example, an
        /// older database without `chat_handle_join` — returns an empty list:
        /// absent history is a legitimate empty result, not a failure.
        /// - Parameters:
        ///   - handle: Open snapshot handle.
        ///   - limit: Maximum handle rows returned; non-positive yields none.
        /// - Returns: Stats ordered by most recent message first.
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

        /// One outgoing message observed in the owner's own send history.
        ///
        /// Only the two fields confirmation needs are carried: the handle the
        /// message went to and when it was sent. The message body is
        /// deliberately absent, so confirmation cannot leak message content
        /// into a caller that only needs to know delivery happened.
        public struct MessageOutgoingRow: Sendable, Equatable {
            /// Handle identifier as stored in `handle.id`.
            public let handle: String
            /// Instant the outgoing message was recorded.
            public let sentAt: Date

            /// Creates an outgoing-message row.
            /// - Parameters:
            ///   - handle: Handle identifier as stored in `handle.id`.
            ///   - sentAt: Instant the message was recorded.
            public init(handle: String, sentAt: Date) {
                self.handle = handle
                self.sentAt = sentAt
            }
        }

        /// Reads the owner's outgoing messages at or after `since`, newest first.
        ///
        /// The direction filter is the point of this read: only `is_from_me`
        /// rows count as evidence that a send landed, and the inner join drops
        /// rows with no handle link rather than attributing them to a recipient
        /// they do not name. A message with a NULL date never satisfies the
        /// comparison, so it is excluded instead of surfaced undated. The bound
        /// and the ordering both normalize through the shared seconds
        /// expression: `m.date` is seconds since 2001 on older stores and
        /// nanoseconds on current ones, so comparing raw ticks against a
        /// seconds-scale `since` would let every nanosecond row — including
        /// stale history — satisfy the window and confirm a send that never
        /// landed.
        /// - Parameters:
        ///   - handle: Open snapshot handle.
        ///   - since: Inclusive lower bound; callers pass a bounded grace window.
        ///   - limit: Maximum rows returned; non-positive yields none.
        /// - Returns: Outgoing rows ordered by most recent first.
        /// - Throws: ``MessagesIndexError/databaseUnavailable`` when the
        ///   statement cannot be prepared, so a caller can distinguish "no
        ///   evidence" from "cannot read evidence".
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
