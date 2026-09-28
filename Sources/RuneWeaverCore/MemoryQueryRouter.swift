// Rune Weaver Core — Query-to-recall-plan inference for automatic recall.

import Foundation

/// Recall plan inferred from one user query without model calls.
///
/// `since` is inclusive and `until` is exclusive; date-only days resolve at
/// local midnight via `TemporalFilter.parse`. Either side may be nil for
/// unbounded. `skipDocIndex` mirrors `LiveSearchGuidance` freshness so live
/// tools cover state the nightly index may not hold yet.
public struct RecallPlan: Sendable, Equatable {
    /// Inclusive lower bound, or nil for unbounded below.
    public let since: Date?
    /// Exclusive upper bound, or nil for unbounded above.
    public let until: Date?
    /// True when freshness terms imply live tools over the document index.
    public let skipDocIndex: Bool
    /// Per-tier result budget from the caller's clamped `RecallBudgets`.
    ///
    /// Single source for automatic recall fan-out: `MemoryEngine` consumes
    /// this instead of reading budgets directly so a custom-budget default
    /// plan cannot diverge from its budgets.
    public let perTier: Int
    /// Lowercased trimmed query with mailbox alias folding only.
    public let expandedQuery: String

    /// Creates a recall plan from resolved bounds and expansion.
    public init(since: Date? = nil, until: Date? = nil, skipDocIndex: Bool, perTier: Int, expandedQuery: String) {
        self.since = since
        self.until = until
        self.skipDocIndex = skipDocIndex
        self.perTier = perTier
        self.expandedQuery = expandedQuery
    }
}

/// Deterministic query-to-plan inference for automatic recall.
///
/// No LLM call: lowercased trimming plus mailbox alias folding only. All date
/// bounds come from `TemporalFilter.parse`; the calendar is used solely to
/// derive `YYYY-MM-DD` strings for yesterday, today, single-date, and month
/// windows. Exactly one temporal behavior wins by precedence: yesterday, then
/// single `YYYY-MM-DD`, then month name, then today-like freshness, else
/// unbounded. Blank queries yield an unbounded plan.
public enum MemoryQueryRouter: Sendable {
    /// Infers a recall plan for one query at one instant.
    /// - Parameters:
    ///   - query: Raw user query text.
    ///   - currentDate: Instant anchoring relative days and month years.
    ///   - budgets: Recall budgets bounding per-tier fan-out; clamped so a
    ///     hand-built out-of-range value degrades to the documented `1...50`
    ///     contract instead of widening recall.
    /// - Returns: Recall plan with parsed bounds and expanded query.
    public static func plan(for query: String, currentDate: Date, budgets: RecallBudgets = RecallBudgets()) -> RecallPlan {
        let perTier = budgets.clamped().perTierLimit
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        let expanded = foldMailboxAliases(lowered)
        let skipDocIndex = LiveSearchGuidance.prefersLiveSearch(for: query)
        guard !lowered.isEmpty else {
            return RecallPlan(skipDocIndex: skipDocIndex, perTier: perTier, expandedQuery: expanded)
        }
        if let range = yesterdayRange(currentDate: currentDate, lowered: lowered) {
            return RecallPlan(since: range.since, until: range.until, skipDocIndex: skipDocIndex, perTier: perTier, expandedQuery: expanded)
        }
        if let range = singleDateRange(lowered: lowered) {
            return RecallPlan(since: range.since, until: range.until, skipDocIndex: skipDocIndex, perTier: perTier, expandedQuery: expanded)
        }
        if let range = monthRange(currentDate: currentDate, lowered: lowered) {
            return RecallPlan(since: range.since, until: range.until, skipDocIndex: skipDocIndex, perTier: perTier, expandedQuery: expanded)
        }
        if let range = todayRange(currentDate: currentDate, lowered: lowered) {
            return RecallPlan(since: range.since, until: range.until, skipDocIndex: skipDocIndex, perTier: perTier, expandedQuery: expanded)
        }
        return RecallPlan(skipDocIndex: skipDocIndex, perTier: perTier, expandedQuery: expanded)
    }

    // MARK: - Temporal windows

