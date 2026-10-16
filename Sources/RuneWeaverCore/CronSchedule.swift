// Rune Weaver Core — Cron schedule expressions, parsing, and next fire evaluation.

import Foundation

/// Failures raised while parsing a cron-like schedule expression.
public enum CronScheduleError: Error, Sendable, Equatable {
    /// The expression has the wrong shape (not five fields or unknown shortcut).
    case invalidExpression(String)
    /// One field could not be parsed.
    case invalidField(field: String, value: String)
    /// A numeric value falls outside its allowed range.
    case outOfRange(field: String, value: Int, range: String)
}

/// A five-field cron schedule (`minute hour day month weekday`).
public struct CronSchedule: Sendable, Codable, Equatable {
    /// Allowed minutes (`0-59`).
    public let minutes: Set<Int>
    /// Allowed hours (`0-23`).
    public let hours: Set<Int>
    /// Allowed days of month (`1-31`).
    public let days: Set<Int>
    /// Allowed months (`1-12`).
    public let months: Set<Int>
    /// Allowed weekdays (`0-6`, `0` is Sunday).
    public let weekdays: Set<Int>

    /// Creates a schedule from pre-validated sets.
    public init(minutes: Set<Int>, hours: Set<Int>, days: Set<Int>, months: Set<Int>, weekdays: Set<Int>) {
        self.minutes = minutes
        self.hours = hours
        self.days = days
        self.months = months
        self.weekdays = weekdays
    }

    /// Creates a schedule by parsing an expression.
    /// - Parameter expression: Five-field cron text or `@` shortcut.
    /// - Throws: ``CronScheduleError`` when the text is malformed.
    public init(parsing expression: String) throws {
        self = try Self.parse(expression)
    }

