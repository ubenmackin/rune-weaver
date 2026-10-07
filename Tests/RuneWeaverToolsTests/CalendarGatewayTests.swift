// Rune Weaver Tools Tests — Calendar gateway persistence tests.
//
// Purpose: verify calendar gateway search, create, update, and delete against a hermetic EventKit seam.
// Scope: in-memory mock store only; no live EventKit access.
// Architectural role: guards gateway persistence behavior while tool tests own the ToolBus surface.

import Foundation
import os
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

/// In-memory EventKit seam double for hermetic gateway tests.
final class MockEventKitStore: EventKitStore, Sendable {
    private struct State: Sendable {
        var status: CalendarAuthorizationStatus
        var requestGranted: Bool
        var calendars: [StoreCalendar]
        var eventsByID: [String: StoreEvent]
        var nextID: Int
        var saveCount: Int
        var removeCount: Int
    }

    private let state: OSAllocatedUnfairLock<State>

    init(
        status: CalendarAuthorizationStatus = .authorized,
        requestGranted: Bool = true,
        calendars: [StoreCalendar] = [StoreCalendar(identifier: "cal-home", title: "Home", sourceTitle: "iCloud")],
        events: [StoreEvent] = []
    ) {
        var byID: [String: StoreEvent] = [:]
        var next = 1
        for event in events {
            var copy = event
            if copy.identifier?.isEmpty ?? true {
                copy.identifier = "mock-\(next)"
                next += 1
            }
            if let id = copy.identifier {
                byID[id] = copy
            }
        }
        self.state = OSAllocatedUnfairLock(initialState: State(
            status: status,
            requestGranted: requestGranted,
            calendars: calendars,
            eventsByID: byID,
            nextID: next,
            saveCount: 0,
            removeCount: 0
        ))
    }

    var saveCount: Int {
        state.withLock { $0.saveCount }
    }

    func authorizationStatus() -> CalendarAuthorizationStatus {
        state.withLock { $0.status }
    }

    func requestAccess() async throws -> Bool {
        state.withLock { $0.requestGranted }
    }

    func calendars() throws -> [StoreCalendar] {
        state.withLock { $0.calendars }
    }

    func predicateForEvents(start: Date, end: Date, calendars: [StoreCalendar]) -> CalendarFetchPredicate {
        CalendarFetchPredicate(start: start, end: end, calendars: calendars)
    }

    func events(matching predicate: CalendarFetchPredicate) throws -> [StoreEvent] {
        state.withLock { s in
            let ids = Set(predicate.calendars.map(\.identifier))
            if ids.isEmpty {
                return Array(s.eventsByID.values)
            }
            return s.eventsByID.values.filter {
                guard let cid = $0.calendarIdentifier else { return false }
                return ids.contains(cid)
            }
        }
    }

    func event(withIdentifier identifier: String) throws -> StoreEvent? {
        state.withLock { $0.eventsByID[identifier] }
    }

    func save(_ event: StoreEvent) throws -> StoreEvent {
        state.withLock { s in
            s.saveCount += 1
            var copy = event
            if copy.identifier?.isEmpty ?? true {
                copy.identifier = "mock-\(s.nextID)"
                s.nextID += 1
            }
            if let id = copy.identifier {
                s.eventsByID[id] = copy
            }
            return copy
        }
    }

    func remove(_ event: StoreEvent, span _: CalendarSpan) throws {
        state.withLock { s in
            s.removeCount += 1
            if let id = event.identifier {
                s.eventsByID.removeValue(forKey: id)
            }
        }
    }

    func reminderAuthorizationStatus() -> EventKitReminderAuthorization {
        .authorized
    }

    func requestReminderAccess() async throws -> Bool {
        true
    }

    func reminderCalendars() throws -> [EventKitReminderCalendar] {
        []
    }

    func fetchReminders(
        matching _: EventKitReminderPredicate,
        completion: @escaping @Sendable ([EventKitReminder]?) -> Void
    ) {
        completion([])
    }

    func reminder(withIdentifier _: String) -> EventKitReminder? {
        nil
    }

    func save(_ reminder: EventKitReminder) throws -> EventKitReminder {
        var copy = reminder
        if copy.identifier.isEmpty {
            copy.identifier = UUID().uuidString
        }
        return copy
    }

    func removeReminder(withIdentifier _: String) throws {}
}

