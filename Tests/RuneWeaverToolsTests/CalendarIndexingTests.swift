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

final class MockCalendarIndexStore: CalendarStore, Sendable {
    struct State: Sendable {
        var status: CalendarAuthorizationStatus
        var calendars: [StoreCalendar]
        var events: [StoreEvent]
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

    func events(matching _: CalendarFetchPredicate) throws -> [StoreEvent] {
        state.withLock { $0.events }
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
}
