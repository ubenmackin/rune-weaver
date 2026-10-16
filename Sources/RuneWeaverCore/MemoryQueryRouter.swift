// Rune Weaver Core — Query-to-recall-plan inference for automatic recall.

import Foundation

/// Recall plan inferred from one user query without model calls. `since` is inclusive and `until`
/// is exclusive; date-only days resolve at local midnight via `TemporalFilter.parse`.
public struct RecallPlan: Sendable, Equatable {
    /// Inclusive lower bound, or nil for unbounded below.
    public let since: Date?
    /// Exclusive upper bound, or nil for unbounded above.
    public let until: Date?
    /// True when freshness terms imply live tools over the document index.
    public let skipDocIndex: Bool
    /// Per-tier result budget from the caller's clamped `RecallBudgets`.
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

/// Deterministic query-to-plan inference for automatic recall. No LLM call: lowercased trimming
/// plus mailbox alias folding only.
public enum MemoryQueryRouter: Sendable {
    /// Infers a recall plan for one query at one instant. query: Raw user query
    /// text.
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
        if let range = pastWeekdayRange(currentDate: currentDate, lowered: lowered) {
            return RecallPlan(since: range.since, until: range.until, skipDocIndex: skipDocIndex, perTier: perTier, expandedQuery: expanded)
        }
        if let range = lastWeekRange(currentDate: currentDate, lowered: lowered) {
            return RecallPlan(since: range.since, until: range.until, skipDocIndex: skipDocIndex, perTier: perTier, expandedQuery: expanded)
        }
        if let range = tomorrowRange(currentDate: currentDate, lowered: lowered) {
            return RecallPlan(since: range.since, until: range.until, skipDocIndex: skipDocIndex, perTier: perTier, expandedQuery: expanded)
        }
        if let range = weekdayRange(currentDate: currentDate, lowered: lowered) {
            return RecallPlan(since: range.since, until: range.until, skipDocIndex: skipDocIndex, perTier: perTier, expandedQuery: expanded)
        }
        if let range = weekRange(currentDate: currentDate, lowered: lowered) {
            return RecallPlan(since: range.since, until: range.until, skipDocIndex: skipDocIndex, perTier: perTier, expandedQuery: expanded)
        }
        if let range = weekendRange(currentDate: currentDate, lowered: lowered) {
            return RecallPlan(since: range.since, until: range.until, skipDocIndex: skipDocIndex, perTier: perTier, expandedQuery: expanded)
        }
        if let range = offsetDayRange(currentDate: currentDate, lowered: lowered) {
            return RecallPlan(since: range.since, until: range.until, skipDocIndex: skipDocIndex, perTier: perTier, expandedQuery: expanded)
        }
        if let range = offsetWeekRange(currentDate: currentDate, lowered: lowered) {
            return RecallPlan(since: range.since, until: range.until, skipDocIndex: skipDocIndex, perTier: perTier, expandedQuery: expanded)
        }
        if let range = offsetMonthRange(currentDate: currentDate, lowered: lowered) {
            return RecallPlan(since: range.since, until: range.until, skipDocIndex: skipDocIndex, perTier: perTier, expandedQuery: expanded)
        }
        if let range = bareFutureRange(currentDate: currentDate, lowered: lowered) {
            return RecallPlan(since: range.since, until: range.until, skipDocIndex: skipDocIndex, perTier: perTier, expandedQuery: expanded)
        }
        if let range = monthRange(currentDate: currentDate, lowered: lowered) {
            return RecallPlan(since: range.since, until: range.until, skipDocIndex: skipDocIndex, perTier: perTier, expandedQuery: expanded)
        }
        if let range = tonightRange(currentDate: currentDate, lowered: lowered) {
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
        let calendar = gregorianCalendar()
        let todayStart = calendar.startOfDay(for: currentDate)
        guard let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart) else { return nil }
        return dayWindow(since: yesterdayStart, until: todayStart, calendar: calendar)
    }

