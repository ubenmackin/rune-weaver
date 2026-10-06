// Rune Weaver Tools — Reminders indexer feeding the local document index.
//
// Purpose: single owner of reminders indexing over the live ReminderStore seam.
// Scope: reminder-to-document mapping, content-hash skip, completion-flip re-index,
// prune of vanished identifiers, plus the coordinator stage builder.
// Architectural role: mirrors the messages stage guard while field types stay owned
// by RemindersGateway.swift.

import CryptoKit
import Foundation
import RuneWeaverCore

// MARK: - Report

/// Outcome of one reminders indexing run.
public struct ReminderIndexReport: Sendable, Equatable {
    /// Live rows examined, including those later skipped.
    public var scanned = 0
    /// Documents written during the run.
    public var indexed = 0
    /// Rows skipped (blank title or unchanged content hash).
    public var skipped = 0
    /// Documents retired because their identifier vanished from the live fetch.
    public var pruned = 0
    /// Chunks written carrying an embedding.
    public var vectorsWritten = 0
    /// Non-fatal problems, without any reminder content.
    public var warnings: [String] = []
    /// Set when the run did not execute.
    public var skippedReason: String?

    /// Creates a run report.
    /// - Parameter skippedReason: Set when the run did not execute.
    public init(skippedReason: String? = nil) {
        self.skippedReason = skippedReason
    }

    /// Whether the indexer actually ran.
    public var didRun: Bool {
        skippedReason == nil
    }
}

// MARK: - Persisted state

/// Known live identifiers from the previous run, used to prune deleted reminders.
public struct RemindersIndexState: Sendable, Codable, Equatable {
    /// Identifiers seen on the previous live fetch.
    public var knownIDs: Set<String>

    /// Creates an index state.
    /// - Parameter knownIDs: Identifiers seen on the previous live fetch.
    public init(knownIDs: Set<String> = []) {
        self.knownIDs = knownIDs
    }
}

// MARK: - Indexer

