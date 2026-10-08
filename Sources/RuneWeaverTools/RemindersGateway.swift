// Rune Weaver Tools — Reminders gateway models and production implementation.
//
// Purpose: EventKit-backed reminders persistence with fail-closed validation and verbatim ID lookup.
// Scope: RemindersGateway plus ReminderStore seam plus reminder value types; no ToolBus surface.
// Architectural role: single persistence owner behind RemindersGateway, mirroring MessagesGateway per-domain seam.

import Foundation
import os
import RuneWeaverCore
#if canImport(EventKit)
    import EventKit
#endif

// MARK: - Models

/// One reminder row returned by search or mutation.
public struct ReminderItem: Codable, Sendable, Equatable {
    /// Opaque EventKit identifier, passed verbatim and never parsed.
    public let id: String
    /// Owning list title.
    public let listName: String
    /// Owning source title (for example iCloud or Local).
    public let sourceTitle: String
    /// Reminder title.
    public let title: String
    /// Optional notes.
    public let notes: String?
    /// ISO8601 due instant, or nil when undated.
    public let dueDateISO: String?
    /// True when completed.
    public let isCompleted: Bool
    /// EventKit priority (0 none through 9).
    public let priority: Int
    /// ISO8601 creation instant, or nil when unknown.
    public let creationDateISO: String?

    public init(
        id: String,
        listName: String,
        sourceTitle: String,
        title: String,
        notes: String? = nil,
        dueDateISO: String? = nil,
        isCompleted: Bool = false,
        priority: Int = 0,
        creationDateISO: String? = nil
    ) {
        self.id = id
        self.listName = listName
        self.sourceTitle = sourceTitle
        self.title = title
        self.notes = notes
        self.dueDateISO = dueDateISO
        self.isCompleted = isCompleted
        self.priority = priority
        self.creationDateISO = creationDateISO
    }
}

// MARK: - Errors

/// Fail-closed errors for reminder operations.
public enum ReminderToolError: Error, Sendable, Equatable, LocalizedError {
    case emptyTitle
    case invalidInput(String)
    case permissionDenied(String)
    case storeUnavailable(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .emptyTitle:
            "Reminder title cannot be empty."
        case let .invalidInput(detail):
            "Invalid reminder input: \(detail)"
        case let .permissionDenied(detail):
            "Reminders access was denied: \(detail) Grant access in System Settings > Privacy & Security > Reminders."
        case let .storeUnavailable(detail):
            "The reminders store is unavailable: \(detail)"
        case let .notFound(identifier):
            "Reminder '\(identifier)' was not found."
        }
    }
}

// MARK: - Reminder values and per-domain store seam

// CalendarStore lives in CalendarGateway.swift and ReminderStore lives here so
// each gateway depends on its own per-domain seam. EventKitStore composes both
// so one live EKEventStore (LiveEventKitStore) backs both without duplication.

/// Authorization state for reminder access.
public enum EventKitReminderAuthorization: Sendable, Equatable {
    case authorized
    case denied
    case restricted
    case notDetermined
}

/// A reminder list (EventKit reminder calendar).
public struct EventKitReminderCalendar: Sendable, Equatable {
    /// Opaque calendar identifier.
    public let identifier: String
    /// List title shown to the owner.
    public let title: String
    /// Owning source title.
    public let sourceTitle: String

    public init(identifier: String, title: String, sourceTitle: String = "") {
        self.identifier = identifier
        self.title = title
        self.sourceTitle = sourceTitle
    }
}

/// A reminder value crossing the EventKit seam.
public struct EventKitReminder: Sendable, Equatable {
    public var identifier: String
    public var calendarIdentifier: String
    public var title: String
    public var notes: String?
    public var dueDate: Date?
    public var isCompleted: Bool
    public var priority: Int
    public var creationDate: Date?

