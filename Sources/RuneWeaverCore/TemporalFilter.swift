// Rune Weaver Core — Sole owner of temporal parsing for dated search tools.

import Foundation

/// Inclusive lower bound plus exclusive upper bound for a dated search. Either side may be nil,
/// meaning unbounded on that side; a fully unbounded range matches everything.
public struct TemporalRange: Sendable, Equatable {
    /// Inclusive lower bound, or nil for unbounded below.
    public let since: Date?
    /// Exclusive upper bound, or nil for unbounded above.
    public let until: Date?

    /// Creates a range from already-parsed bounds. since: Inclusive lower bound, or
    /// nil for unbounded below.
    public init(since: Date? = nil, until: Date? = nil) {
        self.since = since
        self.until = until
    }

    /// True when both sides are unbounded.
    public var isUnbounded: Bool {
        since == nil && until == nil
    }

    /// Lower bound as a Unix timestamp for SQLite comparisons.
    public var lowerBoundTimestamp: TimeInterval? {
        since?.timeIntervalSince1970
    }

    /// Exclusive upper bound as a Unix timestamp for SQLite comparisons.
    public var upperBoundTimestamp: TimeInterval? {
        until?.timeIntervalSince1970
    }

    /// Both bounds as Unix timestamps for stores holding epoch seconds.
    /// - Returns: Tuple of the optional lower and exclusive-upper timestamps.
    public func unixBounds() -> (since: TimeInterval?, until: TimeInterval?) {
        (lowerBoundTimestamp, upperBoundTimestamp)
    }

    /// Reports whether an instant falls in `[since, until)`.
    /// - Parameter date: Instant to test.
    /// - Returns: True when at or after `since` and strictly before `until`.
    public func contains(_ date: Date) -> Bool {
        if let since, date < since {
            return false
        }
        if let until, date >= until {
            return false
        }
        return true
    }

    /// Timestamp overload for stores holding Unix epochs.
    /// - Parameter timestamp: Seconds since 1970-01-01 UTC.
    /// - Returns: True when the instant falls in `[since, until)`.
    public func contains(timestamp: TimeInterval) -> Bool {
        contains(Date(timeIntervalSince1970: timestamp))
    }

    /// Matches an optional document date against the range.
    public func matches(date: Date?) -> Bool {
        guard let date else {
            return isUnbounded
        }
        return contains(date)
    }

    /// Timestamp overload of `matches(date:)` for epoch-second stores.
    /// - Parameter timestamp: Seconds since 1970-01-01 UTC, or nil when undated.
    /// - Returns: True when the row belongs in the result set.
    public func matches(timestamp: TimeInterval?) -> Bool {
        guard let timestamp else {
            return isUnbounded
        }
        return contains(timestamp: timestamp)
    }
}

/// Fail-closed rejection reasons for `since` / `until` parsing. Every message names the offending
/// field so tool errors can surface which parameter the caller must fix without guessing.
public enum TemporalFilterError: Error, Sendable, Equatable, LocalizedError, CustomStringConvertible {
    /// The `since` value is neither date-only nor a full ISO8601 datetime.
    case invalidSince(String)
    /// The `until` value is neither date-only nor a full ISO8601 datetime.
    case invalidUntil(String)
    /// Both sides parsed but `since` falls after `until`.
    case invertedRange(since: Date, until: Date)

    public var errorDescription: String? {
        message
    }

    public var description: String {
        message
    }

    /// Human-readable reason naming the offending field.
    private var message: String {
        switch self {
        case let .invalidSince(raw):
            "Invalid since '\(raw)': expected YYYY-MM-DD or a full ISO8601 datetime."
        case let .invalidUntil(raw):
            "Invalid until '\(raw)': expected YYYY-MM-DD or a full ISO8601 datetime."
        case let .invertedRange(since, until):
            "Invalid since/until range: since (\(TemporalFilter.isoString(from: since)))"
                + " is after until (\(TemporalFilter.isoString(from: until)))."
        }
    }
}

/// Sole parser and formatter for the shared `since` / `until` contract. Date-only `since` means
/// 00:00:00 local inclusive; date-only `until` means 00:00:00 local of that day exclusive.
public enum TemporalFilter: Sendable {
    /// Parses one side of the shared temporal contract.
    public static func parse(since: String?, until: String?) throws -> TemporalRange {
        let lower = try parseBound(since, field: .since)
        let upper = try parseBound(until, field: .until)
        if let lower, let upper, lower > upper {
            throw TemporalFilterError.invertedRange(since: lower, until: upper)
        }
        return TemporalRange(since: lower, until: upper)
    }

    /// Formats an instant as `DD-Mon-YYYY` (for example `13-Sep-2026`) for IMAP `SINCE` / `BEFORE`
    /// search criteria.
    public static func imapDateString(from date: Date) -> String {
        // Fresh formatter per call: IMAP searches are tool-call frequency,
        // and shared formatters would need locking under Swift 6 concurrency.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "dd-MMM-yyyy"
        return formatter.string(from: date)
    }

