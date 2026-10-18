// Rune Weaver Core — Memory query router offset windows plus shared helpers.

import Foundation

extension MemoryQueryRouter {
    // MARK: - Offset windows

    /// Offset day windows for `day after tomorrow`, `N days ago`, and `in N days`.
    ///
    /// Unrecognized counts fall through so the query stays unbounded.
    static func offsetDayRange(currentDate: Date, lowered: String) -> TemporalRange? {
        let tokens = offsetTokens(lowered)
        let calendar = gregorianCalendar()
        let todayStart = calendar.startOfDay(for: currentDate)
        if hasDayAfterTomorrow(tokens) {
            guard let target = calendar.date(byAdding: .day, value: 2, to: todayStart),
                  let next = calendar.date(byAdding: .day, value: 1, to: target) else { return nil }
            return dayWindow(since: target, until: next, calendar: calendar)
        }
        guard tokens.count >= 3 else { return nil }
        for index in 0 ..< (tokens.count - 2) where (tokens[index + 1] == "day" || tokens[index + 1] == "days") && tokens[index + 2] == "ago" {
            guard let count = countWords[tokens[index]], count >= 1 else { continue }
            guard let target = calendar.date(byAdding: .day, value: -count, to: todayStart),
                  let next = calendar.date(byAdding: .day, value: 1, to: target) else { return nil }
            return dayWindow(since: target, until: next, calendar: calendar)
        }
        for index in 0 ..< (tokens.count - 2) where tokens[index] == "in" && (tokens[index + 2] == "day" || tokens[index + 2] == "days") {
            guard let count = countWords[tokens[index + 1]], count >= 1 else { continue }
            guard let target = calendar.date(byAdding: .day, value: count, to: todayStart),
                  let next = calendar.date(byAdding: .day, value: 1, to: target) else { return nil }
            return dayWindow(since: target, until: next, calendar: calendar)
        }
        return nil
    }

    /// Monday-start week windows for `N weeks ago`, `in N weeks`, and `week after next`.
    ///
    /// `week after next` is exactly two ahead; unrecognized counts fall through.
    static func offsetWeekRange(currentDate: Date, lowered: String) -> TemporalRange? {
        let tokens = offsetTokens(lowered)
        guard tokens.count >= 3 else { return nil }
        for index in 0 ..< (tokens.count - 2) where tokens[index] == "week" && tokens[index + 1] == "after" && tokens[index + 2] == "next" {
            return mondayWeekRange(offsetWeeks: 2, currentDate: currentDate)
        }
        for index in 0 ..< (tokens.count - 2) where (tokens[index + 1] == "week" || tokens[index + 1] == "weeks") && tokens[index + 2] == "ago" {
            guard let count = countWords[tokens[index]], count >= 1 else { continue }
            return mondayWeekRange(offsetWeeks: -count, currentDate: currentDate)
        }
        for index in 0 ..< (tokens.count - 2) where tokens[index] == "in" && (tokens[index + 2] == "week" || tokens[index + 2] == "weeks") {
            guard let count = countWords[tokens[index + 1]], count >= 1 else { continue }
            return mondayWeekRange(offsetWeeks: count, currentDate: currentDate)
        }
        return nil
    }

    /// Calendar-month windows for `next month` and `last month` first-to-first.
    static func offsetMonthRange(currentDate: Date, lowered: String) -> TemporalRange? {
        let tokens = offsetTokens(lowered)
        guard tokens.count >= 2 else { return nil }
        var direction: Int?
        for index in 0 ..< (tokens.count - 1) {
            if tokens[index] == "next" || tokens[index] == "following" || tokens[index] == "upcoming", tokens[index + 1] == "month" {
                direction = 1
                break
            }
            if tokens[index] == "last", tokens[index + 1] == "month" {
                direction = -1
                break
            }
        }
        guard let direction else { return nil }
        let calendar = gregorianCalendar()
        let year = calendar.component(.year, from: currentDate)
        let month = calendar.component(.month, from: currentDate)
        // Year rollover keeps December and January adjacent.
        var targetMonth = month + direction
        var targetYear = year
        if targetMonth == 0 {
            targetMonth = 12
            targetYear -= 1
        } else if targetMonth == 13 {
            targetMonth = 1
            targetYear += 1
        }
        var untilMonth = targetMonth + 1
        var untilYear = targetYear
        if untilMonth == 13 {
            untilMonth = 1
            untilYear += 1
        }
        let sinceString = String(format: "%04d-%02d-01", targetYear, targetMonth)
        let untilString = String(format: "%04d-%02d-01", untilYear, untilMonth)
        return try? TemporalFilter.parse(since: sinceString, until: untilString)
    }

    /// Monday-start seven-day window offset from the week containing the anchor.
    ///
    /// Sunday belongs to the Monday six days earlier so mid-week and Sunday anchors agree.
    static func mondayWeekRange(offsetWeeks: Int, currentDate: Date) -> TemporalRange? {
        let calendar = gregorianCalendar()
        let todayStart = calendar.startOfDay(for: currentDate)
        let weekday = calendar.component(.weekday, from: currentDate)
        let daysSinceMonday = (weekday - 2 + 7) % 7
        guard let mondayStart = calendar.date(byAdding: .day, value: -daysSinceMonday, to: todayStart),
              let sinceDate = calendar.date(byAdding: .day, value: offsetWeeks * 7, to: mondayStart),
              let untilDate = calendar.date(byAdding: .day, value: 7, to: sinceDate) else { return nil }
        return dayWindow(since: sinceDate, until: untilDate, calendar: calendar)
    }