    public init(
        identifier: String,
        calendarIdentifier: String,
        title: String,
        notes: String? = nil,
        dueDate: Date? = nil,
        isCompleted: Bool = false,
        priority: Int = 0,
        creationDate: Date? = nil
    ) {
        self.identifier = identifier
        self.calendarIdentifier = calendarIdentifier
        self.title = title
        self.notes = notes
        self.dueDate = dueDate
        self.isCompleted = isCompleted
        self.priority = priority
        self.creationDate = creationDate
    }
}

/// Which half of the reminder set one callback fetch covers.
///
/// EventKit offers no server-side date predicate for reminders, so `start`
/// and `end` narrow due dates in memory inside the store; the gateway then
/// applies the final window plus undated rule over the narrowed rows.
public struct EventKitReminderPredicate: Sendable, Equatable {
    /// False fetches incomplete reminders, true fetches completed ones.
    public let fetchCompleted: Bool
    /// Inclusive lower due bound applied in memory, or nil for unbounded below.
    public let start: Date?
    /// Exclusive upper due bound applied in memory, or nil for unbounded above.
    public let end: Date?
    /// Calendars to search.
    public let calendars: [EventKitReminderCalendar]

    public init(fetchCompleted: Bool, start: Date?, end: Date?, calendars: [EventKitReminderCalendar]) {
        self.fetchCompleted = fetchCompleted
        self.start = start
        self.end = end
        self.calendars = calendars
    }
}

/// Per-domain reminder view of the system event store so tests inject a mock.
///
/// Covers reminder access only; CalendarStore (owned by CalendarGateway.swift)
/// covers calendar access. Implementations read lists live per call, never cached.
public protocol ReminderStore: Sendable {
    /// Current reminder authorization, checked per call.
    func reminderAuthorizationStatus() -> EventKitReminderAuthorization
    /// Explicit consent prompt reserved for the owner-driven enable path.
    ///
    /// Gateways never call this; they only read `reminderAuthorizationStatus()`
    /// and fail closed. The method stays so the live store retains the prompting
    /// capability behind `PermissionProbes.request`, and so mocks can stand in
    /// for that path in tests without involving EventKit prompts.
    func requestReminderAccess() async throws -> Bool
    /// Lists reminder calendars live, never cached.
    func reminderCalendars() throws -> [EventKitReminderCalendar]
    /// Callback fetch mirroring the EventKit completion API.
    ///
    /// Date bounds narrow due dates in memory because EventKit has no
    /// server-side date predicate; undated rows pass through and the gateway
    /// decides whether the query keeps them.
    func fetchReminders(
        matching predicate: EventKitReminderPredicate,
        completion: @escaping @Sendable ([EventKitReminder]?) -> Void
    )
    /// Returns the reminder with an opaque identifier verbatim, or nil on a miss.
    func reminder(withIdentifier identifier: String) -> EventKitReminder?
    /// Upserts a reminder and returns the persisted record.
    ///
    /// The returned value carries the store-assigned identifier, so callers
    /// use it for follow-up update and delete instead of the draft identifier.
    func save(_ reminder: EventKitReminder) throws -> EventKitReminder
    /// Removes a reminder by identifier verbatim.
    func removeReminder(withIdentifier identifier: String) throws
}

// MARK: - Update patch (keeps update within the 6-parameter lint budget)

/// Bundled editable fields for one reminder update.
///
/// Nil means preserve the stored value; a non-nil value replaces it after
/// validation. Notes follows the gateway convention where an empty string
/// clears to nil via validation, so a single optional preserves the
/// preserve-versus-replace distinction without double optionals.
public struct ReminderUpdatePatch: Sendable, Equatable {
    public var title: String?
    public var notes: String?
    public var due: Date?
    public var listName: String?
    public var priority: Int?
    public var completed: Bool?

    public init(
        title: String? = nil,
        notes: String? = nil,
        due: Date? = nil,
        listName: String? = nil,
        priority: Int? = nil,
        completed: Bool? = nil
    ) {
        self.title = title
        self.notes = notes
        self.due = due
        self.listName = listName
        self.priority = priority
        self.completed = completed
    }
}

