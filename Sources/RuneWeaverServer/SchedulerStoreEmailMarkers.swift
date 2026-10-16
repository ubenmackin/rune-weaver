// Rune Weaver Server — Scheduler email-report marker detection beside the job store.

import Foundation
import RuneWeaverCore

// MARK: - Email-Report Marker Helpers

/// Marker detection for the legacy email-report bookkeeping fact shape.
extension SchedulerStore {
    /// Whether a semantic fact carries the legacy email-report last-run shape. Delegates to the
    /// single-sourced reserved-shape guard so the writer-side rejection and this reader-side
    /// detection can never drift apart.
    static func isEmailReportMarker(_ content: String) -> Bool {
        SchedulerRunBookkeeping.isReservedFactText(content)
    }

    /// Whether a job owns an email-report run cursor.
    static func isEmailJob(_ job: SchedulerJob) -> Bool {
        job.hasPollTrigger || job.emailReportJob
    }

    /// Newest embedded run instant inside one marker fact, if any.
    static func embeddedRunDate(in content: String) -> Date? {
        let pattern = #"\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(content.startIndex ..< content.endIndex, in: content)
        let matches = regex.matches(in: content, range: range)
        var newest: Date?
        for match in matches {
            guard let swiftRange = Range(match.range, in: content) else { continue }
            let candidate = String(content[swiftRange])
            if let parsed = Self.parseEmbeddedDate(candidate) {
                if let current = newest {
                    if parsed > current {
                        newest = parsed
                    }
                } else {
                    newest = parsed
                }
            }
        }
        return newest
    }

    /// Parses one embedded date candidate in decreasing specificity.
    private static func parseEmbeddedDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let date = SharedDateFormatters.isoWithFractionalSecondsDate(from: trimmed) {
            return date
        }
        if let date = SharedDateFormatters.isoInternetTimeDate(from: trimmed) {
            return date
        }
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mmXXXXX",
            "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd"
        ]
        // UTC pin keeps zone-less layouts pinned to the same instant the
        // ISO-8601 attempts anchor to; order is preserved so the most
        // specific layout always wins.
        for format in formats {
            if let date = SharedDateFormatters.posixDate(
                from: trimmed,
                format: format,
                timeZone: TimeZone(secondsFromGMT: 0)
            ) {
                return date
            }
        }
        return nil
    }
}
