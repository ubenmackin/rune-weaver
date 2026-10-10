// Rune Weaver Server — Scheduler email-report marker detection beside the job store.

import Foundation
import RuneWeaverCore

// MARK: - Email-Report Marker Helpers

/// Marker detection for the legacy email-report bookkeeping fact shape.
///
/// Detection lives beside the store because the store is where both directions
/// of the reserved shape meet: every memory write boundary rejects reserved
/// text through `SchedulerRunBookkeeping`, while these helpers are the one
/// reader that consumes it, and a reader that drifted from the writer would
/// either strand a marker in recall or delete an ordinary fact. Members stay
/// on `SchedulerStore` itself, so no caller changes.
extension SchedulerStore {
    /// Whether a semantic fact carries the legacy email-report last-run shape.
    ///
    /// Delegates to the single-sourced reserved-shape guard so the writer-side
    /// rejection and this reader-side detection can never drift apart. Anchored
    /// to the `email report last run:` prefix so freeform notes that merely
    /// mention those words are never treated as deletable markers.
    static func isEmailReportMarker(_ content: String) -> Bool {
        SchedulerRunBookkeeping.isReservedFactText(content)
    }

    /// Whether a job owns an email-report run cursor.
    ///
    /// Scoped to a real poll trigger or the owner-set email-report flag. Prompt
    /// and name text is never sniffed: substring matching would hand any
    /// mail-mentioning job a cursor seeded from agent-writable memory, so a
    /// prompt-injected marker could silently skip a window.
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
    ///
    /// Routes the cascade through the shared Core helpers so the locale plus
    /// time-zone policy stays single-sourced with the rest of the codebase;
    /// the precedence (fractional ISO, internet ISO, then UTC-pinned POSIX
    /// layouts) is preserved exactly.
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