// MARK: - Gateway protocol

/// Single owner of all Reminders persistence.
public protocol RemindersGateway: Sendable {
    /// Searches reminders. The only reader.
    func search(
        query: String?,
        listNames: [String]?,
        includeCompleted: Bool,
        since: Date?,
        until: Date?,
        limit: Int
    ) async throws -> [ReminderItem]
    /// Verbatim ID fetch-one mirroring calendar.search eventID.
    /// Takes a bundled range (mirroring the Email bridge `range` pattern)
    /// so the 7-field query stays within the 6-parameter lint budget.
    func search(
        query: String?,
        reminderID: String?,
        listNames: [String]?,
        includeCompleted: Bool,
        range: TemporalRange,
        limit: Int
    ) async throws -> [ReminderItem]
    /// Creates one reminder. The only creator.
    func create(
        title: String,
        notes: String?,
        due: Date?,
        listName: String?,
        priority: Int?
    ) async throws -> ReminderItem
    /// Mutates one reminder, including completion. The only mutator.
    func update(
        reminderID: String,
        patch: ReminderUpdatePatch
    ) async throws -> ReminderItem
    /// Removes one reminder. Owns removal.
    func delete(reminderID: String) async throws
}

extension RemindersGateway {
    /// Best-effort ID fetch-one for conformers without verbatim store access.
    ///
    /// Delegates to the filtered search capped at the gateway maximum and narrows
    /// to the verbatim identifier, so a reminder beyond the cap honestly reports
    /// not-found through this fallback. Production overrides this with a verbatim
    /// `reminder(withIdentifier:)` lookup that never truncates, and test doubles
    /// keep this path only until they implement the verbatim overload directly.
    public func search(
        query: String?,
        reminderID: String?,
        listNames: [String]?,
        includeCompleted: Bool,
        range: TemporalRange,
        limit: Int
    ) async throws -> [ReminderItem] {
        guard let reminderID else {
            return try await search(
                query: query,
                listNames: listNames,
                includeCompleted: includeCompleted,
                since: range.since,
                until: range.until,
                limit: limit
            )
        }
        let candidates = try await search(
            query: query,
            listNames: listNames,
            includeCompleted: true,
            since: range.since,
            until: range.until,
            limit: ProductionRemindersGateway.maxLimit
        )
        guard let found = candidates.first(where: { $0.id == reminderID }) else {
            throw ReminderToolError.notFound(reminderID)
        }
        if !includeCompleted, found.isCompleted {
            throw ReminderToolError.notFound(reminderID)
        }
        return [found]
    }
}

// MARK: - Production gateway

/// Production reminders gateway over the per-domain ReminderStore seam.
public struct ProductionRemindersGateway: RemindersGateway, Sendable {
    public static let defaultLimit = 20
    public static let minLimit = 1
    public static let maxLimit = 50
    /// Callback-fetch timeout so a never-calling store cannot hang a tool forever.
    public static let fetchTimeoutSeconds: TimeInterval = 15

    /// Backing store, injected so tests use a mock.
    public let store: any ReminderStore

    public init(store: any ReminderStore) {
        self.store = store
    }

    public func search(
        query: String?,
        listNames: [String]?,
        includeCompleted: Bool,
        since: Date?,
        until: Date?,
        limit: Int
    ) async throws -> [ReminderItem] {
        try await search(
            query: query,
            reminderID: nil,
            listNames: listNames,
            includeCompleted: includeCompleted,
            range: TemporalRange(since: since, until: until),
            limit: limit
        )
    }

