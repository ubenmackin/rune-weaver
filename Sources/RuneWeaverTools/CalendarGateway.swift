// Rune Weaver Tools — Calendar EventKit gateway and persistence owner.
//
// Purpose: EventKit-backed calendar persistence with fail-closed validation and verbatim ID lookup.
// Scope: CalendarGateway plus CalendarStore seam plus live EKEventStore wrapper; no ToolBus surface.
// Architectural role: single persistence owner behind CalendarGateway, mirroring MessagesGateway per-domain seam.

import Foundation
import RuneWeaverCore
#if canImport(EventKit)
    import EventKit
#endif

// MARK: - Item

/// One calendar event returned by search or mutation.
public struct CalendarEventItem: Codable, Sendable, Equatable {
    public let id: String
    public let calendarName: String?
    public let sourceTitle: String?
    public let title: String
    public let notes: String?
    public let startDateISO: String?
    public let endDateISO: String?
    public let startDisplay: String
    public let endDisplay: String
    public let isAllDay: Bool
    public let location: String?
    public let hasRecurrence: Bool

    public init(
        id: String,
        calendarName: String? = nil,
        sourceTitle: String? = nil,
        title: String,
        notes: String? = nil,
        startDateISO: String? = nil,
        endDateISO: String? = nil,
        startDisplay: String,
        endDisplay: String,
        isAllDay: Bool = false,
        location: String? = nil,
        hasRecurrence: Bool = false
    ) {
        self.id = id
        self.calendarName = calendarName
        self.sourceTitle = sourceTitle
        self.title = title
        self.notes = notes
        self.startDateISO = startDateISO
        self.endDateISO = endDateISO
        self.startDisplay = startDisplay
        self.endDisplay = endDisplay
        self.isAllDay = isAllDay
        self.location = location
        self.hasRecurrence = hasRecurrence
    }
}

/// Device-timezone display strings for event items.
public enum CalendarEventDisplay: Sendable {
    public static func string(
        for date: Date?,
        isoFallback: String?,
        isAllDay: Bool,
        timeZone: TimeZone = .current
    ) -> String {
        guard let date else { return isoFallback ?? "" }
        let formatted = isAllDay
            ? dateOnlyString(from: date, timeZone: timeZone)
            : timedString(from: date, timeZone: timeZone)
        // DateFormatter returns empty on failure, so fall back to ISO rather than surfacing blank.
        guard !formatted.isEmpty else { return isoFallback ?? "" }
        return formatted
    }

    public static func timedString(from date: Date, timeZone: TimeZone = .current) -> String {
        // Fresh formatter per call keeps Swift 6 concurrency safe without shared locking.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE, MMM d, yyyy h:mm a zzz"
        return formatter.string(from: date)
    }

    public static func dateOnlyString(from date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE, MMM d, yyyy"
        return formatter.string(from: date)
    }
}

// MARK: - Errors

/// Owner-facing calendar failures.
public enum CalendarToolError: Error, Sendable, Equatable, LocalizedError {
    case emptyTitle
    case invalidInput(String)
    case permissionDenied(String)
    case storeUnavailable(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .emptyTitle:
            "Event title cannot be empty."
        case let .invalidInput(detail):
            "Invalid calendar input: \(detail)"
        case let .permissionDenied(detail):
            "Calendar access was denied: \(detail) Grant access in System Settings > Privacy & Security > Calendars."
        case let .storeUnavailable(detail):
            "The calendar store is unavailable: \(detail)"
        case let .notFound(detail):
            "Calendar event not found: \(detail)"
        }
    }
}

// MARK: - Shared gateway temporal and text validation

/// Shared calendar/reminders gateway text validation owned by the TemporalFilter contract.
///
/// The fetch window lives in RuneWeaverCore as `TemporalFilter.effectiveWindow`
/// over `defaultPastDays`/`defaultFutureDays`; gateways call it directly and map
/// the inverted-range failure to their domain error so messages stay identical
/// while error types stay per-domain. Title/notes length plus null-byte checks
/// stay centralized here so owner-facing copy and fail-closed rejection have
/// one owner.
extension TemporalFilter {
    /// Owner-facing title bound shared by both gateways and their tools.
    static let gatewayMaxTitleChars = 300
    /// Owner-facing notes bound shared by both gateways and their tools.
    static let gatewayMaxNotesChars = 8000

    /// Shared title validation: rejects null bytes before trimming so an
    /// embedded null can never truncate the stored string, then enforces
    /// non-blank and length bounds with unified owner copy.
    static func gatewayValidatedTitle<Failure: Error>(
        _ raw: String,
        maxChars: Int = gatewayMaxTitleChars,
        empty: () -> Failure,
        invalid: (String) -> Failure
    ) throws -> String {
        guard !raw.contains("\0") else {
            throw invalid("Title must not contain null bytes.")
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw empty() }
        guard trimmed.count <= maxChars else {
            throw invalid("Title must be \(maxChars) characters or fewer.")
        }
        return trimmed
    }

