// Rune Weaver Tools Tests — Calendar indexing tests.
//
// Purpose: verify calendar occurrence mapping, hash skip, pruning, caps, and skip paths.
// Scope: hermetic calendar store plus isolated document index; no live EventKit access.
// Architectural role: guards calendar indexer behavior while gateway tests own persistence.

import Foundation
import os
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

enum MockCalendarIndexError: Error, Sendable, Equatable {
    case chunkFailed
}

final class MockCalendarIndexStore: CalendarStore, Sendable {
    struct State: Sendable {
        var status: CalendarAuthorizationStatus
        var calendars: [StoreCalendar]
        var events: [StoreEvent]
        var lastPredicate: CalendarFetchPredicate?
        var predicates: [CalendarFetchPredicate] = []
        var failAtCall: Int?
    }

    private let state: OSAllocatedUnfairLock<State>

    init(
        status: CalendarAuthorizationStatus = .authorized,
        calendars: [StoreCalendar] = [StoreCalendar(identifier: "cal-home", title: "Home", sourceTitle: "iCloud")],
        events: [StoreEvent] = []
    ) {
        self.state = OSAllocatedUnfairLock(initialState: State(status: status, calendars: calendars, events: events))
    }

    func setEvents(_ events: [StoreEvent]) {
        state.withLock { $0.events = events }
    }

    func authorizationStatus() -> CalendarAuthorizationStatus {
        state.withLock { $0.status }
    }

    func requestAccess() async throws -> Bool {
        true
    }

    func calendars() throws -> [StoreCalendar] {
        state.withLock { $0.calendars }
    }

    func predicateForEvents(start: Date, end: Date, calendars: [StoreCalendar]) -> CalendarFetchPredicate {
        CalendarFetchPredicate(start: start, end: end, calendars: calendars)
    }

    func events(matching predicate: CalendarFetchPredicate) throws -> [StoreEvent] {
        let callIndex = state.withLock { s -> Int in
            let idx = s.predicates.count
            s.predicates.append(predicate)
            s.lastPredicate = predicate
            return idx
        }
        if let failAt = state.withLock({ $0.failAtCall }), callIndex == failAt {
            throw MockCalendarIndexError.chunkFailed
        }
        return state.withLock {
            $0.events.filter { event in
                guard let start = event.startDate else { return true }
                return start >= predicate.start && start <= predicate.end
            }
        }
    }

    var lastPredicate: CalendarFetchPredicate? {
        state.withLock { $0.lastPredicate }
    }

    var predicateHistory: [CalendarFetchPredicate] {
        state.withLock { $0.predicates }
    }

    func setFailAtCall(_ index: Int?) {
        state.withLock { $0.failAtCall = index }
    }

    func event(withIdentifier identifier: String) throws -> StoreEvent? {
        state.withLock { $0.events.first { $0.identifier == identifier } }
    }

    func save(_ event: StoreEvent) throws -> StoreEvent {
        state.withLock { s in
            var copy = event
            if copy.identifier?.isEmpty ?? true {
                copy.identifier = UUID().uuidString
            }
            if let id = copy.identifier, let index = s.events.firstIndex(where: { $0.identifier == id }) {
                s.events[index] = copy
            } else {
                s.events.append(copy)
            }
            return copy
        }
    }

    func remove(_ event: StoreEvent, span _: CalendarSpan) throws {
        state.withLock { s in
            s.events.removeAll { $0.identifier == event.identifier }
        }
    }
}

private struct StubCalendarEmbedder: EmbeddingsBackend, Sendable {
    let modelID = "stub-calendar"
    let dimension: Int? = 3

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { _ in [0.1, 0.2, 0.3] }
    }
}

