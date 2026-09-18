// Rune Weaver Core — Conversation sessions, history, and SQLite persistence.

import Foundation
import os

#if canImport(SQLite3)
    import SQLite3
#endif

/// A single conversation session owned by the manager.
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
            // Shared split treats a trailing newline as a terminator, so titles match history line boundaries.
            let firstLine = NormalizedText.splitLines(firstUser.content).first ?? firstUser.content
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
public typealias SessionSummarizer = @Sendable ([Message]) -> String

/// Default extractive summarizer used when no LLM is wired in.
public func defaultSessionSummarizer(_ messages: [Message]) -> String {
    let parts = messages.map { message -> String in
        // Shared split keeps summarizer first lines on the same boundaries as history coverage.
        let firstLine = NormalizedText.splitLines(message.content).first ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return "[\(message.role.rawValue)] \(trimmed)"
    }
    // Delegated to extractiveSummary(lines:truncationLength:) defined in EpisodeStoreTypes.swift.
    return extractiveSummary(lines: parts, truncationLength: 2000)
}

/// Manages multiple concurrent conversation sessions.
public actor ConversationManager {
    /// Maximum messages kept in memory per session before truncation.
    public let maxMessages: Int
    /// Summarizer applied to messages evicted during truncation.
    public let summarizer: SessionSummarizer
    /// Filesystem path of the SQLite database (or JSON sidecar anchor).
    public let episodesDBPath: String?

    /// Active sessions indexed by identifier.
    private var sessions: [UUID: ConversationSession] = [:]
    /// Sessions created in-memory that have not yet been confirmed on disk.
    private var unpersistedIDs: Set<UUID> = []

    /// Default context window before summarization kicks in.
    public static let defaultMaxMessages = 100

    /// Maximum character length kept in the rolling summary before oldest text is truncated.
    public static let maxSummaryLength: Int = 2000

    /// Default rolling summary character cap.
    public static let defaultMaxSummaryLength = 2000

    /// Bound on active in-memory sessions so memory never grows unbounded.
    public static let maxSessions: Int = 500

    /// Maximum title characters stored per session, bounding the sessions table and sidebar display.
    public static let maxTitleLength: Int = 200

    /// Creates a conversation manager.
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
    @discardableResult
    public func createSession() async -> ConversationSession {
        let session = ConversationSession()
        sessions[session.id] = session
        await persist(session)
        return session
    }

    /// Reads one session from disk and merges it with memory by recency.
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
                        // in-memory session.
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
                RuneWeaverLog.stores.warning("ConversationManager: Failed reading session \(id) from disk: \(error.localizedDescription)")
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
        // Durable bound: memory eviction alone would let the next list or read rehydrate
        // the same persisted row, so the bound would never hold on disk. The evicted
        // identifier is captured first so the in-memory insert stays suspension-free;
        // the persisted row is deleted afterwards, keeping both views converged.
        // Missing rows (never-persisted ghosts) stay a no-op.
        var evictedID: UUID?
        if sessions.count >= Self.maxSessions {
            if let oldest = sessions.values.min(by: { $0.updatedAt < $1.updatedAt }) {
                sessions.removeValue(forKey: oldest.id)
                unpersistedIDs.remove(oldest.id)
                evictedID = oldest.id
            }
        }
        // New sessions defer disk persistence until the first message append so empty/ghost
        // sessions are not written to episodes.db if a turn aborts before generation. Tracked in
        // unpersistedIDs to guard against reconciliation eviction in listSessions.
        let session = ConversationSession(id: id, title: title, source: source)
        sessions[id] = session
        unpersistedIDs.insert(id)
        if let evictedID {
            await deletePersistedSessionUncancellable(id: evictedID)
        }
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
                // Drop memory entries deleted by another process, but keep identifiers never
                // confirmed on disk: new sessions without an immediate persist and appends whose
                // persist has not drained must survive a concurrent list.
                let diskIDs = Set(diskSessions.map(\.id))
                for id in Array(sessions.keys) where !diskIDs.contains(id) && !unpersistedIDs.contains(id) {
                    sessions.removeValue(forKey: id)
                }
            } catch {
                RuneWeaverLog.stores.warning("ConversationManager: Failed reading sessions from disk: \(error.localizedDescription)")
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
    public func removeSession(id: UUID) async {
        sessions.removeValue(forKey: id)
        unpersistedIDs.remove(id)
        await deletePersistedSessionUncancellable(id: id)
    }

    /// Removes all sessions from memory and the persisted store.
    public func removeAllSessions() async {
        sessions.removeAll()
        unpersistedIDs.removeAll()
        guard let path = episodesDBPath else { return }
        await SQLiteSerialIO.runUncancellable {
            do {
                try SessionStoreIO.deleteAll(dbPath: path)
            } catch {
                RuneWeaverLog.stores.error("ConversationManager: Failed to delete all sessions from \(path): \(error)")
            }
        }
    }

    // MARK: - History

    /// Appends a message to a session, truncating when over budget.
    /// Returns the stored message so callers stamp from the persisted instant instead of a
    /// pre-persistence sample. The timestamp is quantized to whole milliseconds so the
    /// in-memory instant survives SQLite REAL plus JSON Double reloads without
    /// sub-millisecond drift, keeping live completion stamps and history reloads in agreement.
    @discardableResult
    public func append(_ message: Message, to sessionID: UUID) async -> Message {
        var session = await ensureSession(id: sessionID)
        // Copy through the message-owned helper so the stored row keeps every field
        // even as the shape grows; only the timestamp is quantized here.
        let stored = message.withCreatedAt(Self.persistedInstant(message.createdAt))
        session.messages.append(stored)
        session.updatedAt = Date()
        truncateIfNeeded(messages: &session.messages, summary: &session.summary)
        sessions[session.id] = session
        await persist(session)
        return stored
    }

    /// Quantizes a timestamp to whole-millisecond precision.
    /// Whole milliseconds survive the persisted Double round-trip exactly while finer
    /// fractions drift, so flooring here keeps the stored instant identical on both
    /// sides of persistence without disturbing chronological order (ties break by row order).
    private static func persistedInstant(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded(.down) / 1000)
    }

    /// Returns context-ready history for a session.
    public func history(for sessionID: UUID) async -> [Message] {
        guard let session = await readSingleMerged(id: sessionID) else { return [] }
        guard let summary = session.summary, !summary.isEmpty else {
            return session.messages
        }
        let summaryMessage = Message(role: .system, content: "\(Message.rollingSummaryPrefix) \(summary)")
        return [summaryMessage] + session.messages
    }

    /// Raw message count for a session.
    public func messageCount(for sessionID: UUID) async -> Int {
        await readSingleMerged(id: sessionID)?.messages.count ?? 0
    }

    /// Builds the working history with the system prompt first.
    public func workingHistory(for sessionID: UUID, systemPrompt: String?) async -> [Message] {
        await history(for: sessionID).withSystemPrompt(systemPrompt)
    }

    /// Bulk-replaces history for session resume with truncation.
    public func setHistory(_ messages: [Message], for sessionID: UUID) async {
        var session = await ensureSession(id: sessionID)
        session.messages = messages
        session.updatedAt = Date()
        truncateIfNeeded(messages: &session.messages, summary: &session.summary)
        sessions[session.id] = session
        await persist(session)
    }

    /// Clears messages (and summary) for one session.
    public func clear(sessionID: UUID) async {
        guard var session = sessions[sessionID] else { return }
        session.messages.removeAll()
        session.summary = nil
        session.updatedAt = Date()
        sessions[sessionID] = session
        await persist(session)
    }

    /// Captures the raw pre-turn session state for cancellation rollback.
    public func rollbackSnapshot(for sessionID: UUID) async -> ConversationSession? {
        await readSingleMerged(id: sessionID)
    }

    /// Restores a rollback snapshot captured by `rollbackSnapshot(for:)`.
    public func restoreRollbackSnapshot(_ snapshot: ConversationSession) async {
        guard sessions[snapshot.id] != nil else { return }
        var restored = snapshot
        restored.updatedAt = Date()
        sessions[snapshot.id] = restored
        await persistUncancellable(restored)
    }

    /// Structured tool actions grouped by parent assistant message, oldest message first.
    /// Each placeholder-bearing assistant note marks one chronological round boundary, so the
    /// assigned round index increments per note in stored order. Reloads therefore interleave
    /// identically to live turns even for payloads written before round tracking.
    public func toolActionsByMessage(for sessionID: UUID) async -> [UUID: [ToolAction]] {
        guard let session = await readSingleMerged(id: sessionID) else { return [:] }
        let resultsByCallID = collectToolResults(from: session.messages)
        let perNote = collectAssistantNotes(from: session.messages, resultsByCallID: resultsByCallID)
        let winners = selectBestOwners(perNote: perNote)
        return rebuildGroupedActions(perNote: perNote, winners: winners)
    }

    // MARK: - Persistence (SQLite with JSON fallback)

    /// Saves all tracked sessions to the configured store.
    public func saveAll() async throws {
        guard let path = episodesDBPath else { return }
        let snapshot = Array(sessions.values)
        try await SQLiteSerialIO.run {
            try SessionStoreIO.write(sessions: snapshot, dbPath: path)
        }
    }

    /// Loads sessions from the configured store, replacing memory.
    public func loadAll() async throws {
        guard let path = episodesDBPath else { return }
        let loaded = try await SQLiteSerialIO.run {
            try SessionStoreIO.read(dbPath: path)
        }
        sessions = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        unpersistedIDs.removeAll()
    }

    /// Saves one session without throwing (used after every mutation).
    private func persist(_ session: ConversationSession) async {
        guard let path = episodesDBPath else { return }
        let snapshot = session
        do {
            try await SQLiteSerialIO.run {
                try SessionStoreIO.write(sessions: [snapshot], dbPath: path, merge: true)
            }
            unpersistedIDs.remove(snapshot.id)
        } catch {
            RuneWeaverLog.stores.warning("ConversationManager: Failed to persist session \(snapshot.id): \(error)")
            // Best-effort only; the identifier stays unpersisted so a
            // concurrent list never mistakes it for a cross-process delete.
        }
    }

    /// Saves one session without observing cancellation.
    private func persistUncancellable(_ session: ConversationSession) async {
        guard let path = episodesDBPath else { return }
        let snapshot = session
        await SQLiteSerialIO.runUncancellable {
            do {
                try SessionStoreIO.write(sessions: [snapshot], dbPath: path, merge: true)
            } catch {
                RuneWeaverLog.stores.error("ConversationManager: Failed to uncancellably persist session \(snapshot.id): \(error)")
            }
        }
        unpersistedIDs.remove(snapshot.id)
    }

    /// Deletes one persisted session without observing cancellation.
    private func deletePersistedSessionUncancellable(id: UUID) async {
        guard let path = episodesDBPath else { return }
        await SQLiteSerialIO.runUncancellable {
            do {
                try SessionStoreIO.delete(sessionID: id, dbPath: path)
            } catch {
                RuneWeaverLog.stores.error("ConversationManager: Failed to uncancellably delete session \(id): \(error)")
            }
        }
    }
}

