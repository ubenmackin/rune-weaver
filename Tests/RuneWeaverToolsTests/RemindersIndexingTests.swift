// Rune Weaver Tools Tests — Reminders indexer tests.
//
// Purpose: verify reminder-to-document mapping, hash skip, completion-flip re-index,
// prune of vanished identifiers, and honest denied plus disabled skip copy.
// Scope: in-memory reminder seam plus isolated document store; no live EventKit access.
// Architectural role: guards the reminders indexing owner while gateway tests own persistence.

import CryptoKit
import Foundation
import os
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

/// In-memory reminder seam for hermetic indexing tests.
final class ReminderIndexingMockStore: ReminderStore, Sendable {
    private struct State: Sendable {
        var authorization: EventKitReminderAuthorization = .authorized
        var calendars: [EventKitReminderCalendar] = [
            EventKitReminderCalendar(identifier: "list-personal", title: "Personal", sourceTitle: "Local"),
            EventKitReminderCalendar(identifier: "list-work", title: "Work", sourceTitle: "iCloud")
        ]
        var reminders: [String: EventKitReminder] = [:]
    }

    private let state: OSAllocatedUnfairLock<State>

    init() {
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    func setAuthorization(_ value: EventKitReminderAuthorization) {
        state.withLock { $0.authorization = value }
    }

    func seed(_ reminder: EventKitReminder) {
        state.withLock { $0.reminders[reminder.identifier] = reminder }
    }

    func remove(id: String) {
        state.withLock { _ = $0.reminders.removeValue(forKey: id) }
    }

    func setCompleted(id: String, completed: Bool) {
        state.withLock {
            if var existing = $0.reminders[id] {
                existing.isCompleted = completed
                $0.reminders[id] = existing
            }
        }
    }

    func reminderAuthorizationStatus() -> EventKitReminderAuthorization {
        state.withLock { $0.authorization }
    }

    func requestReminderAccess() async throws -> Bool {
        true
    }

    func reminderCalendars() throws -> [EventKitReminderCalendar] {
        state.withLock { $0.calendars }
    }

    func fetchReminders(
        matching predicate: EventKitReminderPredicate,
        completion: @escaping @Sendable ([EventKitReminder]?) -> Void
    ) {
        let wanted = Set(predicate.calendars.map(\.identifier))
        let results = state.withLock { s in
            s.reminders.values.filter {
                wanted.contains($0.calendarIdentifier) && $0.isCompleted == predicate.fetchCompleted
            }
        }
        completion(Array(results))
    }

    func reminder(withIdentifier identifier: String) -> EventKitReminder? {
        state.withLock { $0.reminders[identifier] }
    }

    func save(_ reminder: EventKitReminder) throws -> EventKitReminder {
        state.withLock { s in
            var copy = reminder
            if copy.identifier.isEmpty {
                copy.identifier = UUID().uuidString
            }
            s.reminders[copy.identifier] = copy
            return copy
        }
    }

    func removeReminder(withIdentifier identifier: String) throws {
        state.withLock { _ = $0.reminders.removeValue(forKey: identifier) }
    }
}

/// Fixed-vector embedder so vector counts stay deterministic.
struct ReminderIndexingStubEmbedder: EmbeddingsBackend {
    let modelID = "test-stub"
    let dimension: Int? = 3

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { _ in [1.0, 2.0, 3.0] }
    }
}

/// Creates isolated store plus state paths for one test.
private func makeReminderIndexPaths() -> (base: URL, store: String, state: String) {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("runeweaver-reminders-index-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return (
        base,
        base.appendingPathComponent("index.db").path,
        base.appendingPathComponent("reminders-state.json").path
    )
}

