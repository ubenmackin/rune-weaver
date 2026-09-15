import Foundation

#if canImport(SQLite3)
    import SQLite3
#endif

/// A single conversation session owned by the manager.
///
/// Sessions group messages for one continuous interaction. When the
/// history outgrows the context window the oldest turns are folded
/// into `summary` so recent context stays intact.
public struct ConversationSession: Sendable, Codable, Equatable, Identifiable {
    /// Unique identifier for this session.
    public let id: UUID
    /// Human-readable title for this session.
    public var title: String?
    /// Messages in chronological order.
    public var messages: [Message]
    /// Rolling summary of truncated turns, if any.
    public var summary: String?
    /// Creation timestamp.
    public let createdAt: Date
    /// Last mutation timestamp.
    public var updatedAt: Date
    /// Originating source of this session (e.g. "chat", "scheduler").
    public var source: String?

    /// Human-readable display title, falling back to an extractive preview of the first user message.
    public var displayTitle: String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if let firstUser = messages.first(where: { $0.role == .user }) {
            let firstLine = firstUser.content.split(separator: "\n").first.map(String.init) ?? firstUser.content
            let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count > 40 {
                return String(trimmed.prefix(40)) + "…"
            }
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return "Session \(id.uuidString.prefix(8))"
    }

    /// Creates a session.
    /// - Parameters:
    ///   - id: Session identifier. Defaults to a new UUID.
    ///   - title: Human-readable title. Defaults to nil.
    ///   - messages: Initial messages. Defaults to empty.
    ///   - summary: Rolling summary. Defaults to nil.
    ///   - createdAt: Creation date. Defaults to now.
    ///   - updatedAt: Last mutation date. Defaults to now.
    ///   - source: Originating source. Defaults to nil.
    public init(
        id: UUID = UUID(),
        title: String? = nil,
        messages: [Message] = [],
        summary: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        source: String? = nil
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.summary = summary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.source = source
    }
}

/// Metadata summary of one session for listing in clients.
public struct SessionSummary: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let title: String
    public let messageCount: Int
    public let summary: String?
    public let createdAt: Date
    public let updatedAt: Date
    public let source: String?

    public init(
        id: UUID,
        title: String,
        messageCount: Int,
        summary: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        source: String? = nil
    ) {
        self.id = id
        self.title = title
        self.messageCount = messageCount
        self.summary = summary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.source = source
    }
}

/// Failures raised by ``ConversationManager`` persistence.
public enum ConversationManagerError: Error, Sendable, Equatable {
    /// The SQLite store could not be opened or migrated.
    case storeUnavailable(String)
    /// A read or write against the store failed.
    case persistenceFailed(String)
    /// No session exists for the given identifier.
    case unknownSession(String)
}

/// Summarizes dropped turns during truncation.
///
/// Takes the messages being evicted and returns a short summary that
/// is kept as session state. Callers may inject an LLM-backed
/// summarizer; the default is an extractive preview.
/// - Parameter messages: Messages being evicted.
/// - Returns: Summary text.
public typealias SessionSummarizer = @Sendable ([Message]) -> String

/// Default extractive summarizer used when no LLM is wired in.
///
/// Joins the first line of each evicted message, truncated to a
/// bounded length, so no data leaves the machine for summarization.
/// - Parameter messages: Messages being evicted.
/// - Returns: Summary preview.
public func defaultSessionSummarizer(_ messages: [Message]) -> String {
    let parts = messages.map { message -> String in
        let firstLine = message.content.split(separator: "\n").first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return "[\(message.role.rawValue)] \(trimmed)"
    }
    return extractiveSummary(lines: parts, truncationLength: 2000)
}