    /// Last-weekday window for the first `last <weekday>` pair.
    private static func pastWeekdayRange(currentDate: Date, lowered: String) -> TemporalRange? {
        let tokens = lowered.split { !$0.isLetter }.map { String($0) }
        var target: Int?
        for index in 0 ..< tokens.count where tokens[index] == "last" {
            guard index + 1 < tokens.count, let weekday = weekdayIndex[tokens[index + 1]] else { continue }
            target = weekday
            break
        }
        guard let target else { return nil }
        let calendar = gregorianCalendar()
        let todayStart = calendar.startOfDay(for: currentDate)
        let todayWeekday = calendar.component(.weekday, from: currentDate)
        var back = (todayWeekday - target + 7) % 7
        if back == 0 {
            back = 7
        }
        guard let dayStart = calendar.date(byAdding: .day, value: -back, to: todayStart) else { return nil }
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
        return dayWindow(since: dayStart, until: nextDay, calendar: calendar)
    }

    /// Last-week window `[today-7-midnight, today-midnight)` for `last week`.
    private static func lastWeekRange(currentDate: Date, lowered: String) -> TemporalRange? {
        guard LiveSearchGuidance.containsAdjacentPair(first: "last", second: "week", in: lowered) else { return nil }
        let calendar = gregorianCalendar()
        let todayStart = calendar.startOfDay(for: currentDate)
        guard let weekAgo = calendar.date(byAdding: .day, value: -7, to: todayStart) else { return nil }
        return dayWindow(since: weekAgo, until: todayStart, calendar: calendar)
    }