    /// Formats an `until` instant as `DD-Mon-YYYY` for IMAP `BEFORE`.
    /// - Parameter date: Exclusive upper bound to render.
    public static func imapUntilDateString(from date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let startOfDay = calendar.startOfDay(for: date)
        guard date > startOfDay else {
            return imapDateString(from: date)
        }
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            return imapDateString(from: date)
        }
        return imapDateString(from: nextDay)
    }

    /// Renders an instant in UTC ISO8601 for error messages and diagnostics.
    /// - Parameter date: Instant to render.
    /// - Returns: UTC string such as `2026-09-13T10:00:00Z`.
    public static func isoString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    // MARK: - Default search window

    /// Days behind now covered when a search supplies neither bound. A week of history keeps an
    /// unbounded calendar or reminder search answering recent context without scanning the whole
    /// store.
    public static let defaultPastDays = 7

    /// Days ahead of now covered when a search supplies neither bound. Two months of look-ahead
    /// keeps upcoming events and due tasks visible while still bounding the EventKit predicate to a
    /// concrete window.
    public static let defaultFutureDays = 60

    /// Resolves the shared effective window for bounded EventKit searches. Both bounds present
    /// means the caller chose the window, so order is verified fail-closed.
    public static func effectiveWindow(since: Date?, until: Date?, now: Date = Date()) throws -> (Date, Date) {
        if let since, let until {
            guard since <= until else {
                throw TemporalFilterError.invertedRange(since: since, until: until)
            }
            return (since, until)
        }
        if since == nil, until == nil {
            let start = Calendar.current.date(byAdding: .day, value: -defaultPastDays, to: now)
                ?? now.addingTimeInterval(TimeInterval(-defaultPastDays * 24 * 3600))
            let end = Calendar.current.date(byAdding: .day, value: defaultFutureDays, to: now)
                ?? now.addingTimeInterval(TimeInterval(defaultFutureDays * 24 * 3600))
            return (start, end)
        }
        // A nil side stays unbounded logically; distant dates keep the predicate concrete.
        return (since ?? .distantPast, until ?? .distantFuture)
    }

    // MARK: - Unix-timestamp bound helpers

    /// Lower bound as a Unix timestamp for SQLite comparisons.
    public static func lowerBoundTimestamp(in range: TemporalRange) -> TimeInterval? {
        range.lowerBoundTimestamp
    }

    /// Exclusive upper bound as a Unix timestamp for SQLite comparisons.
    public static func upperBoundTimestamp(in range: TemporalRange) -> TimeInterval? {
        range.upperBoundTimestamp
    }

    /// Both bounds as Unix timestamps for stores holding epoch seconds.
    public static func unixBounds(for range: TemporalRange) -> (since: TimeInterval?, until: TimeInterval?) {
        range.unixBounds()
    }

    /// Reports whether an instant falls in the range's `[since, until)`.
    public static func contains(_ date: Date, in range: TemporalRange) -> Bool {
        range.contains(date)
    }

    /// Timestamp overload of `contains(_:in:)` for epoch-second stores.
    public static func contains(timestamp: TimeInterval, in range: TemporalRange) -> Bool {
        range.contains(timestamp: timestamp)
    }

    /// Matches an optional document date; undated rows only match unbounded ranges.
    public static func matches(date: Date?, in range: TemporalRange) -> Bool {
        range.matches(date: date)
    }

    /// Timestamp overload of `matches(date:in:)` for epoch-second stores.
    public static func matches(timestamp: TimeInterval?, in range: TemporalRange) -> Bool {
        range.matches(timestamp: timestamp)
    }

    // MARK: - Mac-epoch bound helpers

    /// Magnitude separating seconds-scale from nanoseconds-scale Mac-epoch ticks.
    public static let macEpochNanosThreshold: Int64 = 1_000_000_000_000

    /// Converts a Mac-epoch tick to a wall-clock date, handling both scales.
    /// - Parameter raw: Raw `message.date` value relative to 2001-01-01.
    /// - Returns: Converted date.
    public static func date(fromMacEpoch raw: Int64) -> Date {
        let seconds = raw > macEpochNanosThreshold ? Double(raw) / 1_000_000_000 : Double(raw)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// Converts a wall-clock date to its seconds-scale Mac-epoch bound.
    /// - Parameter date: Resolved `since` or `until` instant.
    /// - Returns: Seconds since 2001-01-01 for `sqlite3_bind_double`.
    public static func macEpochValue(for date: Date) -> Double {
        date.timeIntervalSinceReferenceDate
    }

    /// Converts a wall-clock date to its nanoseconds-scale Mac-epoch bound.
    /// - Parameter date: Resolved `since` or `until` instant.
    /// - Returns: Nanoseconds since 2001-01-01 for dual-scale SQL predicates.
    public static func macEpochNanosValue(for date: Date) -> Double {
        date.timeIntervalSinceReferenceDate * 1_000_000_000
    }

    /// Normalizes a `message.date` column to seconds-scale Mac-epoch for SQL.
    public static func macEpochSecondsExpression(column: String) -> String {
        "CASE WHEN \(column) > \(macEpochNanosThreshold) THEN \(column) / 1000000000.0 ELSE \(column) END"
    }

    /// Matches an optional raw Mac-epoch tick against the range. Undated rows never match a dated
    /// query; only a fully unbounded query matches an undated row.
    public static func matches(macEpoch raw: Int64?, in range: TemporalRange) -> Bool {
        guard let raw else {
            return range.isUnbounded
        }
        return range.contains(date(fromMacEpoch: raw))
    }

    // MARK: - Private parsing

    /// Which side of the range is being parsed, for field-naming errors.
    private enum BoundField {
        case since
        case until
    }

    /// Parses one bound: blank means omitted, date-only resolves to local
    /// midnight, full datetimes convert exactly, anything else fails closed.
    private static func parseBound(_ raw: String?, field: BoundField) throws -> Date? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        if dateOnlyParts(from: trimmed) != nil {
            // Shaped like a calendar day but possibly impossible (`2026-02-30`,
            // `2026-13-01`): fail closed on the named field instead of letting
            // another grammar reinterpret the text into a neighboring day.
            guard let midnight = dateOnlyMidnight(from: trimmed) else {
                throw fieldError(field, raw: trimmed)
            }
            return midnight
        }
        if let instant = iso8601Instant(from: trimmed) ?? localDateTime(from: trimmed) {
            return instant
        }
        throw fieldError(field, raw: trimmed)
    }

    /// Builds the field-naming rejection for one side of the range.
    private static func fieldError(_ field: BoundField, raw: String) -> TemporalFilterError {
        switch field {
        case .since:
            .invalidSince(raw)
        case .until:
            .invalidUntil(raw)
        }
    }

    /// Intermediate representation for numeric date components parsed from `YYYY-MM-DD`.
    private struct DateOnlyParts {
        let year: Int
        let month: Int
        let day: Int
    }

    /// Strict `YYYY-MM-DD` shape check: exactly ten characters, dashes at
    /// fixed positions, digits elsewhere. Zero-padded two-digit month and day
    /// are required so `2026-9-5` fails closed instead of guessing intent.
    private static func dateOnlyParts(from text: String) -> DateOnlyParts? {
        guard text.count == 10 else {
            return nil
        }
        let chars = Array(text)
        guard chars[4] == "-", chars[7] == "-" else {
            return nil
        }
        for (index, char) in chars.enumerated() where index != 4 && index != 7 {
            guard char.isNumber else {
                return nil
            }
        }
        guard let year = Int(String(chars[0 ..< 4])),
              let month = Int(String(chars[5 ..< 7])),
              let day = Int(String(chars[8 ..< 10]))
        else {
            return nil
        }
        return DateOnlyParts(year: year, month: month, day: day)
    }

    /// Resolves a date-only day to midnight in the device timezone.
    private static func dateOnlyMidnight(from text: String) -> Date? {
        guard let parts = dateOnlyParts(from: text) else {
            return nil
        }
        guard (1 ... 12).contains(parts.month) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        // Day validity comes from the month's actual day range, which also
        // keeps leap-day acceptance tied to leap years without manual math.
        let probe = DateComponents(year: parts.year, month: parts.month, day: 1)
        guard let firstOfMonth = calendar.date(from: probe),
              let dayRange = calendar.range(of: .day, in: .month, for: firstOfMonth),
              dayRange.contains(parts.day)
        else {
            return nil
        }
        let midnight = DateComponents(
            year: parts.year,
            month: parts.month,
            day: parts.day,
            hour: 0,
            minute: 0,
            second: 0,
            nanosecond: 0
        )
        return calendar.date(from: midnight)
    }

    /// Parses full ISO8601 datetimes, honoring the embedded offset exactly.
    private static func iso8601Instant(from text: String) -> Date? {
        let optionSets: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime, .withFractionalSeconds],
            [.withInternetDateTime],
            [.withFullDate, .withFullTime, .withTimeZone, .withFractionalSeconds],
            [.withFullDate, .withFullTime, .withTimeZone]
        ]
        for options in optionSets {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let instant = formatter.date(from: text) {
                return instant
            }
        }
        return nil
    }

    /// Parses offset-less ISO datetimes (`2026-09-13T10:00:00`) in the device
    /// zone. Without an offset there is no instant until a zone is chosen, and
    /// the device zone keeps the datetime on the calendar day the prompt shows.
    private static func localDateTime(from text: String) -> Date? {
        // Longest format first so trailing seconds cannot hide behind the
        // minute-only shape; formatters are strict, never lenient.
        let formats = ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.isLenient = false
            formatter.dateFormat = format
            if let instant = formatter.date(from: text) {
                return instant
            }
        }
        return nil
    }
}