@Suite("Reminders Indexing")
struct RemindersIndexingTests {
    private static func seededStore() -> ReminderIndexingMockStore {
        let store = ReminderIndexingMockStore()
        store.seed(EventKitReminder(
            identifier: "r-open",
            calendarIdentifier: "list-personal",
            title: "Buy oat milk",
            notes: "From the corner shop",
            dueDate: Date(timeIntervalSince1970: 1_786_000_000),
            isCompleted: false,
            priority: 0,
            creationDate: Date(timeIntervalSince1970: 1_785_000_000)
        ))
        store.seed(EventKitReminder(
            identifier: "r-done",
            calendarIdentifier: "list-work",
            title: "File expenses",
            notes: nil,
            dueDate: nil,
            isCompleted: true,
            priority: 0,
            creationDate: Date(timeIntervalSince1970: 1_785_000_001)
        ))
        return store
    }

    @Test
    func `Run indexes incomplete plus completed rows`() async throws {
        let paths = makeReminderIndexPaths()
        let mock = Self.seededStore()
        let docs = DocIndexStore(dbPath: paths.store)
        let indexer = RemindersIndexer(store: mock, index: docs, statePath: paths.state)
        let report = try await indexer.run(reporter: { _ in })
        #expect(report.didRun == true)
        #expect(report.scanned == 2)
        #expect(report.indexed == 2)
        #expect(report.skipped == 0)
        #expect(report.pruned == 0)
        let open = try await docs.document(source: .reminders, externalID: "r-open")
        #expect(open?.displayName == "Buy oat milk")
        #expect(open?.messageID == "r-open")
        let done = try await docs.document(source: .reminders, externalID: "r-done")
        #expect(done?.displayName == "File expenses")
    }

    @Test
    func `Doc mapping carries list plus due plus completed`() async throws {
        let paths = makeReminderIndexPaths()
        let docs = DocIndexStore(dbPath: paths.store)
        let indexer = RemindersIndexer(store: Self.seededStore(), index: docs, statePath: paths.state)
        _ = try await indexer.run(reporter: { _ in })
        let open = try #require(await docs.document(source: .reminders, externalID: "r-open"))
        #expect(open.source == .reminders)
        #expect(open.externalID == "r-open")
        #expect(open.metadata["listName"] == "Personal")
        #expect(open.metadata["sourceTitle"] == "Local")
        #expect(open.metadata["completed"] == "false")
        #expect(open.metadata["dueISO"] != nil)
        let done = try #require(await docs.document(source: .reminders, externalID: "r-done"))
        #expect(done.metadata["listName"] == "Work")
        #expect(done.metadata["sourceTitle"] == "iCloud")
        #expect(done.metadata["completed"] == "true")
        let chunks = try await docs.searchKeyword(query: "oat", limit: 10)
        #expect(chunks.count == 1)
        #expect(chunks.first?.text.contains("Buy oat milk") == true)
        #expect(chunks.first?.text.contains("corner shop") == true)
        #expect(chunks.first?.text.contains("false") == true)
    }

    @Test
    func `Completed flag appears in chunk plus metadata`() async throws {
        let paths = makeReminderIndexPaths()
        let docs = DocIndexStore(dbPath: paths.store)
        let indexer = RemindersIndexer(store: Self.seededStore(), index: docs, statePath: paths.state)
        _ = try await indexer.run(reporter: { _ in })
        let chunks = try await docs.searchKeyword(query: "expenses", limit: 10)
        let chunk = try #require(chunks.first)
        #expect(chunk.text.contains("true") == true)
        let done = try #require(await docs.document(source: .reminders, externalID: "r-done"))
        #expect(done.metadata["completed"] == "true")
    }

    @Test
    func `Second run skips unchanged rows by hash`() async throws {
        let paths = makeReminderIndexPaths()
        let mock = Self.seededStore()
        let docs = DocIndexStore(dbPath: paths.store)
        let indexer = RemindersIndexer(store: mock, index: docs, statePath: paths.state)
        _ = try await indexer.run(reporter: { _ in })
        let second = try await indexer.run(reporter: { _ in })
        #expect(second.didRun == true)
        #expect(second.scanned == 2)
        #expect(second.indexed == 0)
        #expect(second.skipped == 2)
        #expect(second.pruned == 0)
    }

