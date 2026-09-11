import Foundation

/// A single episodic memory record: one turn of conversation history.
///
/// Episodes persist in SQLite (`episodes.db` from `config.toml`) with an
/// FTS5 index over `content` for keyword search. Old episodes are folded
/// into per-session summaries via
/// ``EpisodeStore/summarizeSessions(olderThan:summarizer:)``.
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
    /// - Parameters:
    ///   - id: Unique identifier. Defaults to a new UUID.
    ///   - sessionID: Owning session identifier.
    ///   - role: Who produced the content.
    ///   - content: Text content.
    ///   - timestamp: Occurrence date. Defaults to now.
    ///   - metadata: Key/value annotations. Defaults to empty.
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
///
/// Produced by ``EpisodeStore/summarizeSessions(olderThan:summarizer:)``
/// without mutating the store; see
/// ``EpisodeStore/compactSessions(olderThan:summarizer:)`` for the
/// destructive variant that replaces old rows with a summary episode.
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
    /// - Parameters:
    ///   - sessionID: Owning session identifier.
    ///   - summary: Summary text.
    ///   - messageCount: Folded episode count.
    ///   - oldest: Oldest timestamp.
    ///   - newest: Newest timestamp.
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
///
/// Takes the episodes being compacted (oldest first) and returns the
/// summary kept as an `EpisodeSummary` or a replacement system episode.
/// - Parameter episodes: Episodes being compacted.
/// - Returns: Summary text.
public typealias EpisodeSummarizer = @Sendable ([Episode]) -> String

/// Default extractive summarizer used when no LLM is wired in.
///
/// Joins the first line of each episode, truncated to a bounded length,
/// so no data leaves the machine for summarization.
/// - Parameter episodes: Episodes being compacted.
/// - Returns: Summary preview.
public func defaultEpisodeSummarizer(_ episodes: [Episode]) -> String {
    let parts = episodes.map { episode -> String in
        let firstLine = episode.content.split(separator: "\n").first.map { String($0) } ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return "[\(episode.role.rawValue)] \(trimmed)"
    }
    return extractiveSummary(lines: parts, truncationLength: 4000)
}

/// Builds an extractive summary from preformatted lines.
///
/// Joins `lines` with `"; "` and truncates to exactly
/// `truncationLength` characters inclusive of the trailing ellipsis
/// so callers share one truncation policy. Text at or under the limit
/// returns unchanged with no ellipsis.
/// Used by both the episode and session summarizers.
/// - Parameters:
///   - lines: Preformatted `"[role] first line"` entries.
///   - truncationLength: Maximum characters in the returned text,
///     including the ellipsis when truncation applies. Non-positive
///     limits return an empty string.
/// - Returns: Joined text, truncated to `truncationLength` characters
///   inclusive of the ellipsis when over budget.
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

    /// Shared SQLite primitives for the episode and session stores.
    ///
    /// Centralizes directory creation, handle opening, statement
    /// execution, and text binding so both stores share one
    /// `sqlite3_*` policy. Callers map failures to their domain
    /// errors via the `unavailable`/`failure` closures.
    enum SQLiteHelpers {
        /// Opens a database handle, creating parent directories.
        /// - Parameters:
        ///   - dbPath: SQLite file path. `~` is expanded.
        ///   - unavailable: Maps an open failure to the caller's domain error.
        /// - Returns: Open database handle. Caller must close it.
        static func openHandle(dbPath: String, unavailable: (String) -> some Error) throws -> OpaquePointer? {
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
            return handle
        }

        /// Executes a multi-statement SQL string.
        /// - Parameters:
        ///   - handle: Open database handle.
        ///   - sql: SQL to execute.
        ///   - failure: Maps an execution failure to the caller's domain error.
        static func exec(handle: OpaquePointer?, sql: String, failure: (String) -> some Error) throws {
            var errorMessage: UnsafeMutablePointer<CChar>?
            let status = sql.withCString { sqlite3_exec(handle, $0, nil, nil, &errorMessage) }
            defer { sqlite3_free(errorMessage) }
            guard status == SQLITE_OK else {
                let detail = errorMessage.map { String(cString: $0) } ?? "unknown error"
                throw failure(detail)
            }
        }

        /// Binds optional text, mapping nil to NULL.
        /// - Parameters:
        ///   - statement: Prepared statement.
        ///   - index: One-based bind index.
        ///   - value: Text value, or nil for NULL.
        static func bindText(_ statement: OpaquePointer?, index: Int32, value: String?) {
            if let value {
                _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            } else {
                sqlite3_bind_null(statement, index)
            }
        }

        /// Column-text helper returning nil for NULL columns.
        /// - Parameters:
        ///   - statement: Stepped statement positioned on a row.
        ///   - index: Zero-based column index.
        /// - Returns: Column text, or nil when NULL.
        static func columnText(_ statement: OpaquePointer?, index: Int32) -> String? {
            sqlite3_column_text(statement, index).map { String(cString: $0) }
        }
    }
#endif
