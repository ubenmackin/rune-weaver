// Rune Weaver Core Tests — TemporalFilter parsing-owner tests.
//
// Purpose: pin the shared `since` / `until` contract every search tool
// delegates to, so day-boundary drift cannot reappear per tool.
// Scope: date-only inclusivity at local midnight, date-only `until`
// exclusivity, offset-datetime exactness, blank-as-omitted, fail-closed field
// naming, inverted-range rejection, IMAP formatting (including `BEFORE`
// rounding for non-midnight `until`), Mac-epoch scales, and timestamp helpers.
// Architectural role: guards the single choke point for temporal bounds; later
// tool tasks consume `TemporalFilter.parse` and `imapDateString` directly.

import Foundation
@testable import RuneWeaverCore
import Testing

@Suite("TemporalFilter")
struct TemporalFilterTests {
    /// Local midnight for an expected calendar day in the device timezone.
    private static func localMidnight(year: Int, month: Int, day: Int) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return try #require(calendar.date(from: DateComponents(year: year, month: month, day: day)))
    }

    @Test
    func `Date-only since is inclusive at local midnight`() throws {
        let range = try TemporalFilter.parse(since: "2026-09-13", until: nil)
        let midnight = try Self.localMidnight(year: 2026, month: 9, day: 13)

        #expect(range.since == midnight)
        #expect(range.until == nil)
        // Inclusive lower bound: midnight itself matches, the prior second does not.
        #expect(range.contains(midnight))
        #expect(range.contains(midnight.addingTimeInterval(-1)) == false)
    }

    @Test
    func `Date-only until is exclusive at local midnight`() throws {
        let range = try TemporalFilter.parse(since: nil, until: "2026-09-14")
        let midnight = try Self.localMidnight(year: 2026, month: 9, day: 14)

        #expect(range.since == nil)
        #expect(range.until == midnight)
        // Exclusive upper bound: midnight itself is out, the prior second is in.
        #expect(range.contains(midnight) == false)
        #expect(range.contains(midnight.addingTimeInterval(-1)))
    }

    @Test
    func `Adjacent day windows tile without overlap or gaps`() throws {
        let first = try TemporalFilter.parse(since: "2026-09-13", until: "2026-09-14")
        let second = try TemporalFilter.parse(since: "2026-09-14", until: "2026-09-15")
        let boundary = try Self.localMidnight(year: 2026, month: 9, day: 14)

        // The shared boundary instant belongs to exactly one window.
        #expect(first.contains(boundary) == false)
        #expect(second.contains(boundary))
        #expect(first.contains(boundary.addingTimeInterval(-1)))
    }

    @Test
    func `Datetime with offset converts exactly`() throws {
        let range = try TemporalFilter.parse(since: "2026-09-13T12:00:00+02:00", until: nil)

        // Independent expectation via UTC calendar math, not the parser itself.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let expected = try #require(utc.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: 10)))
        #expect(range.since == expected)

        // The same instant spelled in Zulu must land identically.
        let zulu = try TemporalFilter.parse(since: "2026-09-13T10:00:00Z", until: nil)
        #expect(zulu.since == expected)

        // Fractional seconds survive the conversion too.
        let fractional = try TemporalFilter.parse(since: "2026-09-13T10:00:00.500Z", until: nil)
        #expect(fractional.since == expected.addingTimeInterval(0.5))
    }

    @Test
    func `Blank strings behave as omitted`() throws {
        let range = try TemporalFilter.parse(since: "   ", until: "")
        #expect(range.since == nil)
        #expect(range.until == nil)
        #expect(range.isUnbounded)

        let omitted = try TemporalFilter.parse(since: nil, until: nil)
        #expect(omitted.isUnbounded)
    }

    @Test
    func `Inputs are trimmed before parsing`() throws {
        let range = try TemporalFilter.parse(since: "  2026-09-13  ", until: nil)
        let midnight = try Self.localMidnight(year: 2026, month: 9, day: 13)
        #expect(range.since == midnight)
    }

    @Test
    func `Malformed since names the since field`() throws {
        for bad in ["not-a-date", "2026-13-01", "2026-02-30", "2026-9-5", "13-Sep-2026"] {
            do {
                _ = try TemporalFilter.parse(since: bad, until: nil)
                Issue.record("Expected rejection for since '\(bad)'")
            } catch {
                #expect(error.localizedDescription.contains("since"), "Error must name since for '\(bad)'")
            }
        }
    }

    @Test
    func `Malformed until names the until field`() throws {
        for bad in ["yesterday", "2026-00-10", "2026-04-31", "09/13/2026"] {
            do {
                _ = try TemporalFilter.parse(since: nil, until: bad)
                Issue.record("Expected rejection for until '\(bad)'")
            } catch {
                #expect(error.localizedDescription.contains("until"), "Error must name until for '\(bad)'")
            }
        }
    }

    @Test
    func `Since after until rejects`() throws {
        do {
            _ = try TemporalFilter.parse(since: "2026-09-14", until: "2026-09-13")
            Issue.record("Expected rejection for inverted range")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("since") && message.contains("until"))
        }
    }

    @Test
    func `Equal bounds are an empty but valid window`() throws {
        // Strictly-after rejection leaves equality alone: it simply matches nothing.
        let range = try TemporalFilter.parse(since: "2026-09-13", until: "2026-09-13")
        let midnight = try Self.localMidnight(year: 2026, month: 9, day: 13)
        #expect(range.contains(midnight) == false)
    }

    @Test
    func `IMAP formatting emits DD-Mon-YYYY`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        // Local noon avoids any midnight-boundary ambiguity in the render zone.
        let noon = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: 12)))
        #expect(TemporalFilter.imapDateString(from: noon) == "13-Sep-2026")
    }

    @Test
    func `Undated documents never match a dated query`() throws {
        let dated = try TemporalFilter.parse(since: "2026-09-13", until: nil)
        #expect(dated.matches(date: nil) == false)
        #expect(dated.matches(timestamp: nil) == false)

        // Only a fully unbounded query has no window to exclude them from.
        let unbounded = try TemporalFilter.parse(since: nil, until: nil)
        #expect(unbounded.matches(date: nil))
        #expect(unbounded.matches(timestamp: nil))
    }

    @Test
    func `Unix-timestamp bounds mirror the date bounds`() throws {
        let range = try TemporalFilter.parse(since: "2026-09-13", until: "2026-09-14")
        let bounds = TemporalFilter.unixBounds(for: range)

        #expect(bounds.since == range.since?.timeIntervalSince1970)
        #expect(bounds.until == range.until?.timeIntervalSince1970)
        #expect(TemporalFilter.lowerBoundTimestamp(in: range) == bounds.since)
        #expect(TemporalFilter.upperBoundTimestamp(in: range) == bounds.until)

        // Timestamp helpers honor the same inclusive-since, exclusive-until rule.
        let lower = try #require(bounds.since)
        let upper = try #require(bounds.until)
        #expect(TemporalFilter.contains(timestamp: lower, in: range))
        #expect(TemporalFilter.contains(timestamp: lower - 1, in: range) == false)
        #expect(TemporalFilter.contains(timestamp: upper, in: range) == false)
        #expect(TemporalFilter.contains(timestamp: upper - 1, in: range))
    }

    @Test
    func `IMAP until at midnight stays on its own day`() throws {
        let range = try TemporalFilter.parse(since: "2026-07-14", until: "2026-07-15")
        let until = try #require(range.until)
        // Midnight already names its day, so BEFORE needs no rounding.
        #expect(TemporalFilter.imapUntilDateString(from: until) == "15-Jul-2026")
        #expect(TemporalFilter.imapUntilDateString(from: until) == TemporalFilter.imapDateString(from: until))
    }

    @Test
    func `IMAP until off midnight rounds up to the next local day`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let noon = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 12)))
        // BEFORE truncates to whole days, so noon must ask for the 16th to keep 00:00-12:00.
        #expect(TemporalFilter.imapDateString(from: noon) == "15-Jul-2026")
        #expect(TemporalFilter.imapUntilDateString(from: noon) == "16-Jul-2026")
        // SINCE stays unrounded: same-day is a superset the post-filter narrows.
        let since = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 12)))
        #expect(TemporalFilter.imapDateString(from: since) == "15-Jul-2026")
    }

    @Test
    func `Mac-epoch conversion handles seconds and nanoseconds`() throws {
        let midnight = try Self.localMidnight(year: 2026, month: 9, day: 13)
        let secondsTick = Int64(midnight.timeIntervalSinceReferenceDate)
        let nanosTick = secondsTick * 1_000_000_000

        // Both scales land on the same instant.
        #expect(TemporalFilter.date(fromMacEpoch: secondsTick) == midnight)
        let fromNanos = TemporalFilter.date(fromMacEpoch: nanosTick)
        #expect(abs(fromNanos.timeIntervalSince(midnight)) < 0.001)

        // Bounds expose both scales from one instant.
        #expect(TemporalFilter.macEpochValue(for: midnight) == midnight.timeIntervalSinceReferenceDate)
        #expect(TemporalFilter.macEpochNanosValue(for: midnight) == midnight.timeIntervalSinceReferenceDate * 1_000_000_000)
        #expect(TemporalFilter.macEpochSecondsExpression(column: "m.date").contains("1000000000.0"))

        // The tick matcher honors the window on either scale and drops undated rows when bounded.
        // Mid-window ticks keep the assertion clear of float-rounding at the exact edges.
        let range = try TemporalFilter.parse(since: "2026-09-13", until: "2026-09-14")
        let midSeconds = Int64(midnight.addingTimeInterval(3600).timeIntervalSinceReferenceDate)
        #expect(TemporalFilter.matches(macEpoch: midSeconds, in: range))
        #expect(TemporalFilter.matches(macEpoch: midSeconds * 1_000_000_000, in: range))
        #expect(TemporalFilter.matches(macEpoch: nil, in: range) == false)
        let unbounded = try TemporalFilter.parse(since: nil, until: nil)
        #expect(TemporalFilter.matches(macEpoch: nil, in: unbounded))
    }

    @Test
    func `Recall plan parses July month window without skipping docs`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let currentDate = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 12)))
        let plan = MemoryQueryRouter.plan(for: "July vacation", currentDate: currentDate)
        let expected = try TemporalFilter.parse(since: "2026-07-01", until: "2026-08-01")
        #expect(plan.since == expected.since)
        #expect(plan.until == expected.until)
        #expect(plan.skipDocIndex == false)
    }

    @Test
    func `Recall plan freshness windows today and skips docs`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let currentDate = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: 12)))
        let todayStart = calendar.startOfDay(for: currentDate)
        let tomorrowStart = try #require(calendar.date(byAdding: .day, value: 1, to: todayStart))
        let todayPlan = MemoryQueryRouter.plan(for: "what arrived today?", currentDate: currentDate)
        #expect(todayPlan.since == todayStart)
        #expect(todayPlan.until == tomorrowStart)
        #expect(todayPlan.skipDocIndex == true)

        let unreadPlan = MemoryQueryRouter.plan(for: "anything unread?", currentDate: currentDate)
        #expect(unreadPlan.since == nil)
        #expect(unreadPlan.until == nil)
        #expect(unreadPlan.skipDocIndex == true)

        let plainPlan = MemoryQueryRouter.plan(for: "sourdough recipe", currentDate: currentDate)
        #expect(plainPlan.since == nil)
        #expect(plainPlan.until == nil)
        #expect(plainPlan.skipDocIndex == false)
    }

    @Test
    func `Recall plan windows yesterday and single dates`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let currentDate = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 12)))
        let yesterdayPlan = MemoryQueryRouter.plan(for: "what did we discuss yesterday?", currentDate: currentDate)
        let expectedYesterday = try TemporalFilter.parse(since: "2026-09-13", until: "2026-09-14")
        #expect(yesterdayPlan.since == expectedYesterday.since)
        #expect(yesterdayPlan.until == expectedYesterday.until)

        let singlePlan = MemoryQueryRouter.plan(for: "notes from 2026-09-13", currentDate: currentDate)
        let expectedSingle = try TemporalFilter.parse(since: "2026-09-13", until: "2026-09-14")
        #expect(singlePlan.since == expectedSingle.since)
        #expect(singlePlan.until == expectedSingle.until)
    }

    @Test
    func `Recall plan folds mailbox aliases and leaves blank unbounded`() {
        let currentDate = Date()
        let sentPlan = MemoryQueryRouter.plan(for: "Sent Items from Alice", currentDate: currentDate)
        #expect(sentPlan.expandedQuery.contains("sent"))
        #expect(!sentPlan.expandedQuery.contains("sent items"))

        let blankPlan = MemoryQueryRouter.plan(for: "   ", currentDate: currentDate)
        #expect(blankPlan.since == nil)
        #expect(blankPlan.until == nil)
    }

    @Test
    func `Recall plan keeps todayish and todays quiet without skipping docs`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let currentDate = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: 12)))
        for query in ["todayish update", "todays agenda"] {
            #expect(!LiveSearchGuidance.prefersLiveSearch(for: query))
            let plan = MemoryQueryRouter.plan(for: query, currentDate: currentDate)
            #expect(plan.since == nil)
            #expect(plan.until == nil)
            #expect(plan.skipDocIndex == false)
        }
    }
}
