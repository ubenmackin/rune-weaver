// Rune Weaver Tools — Calendar indexer plus stage builder.
//
// Purpose: single owner of calendar indexing from live EventKit rows into the document index.
// Scope: occurrence expansion with per-series cap, hash-gated upserts, state-tracked pruning.
// Architectural role: owns calendar indexing while CalendarGateway owns persistence.

import CryptoKit
import Foundation
import RuneWeaverCore

// MARK: - Report

/// Outcome of one calendar indexing pass.
public struct CalendarIndexReport: Sendable, Equatable {
    /// Occurrences examined after the per-series cap.
    public var scanned: Int
    /// Documents written during the pass.
    public var indexed: Int
    /// Occurrences skipped as unchanged or untitled.
    public var skipped: Int
    /// Documents deleted as absent from the live fetch.
    public var pruned: Int
    /// Chunks written carrying an embedding.
    public var vectorsWritten: Int
    /// Non-fatal problems without content.
    public var warnings: [String]
    /// Whether the pass executed.
    public var didRun: Bool
    /// Set when the pass did not execute.
    public var skippedReason: String?

    /// Creates a calendar index report.
    public init(
        scanned: Int = 0,
        indexed: Int = 0,
        skipped: Int = 0,
        pruned: Int = 0,
        vectorsWritten: Int = 0,
        warnings: [String] = [],
        didRun: Bool = true,
        skippedReason: String? = nil
    ) {
        self.scanned = scanned
        self.indexed = indexed
        self.skipped = skipped
        self.pruned = pruned
        self.vectorsWritten = vectorsWritten
        self.warnings = warnings
        self.didRun = didRun
        self.skippedReason = skippedReason
    }
}

// MARK: - Persisted state

/// Known live identifiers from the previous run, used to prune deleted events.
public struct CalendarIndexState: Sendable, Codable, Equatable {
    /// Identifiers seen on the previous live fetch.
    public var knownIDs: Set<String>

    /// Creates an index state.
    /// - Parameter knownIDs: Identifiers seen on the previous live fetch.
    public init(knownIDs: Set<String> = []) {
        self.knownIDs = knownIDs
    }
}

// MARK: - Indexer

