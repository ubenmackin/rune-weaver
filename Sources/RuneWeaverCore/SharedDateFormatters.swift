// Rune Weaver Core — Shared date formatting helpers.
//
// Purpose: back run titles, email dates, and mail index dates with one
// formatting call site.
// Scope: locale-stable run titles plus POSIX, ISO-8601, and epoch parsing.
// Architectural role: shared utility beside the other Core helpers; helpers
// build a fresh formatter per call because `DateFormatter` and
// `ISO8601DateFormatter` are reference types with shared mutable state that
// is not safe to share across concurrency domains; per-call instances keep
// every helper concurrency-safe with no shared mutable state.

import Foundation

/// Shared date formatting helpers backing run titles, email dates, and mail index dates.
///
/// Intent: run-title, email, and mail-index paths share one call site so the
/// POSIX locale and time-zone choices stay single-source and titles plus
/// parsed dates stay stable across callers.
///
/// Invariant: no stored formatter instances live here. Each helper configures
/// a local formatter with the same locale, style, and options the callers
/// expect, so formatted output and accepted inputs stay stable without
/// shared state.
public enum SharedDateFormatters: Sendable {
    /// Formats a run-title timestamp with a locale-stable formatter.
    /// - Parameter date: Timestamp to format.
    /// - Returns: Short date plus short time string.
    public static func runTitleString(from date: Date) -> String {
        // Local instance preserves the en_US_POSIX short date plus short time
        // shape without sharing mutable formatter state across threads.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Parses a string with a POSIX formatter for one format.
    /// - Parameters:
    ///   - string: Candidate date string.
    ///   - format: Date format to try.
    ///   - timeZone: Time zone for the attempt (nil keeps the system zone).
    /// - Returns: Parsed date, or nil when the format does not match.
    public static func posixDate(from string: String, format: String, timeZone: TimeZone? = nil) -> Date? {
        // Local instance keeps locale single-source while allowing per-attempt
        // format and time-zone mutations without touching shared state.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.date(from: string)
    }

    /// Parses a timestamp as ISO-8601 with fractional seconds.
    /// - Parameter string: Candidate date string.
    /// - Returns: Parsed date, or nil when the string does not match.
    public static func isoWithFractionalSecondsDate(from string: String) -> Date? {
        // Local instance carries the same internet plus fractional-seconds
        // options so timestamps with fractions still parse.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }

    /// Formats a timestamp as ISO-8601 with fractional seconds.
    /// - Parameter date: Timestamp to format.
    /// - Returns: ISO-8601 string with fractional seconds.
    public static func isoWithFractionalSecondsString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Parses a timestamp as ISO-8601 internet date-time without fractions.
    /// - Parameter string: Candidate date string.
    /// - Returns: Parsed date, or nil when the string does not match.
    public static func isoInternetTimeDate(from string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    /// Formats a timestamp as ISO-8601 internet date-time without fractions.
    /// - Parameter date: Timestamp to format.
    /// - Returns: ISO-8601 internet date-time string without fractions.
    public static func isoInternetTimeString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Parses a timestamp as ISO-8601 internet date-time pinned to UTC.
    /// - Parameter string: Candidate date string.
    /// - Returns: Parsed date, or nil when the string does not match.
    public static func isoInternetTimeUTCDate(from string: String) -> Date? {
        // UTC pin matches the expiry-envelope shape for zone-less inputs.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: string)
    }

    /// Formats a timestamp as ISO-8601 internet date-time pinned to UTC.
    /// - Parameter date: Timestamp to format.
    /// - Returns: ISO-8601 internet date-time string pinned to UTC.
    public static func isoInternetTimeUTCString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    /// Parses a timestamp with the default ISO-8601 options.
    /// - Parameter string: Candidate date string.
    /// - Returns: Parsed date, or nil when the string does not match.
    public static func isoDefaultDate(from string: String) -> Date? {
        // Fresh default instance preserves the RFC 2822 fallback behavior.
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: string)
    }

    /// Formats a timestamp with the default ISO-8601 options.
    /// - Parameter date: Timestamp to format.
    /// - Returns: Default ISO-8601 string.
    public static func isoDefaultString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    }
}