    @Test
    func `Completion flip re-indexes that row`() async throws {
        let paths = makeReminderIndexPaths()
        let mock = Self.seededStore()
        let docs = DocIndexStore(dbPath: paths.store)
        let indexer = RemindersIndexer(store: mock, index: docs, statePath: paths.state)
        _ = try await indexer.run(reporter: { _ in })
        mock.setCompleted(id: "r-open", completed: true)
        let flipped = try await indexer.run(reporter: { _ in })
        #expect(flipped.indexed == 1)
        #expect(flipped.skipped == 1)
        let reopened = try #require(await docs.document(source: .reminders, externalID: "r-open"))
        #expect(reopened.metadata["completed"] == "true")
    }

    @Test
    func `Prune deletes vanished identifiers`() async throws {
        let paths = makeReminderIndexPaths()
        let mock = Self.seededStore()
        let docs = DocIndexStore(dbPath: paths.store)
        let indexer = RemindersIndexer(store: mock, index: docs, statePath: paths.state)
        _ = try await indexer.run(reporter: { _ in })
        mock.remove(id: "r-open")
        let pruned = try await indexer.run(reporter: { _ in })
        #expect(pruned.pruned == 1)
        #expect(try await docs.document(source: .reminders, externalID: "r-open") == nil)
        #expect(try await docs.document(source: .reminders, externalID: "r-done") != nil)
    }

    @Test
    func `Denied authorization yields skippedReason`() async throws {
        let paths = makeReminderIndexPaths()
        let mock = Self.seededStore()
        mock.setAuthorization(.denied)
        let docs = DocIndexStore(dbPath: paths.store)
        let indexer = RemindersIndexer(store: mock, index: docs, statePath: paths.state)
        let report = try await indexer.run(reporter: { _ in })
        #expect(report.didRun == false)
        #expect(report.skippedReason != nil)
        #expect(report.indexed == 0)
    }

    @Test
    func `Disabled policy yields skippedReason`() async throws {
        let paths = makeReminderIndexPaths()
        let docs = DocIndexStore(dbPath: paths.store)
        let mock = Self.seededStore()
        let config = IndexConfig(enabled: true, reminders: false)
        let stage = RemindersIndexer.makeRemindersStage(config: config, store: docs, reminderStore: mock)
        #expect(stage.kind == .reminders)
        let report = try await stage.run(reporter: { _ in }, isCancelled: { false }, policy: config)
        #expect(report.didRun == false)
        #expect(report.skippedReason != nil)
        #expect(report.kind == .reminders)
    }

    @Test
    func `Enabled stage runs and reports reminders kind`() async throws {
        let paths = makeReminderIndexPaths()
        let docs = DocIndexStore(dbPath: paths.store)
        let mock = Self.seededStore()
        let config = IndexConfig(enabled: true, reminders: true)
        let stage = RemindersIndexer.makeRemindersStage(config: config, store: docs, reminderStore: mock)
        #expect(stage.isEnabled == true)
        let report = try await stage.run(reporter: { _ in }, isCancelled: { false }, policy: config)
        #expect(report.kind == .reminders)
        #expect(report.didRun == true)
        #expect(report.indexed == 2)
    }

    @Test
    func `Empty titles are skipped`() async throws {
        let paths = makeReminderIndexPaths()
        let mock = ReminderIndexingMockStore()
        mock.seed(EventKitReminder(
            identifier: "r-blank",
            calendarIdentifier: "list-personal",
            title: "   ",
            notes: "No title here",
            dueDate: nil,
            isCompleted: false
        ))
        mock.seed(EventKitReminder(
            identifier: "r-real",
            calendarIdentifier: "list-personal",
            title: "Real task",
            notes: nil,
            dueDate: nil,
            isCompleted: false
        ))
        let docs = DocIndexStore(dbPath: paths.store)
        let indexer = RemindersIndexer(store: mock, index: docs, statePath: paths.state)
        let report = try await indexer.run(reporter: { _ in })
        #expect(report.scanned == 2)
        #expect(report.indexed == 1)
        #expect(report.skipped == 1)
        #expect(try await docs.document(source: .reminders, externalID: "r-blank") == nil)
        #expect(try await docs.document(source: .reminders, externalID: "r-real") != nil)
    }