/// Indexes calendar event occurrences into the document index.
public actor CalendarIndexer {
    /// Default location of the persisted known-identifier file.
    public static let defaultStatePath = "~/.runeweaver/index/calendars-state.json"
    /// Default per-series occurrence cap.
    public static let defaultOccurrenceCap = 500
    /// Default fetch lookback in calendar years.
    public static let defaultLookbackYears = 10

    private let store: any CalendarStore
    private let index: DocIndexStore
    private let embedder: (any EmbeddingsBackend)?
    private let stateURL: URL
    private let occurrenceCap: Int
    private let now: @Sendable () -> Date

    /// Creates a calendar indexer.
    public init(
        store: any CalendarStore,
        index: DocIndexStore,
        embedder: (any EmbeddingsBackend)? = nil,
        statePath: String = CalendarIndexer.defaultStatePath,
        occurrenceCap: Int = CalendarIndexer.defaultOccurrenceCap,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.index = index
        self.embedder = embedder
        self.stateURL = URL(fileURLWithPath: (statePath as NSString).expandingTildeInPath)
        self.occurrenceCap = max(1, occurrenceCap)
        self.now = now
    }

    /// Runs one calendar indexing pass.
    public func run(reporter: ToolProgressReporter = ToolContext.noProgress) async throws -> CalendarIndexReport {
        guard store.authorizationStatus() == .authorized else {
            return CalendarIndexReport(
                didRun: false,
                skippedReason: "Calendar access was denied. Grant access in System Settings > Privacy & Security > Calendars."
            )
        }
        let nowDate = now()
        let (selected, calendarsByID) = try fetchSelectedEvents(nowDate: nowDate)
        let (previous, stateWarning) = readKnownIDs()
        let runID = UUID().uuidString
        var report = CalendarIndexReport()
        if let stateWarning {
            report.warnings.append(stateWarning)
        }
        var liveIDs = Set<String>()
        liveIDs.reserveCapacity(selected.count)
        let pendings = try await collectPendings(
            from: selected,
            calendarsByID: calendarsByID,
            nowDate: nowDate,
            liveIDs: &liveIDs,
            report: &report
        )
        try await upsertPendings(pendings, runID: runID, report: &report)
        try await pruneVanished(previous: previous, liveIDs: liveIDs, report: &report)
        do {
            try writeKnownIDs(liveIDs)
        } catch {
            report.warnings.append("calendar state not persisted")
        }
        await reporter(ToolProgress(
            message: "Indexing calendars: \(report.indexed) indexed, \(report.scanned) scanned",
            scanned: report.scanned,
            matched: report.indexed
        ))
        return report
    }

    /// Builds the calendars source stage over the shared document store.
    public static func makeCalendarStage(
        config: IndexConfig,
        store: DocIndexStore,
        calendarStore: any CalendarStore,
        embedder: (any EmbeddingsBackend)? = nil
    ) -> IndexClosureStage {
        IndexClosureStage(kind: .calendars, isEnabled: config.enabled && config.calendars) { policy, reporter, _ in
            guard policy.enabled, policy.calendars else {
                return IndexSourceRunReport(
                    kind: .calendars,
                    didRun: false,
                    skippedReason: "Calendar indexing is disabled in [index]."
                )
            }
            let indexer = CalendarIndexer(store: calendarStore, index: store, embedder: embedder)
            let report = try await indexer.run(reporter: reporter)
            return IndexSourceRunReport(
                kind: .calendars,
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
}

// MARK: - Helpers

extension CalendarIndexer {
    static func cappedOccurrences(_ events: [StoreEvent], cap: Int, end: Date) -> [StoreEvent] {
        var grouped: [String: [StoreEvent]] = [:]
        var ungrouped: [StoreEvent] = []
        for event in events {
            if let start = event.startDate, start > end {
                continue
            }
            guard let rawID = event.identifier?.trimmingCharacters(in: .whitespacesAndNewlines), !rawID.isEmpty else {
                ungrouped.append(event)
                continue
            }
            grouped[rawID, default: []].append(event)
        }
        var selected: [StoreEvent] = []
        selected.reserveCapacity(grouped.values.reduce(0) { $0 + min($1.count, cap) })
        for group in grouped.values {
            let sorted = group.sorted {
                switch ($0.startDate, $1.startDate) {
                case let (left?, right?):
                    left > right
                case (.some, nil):
                    true
                case (nil, .some):
                    false
                default:
                    false
                }
            }
            selected.append(contentsOf: sorted.prefix(cap))
        }
        selected.append(contentsOf: ungrouped)
        return selected
    }

    /// Hash inputs gating re-indexing of an unchanged occurrence.
    struct CalendarContentFingerprint: Sendable, Equatable {
        /// Event title.
        var title: String
        /// Event notes.
        var notes: String?
        /// Event location.
        var location: String?
        /// Start date in ISO format.
        var startISO: String?
        /// End date in ISO format.
        var endISO: String?
        /// Owning calendar identifier.
        var calendarID: String?
        /// Whether the event spans all day.
        var isAllDay: Bool
    }

    /// Stable content hash gating re-indexing of an unchanged occurrence.
    /// - Parameter fingerprint: Hash inputs for one occurrence.
    /// - Returns: Lowercase SHA-256 digest.
    static func contentHash(for fingerprint: CalendarContentFingerprint) -> String {
        let joined = [
            fingerprint.title,
            NormalizedText.value(fingerprint.notes) ?? "",
            NormalizedText.value(fingerprint.location) ?? "",
            fingerprint.startISO ?? "",
            fingerprint.endISO ?? "",
            fingerprint.calendarID ?? "",
            fingerprint.isAllDay ? "true" : "false"
        ].joined(separator: "\n")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func chunkText(title: String, notes: String?, location: String?) -> String {
        var parts: [String] = [title]
        if let clean = NormalizedText.value(notes) {
            parts.append(clean)
        }
        if let clean = NormalizedText.value(location) {
            parts.append(clean)
        }
        return parts.joined(separator: "\n\n")
    }

    /// One calendar document awaiting embedding and upsert.
    private struct CalendarPending: Sendable {
        let document: IndexedDocument
        let chunkText: String
    }

    /// Fetches live events and applies the per-series cap with calendar lookup.
    private func fetchSelectedEvents(nowDate: Date) throws -> (selected: [StoreEvent], calendarsByID: [String: StoreCalendar]) {
        let calendars = try store.calendars()
        let start = Calendar.current.date(byAdding: .year, value: -Self.defaultLookbackYears, to: nowDate)
            ?? nowDate.addingTimeInterval(TimeInterval(-Self.defaultLookbackYears * 365 * 86400))
        let end = Calendar.current.date(byAdding: .day, value: 365, to: nowDate) ?? nowDate.addingTimeInterval(365 * 86400)
        let predicate = store.predicateForEvents(start: start, end: end, calendars: calendars)
        let fetched = try store.events(matching: predicate)
        let selected = Self.cappedOccurrences(fetched, cap: occurrenceCap, end: end)
        let calendarsByID = Dictionary(calendars.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        return (selected, calendarsByID)
    }

    /// Scans selected occurrences into pending upserts, tracking live identifiers.
    private func collectPendings(
        from selected: [StoreEvent],
        calendarsByID: [String: StoreCalendar],
        nowDate: Date,
        liveIDs: inout Set<String>,
        report: inout CalendarIndexReport
    ) async throws -> [CalendarPending] {
        var pendings: [CalendarPending] = []
        pendings.reserveCapacity(selected.count)
        for event in selected {
            try Task.checkCancellation()
            guard let rawID = NormalizedText.value(event.identifier), !rawID.contains("\0") else {
                report.scanned += 1
                report.skipped += 1
                continue
            }
            let startISO = event.startDate.map { TemporalFilter.isoString(from: $0) }
            let endISO = event.endDate.map { TemporalFilter.isoString(from: $0) }
            let externalID = startISO.map { "\(rawID)@\($0)" } ?? rawID
            // Tracked before content skips so an untitled or NUL row still
            // counts as live and never prunes a previously indexed document.
            liveIDs.insert(externalID)
            guard let title = NormalizedText.value(event.title), !title.contains("\0") else {
                report.scanned += 1
                report.skipped += 1
                continue
            }
            if (event.notes?.contains("\0") ?? false) || (event.location?.contains("\0") ?? false) {
                report.scanned += 1
                report.skipped += 1
                continue
            }
            let calendar = event.calendarIdentifier.flatMap { calendarsByID[$0] }
            let fingerprint = CalendarContentFingerprint(
                title: title,
                notes: event.notes,
                location: event.location,
                startISO: startISO,
                endISO: endISO,
                calendarID: event.calendarIdentifier,
                isAllDay: event.isAllDay
            )
            let contentHash = Self.contentHash(for: fingerprint)
            report.scanned += 1
            if let stored = try await index.document(source: .calendars, externalID: externalID),
               stored.contentHash == contentHash
            {
                report.skipped += 1
                continue
            }
            let chunkText = Self.chunkText(title: title, notes: event.notes, location: event.location)
            var metadata: [String: String] = [:]
            if let name = calendar?.title, !name.isEmpty {
                metadata["calendarName"] = name
            }
            if let source = calendar?.sourceTitle, !source.isEmpty {
                metadata["sourceTitle"] = source
            }
            if let startISO {
                metadata["startISO"] = startISO
            }
            if let endISO {
                metadata["endISO"] = endISO
            }
            metadata["isAllDay"] = event.isAllDay ? "true" : "false"
            let document = IndexedDocument(
                source: .calendars,
                externalID: externalID,
                displayName: title,
                messageID: rawID,
                mtime: nil,
                contentHash: contentHash,
                mime: "text/calendar",
                extractStatus: .extracted,
                indexedAt: nowDate,
                metadata: metadata
            )
            pendings.append(CalendarPending(document: document, chunkText: chunkText))
        }
        return pendings
    }

    /// Embeds and upserts pending calendar documents.
    private func upsertPendings(_ pendings: [CalendarPending], runID: String, report: inout CalendarIndexReport) async throws {
        let vectors = try await embeddings(for: pendings.map(\.chunkText))
        for (offset, pending) in pendings.enumerated() {
            try Task.checkCancellation()
            let vector = offset < vectors.count ? vectors[offset] : []
            let chunk = IndexedChunk(
                documentID: pending.document.id,
                ordinal: 0,
                text: pending.chunkText,
                embedding: vector,
                isVector: !vector.isEmpty
            )
            _ = try await index.upsertDocumentWithChunks(document: pending.document, chunks: [chunk], runID: runID)
            report.indexed += 1
            if !vector.isEmpty {
                report.vectorsWritten += 1
            }
        }
    }

    /// Deletes stored calendar documents absent from the live fetch.
    private func pruneVanished(previous: Set<String>, liveIDs: Set<String>, report: inout CalendarIndexReport) async throws {
        let vanished = previous.subtracting(liveIDs)
        for externalID in vanished {
            try Task.checkCancellation()
            do {
                if let stored = try await index.document(source: .calendars, externalID: externalID) {
                    if try await index.deleteDocument(id: stored.id) {
                        report.pruned += 1
                    }
                }
            } catch {
                report.warnings.append("calendar prune skipped \(externalID)")
            }
        }
    }

    private func embeddings(for texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty, let embedder else {
            return Array(repeating: [], count: texts.count)
        }
        try Task.checkCancellation()
        do {
            let vectors = try await embedder.embed(texts)
            guard vectors.count == texts.count else {
                return Array(repeating: [], count: texts.count)
            }
            return vectors
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return Array(repeating: [], count: texts.count)
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
            let state = try JSONDecoder().decode(CalendarIndexState.self, from: data)
            return (state.knownIDs, nil)
        } catch {
            RuneWeaverLog.stores.warning("CalendarIndexer: failed to decode state from '\(stateURL.path)': \(error.localizedDescription)")
            return ([], "Calendar index state was unreadable; rebuilt from the live fetch.")
        }
    }

    /// Persists known identifiers atomically.
    private func writeKnownIDs(_ ids: Set<String>) throws {
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(CalendarIndexState(knownIDs: ids))
        try data.write(to: stateURL, options: .atomic)
    }
}
