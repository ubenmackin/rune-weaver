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
    /// Originating source of this session (e.g. "chat", "scheduler",
    /// "fanout_worker").
    public var source: String?
    /// Linked goal identifier, when this session works toward a tracked goal.
    public var goalID: UUID?
    /// Session that spawned this session, when one did (e.g. a fan-out worker nests under the
    /// session that invoked the swarm).
    public var parentSessionID: UUID?
    /// Whether this session is archived (e.g. quiet close on uneventful background jobs).
    public var isArchived: Bool

    /// Coding keys matching the persisted and wire shape. The goal link rides
    /// the `goalId` spelling so dashboard payloads read one key; the legacy
    /// `goalID` spelling still decodes so mixed-version sidecars never fail.
    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case messages
        case summary
        case createdAt
        case updatedAt
        case source
        case goalID = "goalId"
        case goalIDLegacy = "goalID"
        case parentSessionID
        case isArchived
    }

    /// Prefix for auto-generated titles so the fallback, the auto-title guard,
    /// and menu-bar presentation agree on one spelling instead of drifting.
    public static let fallbackTitlePrefix = "Session "
    /// Untitled title for one session, shared so every surface renders the
    /// same placeholder for a conversation without a stored title.
    public static func fallbackTitle(for id: UUID) -> String {
        "\(fallbackTitlePrefix)\(id.uuidString.prefix(8))"
    }

    /// Whether a rendered title is still the auto-generated placeholder rather
    /// than a stored or derived name, so callers can tell an untitled session
    /// from one the user or engine actually named.
    public static func isFallbackTitle(_ title: String) -> Bool {
        title.hasPrefix(fallbackTitlePrefix)
    }

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
        return Self.fallbackTitle(for: id)
    }

    /// Creates a session.
    public init(
        id: UUID = UUID(),
        title: String? = nil,
        messages: [Message] = [],
        summary: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        source: String? = nil,
        goalID: UUID? = nil,
        parentSessionID: UUID? = nil,
        isArchived: Bool = false
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.summary = summary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.source = source
        self.goalID = goalID
        self.parentSessionID = parentSessionID
        self.isArchived = isArchived
    }

    /// Decodes a session, defaulting a missing goal link to unlinked and a missing parent link to
    /// unparented so rows written before either link load instead of failing the whole history. -
    /// Parameter decoder: Source decoder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.messages = try container.decodeIfPresent([Message].self, forKey: .messages) ?? []
        self.summary = try container.decodeIfPresent(String.self, forKey: .summary)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.source = try container.decodeIfPresent(String.self, forKey: .source)
        self.goalID = try container.decodeIfPresent(UUID.self, forKey: .goalID)
            ?? container.decodeIfPresent(UUID.self, forKey: .goalIDLegacy)
        self.parentSessionID = try container.decodeIfPresent(UUID.self, forKey: .parentSessionID)
        self.isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    }

    /// Encodes a session, omitting absent links so older readers see no new
    /// keys and keep loading the row.
    /// - Parameter encoder: Destination encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(messages, forKey: .messages)
        try container.encodeIfPresent(summary, forKey: .summary)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encodeIfPresent(goalID, forKey: .goalID)
        try container.encodeIfPresent(parentSessionID, forKey: .parentSessionID)
        if isArchived {
            try container.encode(true, forKey: .isArchived)
        }
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
    /// Linked goal identifier, when this session works toward a tracked goal.
    /// Carried on the listing payload so the dashboard can resolve a
    /// session-to-goal chip without querying run history.
    public let goalID: UUID?
    /// Parent session identifier, when this session was spawned by another (e.g. a fan-out worker
    /// nesting under the session that invoked the swarm).
    public let parentSessionID: UUID?
    /// Whether this session is archived.
    public let isArchived: Bool

    /// Coding keys matching the wire shape, with the goal link on the shared
    /// `goalId` spelling plus a tolerant legacy fallback.
    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case messageCount
        case summary
        case createdAt
        case updatedAt
        case source
        case goalID = "goalId"
        case goalIDLegacy = "goalID"
        case parentSessionID
        case isArchived
    }

    public init(
        id: UUID,
        title: String,
        messageCount: Int,
        summary: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        source: String? = nil,
        goalID: UUID? = nil,
        parentSessionID: UUID? = nil,
        isArchived: Bool = false
    ) {
        self.id = id
        self.title = title
        self.messageCount = messageCount
        self.summary = summary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.source = source
        self.goalID = goalID
        self.parentSessionID = parentSessionID
        self.isArchived = isArchived
    }

    /// Decodes a summary, defaulting a missing goal link to unlinked and a missing parent link to
    /// unparented so payloads from engines that predate either link still parse.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.messageCount = try container.decode(Int.self, forKey: .messageCount)
        self.summary = try container.decodeIfPresent(String.self, forKey: .summary)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.source = try container.decodeIfPresent(String.self, forKey: .source)
        self.goalID = try container.decodeIfPresent(UUID.self, forKey: .goalID)
            ?? container.decodeIfPresent(UUID.self, forKey: .goalIDLegacy)
        self.parentSessionID = try container.decodeIfPresent(UUID.self, forKey: .parentSessionID)
        self.isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    }

    /// Encodes a summary, omitting absent links so older dashboards see no new
    /// keys.
    /// - Parameter encoder: Destination encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(messageCount, forKey: .messageCount)
        try container.encodeIfPresent(summary, forKey: .summary)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encodeIfPresent(goalID, forKey: .goalID)
        try container.encodeIfPresent(parentSessionID, forKey: .parentSessionID)
        if isArchived {
            try container.encode(true, forKey: .isArchived)
        }
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

    /// Synthetic tool result recorded when a restart strands a call without an outcome.
    /// Single-sourced here so conversation history and run-log persistence report
    /// the same interruption instead of drifting when one copy is edited.
    public static let interruptedToolResultContent = "Tool interrupted by application restart"
    /// Fallback run response recorded when a restart strands a run without output.
    /// Single-sourced here so the SQL bootstrap and the in-memory reconcile path
    /// agree on one restart notice.
    public static let restartedRunResponseMessage = "Process restarted while run was in progress"

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

    /// Creates a new empty session and tracks it. Warm-up debounces internally and never blocks, so
    /// creation returns instantly and can never fail on warm-up.
    @discardableResult
    public func createSession(goalID: UUID? = nil) async -> ConversationSession {
        let session = ConversationSession(goalID: goalID)
        sessions[session.id] = session
        AppleIntelligenceAssessor.shared.prewarm()
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

    /// Single merge point for title/source/goal/parent fills so the memory, disk-hit, and disk-miss
    /// paths converge instead of drifting when one path gains a fix.
    private func mergeTitleSource(
        into session: ConversationSession,
        title: String?,
        source: String?,
        goalID: UUID?,
        parentSessionID: UUID?,
        overwrite: Bool
    ) -> (session: ConversationSession, changed: Bool) {
        var merged = session
        var changed = false
        if let title, overwrite ? merged.title != title : merged.title == nil {
            merged.title = title
            changed = true
        }
        if let source, overwrite ? merged.source != source : merged.source == nil {
            merged.source = source
            changed = true
        }
        if let goalID, overwrite ? merged.goalID != goalID : merged.goalID == nil {
            merged.goalID = goalID
            changed = true
        }
        if let parentSessionID, overwrite ? merged.parentSessionID != parentSessionID : merged.parentSessionID == nil {
            merged.parentSessionID = parentSessionID
            changed = true
        }
        return (merged, changed)
    }

    /// Returns the session, creating it when missing.
    @discardableResult
    public func ensureSession(
        id: UUID,
        title: String? = nil,
        source: String? = nil,
        overwrite: Bool = false,
        goalID: UUID? = nil,
        parentSessionID: UUID? = nil
    ) async -> ConversationSession {
        if let existing = sessions[id] {
            let (merged, changed) = mergeTitleSource(
                into: existing,
                title: title,
                source: source,
                goalID: goalID,
                parentSessionID: parentSessionID,
                overwrite: overwrite
            )
            if changed {
                sessions[id] = merged
                // Persist title/source fills so in-memory updates survive
                // restart, matching the disk path below.
                await persist(merged)
            }
            return merged
        }
        if let diskSession = await readSingleMerged(id: id) {
            if let concurrent = sessions[id] {
                let (merged, changed) = mergeTitleSource(
                    into: concurrent,
                    title: title,
                    source: source,
                    goalID: goalID,
                    parentSessionID: parentSessionID,
                    overwrite: overwrite
                )
                if changed {
                    sessions[id] = merged
                    await persist(merged)
                }
                return merged
            }
            let (mergedDisk, diskChanged) = mergeTitleSource(
                into: diskSession,
                title: title,
                source: source,
                goalID: goalID,
                parentSessionID: parentSessionID,
                overwrite: overwrite
            )
            if diskChanged {
                sessions[id] = mergedDisk
                await persist(mergedDisk)
            }
            return mergedDisk
        }
        if let concurrent = sessions[id] {
            let (merged, changed) = mergeTitleSource(
                into: concurrent,
                title: title,
                source: source,
                goalID: goalID,
                parentSessionID: parentSessionID,
                overwrite: overwrite
            )
            if changed {
                sessions[id] = merged
                await persist(merged)
            }
            return merged
        }
        // Durable bound: memory eviction alone would let the next list or read rehydrate the same
        // persisted row, so the bound would never hold on disk.
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
        let session = ConversationSession(id: id, title: title, source: source, goalID: goalID, parentSessionID: parentSessionID)
        sessions[id] = session
        unpersistedIDs.insert(id)
        // Warm-up for newly created sessions only; the entry debounces
        // internally and never blocks, so creation never waits on the model.
        AppleIntelligenceAssessor.shared.prewarm()
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
                    source: session.source,
                    goalID: session.goalID,
                    parentSessionID: session.parentSessionID,
                    isArchived: session.isArchived
                )
            }
    }

    /// Sets the archived state of a session and persists the change. id: Session
    /// identifier.
    public func setSessionArchived(id: UUID, isArchived: Bool) async {
        var sessionToUpdate: ConversationSession? = sessions[id]
        if sessionToUpdate == nil {
            sessionToUpdate = await readSingleMerged(id: id)
        }
        guard var session = sessionToUpdate, session.isArchived != isArchived else { return }
        session.isArchived = isArchived
        session.updatedAt = Date()
        sessions[id] = session
        await persist(session)
    }

    /// Links a session to a goal, persisting the association. Passing nil unlinks the session.
    public func linkSession(_ sessionID: UUID, toGoal goalID: UUID?) async {
        var sessionToUpdate: ConversationSession? = sessions[sessionID]
        if sessionToUpdate == nil {
            sessionToUpdate = await readSingleMerged(id: sessionID)
        }
        guard var session = sessionToUpdate, session.goalID != goalID else { return }
        session.goalID = goalID
        session.updatedAt = Date()
        sessions[sessionID] = session
        await persist(session)
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

    /// Appends a message to a session, truncating when over budget. Returns the stored message so
    /// callers stamp from the persisted instant instead of a pre-persistence sample.
    @discardableResult
    public func append(_ message: Message, to sessionID: UUID) async -> Message {
        var session = await ensureSession(id: sessionID)
        // Copy through the message-owned helper so the stored row keeps every field
        // even as the shape grows; only the timestamp is quantized here.
        let stored = message.withCreatedAt(Self.persistedInstant(message.createdAt))
        session.messages.append(stored)
        let hasNoTitle = session.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        if message.role == .user, hasNoTitle {
            let auto = session.displayTitle
            // Shared placeholder check keeps the guard in sync with the
            // fallback spelling above instead of hardcoding a second copy.
            if !ConversationSession.isFallbackTitle(auto) {
                session.title = auto
            }
        }
        session.updatedAt = Date()
        truncateIfNeeded(messages: &session.messages, summary: &session.summary)
        sessions[session.id] = session
        await persist(session)
        return stored
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
}

// MARK: - History Editing & Rollback

extension ConversationManager {
    /// Builds the working history with the system prompt first, excluding temporary waiting-on-approval notices.
    /// Marker identity leads so wording edits cannot leak interim notes to the provider
    /// and recreate consecutive-assistant sequencing failures.
    public func workingHistory(for sessionID: UUID, systemPrompt: String?) async -> [Message] {
        let raw = await history(for: sessionID).withSystemPrompt(systemPrompt)
        return raw.filter { msg in
            !OrchestratorToolLoop.isWaitingOnApprovalMessage(msg)
        }
    }

    /// Removes temporary waiting-on-approval notices from a session's persistent history. Read-only
    /// lookup keeps unknown identifiers from materializing empty sessions when merely clearing
    /// notices.
    public func removeWaitingMessages(from sessionID: UUID) async {
        guard var session = await session(id: sessionID) else { return }
        let initialCount = session.messages.count
        session.messages.removeAll { msg in
            OrchestratorToolLoop.isWaitingOnApprovalMessage(msg)
        }
        guard session.messages.count < initialCount else { return }
        session.updatedAt = Date()
        sessions[session.id] = session
        await persist(session)
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
    public func toolActionsByMessage(for sessionID: UUID) async -> [UUID: [ToolAction]] {
        guard let session = await readSingleMerged(id: sessionID) else { return [:] }
        let resultsByCallID = collectToolResults(from: session.messages)
        let perNote = collectAssistantNotes(from: session.messages, resultsByCallID: resultsByCallID)
        let winners = selectBestOwners(perNote: perNote)
        return rebuildGroupedActions(perNote: perNote, winners: winners)
    }
}

// MARK: - Persistence (SQLite with JSON fallback)

extension ConversationManager {
    /// Saves all tracked sessions to the configured store.
    public func saveAll() async throws {
        guard let path = episodesDBPath else { return }
        let snapshot = Array(sessions.values).map(Self.redactedForPersistence)
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
        await reconcileDanglingToolCalls()
    }

    /// Reconciles dangling tool call placeholders in a single session.
    /// Returns true if any messages were synthesized.
    @discardableResult
    private func reconcileDanglingToolCalls(session: inout ConversationSession) -> Bool {
        let resultsByCallID = collectToolResults(from: session.messages)
        var missingCallIDs: [String] = []
        for message in session.messages where message.role == .assistant {
            for line in NormalizedText.splitLines(message.content) {
                guard let parsed = ToolInput.parsePlaceholderLine(line),
                      let callID = nonEmptyCallID(parsed.callID) else { continue }
                if resultsByCallID[callID] == nil, !missingCallIDs.contains(callID) {
                    missingCallIDs.append(callID)
                }
            }
        }
        guard !missingCallIDs.isEmpty else { return false }
        let now = Date()
        for callID in missingCallIDs {
            let syntheticMsg = Message(
                role: .tool,
                content: Self.interruptedToolResultContent,
                toolCallID: callID,
                isError: true,
                errorKind: .executionError,
                createdAt: now
            )
            session.messages.append(syntheticMsg)
        }
        session.updatedAt = now
        return true
    }

    /// Reconciles dangling tool call placeholders from prior interrupted runs across all sessions.
    /// Appends synthetic interrupted tool results so reloads never leave orphaned
    /// pending tool badges in chat history.
    public func reconcileDanglingToolCalls() async {
        for (id, var session) in sessions {
            guard reconcileDanglingToolCalls(session: &session) else { continue }
            sessions[id] = session
            await persistUncancellable(session)
        }
    }

    /// Saves one session without throwing (used after every mutation).
    private func persist(_ session: ConversationSession) async {
        guard let path = episodesDBPath else { return }
        // Durable history keeps hash-only screenshots: the in-memory session
        // retains full pixels for the live turn while the written snapshot
        // strips data URLs so no recoverable pixels reach SQLite.
        let snapshot = Self.redactedForPersistence(session)
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
        let snapshot = Self.redactedForPersistence(session)
        await SQLiteSerialIO.runUncancellable {
            do {
                try SessionStoreIO.write(sessions: [snapshot], dbPath: path, merge: true)
            } catch {
                RuneWeaverLog.stores.error("ConversationManager: Failed to uncancellably persist session \(snapshot.id): \(error)")
            }
        }
        unpersistedIDs.remove(snapshot.id)
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

/// Indexes tool results by trimmed call identifier. Persisted error flags distinguish failures from
/// successes; rows written before the flag default to success.
private func collectToolResults(from messages: [Message]) -> [String: ToolResult] {
    var resultsByCallID: [String: ToolResult] = [:]
    for message in messages where message.role == .tool {
        guard let rawCallID = message.toolCallID, let callID = nonEmptyCallID(rawCallID) else { continue }
        resultsByCallID[callID] = ToolResult(
            toolCallID: callID,
            content: message.content,
            isError: message.isError ?? false,
            errorKind: message.errorKind,
            exitCode: message.exitCode
        )
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
extension ConversationManager {
    /// Summarizes a session's oldest turns on demand.
    @discardableResult
    public func summarize(sessionID: UUID, keeping: Int? = nil) async -> String? {
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
        // The rolling summary feeds every prompt's budget and the persisted row, so it keeps the
        // same bound as eviction instead of growing without limit across repeated on-demand
        // summarizes.
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
        // Invariant: kept history (after any leading .system message) must never
        // start with orphan .tool messages whose assistant call was evicted.
        let preserveFirstSystem = kept.first?.role == .system
        let checkIndex = preserveFirstSystem ? 1 : 0
        while checkIndex < kept.count, kept[checkIndex].role == .tool {
            let orphan = kept.remove(at: checkIndex)
            evicted.append(orphan)
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
    public static let charactersPerToken: Double = 4.0

    /// Wire-format overhead per tool definition (function wrapper keys and
    /// framing around name, description, and schema) so the token estimate
    /// stays honest without a magic literal at the call site.
    public static let toolWireOverheadChars: Int = 50

    /// Estimates token count for a list of messages.
    public static func estimateTokens(in messages: [Message]) -> Int {
        let totalChars = messages.reduce(0) { $0 + $1.content.count }
        return Int(ceil(Double(totalChars) / charactersPerToken))
    }

    /// Estimates token count for registered tools based on their definitions and schemas.
    public static func estimateToolTokens(in tools: [any Tool]) -> Int {
        guard !tools.isEmpty else { return 0 }
        // Each tool definition on the wire includes formatting wrappers
        // plus name, description, and raw JSON schema.
        let totalChars = tools.reduce(0) { sum, tool in
            sum + tool.name.count + tool.description.count + tool.inputSchema.rawValue.count + Self.toolWireOverheadChars
        }
        return Int(ceil(Double(totalChars) / charactersPerToken))
    }

    /// Compacts conversation history when estimated tokens exceed the threshold of the model's context window.
    /// Phase 1: Truncates oversized tool results in older turns.
    /// Phase 2: Summarizes oldest turns if still over budget.
    @discardableResult
    public func compactHistoryIfNeeded(
        for sessionID: UUID,
        contextLength: Int,
        thresholdPercent: Int,
        reservedTokens: Int = 0
    ) async -> Bool {
        guard contextLength > 0, thresholdPercent > 0, var session = await readSingleMerged(id: sessionID) else { return false }
        let effectiveLength = max(100, contextLength - max(0, reservedTokens))
        let maxAllowedTokens = max(100, (effectiveLength * min(100, thresholdPercent)) / 100)

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
