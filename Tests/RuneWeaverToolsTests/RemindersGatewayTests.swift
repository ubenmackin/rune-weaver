// Rune Weaver Tools Tests — Reminders gateway persistence tests.

import Foundation
import os
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

/// In-memory EventKit seam for hermetic reminder tests.
final class MockReminderEventKitStore: EventKitStore, Sendable {
    private struct State: Sendable {
        var authorization: EventKitReminderAuthorization = .authorized
        var requestResult: Bool = true
        var calendars: [EventKitReminderCalendar] = [
            EventKitReminderCalendar(identifier: "list-personal", title: "Personal", sourceTitle: "Local"),
            EventKitReminderCalendar(identifier: "list-work", title: "Work", sourceTitle: "Local")
        ]
        var reminders: [String: EventKitReminder] = [:]
    }

    private let state: OSAllocatedUnfairLock<State>

    init() {
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    var authorization: EventKitReminderAuthorization {
        get {
            state.withLock { $0.authorization }
        }
        set {
            state.withLock { $0.authorization = newValue }
        }
    }

    var requestResult: Bool {
        get {
            state.withLock { $0.requestResult }
        }
        set {
            state.withLock { $0.requestResult = newValue }
        }
    }

    func seed(_ reminder: EventKitReminder) {
        state.withLock { $0.reminders[reminder.identifier] = reminder }
    }

    func reminderAuthorizationStatus() -> EventKitReminderAuthorization {
        state.withLock { $0.authorization }
    }

    func requestReminderAccess() async throws -> Bool {
        state.withLock { $0.requestResult }
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

    func authorizationStatus() -> CalendarAuthorizationStatus {
        .authorized
    }

    func requestAccess() async throws -> Bool {
        true
    }

    func calendars() throws -> [StoreCalendar] {
        []
    }

    func predicateForEvents(start: Date, end: Date, calendars: [StoreCalendar]) -> CalendarFetchPredicate {
        CalendarFetchPredicate(start: start, end: end, calendars: calendars)
    }

    func events(matching _: CalendarFetchPredicate) throws -> [StoreEvent] {
        []
    }

    func event(withIdentifier _: String) throws -> StoreEvent? {
        nil
    }

    func save(_ event: StoreEvent) throws -> StoreEvent {
        event
    }

    func remove(_: StoreEvent, span _: CalendarSpan) throws {}
}

@Suite("Reminders Gateway")
struct RemindersGatewayTests {
    private static func dueDate(daysFromNow days: Int) -> Date {
        Date().addingTimeInterval(Double(days) * 86400)
    }

    private static func seededStore() -> MockReminderEventKitStore {
        let store = MockReminderEventKitStore()
        store.seed(EventKitReminder(
            identifier: "r-milk",
            calendarIdentifier: "list-personal",
            title: "Buy oat milk",
            notes: "From the corner shop",
            dueDate: dueDate(daysFromNow: 1),
            isCompleted: false,
            priority: 0,
            creationDate: Date()
        ))
        store.seed(EventKitReminder(
            identifier: "r-mom",
            calendarIdentifier: "list-personal",
            title: "Call mom",
            notes: nil,
            dueDate: nil,
            isCompleted: false,
            priority: 0,
            creationDate: Date()
        ))
        store.seed(EventKitReminder(
            identifier: "r-done",
            calendarIdentifier: "list-work",
            title: "Buy milk powder",
            notes: nil,
            dueDate: dueDate(daysFromNow: 2),
            isCompleted: true,
            priority: 0,
            creationDate: Date()
        ))
        return store
    }

    @Test
    func `Search filters by query substring`() async throws {
        let gateway = ProductionRemindersGateway(store: Self.seededStore())
        let hits = try await gateway.search(query: "oat MILK", listNames: nil, includeCompleted: false, since: nil, until: nil, limit: 20)
        #expect(hits.count == 1)
        #expect(hits.first?.id == "r-milk")
    }

    @Test
    func `IncludeCompleted toggles completed rows`() async throws {
        let gateway = ProductionRemindersGateway(store: Self.seededStore())
        let openOnly = try await gateway.search(query: "milk", listNames: nil, includeCompleted: false, since: nil, until: nil, limit: 20)
        #expect(openOnly.count == 1)
        #expect(openOnly.allSatisfy { !$0.isCompleted })
        let withDone = try await gateway.search(query: "milk", listNames: nil, includeCompleted: true, since: nil, until: nil, limit: 20)
        #expect(withDone.count == 2)
    }

    @Test
    func `Denied store yields permissionDenied naming Reminders settings`() async {
        let store = Self.seededStore()
        store.authorization = .denied
        store.requestResult = false
        let gateway = ProductionRemindersGateway(store: store)
        do {
            _ = try await gateway.search(query: nil, listNames: nil, includeCompleted: false, since: nil, until: nil, limit: 20)
            Issue.record("Denied search should throw permissionDenied.")
        } catch let error as ReminderToolError {
            guard case .permissionDenied = error else {
                Issue.record("Expected permissionDenied, got \(error).")
                return
            }
            #expect(error.errorDescription?.contains("System Settings") == true)
            #expect(error.errorDescription?.contains("Reminders") == true)
        } catch {
            Issue.record("Unexpected error: \(error).")
        }
    }

    @Test
    func `Create rejects empty title before touching the store`() async {
        let gateway = ProductionRemindersGateway(store: Self.seededStore())
        await #expect(throws: ReminderToolError.emptyTitle) {
            try await gateway.create(title: "   ", notes: nil, due: nil, listName: nil, priority: nil)
        }
    }

    @Test
    func `Create and search round-trip`() async throws {
        let gateway = ProductionRemindersGateway(store: MockReminderEventKitStore())
        let created = try await gateway.create(title: "File taxes", notes: "Before April", due: nil, listName: "Work", priority: 1)
        #expect(created.title == "File taxes")
        #expect(created.listName == "Work")
        #expect(created.isCompleted == false)
        let hits = try await gateway.search(query: "taxes", listNames: nil, includeCompleted: false, since: nil, until: nil, limit: 20)
        #expect(hits.count == 1)
        #expect(hits.first?.id == created.id)
    }

    @Test
    func `Update completion closes and reopens`() async throws {
        let gateway = ProductionRemindersGateway(store: MockReminderEventKitStore())
        let created = try await gateway.create(title: "Water plants", notes: nil, due: nil, listName: nil, priority: nil)
        let done = try await gateway.update(
            reminderID: created.id,
            patch: ReminderUpdatePatch(completed: true)
        )
        #expect(done.isCompleted == true)
        let reopened = try await gateway.update(
            reminderID: created.id,
            patch: ReminderUpdatePatch(completed: false)
        )
        #expect(reopened.isCompleted == false)
    }

    @Test
    func `Unknown identifier yields notFound`() async {
        let gateway = ProductionRemindersGateway(store: MockReminderEventKitStore())
        await #expect(throws: ReminderToolError.notFound("missing-id")) {
            try await gateway.update(
                reminderID: "missing-id",
                patch: ReminderUpdatePatch(title: "New")
            )
        }
        await #expect(throws: ReminderToolError.notFound("missing-id")) {
            try await gateway.delete(reminderID: "missing-id")
        }
    }

    @Test
    func `Delete removes the reminder`() async throws {
        let store = MockReminderEventKitStore()
        let gateway = ProductionRemindersGateway(store: store)
        let created = try await gateway.create(title: "Temporary", notes: nil, due: nil, listName: nil, priority: nil)
        try await gateway.delete(reminderID: created.id)
        let hits = try await gateway.search(query: "Temporary", listNames: nil, includeCompleted: true, since: nil, until: nil, limit: 20)
        #expect(hits.isEmpty)
    }

    @Test
    func `Search clamps limit to 1 through 50`() async throws {
        let gateway = ProductionRemindersGateway(store: Self.seededStore())
        let floored = try await gateway.search(query: nil, listNames: nil, includeCompleted: true, since: nil, until: nil, limit: 0)
        #expect(floored.count == 1)
        let capped = try await gateway.search(query: nil, listNames: nil, includeCompleted: true, since: nil, until: nil, limit: 500)
        #expect(capped.count == 3)
    }

    @Test
    func `Due-first ordering puts undated last`() async throws {
        let gateway = ProductionRemindersGateway(store: Self.seededStore())
        let hits = try await gateway.search(query: nil, listNames: nil, includeCompleted: false, since: nil, until: nil, limit: 20)
        #expect(hits.count == 2)
        #expect(hits.first?.id == "r-milk")
        #expect(hits.last?.id == "r-mom")
    }
}