    /// Shared notes validation: nil preserves, empty clears to nil, otherwise
    /// rejects null bytes and enforces the length bound with unified copy.
    static func gatewayValidatedNotes(
        _ raw: String?,
        maxChars: Int = gatewayMaxNotesChars,
        invalid: (String) -> some Error
    ) throws -> String? {
        guard let raw else { return nil }
        guard !raw.contains("\0") else {
            throw invalid("Notes must not contain null bytes.")
        }
        guard raw.count <= maxChars else {
            throw invalid("Notes must be \(maxChars) characters or fewer.")
        }
        return raw.isEmpty ? nil : raw
    }

    /// Rejects null bytes in a free-form name field before trimming.
    ///
    /// Nulls truncate the underlying store string, so calendar, list, and
    /// location names fail closed with a field-named message rather than
    /// matching or persisting a truncated value.
    @discardableResult
    static func gatewayCheckedName(
        _ raw: String,
        label: String,
        invalid: (String) -> some Error
    ) throws -> String {
        guard !raw.contains("\0") else {
            throw invalid("\(label) must not contain null bytes.")
        }
        return raw
    }
}

// MARK: - Store Seam

/// Authorization state observed per call, never cached.
public enum CalendarAuthorizationStatus: Sendable, Equatable {
    case authorized
    case denied
    case restricted
    case notDetermined
}

/// One calendar listed live per call.
public struct StoreCalendar: Sendable, Equatable {
    public let identifier: String
    public let title: String
    public let sourceTitle: String?

    public init(identifier: String, title: String, sourceTitle: String? = nil) {
        self.identifier = identifier
        self.title = title
        self.sourceTitle = sourceTitle
    }
}

/// Mutable event record exchanged with the store.
public struct StoreEvent: Sendable, Equatable {
    public var identifier: String?
    public var calendarIdentifier: String?
    public var title: String?
    public var notes: String?
    public var startDate: Date?
    public var endDate: Date?
    public var isAllDay: Bool
    public var location: String?
    public var hasRecurrence: Bool

    public init(
        identifier: String? = nil,
        calendarIdentifier: String? = nil,
        title: String? = nil,
        notes: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        isAllDay: Bool = false,
        location: String? = nil,
        hasRecurrence: Bool = false
    ) {
        self.identifier = identifier
        self.calendarIdentifier = calendarIdentifier
        self.title = title
        self.notes = notes
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.location = location
        self.hasRecurrence = hasRecurrence
    }
}

/// Fetch window passed to the store, mirroring the predicate call.
public struct CalendarFetchPredicate: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public let calendars: [StoreCalendar]

    public init(start: Date, end: Date, calendars: [StoreCalendar]) {
        self.start = start
        self.end = end
        self.calendars = calendars
    }
}

/// Recurrence scope for removal.
public enum CalendarSpan: Sendable, Equatable {
    case thisEvent
    case futureEvents
}

/// Per-domain calendar view of the system event store so tests inject a mock.
///
/// The gateway seam stays per domain (CalendarGateway versus RemindersGateway,
/// mirroring MessagesGateway). The store seam is split the same way:
/// CalendarStore covers calendar access only while ReminderStore (owned by
/// RemindersGateway.swift) covers reminders. EventKitStore composes both so one
/// live EKEventStore object can back both gateways without a second abstraction.
/// Implementations read calendars live per call, never cached.
public protocol CalendarStore: Sendable {
    func authorizationStatus() -> CalendarAuthorizationStatus
    /// Explicit consent prompt reserved for the owner-driven enable path.
    ///
    /// Gateways never call this; they only read `authorizationStatus()` and fail
    /// closed. The method stays so the live store retains the prompting
    /// capability behind `PermissionProbes.request`, and so mocks can stand in
    /// for that path in tests without involving EventKit prompts.
    func requestAccess() async throws -> Bool
    func calendars() throws -> [StoreCalendar]
    func predicateForEvents(start: Date, end: Date, calendars: [StoreCalendar]) -> CalendarFetchPredicate
    func events(matching predicate: CalendarFetchPredicate) throws -> [StoreEvent]
    func event(withIdentifier identifier: String) throws -> StoreEvent?
    func save(_ event: StoreEvent) throws -> StoreEvent
    func remove(_ event: StoreEvent, span: CalendarSpan) throws
}

/// Shared composition over both per-domain store seams.
///
/// Exists only so a single live EKEventStore (see LiveEventKitStore) backs both
/// gateways. New code depends on CalendarStore or ReminderStore directly; this
/// composition stays for backward-compatible injection of one object into both.
public protocol EventKitStore: CalendarStore & ReminderStore {}