// MARK: - Tool action history rebuild

/// One assistant note plus its parsed actions in stored order.
private typealias AssistantNoteActions = (id: UUID, actions: [ToolAction])

/// Winning record per call identifier plus the owning note.
/// A single owner keeps reloads interleaved identically to live turns.
private typealias ToolActionWinners = (bestByCallID: [String: ToolAction], ownerByCallID: [String: UUID])

/// Trims an identifier, returning nil when blank.
/// Blank identifiers never share one collapse bucket; each unidentified record stays
/// distinct so two blanks cannot overwrite each other.
private func nonEmptyCallID(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// Indexes tool results by trimmed call identifier.
/// Persisted error flags distinguish failures from successes; rows written before the
/// flag default to success.
private func collectToolResults(from messages: [Message]) -> [String: ToolResult] {
    var resultsByCallID: [String: ToolResult] = [:]
    for message in messages where message.role == .tool {
        guard let rawCallID = message.toolCallID, let callID = nonEmptyCallID(rawCallID) else { continue }
        resultsByCallID[callID] = ToolResult(toolCallID: callID, content: message.content, isError: message.isError ?? false)
    }
    return resultsByCallID
}

/// Parses one assistant note into actions with per-note deduplication.
/// The same identifier twice in one note is the narration plus its persisted twin,
/// so the first occurrence wins and the repeat collapses away.
private func assistantNoteActions(for message: Message, roundIndex: Int, resultsByCallID: [String: ToolResult]) -> [ToolAction] {
    var seenInNote = Set<String>()
    var actions: [ToolAction] = []
    // Shared split treats a trailing newline as a terminator rather than an
    // extra blank, so history coverage and TOML parsing share line boundaries.
    for line in NormalizedText.splitLines(message.content) {
        guard let parsed = ToolInput.parsePlaceholderLine(line) else { continue }
        guard let callID = nonEmptyCallID(parsed.callID) else {
            actions.append(ToolAction(
                toolName: parsed.toolName,
                callID: parsed.callID,
                argumentsJSON: parsed.argumentsJSON,
                result: nil,
                roundIndex: roundIndex
            ))
            continue
        }
        guard seenInNote.insert(callID).inserted else { continue }
        actions.append(ToolAction(
            toolName: parsed.toolName,
            callID: callID,
            argumentsJSON: parsed.argumentsJSON,
            result: resultsByCallID[callID],
            roundIndex: roundIndex
        ))
    }
    return actions
}

/// Collects per-note actions oldest-first, tagging round boundaries.
/// Round boundaries persist as one note per LLM round in stored order, so only notes
/// bearing placeholders advance the round and reloads interleave like live turns.
private func collectAssistantNotes(from messages: [Message], resultsByCallID: [String: ToolResult]) -> [AssistantNoteActions] {
    var perNote: [AssistantNoteActions] = []
    var roundIndex = 0
    for message in messages where message.role == .assistant {
        let actions = assistantNoteActions(for: message, roundIndex: roundIndex, resultsByCallID: resultsByCallID)
        guard !actions.isEmpty else { continue }
        perNote.append((id: message.id, actions: actions))
        roundIndex += 1
    }
    return perNote
}

/// Selects the winning record per identifier with a single owning note.
/// A narrated line plus its persisted twin share one identifier, so the
/// execution-backed record wins over a pending ghost and the earliest wins ties
/// to hold chronological order.
private func selectBestOwners(perNote: [AssistantNoteActions]) -> ToolActionWinners {
    var bestByCallID: [String: ToolAction] = [:]
    var ownerByCallID: [String: UUID] = [:]
    for entry in perNote {
        for action in entry.actions {
            guard let key = nonEmptyCallID(action.callID) else { continue }
            if let existing = bestByCallID[key] {
                if action.result != nil, existing.result == nil {
                    bestByCallID[key] = action
                    ownerByCallID[key] = entry.id
                }
                continue
            }
            bestByCallID[key] = action
            ownerByCallID[key] = entry.id
        }
    }
    return (bestByCallID, ownerByCallID)
}

/// Rebuilds grouped actions in stored order from the winning records.
/// The surviving record is the execution-backed best — never the local pending ghost —
/// and blanks skip the owner map to stay with their owning note.
private func rebuildGroupedActions(perNote: [AssistantNoteActions], winners: ToolActionWinners) -> [UUID: [ToolAction]] {
    var grouped: [UUID: [ToolAction]] = [:]
    for entry in perNote {
        var kept: [ToolAction] = []
        for action in entry.actions {
            guard let key = nonEmptyCallID(action.callID) else {
                kept.append(action)
                continue
            }
            guard winners.ownerByCallID[key] == entry.id, let best = winners.bestByCallID[key] else { continue }
            kept.append(best)
        }
        if !kept.isEmpty {
            grouped[entry.id] = kept
        }
    }
    return grouped
}

// MARK: - ConversationManager truncation

/// Holds the history-eviction helper so the main actor body stays within the
/// length budget while sharing file-private state.
public extension ConversationManager {
    /// Summarizes a session's oldest turns on demand.
    @discardableResult
    func summarize(sessionID: UUID, keeping: Int? = nil) async -> String? {
        guard var session = sessions[sessionID] else { return nil }
        let keep = max(1, keeping ?? maxMessages)
        guard session.messages.count > keep else { return session.summary }

        let hasSystemPrompt = session.messages.first?.role == .system
        let systemPrompt = hasSystemPrompt ? session.messages.first : nil
        let startIndex = hasSystemPrompt ? 1 : 0
        let dropCount = session.messages.count - keep

        let evicted = Array(session.messages[startIndex ..< (startIndex + dropCount)])
        let summary = summarizer(evicted)

        let joinedSummary = [session.summary, summary]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: "\n")
        // The rolling summary feeds every prompt's budget and the persisted
        // row, so it keeps the same bound as eviction instead of growing
        // without limit across repeated on-demand summarizes. The leading
        // ellipsis marks truncation, so it occupies one slot of the budget
        // and the retained tail keeps the total within the bound.
        session.summary = if joinedSummary.count > Self.maxSummaryLength {
            "…" + String(joinedSummary.suffix(Self.maxSummaryLength - 1))
        } else {
            joinedSummary
        }

        var kept = Array(session.messages.suffix(keep - (hasSystemPrompt ? 1 : 0)))
        if let systemPrompt {
            kept.insert(systemPrompt, at: 0)
        }
        session.messages = kept

        session.updatedAt = Date()
        sessions[sessionID] = session
        await persist(session)
        return session.summary
    }

    /// Evicts oldest non-system turns when over `maxMessages`.
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
            // Invariant: never evict the leading system prompt (index 0 if .system)
            // so developer/system instructions remain preserved in context.
            let preserveFirstSystem = kept.first?.role == .system
            let startIndex = preserveFirstSystem ? 1 : 0
            let evictCount = min(extra, max(0, kept.count - startIndex))
            if evictCount > 0 {
                evicted.append(contentsOf: kept[startIndex ..< (startIndex + evictCount)])
                kept.removeSubrange(startIndex ..< (startIndex + evictCount))
            }
        }
        guard !evicted.isEmpty else { return }
        let chunk = summarizer(evicted)
        let combinedSummary = if let existing = summary, !existing.isEmpty {
            existing + "\n" + chunk
        } else {
            chunk
        }
        summary = if combinedSummary.count > Self.maxSummaryLength {
            // The ellipsis marks truncation, so it occupies one slot of the
            // budget and the retained tail keeps the total within the bound.
            "…" + String(combinedSummary.suffix(Self.maxSummaryLength - 1))
        } else {
            combinedSummary
        }
        messages = kept
    }

    /// Estimated character-to-token ratio (standard rule of thumb: ~4 characters per token).
    static let charactersPerToken: Double = 4.0

    /// Estimates token count for a list of messages.
    static func estimateTokens(in messages: [Message]) -> Int {
        let totalChars = messages.reduce(0) { $0 + $1.content.count }
        return Int(ceil(Double(totalChars) / charactersPerToken))
    }

    /// Compacts conversation history when estimated tokens exceed the threshold of the model's context window.
    /// Phase 1: Truncates oversized tool results in older turns.
    /// Phase 2: Summarizes oldest turns if still over budget.
    @discardableResult
    func compactHistoryIfNeeded(
        for sessionID: UUID,
        contextLength: Int,
        thresholdPercent: Int
    ) async -> Bool {
        guard contextLength > 0, thresholdPercent > 0 else { return false }
        guard var session = await readSingleMerged(id: sessionID) else { return false }
        let maxAllowedTokens = max(100, (contextLength * min(100, thresholdPercent)) / 100)

        func currentEstimatedTokens() -> Int {
            var msgs = session.messages
            if let sum = session.summary, !sum.isEmpty {
                msgs.append(Message(role: .system, content: sum))
            }
            return Self.estimateTokens(in: msgs)
        }

        var tokens = currentEstimatedTokens()
        guard tokens > maxAllowedTokens else { return false }

        // Phase 1: Prune oversized tool results (longer than 500 chars)
        // Keep the most recent 2 messages untouched so immediate context is preserved.
        let safeTrailingCount = 2
        let pruneCandidateEnd = max(0, session.messages.count - safeTrailingCount)
        var modified = false

        for index in 0 ..< pruneCandidateEnd {
            if session.messages[index].role == .tool, session.messages[index].content.count > 500 {
                let original = session.messages[index].content
                let truncatedSnippet = String(original.prefix(250)) + "\n... [Output truncated for context budget]"
                session.messages[index] = session.messages[index].withContent(truncatedSnippet)
                modified = true
            }
        }

        if modified {
            tokens = currentEstimatedTokens()
        }

        // Phase 2: If still over budget, summarize oldest turns
        if tokens > maxAllowedTokens {
            var evicted: [Message] = []
            var kept: [Message] = []
            let preserveFirstSystem = session.messages.first?.role == .system
            let startIndex = preserveFirstSystem ? 1 : 0
            let maxEvictIndex = max(startIndex, session.messages.count - safeTrailingCount)

            var messageIndex = 0
            while messageIndex < session.messages.count {
                if messageIndex >= startIndex, messageIndex < maxEvictIndex, tokens > maxAllowedTokens {
                    let candidate = session.messages[messageIndex]
                    evicted.append(candidate)
                    tokens -= Self.estimateTokens(in: [candidate])
                    messageIndex += 1
                } else {
                    kept.append(session.messages[messageIndex])
                    messageIndex += 1
                }
            }

            if !evicted.isEmpty {
                let chunk = summarizer(evicted)
                let combinedSummary = if let existing = session.summary, !existing.isEmpty {
                    existing + "\n" + chunk
                } else {
                    chunk
                }
                session.summary = if combinedSummary.count > Self.maxSummaryLength {
                    "…" + String(combinedSummary.suffix(Self.maxSummaryLength - 1))
                } else {
                    combinedSummary
                }
                session.messages = kept
                modified = true
            }
        }

        if modified {
            session.updatedAt = Date()
            sessions[session.id] = session
            await persist(session)
        }
        return modified
    }
}