/// Manages multiple concurrent conversation sessions.
///
/// The manager keeps per-session message history in memory, truncates
/// the context window via summarization when `maxMessages` is
/// exceeded, and persists sessions to SQLite (`episodesDBPath`, the
/// `episodes.db` file from `config.toml`). Where the SQLite3 module
/// is unavailable the manager falls back to JSON files beside the
/// configured database path so behavior stays identical.
///
/// Blocking SQLite/JSON work runs off the actor executor: every read
/// and write suspends via the shared serial store queue
/// (`SQLiteSerialIO`) so disk order matches actor order and deletes
/// never race earlier writes.
public actor ConversationManager {
    /// Maximum sessions tracked concurrently in memory before evicting oldest.
    public static let maxSessions: Int = 500
    /// Maximum character length kept in the rolling summary before oldest text is truncated.
    public static let maxSummaryLength: Int = 2000
    /// Maximum title characters stored per session, bounding the sessions table and sidebar display.
    public static let maxTitleLength: Int = 200
    /// Maximum messages retained per session before truncation.
    public let maxMessages: Int
    /// Filesystem path of the episodes database, if configured.
    public let episodesDBPath: String?
    /// Summarizer applied to evicted turns.
    private let summarizer: SessionSummarizer

    /// Sessions indexed by identifier.
    private var sessions: [UUID: ConversationSession] = [:]
    /// Identifiers created in memory but not yet confirmed on disk.
    ///
    /// New sessions from `ensureSession` have no immediate persist, and
    /// appends suspend on the serial store queue; a concurrent list must
    /// not treat those identifiers as cross-process deletes.
    private var unpersistedIDs: Set<UUID> = []

    /// Creates a manager.
    /// - Parameters:
    ///   - maxMessages: Messages retained per session before
    ///     truncation. Defaults to 100.
    ///   - episodesDBPath: SQLite path for session persistence.
    ///     Defaults to nil (memory only until `load`/`save` with a path).
    ///   - summarizer: Summarizer for evicted turns. Defaults to
    ///     ``defaultSessionSummarizer``.
    public init(
        maxMessages: Int = 100,
        episodesDBPath: String? = nil,
        summarizer: SessionSummarizer? = nil
    ) {
        self.maxMessages = max(1, maxMessages)
        self.episodesDBPath = episodesDBPath
        self.summarizer = summarizer ?? defaultSessionSummarizer
    }

    // MARK: - Sessions

    /// Creates a new empty session and tracks it.
    ///
    /// Persists the new session before returning so later deletes
    /// cannot race an earlier write.
    /// - Returns: The new session.
    @discardableResult
    public func createSession() async -> ConversationSession {
        let session = ConversationSession()
        sessions[session.id] = session
        await persist(session)
        return session
    }

    /// Reads one session from disk and merges it with memory by recency.
    ///
    /// Centralizes the disk-read plus recency policy shared by single-session
    /// readers so a disk copy never clobbers newer in-memory state (recent
    /// title fills or appends whose persist has not yet drained) and a
    /// missing disk row never clears memory. Disk failures leave memory
    /// untouched so transient I/O never hides live state.
    /// - Parameter id: Session identifier.
    /// - Returns: Merged session, or the memory copy when disk is missing.
    private func readSingleMerged(id: UUID) async -> ConversationSession? {
        if let path = episodesDBPath {
            do {
                let diskSession = try await SQLiteSerialIO.run {
                    try SessionStoreIO.readSingle(sessionID: id, dbPath: path)
                }
                if let diskSession {
                    // Disk confirms the identifier, so a later list sweep
                    // must treat it as a cross-process delete candidate.
                    unpersistedIDs.remove(id)
                    if let existing = sessions[id] {
                        // SQLite REAL timestamps lose sub-second precision, so a
                        // tie means the disk copy is stale next to a just-mutated
                        // memory copy (rapid append plus persist race). Memory wins
                        // ties to avoid clobbering newer titles and appends.
                        if diskSession.updatedAt > existing.updatedAt {
                            sessions[id] = diskSession
                            return diskSession
                        }
                        return existing
                    }
                    sessions[id] = diskSession
                    return diskSession
                }
            } catch {
                fputs("[WARN] ConversationManager: Failed reading session \(id) from disk: \(error.localizedDescription)\n", stderr)
            }
        }
        return sessions[id]
    }

    /// Returns the session with the given identifier.
    /// - Parameter id: Session identifier.
    /// - Returns: The session, or nil when unknown.
    public func session(id: UUID) async -> ConversationSession? {
        await readSingleMerged(id: id)
    }

    /// Returns the session, creating it when missing.
    /// - Parameters:
    ///   - id: Session identifier.
    ///   - title: Optional human-readable title.
    ///   - source: Optional originating source.
    ///   - overwrite: When true, replaces an existing title/source instead
    ///     of only filling blanks, so one call can upsert the scheduler
    ///     identity with a single persist.
    /// - Returns: The existing or newly created session.
    @discardableResult
    public func ensureSession(id: UUID, title: String? = nil, source: String? = nil, overwrite: Bool = false) async -> ConversationSession {
        if var existing = sessions[id] {
            var changed = false
            if let title, overwrite ? existing.title != title : existing.title == nil {
                existing.title = title
                changed = true
            }
            if let source, overwrite ? existing.source != source : existing.source == nil {
                existing.source = source
                changed = true
            }
            if changed {
                sessions[id] = existing
                // Persist title/source fills so in-memory updates survive
                // restart, matching the disk path below.
                await persist(existing)
            }
            return existing
        }
        if var diskSession = await readSingleMerged(id: id) {
            var changed = false
            if let title, overwrite ? diskSession.title != title : diskSession.title == nil {
                diskSession.title = title
                changed = true
            }
            if let source, overwrite ? diskSession.source != source : diskSession.source == nil {
                diskSession.source = source
                changed = true
            }
            if changed {
                sessions[id] = diskSession
                await persist(diskSession)
            }
            return diskSession
        }
        if sessions.count >= Self.maxSessions {
            if let oldest = sessions.values.min(by: { $0.updatedAt < $1.updatedAt }) {
                sessions.removeValue(forKey: oldest.id)
                unpersistedIDs.remove(oldest.id)
            }
        }
        let session = ConversationSession(id: id, title: title, source: source)
        sessions[id] = session
        unpersistedIDs.insert(id)
        return session
    }

    /// Returns summaries of all tracked sessions, sorted by last update date descending.
    public func listSessions() async -> [SessionSummary] {
        if let path = episodesDBPath {
            do {
                let diskSessions = try await SQLiteSerialIO.run {
                    try SessionStoreIO.read(dbPath: path)
                }
                for diskSession in diskSessions {
                    // Disk confirms each identifier; later sweeps may treat
                    // confirmed identifiers as delete candidates.
                    unpersistedIDs.remove(diskSession.id)
                    if let existing = sessions[diskSession.id] {
                        // Same tie-break as single-session reads: disk REAL
                        // precision can tie with newer memory state, so memory
                        // wins ties and disk only wins when strictly newer.
                        if diskSession.updatedAt > existing.updatedAt {
                            sessions[diskSession.id] = diskSession
                        }
                    } else {
                        sessions[diskSession.id] = diskSession
                    }
                }
                // Drop memory entries deleted by another process, but keep
                // identifiers never confirmed on disk: new sessions without
                // an immediate persist and appends whose persist has not
                // drained must survive a concurrent list.
                let diskIDs = Set(diskSessions.map(\.id))
                for id in Array(sessions.keys) where !diskIDs.contains(id) && !unpersistedIDs.contains(id) {
                    sessions.removeValue(forKey: id)
                }
            } catch {
                fputs("[WARN] ConversationManager: Failed reading sessions from disk: \(error.localizedDescription)\n", stderr)
            }
        }
        return sessions.values
            .sorted(by: { $0.updatedAt > $1.updatedAt })
            .map { session in
                SessionSummary(
                    id: session.id,
                    title: session.displayTitle,
                    messageCount: session.messages.count,
                    summary: session.summary,
                    createdAt: session.createdAt,
                    updatedAt: session.updatedAt,
                    source: session.source
                )
            }
    }

    /// Updates the title of a session and persists it.
    ///
    /// Trims surrounding whitespace, ignores empty titles, and truncates
    /// overlong titles to `maxTitleLength` so the sessions table and
    /// sidebar never bloat on unbounded input.
    /// - Parameters:
    ///   - id: Session identifier.
    ///   - title: New title.
    ///   - source: Optional source.
    public func updateTitle(id: UUID, title: String, source: String? = nil) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let bounded = trimmed.count > Self.maxTitleLength ? String(trimmed.prefix(Self.maxTitleLength)) : trimmed
        var sessionToUpdate: ConversationSession? = sessions[id]
        if sessionToUpdate == nil {
            sessionToUpdate = await readSingleMerged(id: id)
        }
        guard var session = sessionToUpdate else { return }
        let titleChanged = session.title != bounded
        let sourceChanged = source != nil && session.source != source
        guard titleChanged || sourceChanged else { return }

        session.title = bounded
        if let source {
            session.source = source
        }
        session.updatedAt = Date()
        sessions[id] = session
        await persist(session)
    }

    /// Removes a session from memory and deletes the persisted row.
    ///
    /// Awaits the delete on the serial persistence queue so earlier
    /// writes complete first and cannot resurrect the session.
    /// - Parameter id: Session identifier.
    public func removeSession(id: UUID) async {
        sessions.removeValue(forKey: id)
        unpersistedIDs.remove(id)
        await deletePersistedSessionUncancellable(id: id)
    }

    /// Removes all sessions from memory and the persisted store.
    ///
    /// Clears in-memory state and deletes persisted rows so removed
    /// sessions do not resurrect on `loadAll`. The delete runs to
    /// completion on the serial queue so a cancelled caller still lands
    /// the delete.
    public func removeAllSessions() async {
        sessions.removeAll()
        unpersistedIDs.removeAll()
        guard let path = episodesDBPath else { return }
        await SQLiteSerialIO.runUncancellable {
            _ = try? SessionStoreIO.deleteAll(dbPath: path)
        }
    }

    // MARK: - History

    /// Appends a message to a session, truncating when over budget.
    ///
    /// Missing sessions are created implicitly. Truncation folds the
    /// oldest turns into the session summary via the configured
    /// summarizer, preferring to keep system messages and the most
    /// recent turns. When overflow exceeds the non-system count the
    /// oldest kept rows are evicted as well to stay within budget,
    /// so system messages may be evicted under overflow.
    /// - Parameters:
    ///   - message: Message to append.
    ///   - sessionID: Owning session identifier.
    public func append(_ message: Message, to sessionID: UUID) async {
        var session = await ensureSession(id: sessionID)
        session.messages.append(message)
        session.updatedAt = Date()
        truncateIfNeeded(messages: &session.messages, summary: &session.summary)
        sessions[session.id] = session
        await persist(session)
    }

    /// Returns context-ready history for a session.
    ///
    /// When the session carries a summary of truncated turns it is
    /// prepended as a `system` message so the LLM retains the gist of
    /// evicted history. Hydrates disk-only sessions the same way
    /// `session(id:)` does so a fresh manager observes durable state.
    /// - Parameter sessionID: Session identifier.
    /// - Returns: Messages for the LLM, or empty when unknown.
    public func history(for sessionID: UUID) async -> [Message] {
        guard let session = await readSingleMerged(id: sessionID) else { return [] }
        guard let summary = session.summary, !summary.isEmpty else {
            return session.messages
        }
        let summaryMessage = Message(role: .system, content: "\(Message.rollingSummaryPrefix) \(summary)")
        return [summaryMessage] + session.messages
    }

    /// Raw message count for a session.
    ///
    /// Hydrates disk-only sessions so counts match `history(for:)`.
    /// - Parameter sessionID: Session identifier.
    /// - Returns: Stored message count, or zero when unknown.
    public func messageCount(for sessionID: UUID) async -> Int {
        await readSingleMerged(id: sessionID)?.messages.count ?? 0
    }

    /// Builds the working history with the system prompt first.
    ///
    /// Single shared helper for `Orchestrator` and the CLI chat loop:
    /// an identical leading system message is kept, a stale one is
    /// replaced, prompts are never stacked, and a rolling summary
    /// (a leading message starting with `Message/rollingSummaryPrefix`)
    /// is preserved ahead of the prompt via `Array.withSystemPrompt(_:)`.
    /// Hydrates disk-only sessions via `history(for:)`.
    /// - Parameters:
    ///   - sessionID: Session identifier.
    ///   - systemPrompt: Developer instructions, if any.
    /// - Returns: Messages for the next LLM call.
    public func workingHistory(for sessionID: UUID, systemPrompt: String?) async -> [Message] {
        await history(for: sessionID).withSystemPrompt(systemPrompt)
    }

    /// Bulk-replaces history for session resume with truncation.
    ///
    /// Used when hydrating working memory from episodic storage: the
    /// messages are set with a single persistence write, folding the
    /// oldest turns into the session summary via the configured
    /// summarizer when over `maxMessages` so a long prior history
    /// never loads unbounded into working memory.
    /// Working memory (`sessions`/`messages` tables) is the live source of
    /// truth; the episodic `episodes` tables sharing the same file are the
    /// durable mirror hydrated only here.
    /// - Parameters:
    ///   - messages: Messages in chronological order.
    ///   - sessionID: Owning session identifier.
    public func setHistory(_ messages: [Message], for sessionID: UUID) async {
        var session = await ensureSession(id: sessionID)
        session.messages = messages
        session.updatedAt = Date()
        truncateIfNeeded(messages: &session.messages, summary: &session.summary)
        sessions[session.id] = session
        await persist(session)
    }

    /// Clears messages (and summary) for one session.
    ///
    /// Persists the cleared session before returning so the cleared
    /// state cannot lose to a reordered earlier write.
    /// - Parameter sessionID: Session identifier.
    public func clear(sessionID: UUID) async {
        guard var session = sessions[sessionID] else { return }
        session.messages.removeAll()
        session.summary = nil
        session.updatedAt = Date()
        sessions[sessionID] = session
        await persist(session)
    }

    /// Captures the raw pre-turn session state for cancellation rollback.
    ///
    /// Reads the stored session directly — never `history(for:)` or
    /// `workingHistory(for:)` — so the snapshot holds raw messages plus
    /// the rolling summary with no synthetic summary-prefix message.
    /// Hydrates disk-only sessions like `session(id:)` so restarts keep
    /// rollback intact.
    /// - Parameter sessionID: Session identifier.
    /// - Returns: Raw session copy, or nil when the session is unknown.
    public func rollbackSnapshot(for sessionID: UUID) async -> ConversationSession? {
        await readSingleMerged(id: sessionID)
    }

    /// Restores a rollback snapshot captured by `rollbackSnapshot(for:)`.
    ///
    /// Writes back raw messages and the rolling summary together, then
    /// persists uncancellably, so a cancelled turn neither duplicates the
    /// summary prefix nor keeps summary growth from truncated appends. The
    /// restore stamps a fresh mutation so disk cannot resurrect cancelled
    /// turns under recency merges. Persisting without observing
    /// cancellation matters because the caller restores from a
    /// `CancellationError` path where the task is already cancelled; a
    /// cancellable persist would be skipped and disk would keep the
    /// cancelled turn to resurrect after restart. A session deleted
    /// mid-turn stays deleted.
    /// - Parameter snapshot: Pre-turn session copy to restore.
    public func restoreRollbackSnapshot(_ snapshot: ConversationSession) async {
        guard sessions[snapshot.id] != nil else { return }
        var restored = snapshot
        restored.updatedAt = Date()
        sessions[snapshot.id] = restored
        await persistUncancellable(restored)
    }

    /// Structured tool actions grouped by parent assistant message.
    ///
    /// Derives one `ToolAction` per persisted `Calling ... [...]`
    /// placeholder line with the shared
    /// `ToolInput/parsePlaceholderLine(_:)` parser and correlates each
    /// call with its `tool`-role result by `callID`, so history clients
    /// render without re-parsing placeholder text across languages.
    /// Hydrates disk-only sessions; unknown sessions yield an empty map.
    /// - Parameter sessionID: Session identifier.
    /// - Returns: Actions keyed by parent message identifier, in stored order.
    public func toolActionsByMessage(for sessionID: UUID) async -> [UUID: [ToolAction]] {
        guard let session = await readSingleMerged(id: sessionID) else { return [:] }
        var resultsByCallID: [String: ToolResult] = [:]
        for message in session.messages where message.role == .tool {
            guard let callID = message.toolCallID else { continue }
            // Persisted error flags distinguish failures from successes;
            // rows written before the flag default to success.
            resultsByCallID[callID] = ToolResult(toolCallID: callID, content: message.content, isError: message.isError ?? false)
        }
        var grouped: [UUID: [ToolAction]] = [:]
        for message in session.messages where message.role == .assistant {
            var actions: [ToolAction] = []
            for line in message.content.components(separatedBy: "\n") {
                guard let parsed = ToolInput.parsePlaceholderLine(line) else { continue }
                actions.append(ToolAction(
                    toolName: parsed.toolName,
                    callID: parsed.callID,
                    argumentsJSON: parsed.argumentsJSON,
                    result: resultsByCallID[parsed.callID]
                ))
            }
            if !actions.isEmpty {
                grouped[message.id] = actions
            }
        }
        return grouped
    }

    // MARK: - Truncation

    /// Summarizes a session's oldest turns on demand.
    ///
    /// Keeps the newest `keeping` messages verbatim and folds the rest
    /// into the session summary.
    /// - Parameters:
    ///   - sessionID: Session identifier.
    ///   - keeping: Recent messages to keep. Defaults to `maxMessages`.
    /// - Returns: Summary text, or nil when the session is unknown
    ///   or already within budget.
    @discardableResult
    public func summarize(sessionID: UUID, keeping: Int? = nil) async -> String? {
        guard var session = sessions[sessionID] else { return nil }
        let keep = max(1, keeping ?? maxMessages)
        guard session.messages.count > keep else { return session.summary }
        let evicted = Array(session.messages.prefix(session.messages.count - keep))
        let summary = summarizer(evicted)
        session.summary = [session.summary, summary]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: "\n")
        session.messages = Array(session.messages.suffix(keep))
        session.updatedAt = Date()
        sessions[sessionID] = session
        await persist(session)
        return session.summary
    }

    /// Evicts oldest non-system turns when over `maxMessages`.
    ///
    /// Prefers non-system rows; when overflow exceeds the non-system
    /// count the oldest kept rows are evicted as well to stay within
    /// budget, which may include system messages.
    /// - Parameters:
    ///   - messages: In-out message buffer to truncate.
    ///   - summary: In-out summary to extend with evicted turns.
    private func truncateIfNeeded(messages: inout [Message], summary: inout String?) {
        guard messages.count > maxMessages else { return }
        let overflow = messages.count - maxMessages
        var evicted: [Message] = []
        var kept: [Message] = []
        kept.reserveCapacity(maxMessages)
        var dropped = 0
        for message in messages {
            if dropped < overflow, message.role != .system {
                evicted.append(message)
                dropped += 1
            } else {
                kept.append(message)
            }
        }
        if dropped < overflow {
            let extra = overflow - dropped
            evicted.append(contentsOf: kept.prefix(extra))
            kept = Array(kept.dropFirst(extra))
        }
        guard !evicted.isEmpty else { return }
        let chunk = summarizer(evicted)
        let combinedSummary = if let existing = summary, !existing.isEmpty {
            existing + "\n" + chunk
        } else {
            chunk
        }
        summary = if combinedSummary.count > Self.maxSummaryLength {
            "…" + String(combinedSummary.suffix(Self.maxSummaryLength))
        } else {
            combinedSummary
        }
        messages = kept
    }

    // MARK: - Persistence (SQLite with JSON fallback)

    /// Saves all tracked sessions to the configured store.
    ///
    /// Uses SQLite at `episodesDBPath` when set; otherwise this is a
    /// no-op. Failures throw so schedulers can retry. Blocking file work
    /// runs off the actor executor on the shared serial store queue so
    /// disk order matches actor order.
    public func saveAll() async throws {
        guard let path = episodesDBPath else { return }
        let snapshot = Array(sessions.values)
        try await SQLiteSerialIO.run {
            try SessionStoreIO.write(sessions: snapshot, dbPath: path)
        }
    }

    /// Loads sessions from the configured store, replacing memory.
    ///
    /// Uses SQLite at `episodesDBPath` when set; otherwise this is a
    /// no-op. Missing files load as empty. The blocking read runs off
    /// the actor executor on the shared serial store queue so it observes
    /// earlier writes.
    public func loadAll() async throws {
        guard let path = episodesDBPath else { return }
        let loaded = try await SQLiteSerialIO.run {
            try SessionStoreIO.read(dbPath: path)
        }
        sessions = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        unpersistedIDs.removeAll()
    }

    /// Saves one session without throwing (used after every mutation).
    ///
    /// Suspends on the shared serial store queue so writes complete in
    /// actor call order; failures are ignored. Confirmed identifiers
    /// leave the unpersisted set so later lists treat them as delete
    /// candidates.
    /// - Parameter session: Session to persist.
    private func persist(_ session: ConversationSession) async {
        guard let path = episodesDBPath else { return }
        let snapshot = session
        do {
            try await SQLiteSerialIO.run {
                try SessionStoreIO.write(sessions: [snapshot], dbPath: path, merge: true)
            }
            unpersistedIDs.remove(snapshot.id)
        } catch {
            // Best-effort only; the identifier stays unpersisted so a
            // concurrent list never mistakes it for a cross-process delete.
        }
    }

    /// Saves one session without observing cancellation.
    ///
    /// Rollback restoring from a `CancellationError` path runs under an
    /// already-cancelled task; a cancellable persist would be skipped and
    /// disk would keep the cancelled turn. Runs to completion on the
    /// serial queue instead.
    /// - Parameter session: Session to persist.
    private func persistUncancellable(_ session: ConversationSession) async {
        guard let path = episodesDBPath else { return }
        let snapshot = session
        await SQLiteSerialIO.runUncancellable {
            _ = try? SessionStoreIO.write(sessions: [snapshot], dbPath: path, merge: true)
        }
        unpersistedIDs.remove(snapshot.id)
    }

    /// Deletes one persisted session without observing cancellation.
    ///
    /// Shares the rollback rationale with `persistUncancellable`: deletes
    /// issued while the task is already cancelled must still land.
    /// - Parameter id: Session identifier.
    private func deletePersistedSessionUncancellable(id: UUID) async {
        guard let path = episodesDBPath else { return }
        await SQLiteSerialIO.runUncancellable {
            _ = try? SessionStoreIO.delete(sessionID: id, dbPath: path)
        }
    }
}