    static func gregorianCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    static func dayWindow(since: Date, until: Date, calendar: Calendar) -> TemporalRange? {
        let sinceString = dayString(from: since, calendar: calendar)
        let untilString = dayString(from: until, calendar: calendar)
        return try? TemporalFilter.parse(since: sinceString, until: untilString)
    }

    // MARK: - Query helpers

    /// Month names plus three-letter abbreviations to calendar months.
    static let monthIndex: [String: Int] = [
        "january": 1, "jan": 1,
        "february": 2, "feb": 2,
        "march": 3, "mar": 3,
        "april": 4, "apr": 4,
        "may": 5,
        "june": 6, "jun": 6,
        "july": 7, "jul": 7,
        "august": 8, "aug": 8,
        "september": 9, "sep": 9, "sept": 9,
        "october": 10, "oct": 10,
        "november": 11, "nov": 11,
        "december": 12, "dec": 12
    ]

    /// Weekday names plus abbreviations to Gregorian weekday numbers.
    static let weekdayIndex: [String: Int] = [
        "sunday": 1, "sun": 1,
        "monday": 2, "mon": 2,
        "tuesday": 3, "tue": 3, "tues": 3,
        "wednesday": 4, "wed": 4,
        "thursday": 5, "thu": 5, "thur": 5, "thurs": 5,
        "friday": 6, "fri": 6,
        "saturday": 7, "sat": 7
    ]

    /// Number words one through twelve plus cardinal digits for offset arithmetic.
    static let countWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        "1": 1, "2": 2, "3": 3, "4": 4, "5": 5, "6": 6,
        "7": 7, "8": 8, "9": 9, "10": 10, "11": 11, "12": 12
    ]

    /// Alphanumeric tokens preserving counts so `in 3 days` keeps its number.
    static func offsetTokens(_ lowered: String) -> [String] {
        lowered.split { !$0.isLetter && !$0.isNumber }.map { String($0) }
    }

    /// True when the day-after-tomorrow triple appears in order.
    static func hasDayAfterTomorrow(_ tokens: [String]) -> Bool {
        guard tokens.count >= 3 else { return false }
        for index in 0 ..< (tokens.count - 2) {
            guard tokens[index] == "day" || tokens[index] == "days", tokens[index + 1] == "after", tokens[index + 2] == "tomorrow" else { continue }
            return true
        }
        return false
    }

    /// First month name in query order, or nil when absent.
    static func firstMonth(in lowered: String) -> Int? {
        let tokens = lowered.split { !$0.isLetter }.map { String($0) }
        for token in tokens {
            if let month = monthIndex[token] {
                return month
            }
        }
        return nil
    }

    /// Compiled once so every turn reuses the same matcher instead of rebuilding it.
    static let dateStringRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "\\b\\d{4}-\\d{2}-\\d{2}\\b"
    )

    /// First `YYYY-MM-DD` substring, or nil when absent.
    static func firstDateString(in lowered: String) -> String? {
        guard let regex = dateStringRegex else { return nil }
        let range = NSRange(lowered.startIndex ..< lowered.endIndex, in: lowered)
        guard let match = regex.firstMatch(in: lowered, range: range), let swiftRange = Range(match.range, in: lowered) else { return nil }
        return String(lowered[swiftRange])
    }

    /// Formats an instant as `YYYY-MM-DD` in the resolving calendar zone.
    static func dayString(from date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 2000, components.month ?? 1, components.day ?? 1)
    }

    // MARK: - Expansion

    /// Lowercased query with mailbox alias folding only, no other synonyms.
    static func foldMailboxAliases(_ lowered: String) -> String {
        var folded = lowered
        for (regex, replacement) in mailboxAliasMatchers {
            let range = NSRange(folded.startIndex ..< folded.endIndex, in: folded)
            folded = regex.stringByReplacingMatches(in: folded, range: range, withTemplate: replacement)
        }
        return folded
    }

    /// Ordered word-boundary replacements from alias phrases to canonical mailboxes.
    static let mailboxAliasReplacements: [(pattern: String, replacement: String)] = [
        ("\\bsent items\\b", "sent"),
        ("\\bsent mail\\b", "sent"),
        ("\\bsent mailbox\\b", "sent"),
        ("\\bdeleted messages\\b", "trash"),
        ("\\bdeleted items\\b", "trash"),
        ("\\bjunk mail\\b", "junk"),
        ("\\bspam mail\\b", "spam"),
        ("\\ball mail\\b", "archive"),
        ("\\barchived\\b", "archive")
    ]

    /// Compiled alias matchers reused across turns so planning never recompiles per query.
    static let mailboxAliasMatchers: [(regex: NSRegularExpression, replacement: String)] = mailboxAliasReplacements.compactMap { pattern, replacement in
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        return (regex, replacement)
    }
}
