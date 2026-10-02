// Rune Weaver Core — Direct-chat message history for recipient resolution.
//
// Purpose: recipient resolution needs prior-contact history — which handles the
// owner actually exchanges direct messages with, how recently, and how often —
// without any caller holding the TCC-protected Messages database open. This
// source provides that read behind a narrow protocol so tools and resolvers
// depend on a seam they can stub.
//
// Scope: one async read of per-handle aggregates. The live database is never
// touched in place: each call copies it (plus sidecars) into an isolated
// temporary snapshot, queries the copy, and removes the copy on every exit
// path. Errors propagate unchanged, so a missing database stays
// `databaseUnavailable` and a denied read stays `permissionDenied` for callers
// that choose to surface them.
//
// Architectural role: the history surface consumed by recipient lookup,
// alongside the contacts search surface and the shared handle value types.

import Foundation

#if canImport(SQLite3)
    import SQLite3

    /// Seam for reading recent direct-message history without exposing a database handle.
    ///
    /// The protocol exists so recipient resolution can be exercised against a
    /// stub and so a future backing store (an index, a cache) can satisfy the
    /// same contract. Implementations own their own safety decisions about the
    /// live Messages database.
    public protocol MessagesHistorySourcing: Sendable {
        /// Returns per-handle aggregates for one-to-one chats, newest first.
        /// - Parameter limit: Maximum handle rows returned.
        /// - Returns: Direct-chat stats ordered by most recent message.
        /// - Throws: An error when the database cannot be snapshotted or read.
        func recentDirectHandleStats(limit: Int) async throws -> [MessageHandleStats]
    }

    /// Reads direct-chat handle history from an isolated snapshot of `chat.db`.
    ///
    /// Snapshotting borrows the same idiom as the Messages indexer: copy the
    /// live store, read only the copy, and never hold the live store open. The
    /// temporary directory is removed on success and on failure alike, so a
    /// failed read cannot leak a copy of the owner's messages.
    public struct MessagesChatHistorySource: MessagesHistorySourcing {
        /// Live database path; expansion happens when the snapshot is taken.
        private let chatDatabasePath: String

        /// Creates a chat history source.
        /// - Parameter chatDatabasePath: Live `chat.db` path; `~` is expanded
        ///   by the snapshotter the same way it is for the Messages indexer.
        public init(chatDatabasePath: String = MessagesIndexer.defaultChatDatabasePath) {
            self.chatDatabasePath = chatDatabasePath
        }

        /// Returns per-handle aggregates for one-to-one chats, newest first.
        ///
        /// The snapshot is the read boundary: the query only ever sees a
        /// consistent copy, and the copy is discarded before the call returns.
        /// `MessagesIndexError` cases pass through unchanged so the caller can
        /// distinguish a missing database from missing Full Disk Access.
        /// - Parameter limit: Maximum handle rows returned.
        /// - Returns: Direct-chat stats ordered by most recent message.
        /// - Throws: ``MessagesIndexError`` when the database is missing,
        ///   unreadable, or cannot be snapshotted.
        public func recentDirectHandleStats(limit: Int) async throws -> [MessageHandleStats] {
            let directory = try MessagesIndexer.snapshotDatabase(chatDatabasePath: chatDatabasePath)
            defer { try? FileManager.default.removeItem(at: directory) }
            let snapshotPath = directory.appendingPathComponent("chat.db").path
            let handle = try MessagesIndexer.openHandle(snapshotPath: snapshotPath)
            defer { sqlite3_close(handle) }
            return try MessagesDatabaseIO.recentDirectHandleStats(handle: handle, limit: limit)
        }
    }
#endif
