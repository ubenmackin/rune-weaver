// Rune Weaver Core — Reserved scheduler run-bookkeeping fact shapes.

import Foundation

/// Single source of truth for semantic-fact text reserved to framework run bookkeeping.
///
/// The scheduler run cursor is framework-owned state: only a completed run advances
/// `SchedulerJob.lastSuccessfulRunEndedAt`. Legacy installs once asked the agent to
/// record an `email report last run:` fact as a stand-in cursor, and the one-shot
/// legacy migration still reads that shape, so the shape stays reserved forever.
/// Every agent- and owner-writable memory boundary rejects it, which means a
/// prompt-injected `memories.store` call can never forge a cursor jump even before
/// the one-shot migration latch applies.
public enum SchedulerRunBookkeeping {
    /// Normalized prefixes reserved for framework-owned run cursor state.
    ///
    /// The legacy marker migration consumes exactly these shapes, so the
    /// writer-side rejection and the reader-side migration cannot drift apart.
    public static let reservedMarkerPrefixes = ["email report last run:"]

    /// Whether fact text is shaped like reserved framework run bookkeeping.
    /// - Parameter content: Candidate fact text.
    /// - Returns: True when the normalized text starts with a reserved prefix.
    public static func isReservedFactText(_ content: String) -> Bool {
        let normalized = normalizedFactText(content)
        return reservedMarkerPrefixes.contains { normalized.hasPrefix($0) }
    }

    /// Renders a framework-owned run cursor instant for publication.
    ///
    /// The run prompt the agent reads and the persisted audit line for a
    /// seeded cursor both print the same instant, so both call this one
    /// formatter: a store-side audit record must never reach up into the
    /// scheduler worker to render a date, and two formatters could drift into
    /// printing the same cursor two ways.
    /// - Parameter date: Cursor instant to render in UTC.
    /// - Returns: The instant as an ISO 8601 string.
    public static func schedulerCursorTimestampString(from date: Date) -> String {
        SharedDateFormatters.isoInternetTimeUTCString(from: date)
    }

    /// Case-folds and separator-folds text so spellings such as
    /// `email-report-last-run:` cannot evade the reserved prefixes.
    /// - Parameter content: Candidate fact text.
    /// - Returns: Normalized text for prefix matching.
    private static func normalizedFactText(_ content: String) -> String {
        content.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
