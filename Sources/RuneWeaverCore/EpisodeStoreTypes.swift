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
    let joined = parts.joined(separator: "; ")
    if joined.count > 4000 {
        return String(joined.prefix(4000)) + "…"
    }
    return joined
}