// MARK: - Create options and update patch (keep create/update within the 6-parameter lint budget)

/// Bundled optional fields for one calendar creation.
///
/// Mirrors `ReminderUpdatePatch`: groups the six optional creation fields so
/// `create(title:options:)` stays at two parameters without a lint suppression.
public struct CalendarCreateOptions: Sendable, Equatable {
    public var notes: String?
    public var start: Date?
    public var end: Date?
    public var isAllDay: Bool
    public var calendarName: String?
    public var location: String?

    public init(
        notes: String? = nil,
        start: Date? = nil,
        end: Date? = nil,
        isAllDay: Bool = false,
        calendarName: String? = nil,
        location: String? = nil
    ) {
        self.notes = notes
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendarName = calendarName
        self.location = location
    }
}

/// Bundled editable fields for one calendar update.
///
/// Nil means preserve the stored value; a non-nil value replaces it after
/// validation, matching the pre-existing per-field semantics.
public struct CalendarUpdatePatch: Sendable, Equatable {
    public var title: String?
    public var notes: String?
    public var start: Date?
    public var end: Date?
    public var calendarName: String?
    public var location: String?

    public init(
        title: String? = nil,
        notes: String? = nil,
        start: Date? = nil,
        end: Date? = nil,
        calendarName: String? = nil,
        location: String? = nil
    ) {
        self.title = title
        self.notes = notes
        self.start = start
        self.end = end
        self.calendarName = calendarName
        self.location = location
    }
}

// MARK: - Gateway

/// Single owner of all calendar persistence.
public protocol CalendarGateway: Sendable {
    func search(
        query: String?,
        eventID: String?,
        calendarNames: [String]?,
        since: Date?,
        until: Date?,
        limit: Int
    ) async throws -> [CalendarEventItem]
    func create(
        title: String,
        options: CalendarCreateOptions
    ) async throws -> CalendarEventItem
    func update(
        eventID: String,
        patch: CalendarUpdatePatch
    ) async throws -> CalendarEventItem
    func delete(eventID: String, span: CalendarSpan) async throws
}

// MARK: - Production Gateway

/// Live gateway reading calendars per call and enforcing shared bounds.
public struct ProductionCalendarGateway: CalendarGateway, Sendable {
    private static let minLimit = 1
    private static let maxLimit = 50

    public let store: any CalendarStore

    public init(store: any CalendarStore) {
        self.store = store
    }

    public func search(
        query: String? = nil,
        eventID: String? = nil,
        calendarNames: [String]? = nil,
        since: Date? = nil,
        until: Date? = nil,
        limit: Int = 20
    ) async throws -> [CalendarEventItem] {
        try await search(
            query: query,
            eventID: eventID,
            calendarNames: calendarNames,
            since: since,
            until: until,
            limit: limit,
            now: Date()
        )
    }

    public func search(
        query: String? = nil,
        eventID: String? = nil,
        calendarNames: [String]? = nil,
        since: Date? = nil,
        until: Date? = nil,
        limit: Int = 20,
        // Injectable so hermetic tests can pin the default window;
        // production callers omit it and read the wall clock.
        now: Date
    ) async throws -> [CalendarEventItem] {
        let capped = min(max(limit, Self.minLimit), Self.maxLimit)
        try ensureAuthorized()
        let all = try liveCalendars()
        let wanted = try normalizedCalendarFilter(calendarNames)
        let targets = resolveSearchTargets(all: all, wanted: wanted)
        // Unknown names yield an honest empty result rather than an error,
        // so a filter naming no live calendar simply matches nothing.
        guard !targets.isEmpty else {
            return []
        }
        // First wins on duplicate identifiers so a duplicated store row can
        // never trap the lookup map.
        let calendarsByID = Dictionary(all.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines)

        // Identifiers are opaque and resolve verbatim outside the window,
        // so a direct lookup still finds an event the window fetch would miss.
        if let eventID {
            return try lookupEventByIdentifier(
                eventID,
                wanted: wanted,
                since: since,
                until: until,
                trimmedQuery: trimmedQuery,
                calendarsByID: calendarsByID
            )
        }

        let filtered = try fetchFilteredEvents(
            targets: targets,
            wanted: wanted,
            since: since,
            until: until,
            trimmedQuery: trimmedQuery,
            now: now
        )
        let sorted =
            if since != nil {
                sortEventsByStartAscending(filtered)
            } else {
                sortEventsByStartDescending(filtered)
            }
        return try sorted.prefix(capped).map { try makeItem(from: $0, calendarsByID: calendarsByID) }
    }