/// Reads live reminders and persists one document per reminder row.
///
/// One document per live reminder: the external identifier is the reminder
/// identifier and the display name is the title. Completed rows stay indexed
/// while present; only identifiers absent from the live fetch are pruned.
public actor RemindersIndexer {
    /// Default location of the persisted known-identifier file.
    public static let defaultStatePath = "~/.runeweaver/index/reminders-state.json"

    /// Live reminder lists plus rows, read per call and never cached.
    private let store: any ReminderStore
    /// Durable retrieval store receiving documents and chunks.
    private let index: DocIndexStore
    /// Optional embeddings backend for vector-eligible reminders.
    private let embedder: (any EmbeddingsBackend)?
    /// Persisted known-identifier location.
    private let stateURL: URL
    /// Wall-clock seam for the indexed-at stamp.
    private let now: @Sendable () -> Date

    /// Creates a reminders indexer.
    /// - Parameters:
    ///   - store: Live reminder seam.
    ///   - index: Document store the run writes into.
    ///   - embedder: Optional embeddings backend for vector-eligible reminders.
    ///   - statePath: Persisted known-identifier file; `~` is expanded.
    ///   - now: Wall-clock seam for the indexed-at stamp.
    public init(
        store: any ReminderStore,
        index: DocIndexStore,
        embedder: (any EmbeddingsBackend)? = nil,
        statePath: String = RemindersIndexer.defaultStatePath,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.index = index
        self.embedder = embedder
        self.stateURL = URL(fileURLWithPath: (statePath as NSString).expandingTildeInPath)
        self.now = now
    }

    /// Runs one indexing pass over every live reminder row.
    /// - Parameter reporter: Sink for advisory progress; defaults to a no-op.
    /// - Returns: Counts describing the run.
    public func run(reporter: ToolProgressReporter = ToolContext.noProgress) async throws -> ReminderIndexReport {
        guard store.reminderAuthorizationStatus() == .authorized else {
            return ReminderIndexReport(
                skippedReason: "Reminders access was denied. Grant access in System Settings > Privacy & Security > Reminders."
            )
        }
        let (rows, calendars) = try await fetchLiveRows()
        let liveIDs = Set(rows.map(\.identifier))
        var report = ReminderIndexReport()
        let (previousIDs, stateWarning) = readKnownIDs()
        if let stateWarning {
            report.warnings.append(stateWarning)
        }
        let byCalendar = Dictionary(
            calendars.map { ($0.identifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let runID = UUID().uuidString
        let indexedAt = now()
        let prepared = try await collectPrepared(from: rows, byCalendar: byCalendar, indexedAt: indexedAt, report: &report)
        try await upsertPrepared(prepared, runID: runID, report: &report)
        try await pruneVanished(previousIDs: previousIDs, liveIDs: liveIDs, report: &report)
        do {
            try writeKnownIDs(liveIDs)
        } catch {
            report.warnings.append("Reminder index state could not be persisted: \(error.localizedDescription)")
        }
        await reporter(ToolProgress(
            message: "Indexing reminders: \(report.indexed) indexed, \(report.scanned) scanned",
            scanned: report.scanned,
            matched: report.indexed
        ))
        return report
    }

    /// Builds the reminders source stage over the shared document store.
    /// - Parameters:
    ///   - config: Index policy snapshot used only for boot-time selection.
    ///   - store: Document store the run writes into.
    ///   - reminderStore: Live reminder seam.
    ///   - embedder: Optional embeddings backend for vector-eligible reminders.
    /// - Returns: A reminders source stage.
    public static func makeRemindersStage(
        config: IndexConfig,
        store: DocIndexStore,
        reminderStore: any ReminderStore,
        embedder: (any EmbeddingsBackend)? = nil
    ) -> IndexClosureStage {
        IndexClosureStage(kind: .reminders, isEnabled: config.enabled && config.reminders) { policy, reporter, _ in
            guard policy.enabled, policy.reminders else {
                return IndexSourceRunReport(
                    kind: .reminders,
                    didRun: false,
                    skippedReason: "Reminders indexing is disabled in [index]."
                )
            }
            let indexer = RemindersIndexer(store: reminderStore, index: store, embedder: embedder)
            let report = try await indexer.run(reporter: reporter)
            return IndexSourceRunReport(
                kind: .reminders,
                scanned: report.scanned,
                indexed: report.indexed,
                vectorChunks: report.vectorsWritten,
                keywordChunks: max(report.indexed - report.vectorsWritten, 0),
                skipped: report.skipped,
                retired: report.pruned,
                didRun: report.didRun,
                skippedReason: report.skippedReason,
                warnings: report.warnings
            )
        }
    }

    /// Stable content hash gating re-indexing of an unchanged row.
    ///
    /// The completed flag participates so toggling done re-indexes that row.
    static func contentHash(
        title: String,
        notes: String?,
        dueISO: String?,
        calendarIdentifier: String,
        listName: String,
        isCompleted: Bool
    ) -> String {
        let joined = [
            title,
            NormalizedText.value(notes) ?? "",
            dueISO ?? "",
            calendarIdentifier,
            listName,
            isCompleted ? "true" : "false"
        ].joined(separator: "\n")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Single searchable chunk: completion status plus title plus notes.
    static func chunkText(title: String, notes: String?, isCompleted: Bool) -> String {
        var lines = ["Completed: \(isCompleted ? "true" : "false")", title]
        if let clean = NormalizedText.value(notes) {
            lines.append(clean)
        }
        return lines.joined(separator: "\n")
    }

    /// One reminder document awaiting embedding and upsert.
    private struct ReminderPending: Sendable {
        let document: IndexedDocument
        let chunkText: String
    }

    /// Fetches incomplete plus completed rows over every live reminder list.
    private func fetchLiveRows() async throws -> (rows: [EventKitReminder], calendars: [EventKitReminderCalendar]) {
        let calendars = try store.reminderCalendars()
        let incomplete = try await bridgedFetch(fetchCompleted: false, calendars: calendars)
        let completed = try await bridgedFetch(fetchCompleted: true, calendars: calendars)
        return (incomplete + completed, calendars)
    }

    /// Scans live rows into pending upserts, skipping unchanged content hashes.
    private func collectPrepared(
        from rows: [EventKitReminder],
        byCalendar: [String: EventKitReminderCalendar],
        indexedAt: Date,
        report: inout ReminderIndexReport
    ) async throws -> [ReminderPending] {
        var prepared: [ReminderPending] = []
        for row in rows {
            try Task.checkCancellation()
            report.scanned += 1
            guard let title = NormalizedText.value(row.title), !title.contains("\0") else {
                report.skipped += 1
                continue
            }
            if row.identifier.contains("\0") || (row.notes?.contains("\0") ?? false) {
                report.skipped += 1
                continue
            }
            let calendar = byCalendar[row.calendarIdentifier]
            let listName = calendar?.title ?? row.calendarIdentifier
            let sourceTitle = calendar?.sourceTitle ?? ""
            let dueISO = row.dueDate.map(TemporalFilter.isoString(from:))
            let contentHash = Self.contentHash(
                title: title,
                notes: row.notes,
                dueISO: dueISO,
                calendarIdentifier: row.calendarIdentifier,
                listName: listName,
                isCompleted: row.isCompleted
            )
            if let existing = try await index.document(source: .reminders, externalID: row.identifier),
               existing.contentHash == contentHash
            {
                report.skipped += 1
                continue
            }
            let chunkText = Self.chunkText(title: title, notes: row.notes, isCompleted: row.isCompleted)
            var metadata: [String: String] = [
                "listName": listName,
                "sourceTitle": sourceTitle,
                "completed": row.isCompleted ? "true" : "false"
            ]
            if let dueISO {
                metadata["dueISO"] = dueISO
            }
            let document = IndexedDocument(
                source: .reminders,
                externalID: row.identifier,
                displayName: title,
                messageID: row.identifier,
                mtime: row.dueDate,
                contentHash: contentHash,
                mime: "text/plain",
                extractStatus: .extracted,
                indexedAt: indexedAt,
                metadata: metadata
            )
            prepared.append(ReminderPending(document: document, chunkText: chunkText))
        }
        return prepared
    }

    /// Embeds and upserts pending reminder documents.
    private func upsertPrepared(_ prepared: [ReminderPending], runID: String, report: inout ReminderIndexReport) async throws {
        var embeddings: [[Float]] = []
        if let embedder, !prepared.isEmpty {
            do {
                embeddings = try await embedder.embed(prepared.map(\.chunkText))
            } catch let cancelled as CancellationError {
                throw cancelled
            } catch {
                embeddings = []
            }
        }
        for (offset, item) in prepared.enumerated() {
            try Task.checkCancellation()
            let vector = offset < embeddings.count ? embeddings[offset] : []
            let chunk = IndexedChunk(
                documentID: item.document.id,
                ordinal: 0,
                text: item.chunkText,
                embedding: vector
            )
            _ = try await index.upsertDocumentWithChunks(document: item.document, chunks: [chunk], runID: runID)
            report.indexed += 1
            if !vector.isEmpty {
                report.vectorsWritten += 1
            }
        }
    }

    /// Deletes stored reminder documents absent from the live fetch.
    private func pruneVanished(previousIDs: Set<String>, liveIDs: Set<String>, report: inout ReminderIndexReport) async throws {
        for vanished in previousIDs.subtracting(liveIDs) {
            try Task.checkCancellation()
            do {
                if let stored = try await index.document(source: .reminders, externalID: vanished) {
                    _ = try await index.deleteDocument(id: stored.id)
                    report.pruned += 1
                }
            } catch let cancelled as CancellationError {
                throw cancelled
            } catch {
                report.warnings.append("Skipped pruning reminder '\(vanished)': \(error.localizedDescription)")
            }
        }
    }

    /// Sole bridge for the callback fetch; the first completion wins.
    private func bridgedFetch(
        fetchCompleted: Bool,
        calendars: [EventKitReminderCalendar]
    ) async throws -> [EventKitReminder] {
        let predicate = EventKitReminderPredicate(
            fetchCompleted: fetchCompleted,
            start: nil,
            end: nil,
            calendars: calendars
        )
        return try await withCheckedThrowingContinuation { continuation in
            let guardBox = ReminderFetchGuard()
            store.fetchReminders(matching: predicate) { reminders in
                guard let reminders else {
                    guardBox.resumeOnce(
                        .failure(ReminderToolError.storeUnavailable("Reminder fetch returned no data.")),
                        continuation: continuation
                    )
                    return
                }
                guardBox.resumeOnce(.success(reminders), continuation: continuation)
            }
        }
    }

    /// Reads persisted known identifiers, defaulting to empty when absent.
    ///
    /// A corrupt file warns once and rebuilds from the live fetch; pruning is
    /// skipped for that pass rather than deleting against an empty set.
    private func readKnownIDs() -> (Set<String>, String?) {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return ([], nil)
        }
        do {
            let data = try Data(contentsOf: stateURL)
            let state = try JSONDecoder().decode(RemindersIndexState.self, from: data)
            return (state.knownIDs, nil)
        } catch {
            RuneWeaverLog.stores.warning("RemindersIndexer: failed to decode state from '\(stateURL.path)': \(error.localizedDescription)")
            return ([], "Reminder index state was unreadable; rebuilt from the live fetch.")
        }
    }

    /// Persists known identifiers atomically.
    private func writeKnownIDs(_ ids: Set<String>) throws {
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(RemindersIndexState(knownIDs: ids))
        try data.write(to: stateURL, options: .atomic)
    }
}

/// Exactly-once guard for the reminder callback bridge.
///
/// A store that calls its completion twice would trap on the second resume,
/// so the fetch and the timeout-free bridge race through this guard.
private final class ReminderFetchGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resumeOnce(
        _ result: Result<[EventKitReminder], Error>,
        continuation: CheckedContinuation<[EventKitReminder], Error>
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        switch result {
        case let .success(value):
            continuation.resume(returning: value)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}
