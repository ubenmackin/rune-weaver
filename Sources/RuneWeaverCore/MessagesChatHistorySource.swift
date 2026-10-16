// Rune Weaver Core — Direct-chat message history for recipient resolution.

import Foundation

#if canImport(SQLite3)
    import SQLite3

    /// Seam for reading recent direct-message history without exposing a database handle.
    public protocol MessagesHistorySourcing: Sendable {
        /// Returns per-handle aggregates for one-to-one chats, newest first.
        /// - Parameter limit: Maximum handle rows returned.
        func recentDirectHandleStats(limit: Int) async throws -> [MessageHandleStats]
    }

    /// Reads direct-chat handle history from an isolated snapshot of `chat.db`. Snapshotting
    /// borrows the same idiom as the Messages indexer: copy the live store, read only the copy, and
    /// never hold the live store open.
    public struct MessagesChatHistorySource: MessagesHistorySourcing {
        /// Live database path; expansion happens when the snapshot is taken.
        private let chatDatabasePath: String

        /// Creates a chat history source.
        /// - Parameter chatDatabasePath: Live `chat.db` path; `~` is expanded
        ///   by the snapshotter the same way it is for the Messages indexer.
        public init(chatDatabasePath: String = MessagesIndexer.defaultChatDatabasePath) {
            self.chatDatabasePath = chatDatabasePath
        }

        /// Returns per-handle aggregates for one-to-one chats, newest first. The snapshot is the
        /// read boundary: the query only ever sees a consistent copy, and the copy is discarded
        /// before the call returns.
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