    public func create(
        title: String,
        options: CalendarCreateOptions = CalendarCreateOptions()
    ) async throws -> CalendarEventItem {
        let cleanTitle = try validatedTitle(title)
        let cleanNotes = try validatedNotes(options.notes)
        if let start = options.start, let end = options.end, end < start {
            throw CalendarToolError.invalidInput("End must not precede start.")
        }
        try ensureAuthorized()
        let all = try liveCalendars()
        guard !all.isEmpty else {
            throw CalendarToolError.storeUnavailable("No calendars available.")
        }
        let target: StoreCalendar
        if let rawName = options.calendarName {
            try TemporalFilter.gatewayCheckedName(rawName, label: "Calendar name") {
                CalendarToolError.invalidInput($0)
            }
            let raw = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty {
                guard let found = calendar(matching: raw, in: all) else {
                    throw CalendarToolError.invalidInput("Unknown calendar \"\(raw)\".")
                }
                target = found
            } else {
                target = all[0]
            }
        } else {
            target = all[0]
        }
        if let rawLocation = options.location {
            try TemporalFilter.gatewayCheckedName(rawLocation, label: "Location") {
                CalendarToolError.invalidInput($0)
            }
        }
        let trimmedLocation = options.location?.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = StoreEvent(
            identifier: nil,
            calendarIdentifier: target.identifier,
            title: cleanTitle,
            notes: cleanNotes,
            startDate: options.start,
            endDate: options.end,
            isAllDay: options.isAllDay,
            location: (trimmedLocation?.isEmpty ?? true) ? nil : trimmedLocation,
            hasRecurrence: false
        )
        let saved: StoreEvent
        do {
            saved = try store.save(draft)
        } catch let error as CalendarToolError {
            throw error
        } catch {
            throw CalendarToolError.storeUnavailable(error.localizedDescription)
        }
        let calendarsByID = Dictionary(all.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        return try makeItem(from: saved, calendarsByID: calendarsByID)
    }

    public func update(
        eventID: String,
        patch: CalendarUpdatePatch = CalendarUpdatePatch()
    ) async throws -> CalendarEventItem {
        let cleanTitle: String? = if let title = patch.title {
            try validatedTitle(title)
        } else {
            nil
        }
        let cleanNotes: String? = if let notes = patch.notes {
            try validatedNotes(notes)
        } else {
            nil
        }
        try ensureAuthorized()
        let all = try liveCalendars()
        let existing: StoreEvent?
        do {
            existing = try store.event(withIdentifier: eventID)
        } catch let error as CalendarToolError {
            throw error
        } catch {
            throw CalendarToolError.storeUnavailable(error.localizedDescription)
        }
        guard var current = existing else {
            throw CalendarToolError.notFound(eventID)
        }
        if let cleanTitle {
            current.title = cleanTitle
        }
        if patch.notes != nil {
            current.notes = cleanNotes
        }
        if patch.start != nil {
            current.startDate = patch.start
        }
        if patch.end != nil {
            current.endDate = patch.end
        }
        if let rawName = patch.calendarName {
            try TemporalFilter.gatewayCheckedName(rawName, label: "Calendar name") {
                CalendarToolError.invalidInput($0)
            }
            let raw = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty {
                guard let found = calendar(matching: raw, in: all) else {
                    throw CalendarToolError.invalidInput("Unknown calendar \"\(raw)\".")
                }
                current.calendarIdentifier = found.identifier
            }
        }
        if patch.location != nil {
            if let rawLocation = patch.location {
                try TemporalFilter.gatewayCheckedName(rawLocation, label: "Location") {
                    CalendarToolError.invalidInput($0)
                }
            }
            let trimmed = patch.location?.trimmingCharacters(in: .whitespacesAndNewlines)
            current.location = (trimmed?.isEmpty ?? true) ? nil : trimmed
        }
        if let start = current.startDate, let end = current.endDate, end < start {
            throw CalendarToolError.invalidInput("End must not precede start.")
        }
        let saved: StoreEvent
        do {
            saved = try store.save(current)
        } catch let error as CalendarToolError {
            throw error
        } catch {
            throw CalendarToolError.storeUnavailable(error.localizedDescription)
        }
        let calendarsByID = Dictionary(all.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        return try makeItem(from: saved, calendarsByID: calendarsByID)
    }

    public func delete(eventID: String, span: CalendarSpan = .thisEvent) async throws {
        try ensureAuthorized()
        let existing: StoreEvent?
        do {
            existing = try store.event(withIdentifier: eventID)
        } catch let error as CalendarToolError {
            throw error
        } catch {
            throw CalendarToolError.storeUnavailable(error.localizedDescription)
        }
        guard let current = existing else {
            throw CalendarToolError.notFound(eventID)
        }
        do {
            try store.remove(current, span: span)
        } catch let error as CalendarToolError {
            throw error
        } catch {
            throw CalendarToolError.storeUnavailable(error.localizedDescription)
        }
    }
}

// MARK: - Production gateway helpers

/// Private helpers live in an extension so the main type body stays within
/// the 350-line lint budget; behavior is unchanged.
extension ProductionCalendarGateway {
    private func ensureAuthorized() throws {
        // Tools and background work never initiate prompts; only the explicit
        // PermissionProbes.request path prompts. Fail closed on notDetermined.
        switch store.authorizationStatus() {
        case .authorized:
            return
        case .notDetermined, .denied, .restricted:
            throw CalendarToolError.permissionDenied("Access has not been granted.")
        }
    }

    private func liveCalendars() throws -> [StoreCalendar] {
        do {
            return try store.calendars()
        } catch let error as CalendarToolError {
            throw error
        } catch {
            throw CalendarToolError.storeUnavailable(error.localizedDescription)
        }
    }

    private func validatedTitle(_ raw: String) throws -> String {
        try TemporalFilter.gatewayValidatedTitle(raw, maxChars: TemporalFilter.gatewayMaxTitleChars) {
            CalendarToolError.emptyTitle
        } invalid: {
            CalendarToolError.invalidInput($0)
        }
    }

    private func validatedNotes(_ raw: String?) throws -> String? {
        try TemporalFilter.gatewayValidatedNotes(raw, maxChars: TemporalFilter.gatewayMaxNotesChars) {
            CalendarToolError.invalidInput($0)
        }
    }

    private func normalizedCalendarFilter(_ names: [String]?) throws -> Set<String>? {
        guard let names else { return nil }
        for name in names {
            try TemporalFilter.gatewayCheckedName(name, label: "Calendar name") {
                CalendarToolError.invalidInput($0)
            }
        }
        let cleaned = names.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        return Set(cleaned)
    }

    private func resolveSearchTargets(all: [StoreCalendar], wanted: Set<String>?) -> [StoreCalendar] {
        guard let wanted else { return all }
        return all.filter {
            wanted.contains($0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
    }

    private func lookupEventByIdentifier(
        _ eventID: String,
        wanted: Set<String>?,
        since: Date?,
        until: Date?,
        trimmedQuery: String?,
        calendarsByID: [String: StoreCalendar]
    ) throws -> [CalendarEventItem] {
        let stored: StoreEvent?
        do {
            stored = try store.event(withIdentifier: eventID)
        } catch let error as CalendarToolError {
            throw error
        } catch {
            throw CalendarToolError.storeUnavailable(error.localizedDescription)
        }
        guard let stored else { throw CalendarToolError.notFound(eventID) }
        if let wanted {
            guard let cid = stored.calendarIdentifier,
                  let cal = calendarsByID[cid],
                  wanted.contains(cal.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            else { throw CalendarToolError.notFound(eventID) }
        }
        let range = TemporalRange(since: since, until: until)
        guard range.matches(date: stored.startDate) else { throw CalendarToolError.notFound(eventID) }
        // A trimmed "*" lists the window like messages/reminders rather than
        // matching a literal asterisk, so it skips the text filter.
        if let queryLowered = trimmedQuery, !queryLowered.isEmpty, queryLowered != "*",
           !matchesQuery(stored, query: queryLowered)
        {
            throw CalendarToolError.notFound(eventID)
        }
        return try [makeItem(from: stored, calendarsByID: calendarsByID)]
    }

    private func fetchFilteredEvents(
        targets: [StoreCalendar],
        wanted: Set<String>?,
        since: Date?,
        until: Date?,
        trimmedQuery: String?,
        now: Date = Date()
    ) throws -> [StoreEvent] {
        let (fetchStart, fetchEnd) = try effectiveWindow(since: since, until: until, now: now)
        let predicate = store.predicateForEvents(start: fetchStart, end: fetchEnd, calendars: targets)
        let fetched: [StoreEvent]
        do {
            fetched = try store.events(matching: predicate)
        } catch let error as CalendarToolError {
            throw error
        } catch {
            throw CalendarToolError.storeUnavailable(error.localizedDescription)
        }
        let effectiveRange = TemporalRange(since: fetchStart, until: fetchEnd)
        let targetIDs = Set(targets.map(\.identifier))
        var filtered: [StoreEvent] = []
        for stored in fetched {
            if wanted != nil {
                guard let cid = stored.calendarIdentifier, targetIDs.contains(cid) else { continue }
            }
            guard effectiveRange.matches(date: stored.startDate) else { continue }
            // A trimmed "*" lists the window like messages/reminders rather than
            // matching a literal asterisk, so it skips the text filter.
            if let queryLowered = trimmedQuery, !queryLowered.isEmpty, queryLowered != "*",
               !matchesQuery(stored, query: queryLowered)
            {
                continue
            }
            filtered.append(stored)
        }
        return filtered
    }

    private func sortEventsByStartAscending(_ events: [StoreEvent]) -> [StoreEvent] {
        events.enumerated().sorted { lhs, rhs in
            switch (lhs.element.startDate, rhs.element.startDate) {
            case (nil, nil):
                return lhs.offset < rhs.offset
            case (nil, _):
                return false
            case (_, nil):
                return true
            case let (left?, right?):
                if left != right {
                    return left < right
                }
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    private func sortEventsByStartDescending(_ events: [StoreEvent]) -> [StoreEvent] {
        events.enumerated().sorted { lhs, rhs in
            switch (lhs.element.startDate, rhs.element.startDate) {
            case (nil, nil):
                return lhs.offset < rhs.offset
            case (nil, _):
                return false
            case (_, nil):
                return true
            case let (left?, right?):
                if left != right {
                    return left > right
                }
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    private func calendar(matching name: String, in calendars: [StoreCalendar]) -> StoreCalendar? {
        // Null bytes never match: callers reject them first, this stays
        // defensive so a truncated comparison can never select the wrong calendar.
        guard !name.contains("\0") else { return nil }
        let want = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return calendars.first {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == want
        }
    }

    private func effectiveWindow(since: Date?, until: Date?, now: Date = Date()) throws -> (Date, Date) {
        // Single window owner lives in Core over defaultPastDays/defaultFutureDays;
        // the Core inverted-range failure maps to the domain invalid-input copy.
        do {
            return try TemporalFilter.effectiveWindow(since: since, until: until, now: now)
        } catch {
            throw CalendarToolError.invalidInput("Since must not be after until.")
        }
    }

    private func matchesQuery(_ event: StoreEvent, query: String) -> Bool {
        if event.title?.localizedCaseInsensitiveContains(query) ?? false {
            return true
        }
        if event.notes?.localizedCaseInsensitiveContains(query) ?? false {
            return true
        }
        if event.location?.localizedCaseInsensitiveContains(query) ?? false {
            return true
        }
        return false
    }

    private func makeItem(
        from event: StoreEvent,
        calendarsByID: [String: StoreCalendar]
    ) throws -> CalendarEventItem {
        guard let identifier = event.identifier, !identifier.isEmpty else {
            throw CalendarToolError.storeUnavailable("Saved event is missing its identifier.")
        }
        let calendar: StoreCalendar? = if let cid = event.calendarIdentifier {
            calendarsByID[cid]
        } else {
            nil
        }
        let startISO = event.startDate.map(TemporalFilter.isoString(from:))
        let endISO = event.endDate.map(TemporalFilter.isoString(from:))
        return CalendarEventItem(
            id: identifier,
            calendarName: calendar?.title,
            sourceTitle: calendar?.sourceTitle,
            title: event.title ?? "",
            notes: event.notes,
            startDateISO: startISO,
            endDateISO: endISO,
            startDisplay: CalendarEventDisplay.string(
                for: event.startDate,
                isoFallback: startISO,
                isAllDay: event.isAllDay
            ),
            endDisplay: CalendarEventDisplay.string(
                for: event.endDate,
                isoFallback: endISO,
                isAllDay: event.isAllDay
            ),
            isAllDay: event.isAllDay,
            location: event.location,
            hasRecurrence: event.hasRecurrence
        )
    }
}

#if canImport(EventKit)

    // MARK: - Live EventKit Store

    /// Live EventKit backing for both gateways, and the only store access path.
    ///
    /// Provides EventKit backing so calendar and reminder persistence share
    /// access to the system store. Reads calendars live per call, never cached,
    /// and maps EK values onto the Store/Reminder seams. Authorization is observed,
    /// never prompted: gateways fail closed and only PermissionProbes.request prompts.
    ///
    /// The wrapped EKEventStore is non-Sendable, so operations allocate an
    /// isolated EKEventStore per invocation to avoid cross-thread races and
    /// satisfy Swift 6 Sendable requirements without unchecked escapes.
    public final class LiveEventKitStore: EventKitStore, Sendable {
        public init() {}

        public convenience init(eventStore _: EKEventStore) {
            self.init()
        }

        // MARK: CalendarStore

        public func authorizationStatus() -> CalendarAuthorizationStatus {
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess:
                return .authorized
            case .restricted:
                return .restricted
            case .denied, .writeOnly:
                return .denied
            case .notDetermined:
                return .notDetermined
            @unknown default:
                // Unknown future cases fail closed to denied so no layer claims access it has not verified.
                return .denied
            }
        }

        public func requestAccess() async throws -> Bool {
            // Retained for the explicit owner-driven enable path; gateways
            // never call this and only read authorizationStatus() fail-closed.
            try await EKEventStore().requestFullAccessToEvents()
        }

        public func calendars() throws -> [StoreCalendar] {
            let eventStore = EKEventStore()
            return eventStore.calendars(for: .event).map {
                StoreCalendar(
                    identifier: $0.calendarIdentifier,
                    title: $0.title,
                    sourceTitle: $0.source?.title
                )
            }
        }

        public func predicateForEvents(start: Date, end: Date, calendars: [StoreCalendar]) -> CalendarFetchPredicate {
            CalendarFetchPredicate(start: start, end: end, calendars: calendars)
        }

        public func events(matching predicate: CalendarFetchPredicate) throws -> [StoreEvent] {
            let eventStore = EKEventStore()
            let ekCalendars = predicate.calendars.compactMap { eventStore.calendar(withIdentifier: $0.identifier) }
            let nsPredicate = eventStore.predicateForEvents(
                withStart: predicate.start,
                end: predicate.end,
                calendars: ekCalendars.isEmpty ? nil : ekCalendars
            )
            return eventStore.events(matching: nsPredicate).map { ekEvent in
                StoreEvent(
                    identifier: ekEvent.eventIdentifier,
                    calendarIdentifier: ekEvent.calendar?.calendarIdentifier,
                    title: ekEvent.title,
                    notes: ekEvent.notes,
                    startDate: ekEvent.startDate,
                    endDate: ekEvent.endDate,
                    isAllDay: ekEvent.isAllDay,
                    location: ekEvent.location,
                    hasRecurrence: ekEvent.recurrenceRules?.isEmpty == false
                )
            }
        }

        public func event(withIdentifier identifier: String) throws -> StoreEvent? {
            let eventStore = EKEventStore()
            guard let ekEvent = eventStore.event(withIdentifier: identifier) else { return nil }
            return StoreEvent(
                identifier: ekEvent.eventIdentifier,
                calendarIdentifier: ekEvent.calendar?.calendarIdentifier,
                title: ekEvent.title,
                notes: ekEvent.notes,
                startDate: ekEvent.startDate,
                endDate: ekEvent.endDate,
                isAllDay: ekEvent.isAllDay,
                location: ekEvent.location,
                hasRecurrence: ekEvent.recurrenceRules?.isEmpty == false
            )
        }

        public func save(_ event: StoreEvent) throws -> StoreEvent {
            let eventStore = EKEventStore()
            let ekEvent: EKEvent = if let identifier = event.identifier,
                                      !identifier.isEmpty,
                                      let existing = eventStore.event(withIdentifier: identifier)
            {
                existing
            } else {
                EKEvent(eventStore: eventStore)
            }
            if let calendarID = event.calendarIdentifier, !calendarID.isEmpty {
                // An explicit identifier must resolve; silently falling back
                // to the default calendar would persist into the wrong
                // calendar, so fail closed with an owner-facing error.
                guard let calendar = eventStore.calendar(withIdentifier: calendarID) else {
                    throw CalendarToolError.invalidInput("Unknown calendar \"\(calendarID)\".")
                }
                ekEvent.calendar = calendar
            } else if ekEvent.calendar == nil {
                ekEvent.calendar = eventStore.defaultCalendarForNewEvents
            }
            ekEvent.title = event.title
            ekEvent.notes = event.notes
            if let startDate = event.startDate {
                ekEvent.startDate = startDate
            }
            if let endDate = event.endDate {
                ekEvent.endDate = endDate
            }
            ekEvent.isAllDay = event.isAllDay
            ekEvent.location = event.location
            try eventStore.save(ekEvent, span: .thisEvent, commit: true)
            return StoreEvent(
                identifier: ekEvent.eventIdentifier,
                calendarIdentifier: ekEvent.calendar?.calendarIdentifier,
                title: ekEvent.title,
                notes: ekEvent.notes,
                startDate: ekEvent.startDate,
                endDate: ekEvent.endDate,
                isAllDay: ekEvent.isAllDay,
                location: ekEvent.location,
                hasRecurrence: ekEvent.recurrenceRules?.isEmpty == false
            )
        }

        public func remove(_ event: StoreEvent, span: CalendarSpan) throws {
            let eventStore = EKEventStore()
            guard let identifier = event.identifier,
                  !identifier.isEmpty,
                  let ekEvent = eventStore.event(withIdentifier: identifier)
            else { return }
            try eventStore.remove(
                ekEvent,
                span: span == .futureEvents ? .futureEvents : .thisEvent,
                commit: true
            )
        }

        // MARK: ReminderStore

        public func reminderAuthorizationStatus() -> EventKitReminderAuthorization {
            switch EKEventStore.authorizationStatus(for: .reminder) {
            case .fullAccess:
                return .authorized
            case .restricted:
                return .restricted
            case .denied, .writeOnly:
                return .denied
            case .notDetermined:
                return .notDetermined
            @unknown default:
                // Unknown future cases fail closed to denied so no layer claims access it has not verified.
                return .denied
            }
        }

        public func requestReminderAccess() async throws -> Bool {
            try await EKEventStore().requestFullAccessToReminders()
        }

        public func reminderCalendars() throws -> [EventKitReminderCalendar] {
            let eventStore = EKEventStore()
            return eventStore.calendars(for: .reminder).map {
                EventKitReminderCalendar(
                    identifier: $0.calendarIdentifier,
                    title: $0.title,
                    sourceTitle: $0.source?.title ?? ""
                )
            }
        }

        public func fetchReminders(
            matching predicate: EventKitReminderPredicate,
            completion: @escaping @Sendable ([EventKitReminder]?) -> Void
        ) {
            let eventStore = EKEventStore()
            let ekCalendars = predicate.calendars.compactMap { eventStore.calendar(withIdentifier: $0.identifier) }
            let nsPredicate = eventStore.predicateForReminders(in: ekCalendars.isEmpty ? nil : ekCalendars)
            _ = eventStore.fetchReminders(matching: nsPredicate) { ekReminders in
                guard let ekReminders else {
                    completion(nil)
                    return
                }
                // In-memory date narrowing mirrors TemporalRange.contains:
                // inclusive lower, exclusive upper, nil side unbounded.
                // Undated rows pass through here; the gateway decides
                // whether the query keeps them.
                let range = TemporalRange(since: predicate.start, until: predicate.end)
                let mapped = ekReminders
                    .filter { $0.isCompleted == predicate.fetchCompleted }
                    .map { Self.makeReminder(from: $0) }
                    .filter {
                        guard let due = $0.dueDate else { return true }
                        return range.contains(due)
                    }
                completion(mapped)
            }
        }

        public func reminder(withIdentifier identifier: String) -> EventKitReminder? {
            let eventStore = EKEventStore()
            guard let ekReminder = eventStore.calendarItem(withIdentifier: identifier) as? EKReminder else {
                return nil
            }
            return Self.makeReminder(from: ekReminder)
        }

        public func save(_ reminder: EventKitReminder) throws -> EventKitReminder {
            let eventStore = EKEventStore()
            let ekReminder: EKReminder = if reminder.identifier.isEmpty {
                EKReminder(eventStore: eventStore)
            } else if let existing = eventStore.calendarItem(withIdentifier: reminder.identifier) as? EKReminder {
                existing
            } else {
                EKReminder(eventStore: eventStore)
            }
            if !reminder.calendarIdentifier.isEmpty {
                // An explicit list identifier must resolve; silently falling
                // back to the default list would persist into the wrong
                // list, so fail closed with an owner-facing error.
                guard let calendar = eventStore.calendar(withIdentifier: reminder.calendarIdentifier) else {
                    throw ReminderToolError.invalidInput("Unknown reminder list '\(reminder.calendarIdentifier)'.")
                }
                ekReminder.calendar = calendar
            } else if ekReminder.calendar == nil {
                ekReminder.calendar = eventStore.defaultCalendarForNewReminders()
            }
            ekReminder.title = reminder.title
            ekReminder.notes = reminder.notes
            if let dueDate = reminder.dueDate {
                ekReminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second],
                    from: dueDate
                )
            } else {
                ekReminder.dueDateComponents = nil
            }
            ekReminder.isCompleted = reminder.isCompleted
            ekReminder.priority = reminder.priority
            try eventStore.save(ekReminder, commit: true)
            return Self.makeReminder(from: ekReminder)
        }

        public func removeReminder(withIdentifier identifier: String) throws {
            let eventStore = EKEventStore()
            guard let ekReminder = eventStore.calendarItem(withIdentifier: identifier) as? EKReminder else {
                return
            }
            try eventStore.remove(ekReminder, commit: true)
        }

        // MARK: Mapping

        private static func makeReminder(from ekReminder: EKReminder) -> EventKitReminder {
            let dueDate: Date? = if let components = ekReminder.dueDateComponents {
                Calendar.current.date(from: components)
            } else {
                nil
            }
            return EventKitReminder(
                identifier: ekReminder.calendarItemIdentifier,
                calendarIdentifier: ekReminder.calendar?.calendarIdentifier ?? "",
                title: ekReminder.title ?? "",
                notes: ekReminder.notes,
                dueDate: dueDate,
                isCompleted: ekReminder.isCompleted,
                priority: ekReminder.priority,
                creationDate: ekReminder.creationDate
            )
        }
    }
#endif