// MARK: - Session store I/O

/// File and SQLite I/O for conversation sessions.
///
/// Prefers the SQLite `sessions` table when the SQLite3 module is
/// available; otherwise persists each session as JSON beside the
/// configured database path so Linux CI and hosts without SQLite
/// headers behave identically.
enum SessionStoreIO {
    /// Writes sessions to the store.
    /// - Parameters:
    ///   - sessions: Sessions to write.
    ///   - dbPath: SQLite path (or JSON sidecar anchor).
    ///   - merge: When true, upserts without dropping other rows.
    static func write(sessions: [ConversationSession], dbPath: String, merge: Bool = false) throws {
        #if canImport(SQLite3)
            try SQLiteSessionStore.write(sessions: sessions, dbPath: dbPath, merge: merge)
        #else
            try JSONSessionStore.write(sessions: sessions, dbPath: dbPath, merge: merge)
        #endif
    }

    /// Reads all sessions from the store.
    /// - Parameter dbPath: SQLite path (or JSON sidecar anchor).
    /// - Returns: Stored sessions, empty when the store is missing.
    static func read(dbPath: String) throws -> [ConversationSession] {
        #if canImport(SQLite3)
            return try SQLiteSessionStore.read(dbPath: dbPath)
        #else
            return try JSONSessionStore.read(dbPath: dbPath)
        #endif
    }