    @Test
    func `Embedder writes vectors`() async throws {
        let paths = makeReminderIndexPaths()
        let docs = DocIndexStore(dbPath: paths.store)
        let indexer = RemindersIndexer(
            store: Self.seededStore(),
            index: docs,
            embedder: ReminderIndexingStubEmbedder(),
            statePath: paths.state
        )
        let report = try await indexer.run(reporter: { _ in })
        #expect(report.indexed == 2)
        #expect(report.vectorsWritten == 2)
    }

    @Test
    func `Mtime falls back from due date to creation date to nil`() async throws {
        let paths = makeReminderIndexPaths()
        let mock = ReminderIndexingMockStore()
        let due = Date(timeIntervalSince1970: 1_786_000_000)
        let created = Date(timeIntervalSince1970: 1_785_500_000)
        mock.seed(EventKitReminder(
            identifier: "r-mtime-due",
            calendarIdentifier: "list-personal",
            title: "Dated pineapplealpha errand",
            notes: nil,
            dueDate: due,
            isCompleted: false,
            priority: 0,
            creationDate: created
        ))
        mock.seed(EventKitReminder(
            identifier: "r-mtime-created",
            calendarIdentifier: "list-personal",
            title: "Created mangobeta errand",
            notes: nil,
            dueDate: nil,
            isCompleted: false,
            priority: 0,
            creationDate: created
        ))
        mock.seed(EventKitReminder(
            identifier: "r-mtime-dateless",
            calendarIdentifier: "list-personal",
            title: "Dateless zebragamma errand",
            notes: nil,
            dueDate: nil,
            isCompleted: false,
            priority: 0,
            creationDate: nil
        ))
        let docs = DocIndexStore(dbPath: paths.store)
        let indexer = RemindersIndexer(store: mock, index: docs, statePath: paths.state)
        _ = try await indexer.run(reporter: { _ in })
        let dated = try #require(await docs.document(source: .reminders, externalID: "r-mtime-due"))
        #expect(dated.mtime == due)
        let fallback = try #require(await docs.document(source: .reminders, externalID: "r-mtime-created"))
        #expect(fallback.mtime == created)
        let dateless = try #require(await docs.document(source: .reminders, externalID: "r-mtime-dateless"))
        #expect(dateless.mtime == nil)
    }

    @Test
    func `Content hash join stays byte-identical`() {
        let due = Date(timeIntervalSince1970: 1_786_000_000)
        let dueISO = TemporalFilter.isoString(from: due)
        let actual = RemindersIndexer.contentHash(
            title: "Buy oat milk",
            notes: "From the corner shop",
            dueISO: dueISO,
            calendarIdentifier: "list-personal",
            listName: "Personal",
            isCompleted: false
        )
        let joined = [
            "Buy oat milk",
            "From the corner shop",
            dueISO,
            "list-personal",
            "Personal",
            "false"
        ].joined(separator: "\n")
        let digest = SHA256.hash(data: Data(joined.utf8))
        let expected = digest.map { String(format: "%02x", $0) }.joined()
        #expect(actual == expected)
    }