@Suite("Calendar Indexing")
struct CalendarIndexingTests {
    private func makePaths() -> (base: URL, store: String, state: String) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rw-cal-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return (base, base.appendingPathComponent("index.db").path, base.appendingPathComponent("cal-state.json").path)
    }

    private func makeEvent(id: String, title: String, start: Date, calendarID: String = "cal-home") -> StoreEvent {
        StoreEvent(
            identifier: id,
            calendarIdentifier: calendarID,
            title: title,
            notes: "notes for \(title)",
            startDate: start,
            endDate: start.addingTimeInterval(3600),
            isAllDay: false,
            location: "Room 1",
            hasRecurrence: false
        )
    }

    private func noProgress() -> ToolProgressReporter {
        { _ in }
    }

    @Test
    func `Occurrence maps to document with metadata and chunk`() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let mock = MockCalendarIndexStore(events: [makeEvent(id: "evt-1", title: "Team sync", start: start)])
        let index = DocIndexStore(dbPath: paths.store)
        let indexer = CalendarIndexer(store: mock, index: index, statePath: paths.state, now: { start })
        let report = try await indexer.run(reporter: noProgress())
        #expect(report.didRun)
        #expect(report.indexed == 1)
        #expect(report.scanned == 1)
        let startISO = TemporalFilter.isoString(from: start)
        let externalID = "evt-1@\(startISO)"
        let document = try await index.document(source: .calendars, externalID: externalID)
        #expect(document?.displayName == "Team sync")
        #expect(document?.messageID == "evt-1")
        #expect(document?.metadata["calendarName"] == "Home")
        #expect(document?.metadata["startISO"] == startISO)
        #expect(document?.metadata["isAllDay"] == "false")
        let hits = try await index.searchKeyword(query: "Team sync", limit: 5)
        #expect(hits.contains { $0.text.contains("Team sync") })
    }

    @Test
    func `Hash skip makes rerun a no-op`() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let mock = MockCalendarIndexStore(events: [makeEvent(id: "evt-1", title: "Standup", start: start)])
        let index = DocIndexStore(dbPath: paths.store)
        let indexer = CalendarIndexer(store: mock, index: index, statePath: paths.state, now: { start })
        let first = try await indexer.run(reporter: noProgress())
        #expect(first.indexed == 1)
        let second = try await indexer.run(reporter: noProgress())
        #expect(second.didRun)
        #expect(second.indexed == 0)
        #expect(second.skipped == 1)
    }

    @Test
    func `Prune deletes vanished identifiers`() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let mock = MockCalendarIndexStore(events: [
            makeEvent(id: "evt-keep", title: "Keep", start: start),
            makeEvent(id: "evt-gone", title: "Gone", start: start)
        ])
        let index = DocIndexStore(dbPath: paths.store)
        let indexer = CalendarIndexer(store: mock, index: index, statePath: paths.state, now: { start })
        _ = try await indexer.run(reporter: noProgress())
        mock.setEvents([makeEvent(id: "evt-keep", title: "Keep", start: start)])
        let second = try await indexer.run(reporter: noProgress())
        #expect(second.pruned == 1)
        let startISO = TemporalFilter.isoString(from: start)
        let gone = try await index.document(source: .calendars, externalID: "evt-gone@\(startISO)")
        #expect(gone == nil)
        let kept = try await index.document(source: .calendars, externalID: "evt-keep@\(startISO)")
        #expect(kept != nil)
    }

    @Test
    func `Cap keeps newest 500 of a large series`() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        var seeds: [StoreEvent] = []
        for day in 0 ..< 2000 {
            let start = Calendar.current.date(byAdding: .day, value: -day, to: anchor) ?? anchor.addingTimeInterval(Double(-day) * 86400)
            seeds.append(StoreEvent(
                identifier: "series-1",
                calendarIdentifier: "cal-home",
                title: "Daily \(day)",
                startDate: start,
                endDate: start.addingTimeInterval(3600),
                isAllDay: false,
                hasRecurrence: true
            ))
        }
        let mock = MockCalendarIndexStore(events: seeds)
        let index = DocIndexStore(dbPath: paths.store)
        let indexer = CalendarIndexer(store: mock, index: index, statePath: paths.state, now: { anchor })
        let report = try await indexer.run(reporter: noProgress())
        #expect(report.indexed == 500)
        #expect(report.scanned == 500)
        let newest = seeds.prefix(500)
        for event in newest {
            let startDate = try #require(event.startDate)
            let iso = TemporalFilter.isoString(from: startDate)
            let found = try await index.document(source: .calendars, externalID: "series-1@\(iso)")
            #expect(found != nil)
        }
        let oldestStart = try #require(seeds.last?.startDate)
        let oldestISO = TemporalFilter.isoString(from: oldestStart)
        let oldest = try await index.document(source: .calendars, externalID: "series-1@\(oldestISO)")
        #expect(oldest == nil)
    }

    @Test
    func `Denied store yields skipped reason`() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        let mock = MockCalendarIndexStore(status: .denied)
        let index = DocIndexStore(dbPath: paths.store)
        let indexer = CalendarIndexer(store: mock, index: index, statePath: paths.state)
        let report = try await indexer.run(reporter: noProgress())
        #expect(report.didRun == false)
        #expect(report.skippedReason != nil)
        #expect(report.indexed == 0)
    }

    @Test
    func `Disabled policy yields skipped reason`() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        let index = DocIndexStore(dbPath: paths.store)
        let mock = MockCalendarIndexStore()
        let config = IndexConfig(enabled: true, calendars: false)
        let stage = CalendarIndexer.makeCalendarStage(config: config, store: index, calendarStore: mock)
        #expect(stage.kind == .calendars)
        #expect(stage.isEnabled == false)
        let policy = IndexConfig(enabled: true, calendars: false)
        let report = try await stage.run(reporter: noProgress(), isCancelled: { false }, policy: policy)
        #expect(report.didRun == false)
        #expect(report.skippedReason != nil)
    }

    @Test
    func `Empty titles are skipped`() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let mock = MockCalendarIndexStore(events: [
            StoreEvent(identifier: "evt-blank", calendarIdentifier: "cal-home", title: "   ", startDate: start, endDate: start.addingTimeInterval(3600)),
            StoreEvent(identifier: "evt-nil", calendarIdentifier: "cal-home", title: nil, startDate: start, endDate: start.addingTimeInterval(3600)),
            makeEvent(id: "evt-good", title: "Good", start: start)
        ])
        let index = DocIndexStore(dbPath: paths.store)
        let indexer = CalendarIndexer(store: mock, index: index, statePath: paths.state, now: { start })
        let report = try await indexer.run(reporter: noProgress())
        #expect(report.indexed == 1)
        #expect(report.skipped == 2)
    }

    @Test
    func `Embedder writes vectors`() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let mock = MockCalendarIndexStore(events: [makeEvent(id: "evt-1", title: "Vector meeting", start: start)])
        let index = DocIndexStore(dbPath: paths.store)
        let indexer = CalendarIndexer(
            store: mock,
            index: index,
            embedder: StubCalendarEmbedder(),
            statePath: paths.state,
            now: { start }
        )
        let report = try await indexer.run(reporter: noProgress())
        #expect(report.vectorsWritten == 1)
    }

    @Test
    func `Fetch window walks decade in eleven one-year chunks`() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let mock = MockCalendarIndexStore()
        let index = DocIndexStore(dbPath: paths.store)
        let indexer = CalendarIndexer(store: mock, index: index, statePath: paths.state, now: { now })
        _ = try await indexer.run(reporter: noProgress())
        let predicates = mock.predicateHistory
        let expectedStart = try #require(Calendar.current.date(byAdding: .year, value: -CalendarIndexer.defaultLookbackYears, to: now))
        let expectedEnd = try #require(Calendar.current.date(byAdding: .day, value: 365, to: now))
        #expect(CalendarIndexer.defaultLookbackYears == 10)
        #expect(predicates.count == 11)
        #expect(predicates.first?.start == expectedStart)
        #expect(predicates.last?.end == expectedEnd)
        for offset in 1 ..< predicates.count {
            #expect(predicates[offset].start == predicates[offset - 1].end)
        }
    }

    @Test
    func `Multi-chunk union covers every year`() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let expectedStart = try #require(Calendar.current.date(byAdding: .year, value: -10, to: now))
        let expectedEnd = try #require(Calendar.current.date(byAdding: .day, value: 365, to: now))
        var chunkStart = expectedStart
        var seeds: [StoreEvent] = []
        var ordinal = 0
        while chunkStart < expectedEnd {
            let next = Calendar.current.date(byAdding: .year, value: 1, to: chunkStart) ?? chunkStart.addingTimeInterval(366 * 86400)
            let chunkEnd = min(next, expectedEnd)
            let mid = chunkStart.addingTimeInterval(30 * 86400)
            #expect(mid < chunkEnd)
            seeds.append(makeEvent(id: "evt-\(ordinal)", title: "Year \(ordinal)", start: mid))
            ordinal += 1
            if chunkEnd >= expectedEnd {
                break
            }
            chunkStart = chunkEnd
        }
        #expect(seeds.count == 11)
        let mock = MockCalendarIndexStore(events: seeds)
        let index = DocIndexStore(dbPath: paths.store)
        let indexer = CalendarIndexer(store: mock, index: index, statePath: paths.state, now: { now })
        let report = try await indexer.run(reporter: noProgress())
        #expect(report.indexed == seeds.count)
        #expect(report.scanned == seeds.count)
        #expect(mock.predicateHistory.count == 11)
        for seed in seeds {
            let startDate = try #require(seed.startDate)
            let identifier = try #require(seed.identifier)
            let iso = TemporalFilter.isoString(from: startDate)
            let found = try await index.document(source: .calendars, externalID: "\(identifier)@\(iso)")
            #expect(found != nil)
        }
    }

    @Test
    func `Boundary instant kept once`() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let expectedStart = try #require(Calendar.current.date(byAdding: .year, value: -10, to: now))
        let boundary = try #require(Calendar.current.date(byAdding: .year, value: 1, to: expectedStart))
        let mock = MockCalendarIndexStore(events: [makeEvent(id: "evt-edge", title: "Edge", start: boundary)])
        let index = DocIndexStore(dbPath: paths.store)
        let indexer = CalendarIndexer(store: mock, index: index, statePath: paths.state, now: { now })
        let report = try await indexer.run(reporter: noProgress())
        #expect(report.scanned == 1)
        #expect(report.indexed == 1)
        let iso = TemporalFilter.isoString(from: boundary)
        let found = try await index.document(source: .calendars, externalID: "evt-edge@\(iso)")
        #expect(found != nil)
    }

    @Test
    func `Cap applies post-union newest-first`() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let expectedStart = try #require(Calendar.current.date(byAdding: .year, value: -10, to: now))
        let expectedEnd = try #require(Calendar.current.date(byAdding: .day, value: 365, to: now))
        var chunkStart = expectedStart
        var seeds: [StoreEvent] = []
        var day = 0
        while chunkStart < expectedEnd, seeds.count < 6 {
            let next = Calendar.current.date(byAdding: .year, value: 1, to: chunkStart) ?? chunkStart.addingTimeInterval(366 * 86400)
            let chunkEnd = min(next, expectedEnd)
            let mid = chunkStart.addingTimeInterval(30 * 86400)
            seeds.append(StoreEvent(
                identifier: "series-cap",
                calendarIdentifier: "cal-home",
                title: "Cap \(day)",
                startDate: mid,
                endDate: mid.addingTimeInterval(3600),
                isAllDay: false,
                hasRecurrence: true
            ))
            day += 1
            if chunkEnd >= expectedEnd {
                break
            }
            chunkStart = chunkEnd
        }
        #expect(seeds.count == 6)
        let mock = MockCalendarIndexStore(events: seeds)
        let index = DocIndexStore(dbPath: paths.store)
        let indexer = CalendarIndexer(
            store: mock,
            index: index,
            statePath: paths.state,
            occurrenceCap: 3,
            now: { now }
        )
        let report = try await indexer.run(reporter: noProgress())
        #expect(report.scanned == 3)
        #expect(report.indexed == 3)
        let ranked = seeds.compactMap(\.startDate).sorted(by: >)
        for start in ranked.prefix(3) {
            let iso = TemporalFilter.isoString(from: start)
            let found = try await index.document(source: .calendars, externalID: "series-cap@\(iso)")
            #expect(found != nil)
        }
        for start in ranked.suffix(from: 3) {
            let iso = TemporalFilter.isoString(from: start)
            let missing = try await index.document(source: .calendars, externalID: "series-cap@\(iso)")
            #expect(missing == nil)
        }
    }

    @Test
    func `Chunk throw aborts before any upsert`() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let expectedStart = try #require(Calendar.current.date(byAdding: .year, value: -10, to: now))
        let firstMid = expectedStart.addingTimeInterval(30 * 86400)
        let mock = MockCalendarIndexStore(events: [makeEvent(id: "evt-1", title: "First", start: firstMid)])
        mock.setFailAtCall(1)
        let index = DocIndexStore(dbPath: paths.store)
        let indexer = CalendarIndexer(store: mock, index: index, statePath: paths.state, now: { now })
        do {
            _ = try await indexer.run(reporter: noProgress())
            Issue.record("Expected chunk failure to throw")
        } catch let error as MockCalendarIndexError {
            #expect(error == .chunkFailed)
        }
        #expect(mock.predicateHistory.count == 2)
        let iso = TemporalFilter.isoString(from: firstMid)
        let found = try await index.document(source: .calendars, externalID: "evt-1@\(iso)")
        #expect(found == nil)
    }

    @Test
    func `Recent occurrence indexes while out-of-window occurrence stays out`() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.base) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let recentStart = Calendar.current.date(byAdding: .month, value: -1, to: now) ?? now.addingTimeInterval(-30 * 86400)
        let oldStart = Calendar.current.date(byAdding: .year, value: -11, to: now) ?? now.addingTimeInterval(-11 * 365 * 86400)
        let mock = MockCalendarIndexStore(events: [
            makeEvent(id: "evt-recent", title: "Recent", start: recentStart),
            makeEvent(id: "evt-old", title: "Ancient", start: oldStart)
        ])
        let index = DocIndexStore(dbPath: paths.store)
        let indexer = CalendarIndexer(store: mock, index: index, statePath: paths.state, now: { now })
        let report = try await indexer.run(reporter: noProgress())
        #expect(report.indexed == 1)
        #expect(report.scanned == 1)
        let recentISO = TemporalFilter.isoString(from: recentStart)
        let recent = try await index.document(source: .calendars, externalID: "evt-recent@\(recentISO)")
        #expect(recent != nil)
        let oldISO = TemporalFilter.isoString(from: oldStart)
        let old = try await index.document(source: .calendars, externalID: "evt-old@\(oldISO)")
        #expect(old == nil)
    }
}