    /// Single `YYYY-MM-DD` day window `[date, next-day)` for the first match.
    private static func singleDateRange(lowered: String) -> TemporalRange? {
        guard let match = firstDateString(in: lowered) else { return nil }
        let calendar = gregorianCalendar()
        guard let midnight = try? TemporalFilter.parse(since: match, until: nil).since else { return nil }
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: midnight) else { return nil }
        return dayWindow(since: midnight, until: nextDay, calendar: calendar)
    }

    /// Tomorrow window `[tomorrow-midnight, next-day-midnight)` when present.
    private static func tomorrowRange(currentDate: Date, lowered: String) -> TemporalRange? {
        // The day-after phrase contains tomorrow but resolves two days out.
        if hasDayAfterTomorrow(offsetTokens(lowered)) {
            return nil
        }
        guard LiveSearchGuidance.containsWord("tomorrow", in: lowered) else { return nil }
        let calendar = gregorianCalendar()
        let todayStart = calendar.startOfDay(for: currentDate)
        guard let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) else { return nil }
        guard let dayAfter = calendar.date(byAdding: .day, value: 1, to: tomorrowStart) else { return nil }
        return dayWindow(since: tomorrowStart, until: dayAfter, calendar: calendar)
    }

    /// Tonight folds into the today window so evening queries stay in-day.
    private static func tonightRange(currentDate: Date, lowered: String) -> TemporalRange? {
        guard LiveSearchGuidance.containsWord("tonight", in: lowered) else { return nil }
        let calendar = gregorianCalendar()
        let todayStart = calendar.startOfDay(for: currentDate)
        guard let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) else { return nil }
        return dayWindow(since: todayStart, until: tomorrowStart, calendar: calendar)
    }

    /// Next-occurrence weekday window for the first non-`last` weekday name. Today counts when it
    /// is that weekday, so a same-day name stays in-day instead of leaping a week forward.
    private static func weekdayRange(currentDate: Date, lowered: String) -> TemporalRange? {
        let tokens = lowered.split { !$0.isLetter }.map { String($0) }
        var target: Int?
        for (index, token) in tokens.enumerated() {
            guard let weekday = weekdayIndex[token] else { continue }
            if index > 0, tokens[index - 1] == "last" {
                continue
            }
            target = weekday
            break
        }
        guard let target else { return nil }
        let calendar = gregorianCalendar()
        let todayStart = calendar.startOfDay(for: currentDate)
        let todayWeekday = calendar.component(.weekday, from: currentDate)
        let ahead = (target - todayWeekday + 7) % 7
        guard let dayStart = calendar.date(byAdding: .day, value: ahead, to: todayStart) else { return nil }
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
        return dayWindow(since: dayStart, until: nextDay, calendar: calendar)
    }

    /// Rolling week windows: `this week` is seven days from today, `next` or
    /// `following` or `upcoming week` is next Monday through plus seven days.
    private static func weekRange(currentDate: Date, lowered: String) -> TemporalRange? {
        let tokens = lowered.split { !$0.isLetter }.map { String($0) }
        var kind: Int?
        for index in 0 ..< tokens.count where tokens[index] == "week" {
            guard index > 0 else { continue }
            let previous = tokens[index - 1]
            if previous == "this" {
                kind = 0
                break
            }
            if previous == "next" || previous == "following" || previous == "upcoming" {
                kind = 1
                break
            }
        }
        guard let kind else { return nil }
        let calendar = gregorianCalendar()
        let todayStart = calendar.startOfDay(for: currentDate)
        if kind == 0 {
            guard let weekOut = calendar.date(byAdding: .day, value: 7, to: todayStart) else { return nil }
            return dayWindow(since: todayStart, until: weekOut, calendar: calendar)
        } else {
            let weekday = calendar.component(.weekday, from: currentDate)
            let daysSinceMonday = (weekday - 2 + 7) % 7
            guard let mondayStart = calendar.date(byAdding: .day, value: -daysSinceMonday, to: todayStart),
                  let nextMonday = calendar.date(byAdding: .day, value: 7, to: mondayStart),
                  let weekAfter = calendar.date(byAdding: .day, value: 7, to: nextMonday) else { return nil }
            return dayWindow(since: nextMonday, until: weekAfter, calendar: calendar)
        }
    }

    /// Coming-weekend window `[Saturday-midnight, Monday-midnight)`. A same-day Saturday stays
    /// in-day; Sunday reaches forward six days so the window never reaches backward.
    private static func weekendRange(currentDate: Date, lowered: String) -> TemporalRange? {
        guard LiveSearchGuidance.containsWord("weekend", in: lowered) else { return nil }
        let calendar = gregorianCalendar()
        let todayStart = calendar.startOfDay(for: currentDate)
        let todayWeekday = calendar.component(.weekday, from: currentDate)
        let ahead = (7 - todayWeekday + 7) % 7
        guard let saturdayStart = calendar.date(byAdding: .day, value: ahead, to: todayStart) else { return nil }
        guard let mondayStart = calendar.date(byAdding: .day, value: 2, to: saturdayStart) else { return nil }
        return dayWindow(since: saturdayStart, until: mondayStart, calendar: calendar)
    }

    /// Bare future window `[now, now+60-days)` for `next`, `following`, or `upcoming`.
    private static func bareFutureRange(currentDate: Date, lowered: String) -> TemporalRange? {
        let isBare = LiveSearchGuidance.containsWord("next", in: lowered)
            || LiveSearchGuidance.containsWord("upcoming", in: lowered)
            || LiveSearchGuidance.containsWord("following", in: lowered)
        guard isBare else { return nil }
        let calendar = gregorianCalendar()
        guard let sixtyOut = calendar.date(byAdding: .day, value: 60, to: currentDate) else { return nil }
        return TemporalRange(since: currentDate, until: sixtyOut)
    }

    /// Month window `[first-of-month, first-of-next-month)` for the first month name.
    private static func monthRange(currentDate: Date, lowered: String) -> TemporalRange? {
        guard let month = firstMonth(in: lowered) else { return nil }
        let calendar = gregorianCalendar()
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
    private static func todayRange(currentDate: Date, lowered: String) -> TemporalRange? {
        let isTodayLike = LiveSearchGuidance.containsWord("today", in: lowered) || LiveSearchGuidance.containsThisMorning(in: lowered)
        guard isTodayLike else { return nil }
        let calendar = gregorianCalendar()
        let todayStart = calendar.startOfDay(for: currentDate)
        guard let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) else { return nil }
        return dayWindow(since: todayStart, until: tomorrowStart, calendar: calendar)
    }
}