    @Test
    func `Bounded search matches dated rows while dateless rows stay window-invisible`() async throws {
        let paths = makeReminderIndexPaths()
        let mock = ReminderIndexingMockStore()
        let due = Date(timeIntervalSince1970: 1_786_000_000)
        let created = Date(timeIntervalSince1970: 1_785_000_000)
        mock.seed(EventKitReminder(
            identifier: "r-window-dated",
            calendarIdentifier: "list-personal",
            title: "Dated pineapplealpha errand",
            notes: nil,
            dueDate: due,
            isCompleted: false,
            priority: 0,
            creationDate: created
        ))
        mock.seed(EventKitReminder(
            identifier: "r-window-created",
            calendarIdentifier: "list-personal",
            title: "Created mangobeta errand",
            notes: nil,
            dueDate: nil,
            isCompleted: false,
            priority: 0,
            creationDate: created
        ))
        mock.seed(EventKitReminder(
            identifier: "r-window-dateless",
            calendarIdentifier: "list-personal",
            title: "Dateless zebragamma errand",
            notes: nil,
            dueDate: nil,
            isCompleted: false,
            priority: 0,
            creationDate: nil
        ))
        let docs = DocIndexStore(dbPath: paths.store)
        let indexer = RemindersIndexer(store: mock, index: docs, statePath: paths.state)
        _ = try await indexer.run(reporter: { _ in })
        let unboundedDateless = try await docs.searchKeyword(query: "zebragamma", limit: 10)
        #expect(unboundedDateless.count == 1)
        let dueSince = Date(timeIntervalSince1970: 1_786_000_000 - 86400)
        let dueUntil = Date(timeIntervalSince1970: 1_786_000_000 + 86400)
        let boundedDateless = try await docs.searchKeyword(
            query: "zebragamma",
            limit: 10,
            since: dueSince,
            until: dueUntil
        )
        #expect(boundedDateless.isEmpty)
        let boundedDated = try await docs.searchKeyword(
            query: "pineapplealpha",
            limit: 10,
            since: dueSince,
            until: dueUntil
        )
        #expect(boundedDated.count == 1)
        #expect(boundedDated.first?.text.contains("pineapplealpha") == true)
        let createdSince = Date(timeIntervalSince1970: 1_785_000_000 - 86400)
        let createdUntil = Date(timeIntervalSince1970: 1_785_000_000 + 86400)
        let boundedCreated = try await docs.searchKeyword(
            query: "mangobeta",
            limit: 10,
            since: createdSince,
            until: createdUntil
        )
        #expect(boundedCreated.count == 1)
        #expect(boundedCreated.first?.text.contains("mangobeta") == true)
    }

    @Test
    func `Second pass upserts nothing across dated creation and dateless rows`() async throws {
        let paths = makeReminderIndexPaths()
        let mock = ReminderIndexingMockStore()
        let due = Date(timeIntervalSince1970: 1_786_000_000)
        let created = Date(timeIntervalSince1970: 1_785_500_000)
        mock.seed(EventKitReminder(
            identifier: "r-skip-due",
            calendarIdentifier: "list-personal",
            title: "Dated pineapplealpha errand",
            notes: nil,
            dueDate: due,
            isCompleted: false,
            priority: 0,
            creationDate: created
        ))
        mock.seed(EventKitReminder(
            identifier: "r-skip-created",
            calendarIdentifier: "list-personal",
            title: "Created mangobeta errand",
            notes: nil,
            dueDate: nil,
            isCompleted: false,
            priority: 0,
            creationDate: created
        ))
        mock.seed(EventKitReminder(
            identifier: "r-skip-dateless",
            calendarIdentifier: "list-personal",
            title: "Dateless zebragamma errand",
            notes: nil,
            dueDate: nil,
            isCompleted: false,
            priority: 0,
            creationDate: nil
        ))
        let docs = DocIndexStore(dbPath: paths.store)
        let indexer = RemindersIndexer(store: mock, index: docs, statePath: paths.state)
        _ = try await indexer.run(reporter: { _ in })
        let second = try await indexer.run(reporter: { _ in })
        #expect(second.didRun == true)
        #expect(second.scanned == 3)
        #expect(second.indexed == 0)
        #expect(second.skipped == 3)
        #expect(second.pruned == 0)
    }
}