    /// Parses an expression into a schedule.
    public static func parse(_ expression: String) throws -> CronSchedule {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CronScheduleError.invalidExpression("schedule must not be empty")
        }
        if trimmed.hasPrefix("@") {
            return try parseShortcut(trimmed)
        }
        let fields = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard fields.count == 5 else {
            throw CronScheduleError.invalidExpression(
                "expected five fields 'minute hour day month weekday' (got \(fields.count) in '\(trimmed)')"
            )
        }
        let minutes = try parseField(fields[0], range: 0 ... 59, field: "minute")
        let hours = try parseField(fields[1], range: 0 ... 23, field: "hour")
        let days = try parseField(fields[2], range: 1 ... 31, field: "day")
        let months = try parseField(fields[3], range: 1 ... 12, field: "month")
        let rawWeekdays = try parseField(fields[4], range: 0 ... 7, field: "weekday")
        var weekdays = rawWeekdays
        if weekdays.contains(7) {
            weekdays.remove(7)
            weekdays.insert(0)
        }
        return CronSchedule(minutes: minutes, hours: hours, days: days, months: months, weekdays: weekdays)
    }

    /// Whether an expression parses without throwing.
    /// - Parameter expression: Candidate cron text or shortcut.
    /// - Returns: True when parsing succeeds.
    public static func isValid(_ expression: String) -> Bool {
        (try? parse(expression)) != nil
    }

    /// Whether a date matches this schedule.
    public func matches(_ date: Date, calendar: Calendar = .current) -> Bool {
        let components = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: date)
        guard let minute = components.minute,
              let hour = components.hour,
              let day = components.day,
              let month = components.month,
              let weekday = components.weekday
        else { return false }
        let cronWeekday = (weekday - 1) % 7
        guard minutes.contains(minute), hours.contains(hour), months.contains(month) else { return false }
        let domUnrestricted = days == Set(1 ... 31)
        let dowUnrestricted = weekdays == Set(0 ... 6)
        if domUnrestricted, dowUnrestricted {
            return true
        }
        if domUnrestricted {
            return weekdays.contains(cronWeekday)
        }
        if dowUnrestricted {
            return days.contains(day)
        }
        return days.contains(day) || weekdays.contains(cronWeekday)
    }

    /// Computes the next fire time strictly after a date.
    public func nextFire(after date: Date, calendar: Calendar = .current) -> Date? {
        let working = calendar
        guard let secondZeroed = working.date(bySetting: .second, value: 0, of: date) else { return nil }
        let nanoZeroed = working.date(bySetting: .nanosecond, value: 0, of: secondZeroed) ?? secondZeroed
        let candidate: Date
        if nanoZeroed <= date {
            guard let advanced = working.date(byAdding: .minute, value: 1, to: nanoZeroed) else { return nil }
            candidate = advanced
        } else {
            candidate = nanoZeroed
        }
        var cursor = candidate
        for _ in 0 ..< 527_040 {
            if matches(cursor, calendar: working) {
                return cursor
            }
            guard let next = working.date(byAdding: .minute, value: 1, to: cursor) else { return nil }
            cursor = next
        }
        return nil
    }

    /// Whether the schedule fires in a half-open check window.
    public func isDue(at now: Date, lastCheck: Date, calendar: Calendar = .current) -> Bool {
        guard let next = nextFire(after: lastCheck, calendar: calendar) else { return false }
        return next <= now
    }

    /// Canonical display of the schedule (sorted lists, `*` for full ranges).
    public var canonicalExpression: String {
        let minute = Self.formatField(minutes, full: Set(0 ... 59))
        let hour = Self.formatField(hours, full: Set(0 ... 23))
        let day = Self.formatField(days, full: Set(1 ... 31))
        let month = Self.formatField(months, full: Set(1 ... 12))
        let weekday = Self.formatField(weekdays, full: Set(0 ... 6))
        return "\(minute) \(hour) \(day) \(month) \(weekday)"
    }

    // MARK: - Private parsing

    /// Parses an `@` shortcut into a schedule.
    private static func parseShortcut(_ text: String) throws -> CronSchedule {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let expanded: String
        switch lowered {
        case "@yearly", "@annually":
            expanded = "0 0 1 1 *"
        case "@monthly":
            expanded = "0 0 1 * *"
        case "@weekly":
            expanded = "0 0 * * 0"
        case "@daily", "@midnight":
            expanded = "0 0 * * *"
        case "@hourly":
            expanded = "0 * * * *"
        case "@minutely", "@every_minute":
            expanded = "* * * * *"
        default:
            throw CronScheduleError.invalidExpression("unknown schedule shortcut '\(text)'")
        }
        return try parse(expanded)
    }

    /// Parses one cron field into its allowed values.
    private static func parseField(_ text: String, range: ClosedRange<Int>, field: String) throws -> Set<Int> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CronScheduleError.invalidField(field: field, value: text)
        }
        if trimmed == "*" {
            return Set(range)
        }
        var values = Set<Int>()
        let parts = trimmed.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else {
            throw CronScheduleError.invalidField(field: field, value: text)
        }
        for part in parts {
            let expanded = try parseListPart(part, range: range, field: field)
            values.formUnion(expanded)
        }
        guard !values.isEmpty else {
            throw CronScheduleError.invalidField(field: field, value: text)
        }
        return values
    }

    /// Parses one comma-separated list element.
    private static func parseListPart(_ part: String, range: ClosedRange<Int>, field: String) throws -> Set<Int> {
        let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CronScheduleError.invalidField(field: field, value: part)
        }
        if trimmed.contains("/") {
            let sides = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard sides.count == 2 else {
                throw CronScheduleError.invalidField(field: field, value: part)
            }
            guard let step = Int(sides[1].trimmingCharacters(in: .whitespaces)), step > 0 else {
                throw CronScheduleError.invalidField(field: field, value: part)
            }
            let base = sides[0].trimmingCharacters(in: .whitespaces)
            if base == "*" {
                return Set(stride(from: range.lowerBound, through: range.upperBound, by: step))
            }
            if base.contains("-") {
                let bounds = try parseRangeBounds(base, range: range, field: field)
                return Set(stride(from: bounds.0, through: bounds.1, by: step))
            }
            guard let start = Int(base) else {
                throw CronScheduleError.invalidField(field: field, value: part)
            }
            try checkRange(start, range: range, field: field)
            return Set(stride(from: start, through: range.upperBound, by: step))
        }
        if trimmed.contains("-") {
            let bounds = try parseRangeBounds(trimmed, range: range, field: field)
            return Set(bounds.0 ... bounds.1)
        }
        guard let single = Int(trimmed) else {
            throw CronScheduleError.invalidField(field: field, value: part)
        }
        try checkRange(single, range: range, field: field)
        return [single]
    }

    /// Parses `low-high` range bounds.
    private static func parseRangeBounds(_ text: String, range: ClosedRange<Int>, field: String) throws -> (Int, Int) {
        let sides = text.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard sides.count == 2,
              let low = Int(sides[0].trimmingCharacters(in: .whitespaces)),
              let high = Int(sides[1].trimmingCharacters(in: .whitespaces))
        else {
            throw CronScheduleError.invalidField(field: field, value: text)
        }
        try checkRange(low, range: range, field: field)
        try checkRange(high, range: range, field: field)
        guard low <= high else {
            throw CronScheduleError.invalidField(field: field, value: text)
        }
        return (low, high)
    }

    /// Validates one numeric value against its range.
    private static func checkRange(_ value: Int, range: ClosedRange<Int>, field: String) throws {
        guard range.contains(value) else {
            throw CronScheduleError.outOfRange(field: field, value: value, range: "\(range.lowerBound)-\(range.upperBound)")
        }
    }

    /// Formats one field set for display.
    private static func formatField(_ values: Set<Int>, full: Set<Int>) -> String {
        if values == full {
            return "*"
        }
        return values.sorted().map(String.init).joined(separator: ",")
    }
}