// MARK: - Session store I/O

/// File and SQLite I/O for conversation sessions.
enum SessionStoreIO {
    /// Writes sessions to the store.
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
    static func readSingle(sessionID: UUID, dbPath: String) throws -> ConversationSession? {
        #if canImport(SQLite3)
            return try SQLiteSessionStore.readSingle(sessionID: sessionID, dbPath: dbPath)
        #else
            return try JSONSessionStore.readSingle(sessionID: sessionID, dbPath: dbPath)
        #endif
    }

    /// Deletes one session from the store. Missing rows are a no-op.
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
    enum SQLiteSessionStore {
        /// Lock-guarded record of paths already probed for migrations.
        private final class MigrationPathCache: Sendable {
            /// Probed standardized paths guarded by OSAllocatedUnfairLock.
            private let paths = OSAllocatedUnfairLock(initialState: Set<String>())

            /// Creates an empty cache.
            init() {}

            /// Checks whether a path was already probed.
            /// - Parameter key: Standardized path.
            /// - Returns: True when already recorded.
            func contains(_ key: String) -> Bool {
                paths.withLock { $0.contains(key) }
            }

            /// Records a path, evicting deterministically at capacity.
            func insert(_ key: String, maxCapacity: Int) {
                paths.withLock { set in
                    if set.count >= maxCapacity, let victim = set.sorted().first {
                        set.remove(victim)
                    }
                    set.insert(key)
                }
            }
        }