@Suite("Calendar Gateway")
struct CalendarGatewayTests {
    private func daysFromNow(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: Date())
            ?? Date().addingTimeInterval(Double(days) * 86400)
    }

    private func storedEvent(
        id: String? = nil,
        title: String,
        offsetDays: Int?,
        calendarID: String = "cal-home",
        notes: String? = nil,
        location: String? = nil
    ) -> StoreEvent {
        let start: Date? = offsetDays.map { daysFromNow($0) }
        let end: Date? = start.map { $0.addingTimeInterval(3600) }
        return StoreEvent(
            identifier: id,
            calendarIdentifier: calendarID,
            title: title,
            notes: notes,
            startDate: start,
            endDate: end,
            isAllDay: false,
            location: location,
            hasRecurrence: false
        )
    }

    @Test
    func `Granted search filters by query`() async throws {
        let store = MockEventKitStore(events: [
            storedEvent(title: "Dentist appointment", offsetDays: -1, notes: "teeth cleaning", location: "Clinic"),
            storedEvent(title: "Lunch with Sam", offsetDays: -1)
        ])
        let gateway = ProductionCalendarGateway(store: store)
        let hits = try await gateway.search(query: "dentist")
        #expect(hits.count == 1)
        #expect(hits.first?.title == "Dentist appointment")
    }

    @Test
    func `Empty query lists window`() async throws {
        let store = MockEventKitStore(events: [
            storedEvent(title: "Inside past", offsetDays: -1),
            storedEvent(title: "Inside future", offsetDays: 1),
            storedEvent(title: "Too old", offsetDays: -30),
            storedEvent(title: "Too far", offsetDays: 90)
        ])
        let gateway = ProductionCalendarGateway(store: store)
        let hits = try await gateway.search()
        #expect(hits.count == 2)
        #expect(!hits.map(\.title).contains("Too old"))
        #expect(!hits.map(\.title).contains("Too far"))
    }

    @Test
    func `Denied search throws permissionDenied`() async throws {
        let store = MockEventKitStore(status: .denied)
        let gateway = ProductionCalendarGateway(store: store)
        do {
            _ = try await gateway.search(query: "anything")
            #expect(Bool(false), "Denied store must throw")
        } catch let error as CalendarToolError {
            guard case .permissionDenied = error else {
                #expect(Bool(false), "Expected permissionDenied, got \(error)")
                return
            }
            #expect(error.errorDescription?.contains("System Settings") ?? false)
        }
    }

    @Test
    func `Create rejects empty title before store`() async throws {
        let store = MockEventKitStore()
        let gateway = ProductionCalendarGateway(store: store)
        do {
            _ = try await gateway.create(title: "   ")
            #expect(Bool(false), "Empty title must throw")
        } catch let error as CalendarToolError {
            #expect(error == .emptyTitle)
        }
        #expect(store.saveCount == 0)
    }

    @Test
    func `Update of unknown id throws notFound`() async throws {
        let store = MockEventKitStore()
        let gateway = ProductionCalendarGateway(store: store)
        do {
            _ = try await gateway.update(eventID: "missing-123", patch: CalendarUpdatePatch(title: "New title"))
            #expect(Bool(false), "Unknown id must throw")
        } catch let error as CalendarToolError {
            guard case let .notFound(id) = error else {
                #expect(Bool(false), "Expected notFound, got \(error)")
                return
            }
            #expect(id.contains("missing-123"))
        }
    }

    @Test
    func `Delete removes event`() async throws {
        let store = MockEventKitStore()
        let gateway = ProductionCalendarGateway(store: store)
        let created = try await gateway.create(
            title: "Temp event",
            options: CalendarCreateOptions(start: daysFromNow(1), end: daysFromNow(1).addingTimeInterval(3600))
        )
        #expect(try await gateway.search(query: "Temp").count == 1)
        try await gateway.delete(eventID: created.id)
        #expect(try await gateway.search(query: "Temp").isEmpty)
    }

    @Test
    func `Limit clamps 1 to 50`() async throws {
        var seeds: [StoreEvent] = []
        for index in 0 ..< 60 {
            seeds.append(storedEvent(title: "Event \(index)", offsetDays: 1))
        }
        let store = MockEventKitStore(events: seeds)
        let gateway = ProductionCalendarGateway(store: store)
        #expect(try await gateway.search(limit: 100).count == 50)
        #expect(try await gateway.search(limit: 0).count == 1)
        #expect(try await gateway.search().count == 20)
    }

    @Test
    func `Search create update delete round trip`() async throws {
        let store = MockEventKitStore()
        let gateway = ProductionCalendarGateway(store: store)
        let created = try await gateway.create(
            title: "Team sync",
            options: CalendarCreateOptions(
                notes: "weekly",
                start: daysFromNow(2),
                end: daysFromNow(2).addingTimeInterval(3600)
            )
        )
        #expect(created.title == "Team sync")
        #expect(try await gateway.search(query: "team").count == 1)
        let updated = try await gateway.update(eventID: created.id, patch: CalendarUpdatePatch(title: "Team sync renamed"))
        #expect(updated.title == "Team sync renamed")
        #expect(try await gateway.search(query: "renamed").count == 1)
        try await gateway.delete(eventID: created.id)
        #expect(try await gateway.search(query: "renamed").isEmpty)
    }

    private func utcDate(_ iso: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return try #require(formatter.date(from: iso))
    }

    @Test
    func `Woven fixture renders device-local display while ISO stays Zulu`() async throws {
        let pacific = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let start = try utcDate("2026-10-07T00:00:00Z")
        let end = try utcDate("2026-10-07T01:00:00Z")
        #expect(CalendarEventDisplay.timedString(from: start, timeZone: pacific) == "Tue, Oct 6, 2026 5:00 PM PDT")
        #expect(TemporalFilter.isoString(from: start) == "2026-10-07T00:00:00Z")
        let store = MockEventKitStore(events: [
            StoreEvent(
                identifier: "woven-1",
                calendarIdentifier: "cal-home",
                title: "Woven",
                startDate: start,
                endDate: end,
                isAllDay: false
            )
        ])
        let gateway = ProductionCalendarGateway(store: store)
        let hits = try await gateway.search(query: "Woven")
        #expect(hits.count == 1)
        #expect(hits.first?.startDateISO == "2026-10-07T00:00:00Z")
        #expect(hits.first?.endDateISO == "2026-10-07T01:00:00Z")
        #expect(!(hits.first?.startDisplay.isEmpty ?? true))
        #expect(!(hits.first?.endDisplay.isEmpty ?? true))
    }

    @Test
    func `Timed rendering differs across DST boundary`() throws {
        let pacific = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let summer = try utcDate("2026-07-01T19:00:00Z")
        let winter = try utcDate("2026-01-05T20:00:00Z")
        let summerDisplay = CalendarEventDisplay.timedString(from: summer, timeZone: pacific)
        let winterDisplay = CalendarEventDisplay.timedString(from: winter, timeZone: pacific)
        #expect(summerDisplay.contains("PDT"))
        #expect(winterDisplay.contains("PST"))
        #expect(summerDisplay.contains(","))
        #expect(winterDisplay.contains(","))
    }

    @Test
    func `All-day renders date-only`() async throws {
        let pacific = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let date = try utcDate("2026-10-07T00:00:00Z")
        let display = CalendarEventDisplay.string(
            for: date,
            isoFallback: "2026-10-07T00:00:00Z",
            isAllDay: true,
            timeZone: pacific
        )
        #expect(display == "Tue, Oct 6, 2026")
        #expect(!display.contains(":"))
        let store = MockEventKitStore(events: [
            StoreEvent(
                identifier: "allday-1",
                calendarIdentifier: "cal-home",
                title: "Holiday",
                startDate: date,
                endDate: date,
                isAllDay: true
            )
        ])
        let gateway = ProductionCalendarGateway(store: store)
        let hits = try await gateway.search(query: "Holiday")
        #expect(hits.count == 1)
        #expect(!(hits.first?.startDisplay.contains(":") ?? true))
        #expect(!(hits.first?.endDisplay.contains(":") ?? true))
    }

    @Test
    func `Display falls back to ISO when date missing`() {
        #expect(
            CalendarEventDisplay.string(for: nil, isoFallback: "2026-10-07T00:00:00Z", isAllDay: false)
                == "2026-10-07T00:00:00Z"
        )
        #expect(
            CalendarEventDisplay.string(for: nil, isoFallback: "2026-10-07T00:00:00Z", isAllDay: true)
                == "2026-10-07T00:00:00Z"
        )
        #expect(CalendarEventDisplay.string(for: nil, isoFallback: nil, isAllDay: false) == "")
    }
}
