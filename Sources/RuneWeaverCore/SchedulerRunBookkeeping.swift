// Rune Weaver Core — Reserved scheduler run-bookkeeping fact shapes.

import Foundation

/// Single source of truth for semantic-fact text reserved to framework run bookkeeping. The
/// scheduler run cursor is framework-owned state: only a completed run advances
/// `SchedulerJob.lastSuccessfulRunEndedAt`.
public enum SchedulerRunBookkeeping {
    /// Normalized prefixes reserved for framework-owned run cursor state.
    public static let reservedMarkerPrefixes = ["email report last run:"]

    /// Whether fact text is shaped like reserved framework run bookkeeping.
    /// - Parameter content: Candidate fact text.
    /// - Returns: True when the normalized text starts with a reserved prefix.
    public static func isReservedFactText(_ content: String) -> Bool {
        let normalized = normalizedFactText(content)
        return reservedMarkerPrefixes.contains { normalized.hasPrefix($0) }
    }

    /// Renders a framework-owned run cursor instant for publication.
    public static func schedulerCursorTimestampString(from date: Date) -> String {
        SharedDateFormatters.isoInternetTimeUTCString(from: date)
    }

    /// Case-folds and separator-folds text so spellings such as `email-report-last-run:` cannot
    /// evade the reserved prefixes.
    /// - Parameter content: Candidate fact text.
    private static func normalizedFactText(_ content: String) -> String {
        content.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