    public func search(
        query: String?,
        reminderID: String?,
        listNames: [String]?,
        includeCompleted: Bool,
        range: TemporalRange,
        limit: Int
    ) async throws -> [ReminderItem] {
        try ensureReminderAccess()
        let capped = Self.clampedLimit(limit)
        let calendars = try liveCalendars()
        let scoped = try Self.scopedCalendars(calendars, listNames: listNames)
        if listNames != nil, scoped.isEmpty {
            // Unknown list names yield an honest empty result rather than an
            // error, so a filter naming no live list simply matches nothing.
            return []
        }
        guard !scoped.isEmpty else {
            return []
        }
        // Opaque identifiers resolve verbatim outside the window, so a direct
        // lookup still finds a reminder the windowed fetch would miss.
        if let reminderID {
            return try lookupReminderByIdentifier(
                reminderID,
                scoped: scoped,
                includeCompleted: includeCompleted,
                range: range,
                query: query,
                capped: capped
            )
        }
        let (fetchStart, fetchEnd) = try Self.effectiveWindow(since: range.since, until: range.until)
        let incomplete = try await bridgedFetch(fetchCompleted: false, start: fetchStart, end: fetchEnd, calendars: scoped)
        var combined = incomplete
        if includeCompleted {
            let completed = try await bridgedFetch(fetchCompleted: true, start: fetchStart, end: fetchEnd, calendars: scoped)
            combined.append(contentsOf: completed)
        }
        let visible = includeCompleted ? combined : combined.filter { !$0.isCompleted }
        // Shared default window with calendar.search; undated reminders stay
        // visible only for an unbounded query, while dated rows must fall inside.
        let effectiveRange = TemporalRange(since: fetchStart, until: fetchEnd)
        let isUnboundedQuery = range.isUnbounded
        let dated = visible.filter {
            guard let due = $0.dueDate else { return isUnboundedQuery }
            return effectiveRange.contains(due)
        }
        let queried = Self.appliedQuery(dated, query: query)
        // First wins on duplicate identifiers so a duplicated store row can
        // never trap the lookup map.
        let byCalendar = Dictionary(scoped.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        let items = queried.map { Self.makeItem($0, calendarsByID: byCalendar) }
        return Array(Self.sortedDueFirst(items, backing: queried).prefix(capped))
    }

    public func create(
        title: String,
        notes: String? = nil,
        due: Date? = nil,
        listName: String? = nil,
        priority: Int? = nil
    ) async throws -> ReminderItem {
        let cleanTitle = try Self.validatedTitle(title)
        let cleanNotes = try Self.validatedNotes(notes)
        let cleanPriority = try Self.validatedPriority(priority)
        try ensureReminderAccess()
        let calendars = try liveCalendars()
        guard !calendars.isEmpty else {
            throw ReminderToolError.storeUnavailable("No reminder lists are available.")
        }
        let target = try Self.resolveCalendar(calendars, listName: listName)
        let now = Date()
        let record = EventKitReminder(
            identifier: "",
            calendarIdentifier: target.identifier,
            title: cleanTitle,
            notes: cleanNotes,
            dueDate: due,
            isCompleted: false,
            priority: cleanPriority,
            creationDate: now
        )
        let persisted: EventKitReminder
        do {
            persisted = try store.save(record)
        } catch let error as ReminderToolError {
            throw error
        } catch {
            throw ReminderToolError.storeUnavailable(error.localizedDescription)
        }
        let calendarsByID = Dictionary(calendars.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        let resolvedCalendar = calendarsByID[persisted.calendarIdentifier] ?? target
        return Self.makeItem(persisted, calendar: resolvedCalendar)
    }

    public func update(
        reminderID: String,
        patch: ReminderUpdatePatch
    ) async throws -> ReminderItem {
        guard !reminderID.isEmpty else {
            throw ReminderToolError.notFound(reminderID)
        }
        try ensureReminderAccess()
        guard var existing = store.reminder(withIdentifier: reminderID) else {
            throw ReminderToolError.notFound(reminderID)
        }
        if let title = patch.title {
            existing.title = try Self.validatedTitle(title)
        }
        if patch.notes != nil {
            existing.notes = try Self.validatedNotes(patch.notes)
        }
        // Nil preserves the current due date; clearing uses a future explicit affordance.
        if let due = patch.due {
            existing.dueDate = due
        }
        if let listName = patch.listName {
            try TemporalFilter.gatewayCheckedName(listName, label: "List name") {
                ReminderToolError.invalidInput($0)
            }
            if !listName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let calendars = try liveCalendars()
                existing.calendarIdentifier = try Self.resolveCalendar(calendars, listName: listName).identifier
            }
        }
        if let priority = patch.priority {
            existing.priority = try Self.validatedPriority(priority)
        }
        if let completed = patch.completed {
            existing.isCompleted = completed
        }
        let persisted: EventKitReminder
        do {
            persisted = try store.save(existing)
        } catch let error as ReminderToolError {
            throw error
        } catch {
            throw ReminderToolError.storeUnavailable(error.localizedDescription)
        }
        let calendars: [EventKitReminderCalendar]
        do {
            calendars = try store.reminderCalendars()
        } catch {
            RuneWeaverLog.tools.debug("RemindersGateway: failed to fetch reminder calendars: \(error.localizedDescription)")
            calendars = []
        }
        let calendar = calendars.first { $0.identifier == persisted.calendarIdentifier }
            ?? EventKitReminderCalendar(identifier: persisted.calendarIdentifier, title: persisted.calendarIdentifier)
        return Self.makeItem(persisted, calendar: calendar)
    }

    public func delete(reminderID: String) async throws {
        guard !reminderID.isEmpty else {
            throw ReminderToolError.notFound(reminderID)
        }
        try ensureReminderAccess()
        guard store.reminder(withIdentifier: reminderID) != nil else {
            throw ReminderToolError.notFound(reminderID)
        }
        do {
            try store.removeReminder(withIdentifier: reminderID)
        } catch let error as ReminderToolError {
            throw error
        } catch {
            throw ReminderToolError.storeUnavailable(error.localizedDescription)
        }
    }
}

// MARK: - Production gateway private helpers

/// Private helpers live in an extension so the main type body stays within
/// the 350-line lint budget; behavior is unchanged.
extension ProductionRemindersGateway {
    /// Fails closed unless reminder access is currently authorized.
    ///
    /// Tools and background work never initiate prompts; only the explicit
    /// PermissionProbes.request path prompts. Fail closed on notDetermined.
    private func ensureReminderAccess() throws {
        guard store.reminderAuthorizationStatus() == .authorized else {
            throw ReminderToolError.permissionDenied("Access has not been granted.")
        }
    }

