// Rune Weaver Core — Sole owner of temporal parsing for dated search tools.
//
// Purpose: parse the `since` / `until` parameters accepted by every search
// tool into absolute bounds, and format instants for IMAP date searches.
// Scope: date-only `YYYY-MM-DD` plus full ISO8601 datetimes; local-midnight
// resolution for date-only days; IMAP `DD-Mon-YYYY` formatting (including
// `BEFORE` rounding for non-midnight `until`); Unix-timestamp bound helpers
// plus Mac-epoch conversion for SQLite-backed stores. No other file implements date math.
// Architectural role: single choke point so day boundaries, exclusivity, and
// fail-closed rejection behave identically across mail, messages, and memory.

import Foundation

/// Inclusive lower bound plus exclusive upper bound for a dated search.
///
/// `since` is inclusive and `until` is exclusive: an instant stamped exactly
/// at `until` belongs to the next window, not this one. Exclusivity lets
/// adjacent day windows (`[Sep-13, Sep-14)`, `[Sep-14, Sep-15)`) tile the
/// timeline with neither overlap nor gaps. Either side may be nil, meaning
/// unbounded on that side; a fully unbounded range matches everything.
public struct TemporalRange: Sendable, Equatable {
    /// Inclusive lower bound, or nil for unbounded below.
    public let since: Date?
    /// Exclusive upper bound, or nil for unbounded above.
    public let until: Date?

    /// Creates a range from already-parsed bounds.
    /// - Parameters:
    ///   - since: Inclusive lower bound, or nil for unbounded below.
    ///   - until: Exclusive upper bound, or nil for unbounded above.
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
    ///
    /// Undated rows never match a dated query: without a stamp there is no
    /// honest way to place the row inside a bounded window, so fail-closed
    /// exclusion beats speculative inclusion. Only a fully unbounded query
    /// matches an undated row.
    /// - Parameter date: Document timestamp, or nil when the row carries none.
    /// - Returns: True when the row belongs in the result set.
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

/// Fail-closed rejection reasons for `since` / `until` parsing.
///
/// Every message names the offending field so tool errors can surface which
/// parameter the caller must fix without guessing.
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

/// Sole parser and formatter for the shared `since` / `until` contract.
///
/// Parameter names are `since` and `until` on every search tool with no
/// aliases. Date-only `since` means 00:00:00 local inclusive; date-only
/// `until` means 00:00:00 local of that day exclusive. Full datetimes convert
/// exactly, honoring their offset. Blank strings behave as omitted, and both
/// parameters are optional with omission meaning unbounded on that side.
public enum TemporalFilter: Sendable {
    /// Parses one side of the shared temporal contract.
    ///
    /// Date-only days resolve at midnight in `TimeZone.current` rather than
    /// UTC so the parsed window lands on the same calendar day the prompt
    /// advertises: `SystemPromptComposer.currentDateString` renders "today"
    /// in the device zone, and a model reasoning about "since today" must get
    /// that zone's midnight, not UTC's.
    /// - Parameters:
    ///   - since: Inclusive lower bound text, or nil/blank for unbounded below.
    ///   - until: Exclusive upper bound text, or nil/blank for unbounded above.
    /// - Returns: Absolute bounds with nil sides left unbounded.
    /// - Throws: `TemporalFilterError` naming the offending field on malformed
    ///   input, or on `since` falling after `until`.
    public static func parse(since: String?, until: String?) throws -> TemporalRange {
        let lower = try parseBound(since, field: .since)
        let upper = try parseBound(until, field: .until)
        if let lower, let upper, lower > upper {
            throw TemporalFilterError.invertedRange(since: lower, until: upper)
        }
        return TemporalRange(since: lower, until: upper)
    }

    /// Formats an instant as `DD-Mon-YYYY` (for example `13-Sep-2026`) for
    /// IMAP `SINCE` / `BEFORE` search criteria.
    ///
    /// The day renders in `TimeZone.current` so the calendar day matches the
    /// local-day semantics `parse` applies to date-only bounds.
    /// - Parameter date: Instant to render.
    /// - Returns: English-abbreviated IMAP date string.
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
    ///
    /// IMAP day granularity truncates the time of day: `BEFORE 15-Jul-2026`
    /// excludes the entire 15th, so a non-midnight `until` (for example
    /// `2026-07-15T12:00`) rounds up to the next local day to keep the
    /// `00:00-12:00` slice. An `until` exactly at local midnight already
    /// names its own day, so it stays. `SINCE` needs no rounding (same-day
    /// is a superset) and keeps `imapDateString`. The Swift exact
    /// post-filter remains the narrowing step in both cases.
    /// - Parameter date: Exclusive upper bound to render.
    /// - Returns: English-abbreviated IMAP date string covering the bound.
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
    ///
    /// Messages stores seconds on older databases and nanoseconds on current
    /// ones; a seconds value cannot reach this bound within any realistic
    /// date range, so the comparison distinguishes the scales.
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
    ///
    /// The `CASE` divides nanosecond rows by 1e9 and leaves seconds rows
    /// untouched, so one seconds bound filters both scales without comparing
    /// raw ticks to a seconds-only value.
    /// - Parameter column: SQL column expression holding the raw tick.
    /// - Returns: SQL expression evaluating to seconds since 2001-01-01.
    public static func macEpochSecondsExpression(column: String) -> String {
        "CASE WHEN \(column) > \(macEpochNanosThreshold) THEN \(column) / 1000000000.0 ELSE \(column) END"
    }

    /// Matches an optional raw Mac-epoch tick against the range.
    ///
    /// Undated rows never match a dated query; only a fully unbounded query
    /// matches an undated row.
    /// - Parameters:
    ///   - raw: Raw `message.date` value, or nil when the row carries none.
    ///   - range: Dated window with `since` inclusive and `until` exclusive.
    /// - Returns: True when the row belongs in the result set.
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

    /// Strict `YYYY-MM-DD` shape check: exactly ten characters, dashes at
    /// fixed positions, digits elsewhere. Zero-padded two-digit month and day
    /// are required so `2026-9-5` fails closed instead of guessing intent.
    private static func dateOnlyParts(from text: String) -> (year: Int, month: Int, day: Int)? {
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
        return (year, month, day)
    }

    /// Resolves a date-only day to midnight in the device timezone.
    ///
    /// Month and day ranges are validated against the real calendar (so
    /// `2026-02-30` and `2026-13-01` reject) because `Calendar.date(from:)`
    /// normalizes overflow into neighboring months instead of failing.
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
    ///
    /// The cascade covers fractional and whole seconds plus colon and
    /// colon-less timezone spellings; each formatter either converts exactly
    /// or declines, and a decline falls through to rejection by the caller.
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