    /// Yesterday window `[yesterday-midnight, today-midnight)` when present.
    private static func yesterdayRange(currentDate: Date, lowered: String) -> TemporalRange? {
        // Word boundary owned by `LiveSearchGuidance`; the router delegates
        // one-way so temporal checks share the single freshness boundary.
        guard LiveSearchGuidance.containsWord("yesterday", in: lowered) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let todayStart = calendar.startOfDay(for: currentDate)
        guard let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart) else { return nil }
        let sinceString = dayString(from: yesterdayStart, calendar: calendar)
        let untilString = dayString(from: todayStart, calendar: calendar)
        return try? TemporalFilter.parse(since: sinceString, until: untilString)
    }

    /// Single `YYYY-MM-DD` day window `[date, next-day)` for the first match.
    private static func singleDateRange(lowered: String) -> TemporalRange? {
        guard let match = firstDateString(in: lowered) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let midnight = try? TemporalFilter.parse(since: match, until: nil).since else { return nil }
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: midnight) else { return nil }
        let untilString = dayString(from: nextDay, calendar: calendar)
        return try? TemporalFilter.parse(since: match, until: untilString)
    }

    /// Month window `[first-of-month, first-of-next-month)` for the first month name.
    ///
    /// A bare month name resolves to the most recent occurrence: when the
    /// same-year window would start after `currentDate` (for example asking
    /// for `december` in January), the window rolls back one year so recall
    /// looks backward instead of opening a months-future window the stores
    /// can never satisfy.
    private static func monthRange(currentDate: Date, lowered: String) -> TemporalRange? {
        guard let month = firstMonth(in: lowered) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let year = calendar.component(.year, from: currentDate)
        let sinceString = String(format: "%04d-%02d-01", year, month)
        let nextMonth = month == 12 ? 1 : month + 1
        let nextYear = month == 12 ? year + 1 : year
        let untilString = String(format: "%04d-%02d-01", nextYear, nextMonth)
        guard let initial = try? TemporalFilter.parse(since: sinceString, until: untilString) else { return nil }
        guard let since = initial.since, since > currentDate else { return initial }
        guard let until = initial.until,
              let rolledSince = calendar.date(byAdding: .year, value: -1, to: since),
              let rolledUntil = calendar.date(byAdding: .year, value: -1, to: until)
        else { return initial }
        return TemporalRange(since: rolledSince, until: rolledUntil)
    }

    /// Today window `[today-midnight, tomorrow-midnight)` for today-like freshness.
    ///
    /// Whole-word matching keeps `todays` and `todayish` from opening a
    /// day window while `may` inside `maybe` already stays quiet; the
    /// `this morning` phrase matches across its space and hyphen spellings
    /// via adjacent tokens for the same boundary reason. Boundaries are owned
    /// by `LiveSearchGuidance`; the router delegates one-way.
    private static func todayRange(currentDate: Date, lowered: String) -> TemporalRange? {
        let isTodayLike = LiveSearchGuidance.containsWord("today", in: lowered) || LiveSearchGuidance.containsThisMorning(in: lowered)
        guard isTodayLike else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let todayStart = calendar.startOfDay(for: currentDate)
        guard let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) else { return nil }
        let sinceString = dayString(from: todayStart, calendar: calendar)
        let untilString = dayString(from: tomorrowStart, calendar: calendar)
        return try? TemporalFilter.parse(since: sinceString, until: untilString)
    }

    // MARK: - Query helpers

    /// Month names to calendar months for window inference.
    private static let monthIndex: [String: Int] = [
        "january": 1, "february": 2, "march": 3, "april": 4,
        "may": 5, "june": 6, "july": 7, "august": 8,
        "september": 9, "october": 10, "november": 11, "december": 12
    ]

    /// First month name in query order, or nil when absent.
    private static func firstMonth(in lowered: String) -> Int? {
        let tokens = lowered.split { !$0.isLetter }.map { String($0) }
        for token in tokens {
            if let month = monthIndex[token] {
                return month
            }
        }
        return nil
    }

    /// Compiled once so every turn reuses the same matcher instead of rebuilding it.
    private static let dateStringRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "\\b\\d{4}-\\d{2}-\\d{2}\\b"
    )

    /// First `YYYY-MM-DD` substring, or nil when absent.
    private static func firstDateString(in lowered: String) -> String? {
        guard let regex = dateStringRegex else { return nil }
        let range = NSRange(lowered.startIndex ..< lowered.endIndex, in: lowered)
        guard let match = regex.firstMatch(in: lowered, range: range) else { return nil }
        guard let swiftRange = Range(match.range, in: lowered) else { return nil }
        return String(lowered[swiftRange])
    }

    /// Formats an instant as `YYYY-MM-DD` in the resolving calendar zone.
    private static func dayString(from date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 2000, components.month ?? 1, components.day ?? 1)
    }

    // MARK: - Expansion

    /// Lowercased query with mailbox alias folding only, no other synonyms.
    private static func foldMailboxAliases(_ lowered: String) -> String {
        var folded = lowered
        for (regex, replacement) in mailboxAliasMatchers {
            let range = NSRange(folded.startIndex ..< folded.endIndex, in: folded)
            folded = regex.stringByReplacingMatches(in: folded, range: range, withTemplate: replacement)
        }
        return folded
    }

    /// Ordered word-boundary replacements from alias phrases to canonical mailboxes.
    ///
    /// Only multi-word mailbox phrases plus the unambiguous `archived` form
    /// fold; single-word verbs such as `deleted` or `draft` stay untouched so
    /// action queries never misfire into mailbox tokens.
    private static let mailboxAliasReplacements: [(pattern: String, replacement: String)] = [
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
    private static let mailboxAliasMatchers: [(regex: NSRegularExpression, replacement: String)] = mailboxAliasReplacements.compactMap { pattern, replacement in
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        return (regex, replacement)
    }
}
