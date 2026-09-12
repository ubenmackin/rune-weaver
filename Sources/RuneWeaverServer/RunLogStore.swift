// Rune Weaver Server — In-memory run log and execution audit store.
//
// Maintains an audit trail of chat turns and scheduled job firings for API
// consumers. Provides bounded in-memory FIFO retention with lock-free actor
// isolation, query limits, and job-specific history filtering.

import Foundation

/// One recorded run: a chat turn or a scheduler job execution.
///
/// The run log is the audit trail for the API surface: every `POST /chat`
/// turn and every scheduler firing appends one entry so clients can review
/// what the engine did without reopening conversation history.
public struct RunLogEntry: Sendable, Codable, Equatable, Identifiable {
    /// Stable entry identifier.
    public let id: UUID
    /// Owning scheduler job, when this run came from a job.
    public let jobID: UUID?
    /// Run kind (`"chat"` or `"scheduler"`).
    public let kind: String
    /// Outcome (`"ok"`, `"error"`, or `"skipped"` for already-running jobs).
    public let status: String
    /// Human-readable summary (user text or job result preview).
    public let message: String
    /// When the run finished.
    public let timestamp: Date

    /// Creates a run log entry.
    /// - Parameters:
    ///   - id: Entry identifier. Defaults to a new UUID.
    ///   - jobID: Owning scheduler job, if any.
    ///   - kind: Run kind (`"chat"` or `"scheduler"`).
    ///   - status: Outcome (`"ok"`, `"error"`, or `"skipped"`).
    ///   - message: Human-readable summary.
    ///   - timestamp: Finish date. Defaults to now.
    public init(
        id: UUID = UUID(),
        jobID: UUID? = nil,
        kind: String,
        status: String,
        message: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.jobID = jobID
        self.kind = kind
        self.status = status
        self.message = message
        self.timestamp = timestamp
    }
}

/// In-memory append-only store for run log entries.
///
/// Single owner of run history so REST (`GET /runs`), the chat path, and
/// the scheduler firing path share one audit trail. Entries persist only
/// for the process lifetime. Stored messages are truncated to
/// `maxMessageLength` characters so one huge `POST /chat` body cannot
/// exhaust memory across the bounded entry window.
public actor RunLogStore {
    /// Maximum characters kept per entry message; longer messages are
    /// truncated with a trailing `…`.
    public static let maxMessageLength = 1000
    /// Maximum entries kept; oldest entries drop first.
    public let capacity: Int
    /// Entries in append order.
    private var entries: [RunLogEntry] = []

    /// Creates a run log store.
    /// - Parameter capacity: Maximum entries kept. Defaults to 500.
    public init(capacity: Int = 500) {
        self.capacity = max(1, capacity)
    }

    /// Appends one entry, evicting the oldest when over capacity.
    ///
    /// The message is truncated to `maxMessageLength` characters (with a
    /// trailing `…`) so capacity bounds bytes as well as entry count.
    /// - Parameters:
    ///   - kind: Run kind (`"chat"` or `"scheduler"`).
    ///   - status: Outcome (`"ok"`, `"error"`, or `"skipped"`).
    ///   - message: Human-readable summary.
    ///   - jobID: Owning scheduler job, if any.
    /// - Returns: The stored entry.
    @discardableResult
    public func append(kind: String, status: String, message: String, jobID: UUID? = nil) -> RunLogEntry {
        let entry = RunLogEntry(jobID: jobID, kind: kind, status: status, message: Self.truncated(message))
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        return entry
    }

    /// Appends a prebuilt entry, evicting the oldest when over capacity.
    ///
    /// The entry message is truncated to `maxMessageLength` characters
    /// before storage.
    /// - Parameter entry: Entry to store.
    public func append(_ entry: RunLogEntry) {
        let stored = RunLogEntry(
            id: entry.id,
            jobID: entry.jobID,
            kind: entry.kind,
            status: entry.status,
            message: Self.truncated(entry.message),
            timestamp: entry.timestamp
        )
        entries.append(stored)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// Truncates a run-log message to the fixed bound.
    /// - Parameter message: Raw message.
    /// - Returns: Message capped at `maxMessageLength` characters.
    public static func truncated(_ message: String) -> String {
        guard message.count > maxMessageLength else { return message }
        return String(message.prefix(maxMessageLength)) + "…"
    }

    /// Lists entries, newest first.
    /// - Parameter limit: Maximum entries. Defaults to 50. Non-positive
    ///   limits return an empty list.
    /// - Returns: Entries newest first.
    public func list(limit: Int = 50) -> [RunLogEntry] {
        guard limit > 0 else { return [] }
        return Array(entries.suffix(limit).reversed())
    }

    /// Looks up one entry.
    /// - Parameter id: Entry identifier.
    /// - Returns: The entry, or nil when unknown.
    public func entry(id: UUID) -> RunLogEntry? {
        entries.first { $0.id == id }
    }

    /// Number of stored entries.
    /// - Returns: Entry count.
    public func count() -> Int {
        entries.count
    }

    /// Removes every entry.
    public func clear() {
        entries.removeAll()
    }
}