    /// Reads a single session from the store.
    /// - Parameters:
    ///   - sessionID: Session identifier.
    ///   - dbPath: SQLite path (or JSON sidecar anchor).
    /// - Returns: Stored session, or nil when missing.
    static func readSingle(sessionID: UUID, dbPath: String) throws -> ConversationSession? {
        #if canImport(SQLite3)
            return try SQLiteSessionStore.readSingle(sessionID: sessionID, dbPath: dbPath)
        #else
            return try JSONSessionStore.readSingle(sessionID: sessionID, dbPath: dbPath)
        #endif
    }

    /// Deletes one session from the store. Missing rows are a no-op.
    /// - Parameters:
    ///   - sessionID: Session identifier.
    ///   - dbPath: SQLite path (or JSON sidecar anchor).
    static func delete(sessionID: UUID, dbPath: String) throws {
        #if canImport(SQLite3)
            try SQLiteSessionStore.delete(sessionID: sessionID, dbPath: dbPath)
        #else
            try JSONSessionStore.delete(sessionID: sessionID, dbPath: dbPath)
        #endif
    }

    /// Deletes all sessions from the store. Missing stores are a no-op.
    /// - Parameter dbPath: SQLite path (or JSON sidecar anchor).
    static func deleteAll(dbPath: String) throws {
        #if canImport(SQLite3)
            try SQLiteSessionStore.deleteAll(dbPath: dbPath)
        #else
            try JSONSessionStore.deleteAll(dbPath: dbPath)
        #endif
    }
}