        /// Paths already probed for migrations in this process.
        private static let migratedPaths = MigrationPathCache()
        /// Bounds the migration cache so distinct database paths never grow
        /// memory without bound, matching the session-cap discipline.
        private static let maxMigratedPaths = 500

        /// Standardized cache key for a database path.
        private static func migrationCacheKey(_ dbPath: String) -> String {
            let expanded = (dbPath as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }

        /// Records a migrated path, evicting deterministically at capacity.
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
            // Snapshot the migration cache without holding the lock across blocking SQLite I/O, so
            // concurrent opens never block on disk work. A duplicate migration from a concurrent
            // open is safe because the probe plus conditional `ALTER` is idempotent.
            let needsMigration = !migratedPaths.contains(cacheKey)
            if needsMigration {
                // Best-effort migration for existing databases created without title, source, or
                // error-flag columns.
                let existingSessions = SQLiteHelpers.columnNames(handle: handle, table: .sessions)
                let sessionColumnsToAdd: [(name: String, sql: String)] = [
                    ("title", "ALTER TABLE sessions ADD COLUMN title TEXT;"),
                    ("source", "ALTER TABLE sessions ADD COLUMN source TEXT;")
                ]
                for (col, alterSQL) in sessionColumnsToAdd where !existingSessions.contains(col) {
                    do {
                        try SQLiteHelpers.exec(
                            handle: handle,
                            sql: alterSQL,
                            failure: ConversationManagerError.persistenceFailed
                        )
                    } catch {
                        let code = sqlite3_errcode(handle)
                        RuneWeaverLog.stores.warning("SQLiteSessionStore: Migration failed for column '\(col)' (code \(code)): \(error)")
                    }
                }
                if !SQLiteHelpers.columnNames(handle: handle, table: .messages).contains("is_error") {
                    do {
                        try SQLiteHelpers.exec(
                            handle: handle,
                            sql: "ALTER TABLE messages ADD COLUMN is_error INTEGER;",
                            failure: ConversationManagerError.persistenceFailed
                        )
                    } catch {
                        let code = sqlite3_errcode(handle)
                        RuneWeaverLog.stores.warning("SQLiteSessionStore: Migration failed for column 'is_error' (code \(code)): \(error)")
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
        private static func exec(handle: OpaquePointer?, sql: String) throws {
            try SQLiteHelpers.exec(handle: handle, sql: sql, failure: ConversationManagerError.persistenceFailed)
        }

        /// Binds optional text, mapping nil to NULL.
        private static func bindText(_ statement: OpaquePointer?, index: Int32, value: String?) {
            SQLiteHelpers.bindText(statement, index: index, value: value)
        }

        /// Writes sessions, optionally preserving existing rows.
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

        /// Upserts one session and rewrites its messages.
        private static func upsert(session: ConversationSession, handle: OpaquePointer?) throws {
            var sessionStatement: OpaquePointer?
            let sessionSQL = "INSERT INTO sessions(id, title, summary, created_at, updated_at, source) VALUES(?, ?, ?, ?, ?, ?) "
                + "ON CONFLICT(id) DO UPDATE SET title=excluded.title, summary=excluded.summary, updated_at=excluded.updated_at, source=excluded.source;"
            guard sqlite3_prepare_v2(handle, sessionSQL, -1, &sessionStatement, nil) == SQLITE_OK else {
                let code = sqlite3_errcode(handle)
                throw ConversationManagerError.persistenceFailed("Could not prepare session upsert (code \(code))")
            }
            defer { sqlite3_finalize(sessionStatement) }
            bindText(sessionStatement, index: 1, value: session.id.uuidString)
            bindText(sessionStatement, index: 2, value: session.title)
            bindText(sessionStatement, index: 3, value: session.summary)
            sqlite3_bind_double(sessionStatement, 4, session.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(sessionStatement, 5, session.updatedAt.timeIntervalSince1970)
            bindText(sessionStatement, index: 6, value: session.source)
            guard sqlite3_step(sessionStatement) == SQLITE_DONE else {
                throw ConversationManagerError.persistenceFailed("Could not write session \(session.id)")
            }
            try rewriteMessages(for: session, handle: handle)
        }

        /// Rewrites all message rows for one session.
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

        /// Inserts one message row.
        private static func insertMessage(_ message: Message, sessionID: UUID, handle: OpaquePointer?) throws {
            let messageSQL = "INSERT INTO messages(id, session_id, role, content, tool_call_id, is_error, created_at) VALUES(?, ?, ?, ?, ?, ?, ?);"
            var messageStatement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, messageSQL, -1, &messageStatement, nil) == SQLITE_OK else {
                let code = sqlite3_errcode(handle)
                throw ConversationManagerError.persistenceFailed("Could not prepare message insert (code \(code))")
            }
            defer { sqlite3_finalize(messageStatement) }
            bindText(messageStatement, index: 1, value: message.id.uuidString)
            bindText(messageStatement, index: 2, value: sessionID.uuidString)
            bindText(messageStatement, index: 3, value: message.role.rawValue)
            bindText(messageStatement, index: 4, value: message.content)
            bindText(messageStatement, index: 5, value: message.toolCallID)
            if let isError = message.isError {
                sqlite3_bind_int64(messageStatement, 6, isError ? 1 : 0)
            } else {
                sqlite3_bind_null(messageStatement, 6)
            }
            sqlite3_bind_double(messageStatement, 7, message.createdAt.timeIntervalSince1970)
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
    enum JSONSessionStore {
        /// Directory holding one JSON file per session.
        /// - Parameter dbPath: Configured database path used as anchor.
        /// - Returns: Sidecar directory URL.
        private static func directory(dbPath: String) -> URL {
            let expanded = (dbPath as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded + ".sessions", isDirectory: true)
        }

        /// Writes sessions as JSON files.
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