    /// Reads reminder lists live per call, mapping failures to storeUnavailable.
    private func liveCalendars() throws -> [EventKitReminderCalendar] {
        do {
            return try store.reminderCalendars()
        } catch let error as ReminderToolError {
            throw error
        } catch {
            throw ReminderToolError.storeUnavailable(error.localizedDescription)
        }
    }

    /// Sole bridge for the callback fetch; no other continuation exists here.
    ///
    /// A never-calling store cannot hang a tool forever: the first completion
    /// wins and a timeout fails closed. A double-calling store cannot trap:
    /// only the first completion resumes. The timeout task is cancelled as
    /// soon as the fetch completes so no 15-second task outlives success.
    private func bridgedFetch(
        fetchCompleted: Bool,
        start: Date?,
        end: Date?,
        calendars: [EventKitReminderCalendar]
    ) async throws -> [EventKitReminder] {
        let predicate = EventKitReminderPredicate(
            fetchCompleted: fetchCompleted,
            start: start,
            end: end,
            calendars: calendars
        )
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[EventKitReminder], Error>) in
            let guardBox = FetchResumeGuard()
            let timeoutTask = Task {
                do {
                    try await Task.sleep(nanoseconds: UInt64(Self.fetchTimeoutSeconds * 1_000_000_000))
                } catch {
                    return
                }
                guardBox.resumeOnce(
                    .failure(ReminderToolError.storeUnavailable("Reminder fetch timed out.")),
                    continuation: continuation
                )
            }
            store.fetchReminders(matching: predicate) { reminders in
                timeoutTask.cancel()
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

    /// Verbatim ID fetch-one mirroring calendar.search eventID.
    /// Takes a bundled range so the lookup stays within the 6-parameter budget.
    private func lookupReminderByIdentifier(
        _ reminderID: String,
        scoped: [EventKitReminderCalendar],
        includeCompleted: Bool,
        range: TemporalRange,
        query: String?,
        capped: Int
    ) throws -> [ReminderItem] {
        guard let stored = store.reminder(withIdentifier: reminderID) else {
            throw ReminderToolError.notFound(reminderID)
        }
        let scopedIDs = Set(scoped.map(\.identifier))
        guard scopedIDs.contains(stored.calendarIdentifier) else {
            throw ReminderToolError.notFound(reminderID)
        }
        if !includeCompleted, stored.isCompleted {
            throw ReminderToolError.notFound(reminderID)
        }
        // Undated matches only an unbounded query; dated must fall inside.
        if let due = stored.dueDate {
            guard range.contains(due) else { throw ReminderToolError.notFound(reminderID) }
        } else if !range.isUnbounded {
            throw ReminderToolError.notFound(reminderID)
        }
        let matchesQuery = Self.appliedQuery([stored], query: query)
        guard !matchesQuery.isEmpty else { throw ReminderToolError.notFound(reminderID) }
        // First wins on duplicate identifiers so a duplicated store row can
        // never trap the lookup map.
        let byCalendar = Dictionary(scoped.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        let item = Self.makeItem(stored, calendarsByID: byCalendar)
        return Array([item].prefix(capped))
    }

    private static func clampedLimit(_ limit: Int) -> Int {
        min(max(limit, minLimit), maxLimit)
    }

    private static func scopedCalendars(
        _ calendars: [EventKitReminderCalendar],
        listNames: [String]?
    ) throws -> [EventKitReminderCalendar] {
        let rawNames = listNames ?? []
        for name in rawNames {
            try TemporalFilter.gatewayCheckedName(name, label: "List name") {
                ReminderToolError.invalidInput($0)
            }
        }
        let wanted = rawNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !wanted.isEmpty else {
            return calendars
        }
        let lowered = Set(wanted.map { $0.lowercased() })
        return calendars.filter { lowered.contains($0.title.lowercased()) }
    }

    private static func resolveCalendar(
        _ calendars: [EventKitReminderCalendar],
        listName: String?
    ) throws -> EventKitReminderCalendar {
        if let listName {
            try TemporalFilter.gatewayCheckedName(listName, label: "List name") {
                ReminderToolError.invalidInput($0)
            }
        }
        let trimmed = listName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            guard let first = calendars.first else {
                throw ReminderToolError.storeUnavailable("No reminder lists are available.")
            }
            return first
        }
        // Null bytes never match: rejected above, this stays defensive so a
        // truncated comparison can never select the wrong list.
        guard !trimmed.contains("\0") else {
            throw ReminderToolError.invalidInput("List name must not contain null bytes.")
        }
        if let match = calendars.first(where: { $0.title.lowercased() == trimmed.lowercased() }) {
            return match
        }
        throw ReminderToolError.invalidInput("Unknown reminder list '\(trimmed)'.")
    }

    /// Case-insensitive substring on title plus notes; blank or "*" matches all.
    private static func appliedQuery(_ reminders: [EventKitReminder], query: String?) -> [EventKitReminder] {
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, trimmed != "*" else {
            return reminders
        }
        return reminders.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed)
                || ($0.notes?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    /// Due-first with undated last, tie-broken by creation then title.
    private static func sortedDueFirst(_ items: [ReminderItem], backing: [EventKitReminder]) -> [ReminderItem] {
        let paired = zip(items, backing).sorted { lhs, rhs in
            switch (lhs.1.dueDate, rhs.1.dueDate) {
            case (nil, nil):
                break
            case (nil, _):
                return false
            case (_, nil):
                return true
            case let (leftDue?, rightDue?):
                if leftDue != rightDue {
                    return leftDue < rightDue
                }
            }
            switch (lhs.1.creationDate, rhs.1.creationDate) {
            case let (leftCreated?, rightCreated?) where leftCreated != rightCreated:
                return leftCreated < rightCreated
            default:
                return lhs.1.title.localizedCaseInsensitiveCompare(rhs.1.title) == .orderedAscending
            }
        }
        return paired.map(\.0)
    }

    private static func validatedTitle(_ raw: String) throws -> String {
        try TemporalFilter.gatewayValidatedTitle(raw, maxChars: TemporalFilter.gatewayMaxTitleChars) {
            ReminderToolError.emptyTitle
        } invalid: {
            ReminderToolError.invalidInput($0)
        }
    }

    private static func validatedNotes(_ raw: String?) throws -> String? {
        try TemporalFilter.gatewayValidatedNotes(raw, maxChars: TemporalFilter.gatewayMaxNotesChars) {
            ReminderToolError.invalidInput($0)
        }
    }

    private static func validatedPriority(_ raw: Int?) throws -> Int {
        guard let raw else {
            return 0
        }
        guard (0 ... 9).contains(raw) else {
            throw ReminderToolError.invalidInput("Priority must be 0 through 9.")
        }
        return raw
    }

    /// Shared fetch window with calendar.search, owned by TemporalFilter in Core.
    private static func effectiveWindow(since: Date?, until: Date?, now: Date = Date()) throws -> (Date, Date) {
        // Single window owner lives in Core over defaultPastDays/defaultFutureDays;
        // the Core inverted-range failure maps to the domain invalid-input copy.
        do {
            return try TemporalFilter.effectiveWindow(since: since, until: until, now: now)
        } catch {
            throw ReminderToolError.invalidInput("Since must not be after until.")
        }
    }

    private static func isoString(_ date: Date) -> String {
        TemporalFilter.isoString(from: date)
    }

    private static func makeItem(_ record: EventKitReminder, calendar: EventKitReminderCalendar) -> ReminderItem {
        ReminderItem(
            id: record.identifier,
            listName: calendar.title,
            sourceTitle: calendar.sourceTitle,
            title: record.title,
            notes: record.notes,
            dueDateISO: record.dueDate.map(isoString),
            isCompleted: record.isCompleted,
            priority: record.priority,
            creationDateISO: record.creationDate.map(isoString)
        )
    }

    private static func makeItem(
        _ record: EventKitReminder,
        calendarsByID: [String: EventKitReminderCalendar]
    ) -> ReminderItem {
        let calendar = calendarsByID[record.calendarIdentifier]
            ?? EventKitReminderCalendar(identifier: record.calendarIdentifier, title: record.calendarIdentifier)
        return makeItem(record, calendar: calendar)
    }
}

/// Exactly-once guard for the callback bridge.
///
/// The store must call its completion exactly once, but a buggy store could
/// call twice (trapping on second resume) or never (hanging the tool). The
/// timeout and the fetch race through this guard so only the first wins.
private final class FetchResumeGuard: Sendable {
    private let didResume = OSAllocatedUnfairLock(initialState: false)

    func resumeOnce(
        _ result: Result<[EventKitReminder], Error>,
        continuation: CheckedContinuation<[EventKitReminder], Error>
    ) {
        let shouldResume = didResume.withLock { resumed -> Bool in
            guard !resumed else { return false }
            resumed = true
            return true
        }
        guard shouldResume else { return }
        switch result {
        case let .success(value):
            continuation.resume(returning: value)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}