#if canImport(SQLite3)
    /// Minimal SQLite store for sessions and their messages.
    ///
    /// Schema:
    /// `sessions(id TEXT PRIMARY KEY, summary TEXT, created_at REAL, updated_at REAL)`
    /// `messages(id TEXT PRIMARY KEY, session_id TEXT, role TEXT, content TEXT, tool_call_id TEXT, is_error INTEGER, created_at REAL)`
    enum SQLiteSessionStore {
        /// Lock-guarded record of paths already probed for migrations.
        ///
        /// Keeps the one-probe-per-path fast path without shared mutable
        /// state: every access runs inside the box so Swift 6 sees no
        /// data race, and eviction picks the sorted first entry so repeated
        /// runs evict the same victim instead of depending on hash order.
        private final class MigrationPathCache: @unchecked Sendable {
            /// Probed standardized paths.
            private var paths: Set<String> = []
            /// Guards `paths`.
            private let lock = NSLock()

            /// Creates an empty cache.
            init() {}

            /// Checks whether a path was already probed.
            /// - Parameter key: Standardized path.
            /// - Returns: True when already recorded.
            func contains(_ key: String) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                return paths.contains(key)
            }

            /// Records a path, evicting deterministically at capacity.
            ///
            /// Eviction only forces a future re-probe (idempotent
            /// `table_info` plus conditional `ALTER`), never a correctness
            /// loss, so the sorted-first victim keeps behavior repeatable.
            /// - Parameters:
            ///   - key: Standardized path to record.
            ///   - maxCapacity: Bound matching the session-cap discipline.
            func insert(_ key: String, maxCapacity: Int) {
                lock.lock()
                defer { lock.unlock() }
                if paths.count >= maxCapacity, let victim = paths.sorted().first {
                    paths.remove(victim)
                }
                paths.insert(key)
            }
        }

        /// Paths already probed for migrations in this process.
        ///
        /// Probing `table_info` plus conditional `ALTER` on every open
        /// costs per-operation overhead; the cache keeps one probe per
        /// path while reads still tolerate a failed migration via
        /// fallback selects below. Immutable box keeps all mutation inside
        /// `withLock`-style methods with no isolation opt-out.
        private static let migratedPaths = MigrationPathCache()
        /// Bounds the migration cache so distinct database paths never grow
        /// memory without bound, matching the session-cap discipline.
        private static let maxMigratedPaths = 500

        /// Standardized cache key for a database path.
        ///
        /// Tilde expansion alone leaves `./db`, `db`, and symlinked forms
        /// as distinct keys; standardizing keeps one entry per file.
        /// - Parameter dbPath: Configured database path.
        /// - Returns: Absolute standardized path.
        private static func migrationCacheKey(_ dbPath: String) -> String {
            let expanded = (dbPath as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }

        /// Records a migrated path, evicting deterministically at capacity.
        ///
        /// Eviction only forces a future re-probe (idempotent `table_info`
        /// plus conditional `ALTER`), never a correctness loss. Runs inside
        /// the cache box so callers never hold a lock across blocking
        /// SQLite I/O.
        /// - Parameter key: Standardized path to record.
        private static func noteMigrated(_ key: String) {
            migratedPaths.insert(key, maxCapacity: maxMigratedPaths)
        }

        /// Opens (creating parent directories) and migrates the database.
        /// - Parameter dbPath: SQLite file path. `~` is expanded.
        /// - Returns: Open database handle. Caller must close it.
        private static func open(dbPath: String) throws -> OpaquePointer? {
            // Shared busy_timeout/WAL policy lives in `SQLiteHelpers.openHandle`.
            let handle = try SQLiteHelpers.openHandle(dbPath: dbPath, unavailable: ConversationManagerError.storeUnavailable)
            try SQLiteHelpers.exec(
                handle: handle,
                sql: """
                CREATE TABLE IF NOT EXISTS sessions(
                    id TEXT PRIMARY KEY,
                    title TEXT,
                    summary TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    source TEXT
                );
                CREATE TABLE IF NOT EXISTS messages(
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL,
                    role TEXT NOT NULL,
                    content TEXT NOT NULL,
                    tool_call_id TEXT,
                    is_error INTEGER,
                    created_at REAL NOT NULL,
                    FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE
                );
                CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id);
                """,
                failure: ConversationManagerError.persistenceFailed
            )
            let cacheKey = migrationCacheKey(dbPath)
            // Snapshot the migration cache without holding the lock across
            // blocking SQLite I/O, so concurrent opens never block on disk
            // work. A duplicate migration from a concurrent open is safe
            // because the probe plus conditional `ALTER` is idempotent.
            let needsMigration = !migratedPaths.contains(cacheKey)
            if needsMigration {
                // Best-effort migration for existing databases created without
                // title, source, or error-flag columns. Probes `table_info`
                // first so the expected present-column case never issues
                // `ALTER` (and never depends on matching the localized
                // SQLite message text); residual failures are reported by
                // SQLite error code and tolerated by fallback reads/writes
                // so one failed migration never fails every later read.
                // Column names map through a literal allowlist so no
                // interpolated identifier ever reaches SQLite.
                let existingSessions = columnNames(in: "sessions", handle: handle)
                for col in ["title", "source"] where !existingSessions.contains(col) {
                    let alterSQL: String
                    switch col {
                    case "title":
                        alterSQL = "ALTER TABLE sessions ADD COLUMN title TEXT;"
                    case "source":
                        alterSQL = "ALTER TABLE sessions ADD COLUMN source TEXT;"
                    default:
                        preconditionFailure("Unsupported sessions migration column")
                    }
                    do {
                        try SQLiteHelpers.exec(
                            handle: handle,
                            sql: alterSQL,
                            failure: ConversationManagerError.persistenceFailed
                        )
                    } catch {
                        let code = sqlite3_errcode(handle)
                        fputs("[WARN] SQLiteSessionStore: Migration failed for column '\(col)' (code \(code)): \(error)\n", stderr)
                    }
                }
                if !columnNames(in: "messages", handle: handle).contains("is_error") {
                    do {
                        try SQLiteHelpers.exec(
                            handle: handle,
                            sql: "ALTER TABLE messages ADD COLUMN is_error INTEGER;",
                            failure: ConversationManagerError.persistenceFailed
                        )
                    } catch {
                        let code = sqlite3_errcode(handle)
                        fputs("[WARN] SQLiteSessionStore: Migration failed for column 'is_error' (code \(code)): \(error)\n", stderr)
                    }
                }
                // Record through the lock-guarded box so only the cache
                // mutation is serialized while the probe and `ALTER` above
                // run unlocked.
                noteMigrated(cacheKey)
            }
            try SQLiteHelpers.exec(handle: handle, sql: "PRAGMA foreign_keys = ON;", failure: ConversationManagerError.persistenceFailed)
            return handle
        }

        /// Executes a multi-statement SQL string.
        /// - Parameters:
        ///   - handle: Open database handle.
        ///   - sql: SQL to execute.
        private static func exec(handle: OpaquePointer?, sql: String) throws {
            try SQLiteHelpers.exec(handle: handle, sql: sql, failure: ConversationManagerError.persistenceFailed)
        }

        /// Lists the declared column names of a table, lowercased.
        ///
        /// Probes `PRAGMA table_info` so migrations only alter tables that
        /// actually lack the column. The table name is allowlisted to the
        /// store's own tables so no caller-controlled identifier reaches
        /// SQLite; unknown names trap in debug and read as empty in release.
        /// - Parameters:
        ///   - table: Table to inspect (`sessions` or `messages`).
        ///   - handle: Open database handle.
        /// - Returns: Lowercased column names, empty when unreadable.
        private static func columnNames(in table: String, handle: OpaquePointer?) -> Set<String> {
            let pragmaSQL: String
            switch table {
            case "sessions":
                pragmaSQL = "PRAGMA table_info(sessions);"
            case "messages":
                pragmaSQL = "PRAGMA table_info(messages);"
            default:
                preconditionFailure("Unsupported table for column lookup")
            }
            var names: Set<String> = []
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, pragmaSQL, -1, &statement, nil) == SQLITE_OK else {
                return names
            }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                if let name = sqlite3_column_text(statement, 1).map({ String(cString: $0) }) {
                    names.insert(name.lowercased())
                }
            }
            return names
        }

        /// Binds optional text, mapping nil to NULL.
        /// - Parameters:
        ///   - statement: Prepared statement.
        ///   - index: One-based bind index.
        ///   - value: Text value, or nil for NULL.
        private static func bindText(_ statement: OpaquePointer?, index: Int32, value: String?) {
            SQLiteHelpers.bindText(statement, index: index, value: value)
        }

        /// Writes sessions, optionally preserving existing rows.
        /// - Parameters:
        ///   - sessions: Sessions to upsert.
        ///   - dbPath: SQLite file path.
        ///   - merge: When false, replaces the whole store atomically.
        static func write(sessions: [ConversationSession], dbPath: String, merge: Bool) throws {
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            try exec(handle: handle, sql: "BEGIN IMMEDIATE;")
            do {
                if !merge {
                    try exec(handle: handle, sql: "DELETE FROM messages; DELETE FROM sessions;")
                }
                for session in sessions {
                    try upsert(session: session, handle: handle)
                }
                try exec(handle: handle, sql: "COMMIT;")
            } catch {
                try? exec(handle: handle, sql: "ROLLBACK;")
                throw error
            }
        }

        /// Whether a failed `prepare` means a missing column from an older schema.
        ///
        /// Only the `no such column` shape falls back to the legacy statement;
        /// transient failures (`BUSY`, `NOMEM`, corrupt) must surface instead
        /// of silently dropping `title`/`source`/`is_error`.
        /// - Parameter handle: Open database handle.
        /// - Returns: True when the last error reports a missing column.
        private static func isMissingColumnError(handle: OpaquePointer?) -> Bool {
            guard sqlite3_errcode(handle) == SQLITE_ERROR else { return false }
            guard let message = sqlite3_errmsg(handle).map({ String(cString: $0).lowercased() }) else { return false }
            return message.contains("no such column")
        }

        /// Upserts one session and rewrites its messages.
        /// - Parameters:
        ///   - session: Session to store.
        ///   - handle: Open database handle.
        private static func upsert(session: ConversationSession, handle: OpaquePointer?) throws {
            var sessionStatement: OpaquePointer?
            let sessionSQL = "INSERT INTO sessions(id, title, summary, created_at, updated_at, source) VALUES(?, ?, ?, ?, ?, ?) "
                + "ON CONFLICT(id) DO UPDATE SET title=excluded.title, summary=excluded.summary, updated_at=excluded.updated_at, source=excluded.source;"
            let legacySessionSQL = "INSERT INTO sessions(id, summary, created_at, updated_at) VALUES(?, ?, ?, ?) "
                + "ON CONFLICT(id) DO UPDATE SET summary=excluded.summary, updated_at=excluded.updated_at;"
            let sessionPrepare = sqlite3_prepare_v2(handle, sessionSQL, -1, &sessionStatement, nil)
            let useLegacySession: Bool
            if sessionPrepare == SQLITE_OK {
                useLegacySession = false
            } else if isMissingColumnError(handle: handle) {
                useLegacySession = true
            } else {
                let code = sqlite3_errcode(handle)
                sqlite3_finalize(sessionStatement)
                sessionStatement = nil
                fputs(
                    "[ERROR] SQLiteSessionStore: session upsert prepare"
                        + " failed (code \(code)); not a missing column,"
                        + " failing instead of dropping title/source.\n",
                    stderr
                )
                throw ConversationManagerError.persistenceFailed("Could not prepare session upsert (code \(code))")
            }
            if useLegacySession {
                sqlite3_finalize(sessionStatement)
                sessionStatement = nil
                guard sqlite3_prepare_v2(handle, legacySessionSQL, -1, &sessionStatement, nil) == SQLITE_OK else {
                    throw ConversationManagerError.persistenceFailed("Could not prepare session upsert")
                }
                bindText(sessionStatement, index: 1, value: session.id.uuidString)
                bindText(sessionStatement, index: 2, value: session.summary)
                sqlite3_bind_double(sessionStatement, 3, session.createdAt.timeIntervalSince1970)
                sqlite3_bind_double(sessionStatement, 4, session.updatedAt.timeIntervalSince1970)
            } else {
                bindText(sessionStatement, index: 1, value: session.id.uuidString)
                bindText(sessionStatement, index: 2, value: session.title)
                bindText(sessionStatement, index: 3, value: session.summary)
                sqlite3_bind_double(sessionStatement, 4, session.createdAt.timeIntervalSince1970)
                sqlite3_bind_double(sessionStatement, 5, session.updatedAt.timeIntervalSince1970)
                bindText(sessionStatement, index: 6, value: session.source)
            }
            defer { sqlite3_finalize(sessionStatement) }
            guard sqlite3_step(sessionStatement) == SQLITE_DONE else {
                throw ConversationManagerError.persistenceFailed("Could not write session \(session.id)")
            }
            try rewriteMessages(for: session, handle: handle)
        }

        /// Rewrites all message rows for one session.
        ///
        /// Delete-then-insert keeps the stored order identical to the
        /// in-memory order without per-row diffing; the caller holds the
        /// surrounding transaction so a mid-rewrite failure rolls back
        /// the session row as well.
        /// - Parameters:
        ///   - session: Session whose messages replace stored rows.
        ///   - handle: Open database handle.
        private static func rewriteMessages(for session: ConversationSession, handle: OpaquePointer?) throws {
            var deleteStatement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "DELETE FROM messages WHERE session_id = ?;", -1, &deleteStatement, nil) == SQLITE_OK else {
                throw ConversationManagerError.persistenceFailed("Could not prepare message cleanup")
            }
            defer { sqlite3_finalize(deleteStatement) }
            bindText(deleteStatement, index: 1, value: session.id.uuidString)
            guard sqlite3_step(deleteStatement) == SQLITE_DONE else {
                throw ConversationManagerError.persistenceFailed("Could not rewrite messages for \(session.id)")
            }
            for message in session.messages {
                try insertMessage(message, sessionID: session.id, handle: handle)
            }
        }

        /// Inserts one message row, tolerating older schemas.
        ///
        /// Falls back to the minimal-column statement only when the failure
        /// reports a missing column, so transient failures still surface
        /// instead of silently dropping the error flag.
        /// - Parameters:
        ///   - message: Message to store.
        ///   - sessionID: Owning session identifier.
        ///   - handle: Open database handle.
        private static func insertMessage(_ message: Message, sessionID: UUID, handle: OpaquePointer?) throws {
            let messageSQL = "INSERT INTO messages(id, session_id, role, content, tool_call_id, is_error, created_at) VALUES(?, ?, ?, ?, ?, ?, ?);"
            let legacyMessageSQL = "INSERT INTO messages(id, session_id, role, content, tool_call_id, created_at) VALUES(?, ?, ?, ?, ?, ?);"
            var messageStatement: OpaquePointer?
            var useLegacyMessage = false
            if sqlite3_prepare_v2(handle, messageSQL, -1, &messageStatement, nil) != SQLITE_OK {
                if isMissingColumnError(handle: handle) {
                    sqlite3_finalize(messageStatement)
                    messageStatement = nil
                    guard sqlite3_prepare_v2(handle, legacyMessageSQL, -1, &messageStatement, nil) == SQLITE_OK else {
                        throw ConversationManagerError.persistenceFailed("Could not prepare message insert")
                    }
                    useLegacyMessage = true
                } else {
                    let code = sqlite3_errcode(handle)
                    sqlite3_finalize(messageStatement)
                    messageStatement = nil
                    fputs(
                        "[ERROR] SQLiteSessionStore: message insert"
                            + " prepare failed (code \(code)); not"
                            + " a missing column, failing instead"
                            + " of dropping is_error.\n",
                        stderr
                    )
                    throw ConversationManagerError.persistenceFailed("Could not prepare message insert (code \(code))")
                }
            }
            defer { sqlite3_finalize(messageStatement) }
            bindText(messageStatement, index: 1, value: message.id.uuidString)
            bindText(messageStatement, index: 2, value: sessionID.uuidString)
            bindText(messageStatement, index: 3, value: message.role.rawValue)
            bindText(messageStatement, index: 4, value: message.content)
            bindText(messageStatement, index: 5, value: message.toolCallID)
            if useLegacyMessage {
                sqlite3_bind_double(messageStatement, 6, message.createdAt.timeIntervalSince1970)
            } else {
                if let isError = message.isError {
                    sqlite3_bind_int64(messageStatement, 6, isError ? 1 : 0)
                } else {
                    sqlite3_bind_null(messageStatement, 6)
                }
                sqlite3_bind_double(messageStatement, 7, message.createdAt.timeIntervalSince1970)
            }
            guard sqlite3_step(messageStatement) == SQLITE_DONE else {
                throw ConversationManagerError.persistenceFailed("Could not write message \(message.id)")
            }
        }

        /// Reads all sessions with their messages in order.
        /// - Parameter dbPath: SQLite file path.
        /// - Returns: Stored sessions, empty when the file is missing.
        static func read(dbPath: String) throws -> [ConversationSession] {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return [] }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            let (loadedByID, order) = try SQLiteSessionReadSupport.loadAllSessions(handle: handle)
            var sessionsByID = loadedByID
            try SQLiteSessionReadSupport.appendAllMessages(handle: handle, sessionsByID: &sessionsByID)
            return order.compactMap { sessionsByID[$0] }
        }

        /// Reads a single session with its messages.
        /// - Parameters:
        ///   - sessionID: Session identifier.
        ///   - dbPath: SQLite file path.
        /// - Returns: Loaded session, or nil if missing.
        static func readSingle(sessionID: UUID, dbPath: String) throws -> ConversationSession? {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return nil }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            guard var session = try SQLiteSessionReadSupport.loadSingleSessionBase(
                handle: handle,
                sessionID: sessionID
            ) else {
                return nil
            }
            try SQLiteSessionReadSupport.appendSingleSessionMessages(handle: handle, session: &session)
            return session
        }

        /// Deletes one session and its messages. Missing rows are a no-op.
        /// - Parameters:
        ///   - sessionID: Session identifier.
        ///   - dbPath: SQLite file path.
        static func delete(sessionID: UUID, dbPath: String) throws {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "DELETE FROM sessions WHERE id = ?;", -1, &statement, nil) == SQLITE_OK else {
                throw ConversationManagerError.persistenceFailed("Could not prepare session delete")
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, index: 1, value: sessionID.uuidString)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw ConversationManagerError.persistenceFailed("Could not delete session \(sessionID)")
            }
        }

        /// Deletes all sessions and their messages. Missing files are a no-op.
        /// - Parameter dbPath: SQLite file path.
        static func deleteAll(dbPath: String) throws {
            let expanded = (dbPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return }
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            try exec(handle: handle, sql: "DELETE FROM messages; DELETE FROM sessions;")
        }
    }
