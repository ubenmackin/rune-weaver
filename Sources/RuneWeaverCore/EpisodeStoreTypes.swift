// Rune Weaver Core — Types and summarizers for episodic memory.

import Foundation

/// A single episodic memory record: one turn of conversation history.
public struct Episode: Sendable, Codable, Equatable, Identifiable {
    /// Unique identifier for this episode.
    public let id: UUID
    /// Owning conversation session.
    public let sessionID: UUID
    /// Who produced the content.
    public let role: Message.Role
    /// Text content of the turn.
    public let content: String
    /// When the turn occurred.
    public let timestamp: Date
    /// Caller-supplied key/value annotations (never secrets).
    public let metadata: [String: String]

    /// Creates an episode.
    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        role: Message.Role,
        content: String,
        timestamp: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.sessionID = sessionID
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.metadata = metadata
    }

    /// Coding keys matching the SQLite `episodes` column names.
    enum CodingKeys: String, CodingKey {
        /// Episode identifier (`id` column).
        case id
        /// Owning session (`session_id` column).
        case sessionID = "session_id"
        /// Author role (`role` column).
        case role
        /// Text content (`content` column).
        case content
        /// Occurrence time (`timestamp` column).
        case timestamp
        /// JSON metadata (`metadata` column).
        case metadata
    }
}

/// Rolled-up summary of one session's old episodes.
public struct EpisodeSummary: Sendable, Codable, Equatable {
    /// Session the summarized episodes belong to.
    public let sessionID: UUID
    /// Summary text covering the compacted episodes.
    public let summary: String
    /// How many episodes were folded in.
    public let messageCount: Int
    /// Oldest episode timestamp in the group.
    public let oldest: Date
    /// Newest episode timestamp in the group.
    public let newest: Date

    /// Creates a summary.
    public init(sessionID: UUID, summary: String, messageCount: Int, oldest: Date, newest: Date) {
        self.sessionID = sessionID
        self.summary = summary
        self.messageCount = messageCount
        self.oldest = oldest
        self.newest = newest
    }
}

/// Failures raised by ``EpisodeStore``.
public enum EpisodeStoreError: Error, Sendable, Equatable {
    /// The SQLite store could not be opened or migrated.
    case storeUnavailable(String)
    /// A read or write against the store failed.
    case persistenceFailed(String)
}

/// Summarizes a batch of episodes into short text.
public typealias EpisodeSummarizer = @Sendable ([Episode]) -> String

/// Default extractive summarizer used when no LLM is wired in.
public func defaultEpisodeSummarizer(_ episodes: [Episode]) -> String {
    let parts = episodes.map { episode -> String in
        let firstLine = episode.content.split(separator: "\n").first.map { String($0) } ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return "[\(episode.role.rawValue)] \(trimmed)"
    }
    return extractiveSummary(lines: parts, truncationLength: 4000)
}

/// Builds an extractive summary from preformatted lines.
func extractiveSummary(lines: [String], truncationLength: Int) -> String {
    guard truncationLength > 0 else { return "" }
    let joined = lines.joined(separator: "; ")
    guard joined.count > truncationLength else { return joined }
    if truncationLength == 1 {
        return "…"
    }
    return String(joined.prefix(truncationLength - 1)) + "…"
}

#if canImport(SQLite3)
    import SQLite3

    /// Allowlisted tables eligible for schema probing.
    ///
    /// The probe builds its `PRAGMA` from fixed constants so callers can
    /// never inject an arbitrary identifier; adding a case here is the
    /// only way to make another table queryable.
    package enum SQLiteKnownTable: Sendable {
        /// Conversation sessions.
        case sessions
        /// Messages belonging to a session.
        case messages
        /// Graduated-trust grants.
        case trustGrants

        /// Fixed `PRAGMA` statement for the table.
        package var pragmaSQL: String {
            switch self {
            case .sessions: "PRAGMA table_info(sessions);"
            case .messages: "PRAGMA table_info(messages);"
            case .trustGrants: "PRAGMA table_info(trust_grants);"
            }
        }
    }

    /// Shared SQLite primitives for the episode, session, scheduler, and run-log stores.
    package enum SQLiteHelpers {
        /// Opens a database handle, creating parent directories.
        package static func openHandle(dbPath: String, unavailable: (String) -> some Error) throws -> OpaquePointer? {
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
                throw unavailable("Could not open SQLite store at \(dbPath)")
            }
            do {
                try exec(
                    handle: handle,
                    sql: "PRAGMA busy_timeout = 5000; PRAGMA journal_mode = WAL;",
                    failure: unavailable
                )
            } catch {
                sqlite3_close(handle)
                throw error
            }
            return handle
        }

        /// Executes a multi-statement SQL string.
        package static func exec(handle: OpaquePointer?, sql: String, failure: (String) -> some Error) throws {
            var errorMessage: UnsafeMutablePointer<CChar>?
            let status = sql.withCString { sqlite3_exec(handle, $0, nil, nil, &errorMessage) }
            defer { sqlite3_free(errorMessage) }
            guard status == SQLITE_OK else {
                let detail = errorMessage.map { String(cString: $0) } ?? "unknown error"
                throw failure(detail)
            }
        }

        /// Binds optional text, mapping nil to NULL.
        package static func bindText(_ statement: OpaquePointer?, index: Int32, value: String?) {
            if let value {
                _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            } else {
                sqlite3_bind_null(statement, index)
            }
        }

        /// Column-text helper returning nil for NULL columns.
        package static func columnText(_ statement: OpaquePointer?, index: Int32) -> String? {
            sqlite3_column_text(statement, index).map { String(cString: $0) }
        }

        /// Binds optional 64-bit integer, mapping nil to NULL.
        package static func bindInt64(_ statement: OpaquePointer?, index: Int32, value: Int64?) {
            if let value {
                sqlite3_bind_int64(statement, index, value)
            } else {
                sqlite3_bind_null(statement, index)
            }
        }

        /// Column-int64 helper returning nil for NULL columns.
        package static func columnInt64(_ statement: OpaquePointer?, index: Int32) -> Int64? {
            if sqlite3_column_type(statement, index) == SQLITE_NULL {
                return nil
            }
            return sqlite3_column_int64(statement, index)
        }

        /// Binds double value.
        package static func bindDouble(_ statement: OpaquePointer?, index: Int32, value: Double) {
            sqlite3_bind_double(statement, index, value)
        }

        /// Column-double helper.
        package static func columnDouble(_ statement: OpaquePointer?, index: Int32) -> Double {
            sqlite3_column_double(statement, index)
        }

        /// Lists declared columns for a table, lowercased for case-tolerant migration checks.
        /// - Parameters:
        ///   - handle: Open database handle being migrated or projected.
        ///   - table: Allowlisted table; its fixed `PRAGMA` is the only SQL issued.
        /// - Returns: Lowercased column names, or empty when the probe cannot prepare so callers attempt migration.
        package static func columnNames(handle: OpaquePointer?, table: SQLiteKnownTable) -> Set<String> {
            var names: Set<String> = []
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, table.pragmaSQL, -1, &statement, nil) == SQLITE_OK else {
                return names
            }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                if let name = columnText(statement, index: 1) {
                    names.insert(name.lowercased())
                }
            }
            return names
        }
    }
#endif