#else
    /// JSON-file fallback used where the SQLite3 module is unavailable.
    ///
    /// Each session is stored as `<anchor>.sessions/<id>.json` so hosts
    /// without SQLite headers (e.g. Linux CI) persist identically.
    enum JSONSessionStore {
        /// Directory holding one JSON file per session.
        /// - Parameter dbPath: Configured database path used as anchor.
        /// - Returns: Sidecar directory URL.
        private static func directory(dbPath: String) -> URL {
            let expanded = (dbPath as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded + ".sessions", isDirectory: true)
        }

        /// Writes sessions as JSON files.
        /// - Parameters:
        ///   - sessions: Sessions to write.
        ///   - dbPath: Anchor path for the sidecar directory.
        ///   - merge: Ignored (files are always upserted); present for
        ///     API parity with the SQLite store.
        static func write(sessions: [ConversationSession], dbPath: String, merge _: Bool = false) throws {
            let directoryURL = directory(dbPath: dbPath)
            do {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .secondsSince1970
                for session in sessions {
                    let data = try encoder.encode(session)
                    try data.write(to: directoryURL.appendingPathComponent("\(session.id.uuidString).json"), options: .atomic)
                }
            } catch {
                throw ConversationManagerError.persistenceFailed("Could not write sessions: \(error.localizedDescription)")
            }
        }

        /// Reads all JSON session files.
        /// - Parameter dbPath: Anchor path for the sidecar directory.
        /// - Returns: Stored sessions, empty when the directory is missing.
        static func read(dbPath: String) throws -> [ConversationSession] {
            let directoryURL = directory(dbPath: dbPath)
            guard FileManager.default.fileExists(atPath: directoryURL.path) else { return [] }
            do {
                let files = try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .secondsSince1970
                return try files
                    .filter { $0.pathExtension == "json" }
                    .map { try decoder.decode(ConversationSession.self, from: Data(contentsOf: $0)) }
            } catch {
                throw ConversationManagerError.persistenceFailed("Could not read sessions: \(error.localizedDescription)")
            }
        }

        /// Reads a single JSON session file.
        /// - Parameters:
        ///   - sessionID: Session identifier.
        ///   - dbPath: Anchor path for the sidecar directory.
        /// - Returns: Loaded session, or nil when missing.
        static func readSingle(sessionID: UUID, dbPath: String) throws -> ConversationSession? {
            let fileURL = directory(dbPath: dbPath).appendingPathComponent("\(sessionID.uuidString).json")
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .secondsSince1970
                return try decoder.decode(ConversationSession.self, from: Data(contentsOf: fileURL))
            } catch {
                throw ConversationManagerError.persistenceFailed("Could not read session \(sessionID): \(error.localizedDescription)")
            }
        }

        /// Deletes one JSON session file. Missing files are a no-op.
        /// - Parameters:
        ///   - sessionID: Session identifier.
        ///   - dbPath: Anchor path for the sidecar directory.
        static func delete(sessionID: UUID, dbPath: String) throws {
            let fileURL = directory(dbPath: dbPath).appendingPathComponent("\(sessionID.uuidString).json")
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                throw ConversationManagerError.persistenceFailed("Could not delete session: \(error.localizedDescription)")
            }
        }

        /// Deletes all JSON session files. Missing directories are a no-op.
        /// - Parameter dbPath: Anchor path for the sidecar directory.
        static func deleteAll(dbPath: String) throws {
            let directoryURL = directory(dbPath: dbPath)
            guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
            do {
                let files = try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
                for file in files where file.pathExtension == "json" {
                    try FileManager.default.removeItem(at: file)
                }
            } catch {
                throw ConversationManagerError.persistenceFailed("Could not delete sessions: \(error.localizedDescription)")
            }
        }
    }
#endif
