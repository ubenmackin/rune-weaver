// Rune Weaver Core — Shared text normalization for blank copy and line boundaries.
//
// Centralizes the optional-copy absence agreement plus the single CRLF/CR fold
// and trailing-newline-as-terminator split so TOML decoding, history coverage,
// narration fallback, file reads, archive listing, and template rendering agree
// on line boundaries. Lives in its own type so display, parsing, and template
// callers share one fold instead of drifting across per-file extensions.

import Foundation

/// Single shared text normalization for blank copy and line boundaries.
/// Optional display copy reads absent and whitespace-only identically so health
/// pills, error banners, and staged progress agree on what counts as blank;
/// the single line-ending fold plus terminator-aware split keeps every parser
/// on the same line boundaries.
public enum NormalizedText: Sendable {
    /// Copy worth rendering, or absent when there is nothing to show.
    /// Keeps banners collapsed and pills honest across health, ensure, and
    /// staged progress, which all poll independently and must agree.
    /// - Parameter value: Raw optional text.
    /// - Returns: Usable copy, or nil when there is nothing to render.
    public static func value(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Copy worth rendering, falling back when there is nothing to show.
    /// Shares the same absence agreement as the optional path so callers that
    /// need a string never diverge on what counts as blank.
    /// - Parameters:
    ///   - value: Raw optional text.
    ///   - fallback: Value used when there is nothing to render.
    /// - Returns: Usable copy, or the fallback when absent.
    public static func value(_ value: String?, fallback: String) -> String {
        self.value(value) ?? fallback
    }

    /// Folds CRLF and legacy CR line endings to LF so narration parsing agrees
    /// with history coverage, which folds the same shapes before matching
    /// plumbing lines. Single shared fold keeps every caller from drifting on
    /// carriage returns.
    /// - Parameter text: Raw text carrying mixed line endings.
    /// - Returns: Text with every line ending folded to LF.
    public static func normalizedLineEndings(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Splits text into lines with one shared CRLF/CR fold.
    /// Folding first keeps "\r\n" as a single break instead of a phantom blank,
    /// so TOML, history, archive, and template parsing agree on line boundaries.
    /// A single trailing newline is a terminator, not an extra line, so it is
    /// dropped; interior blanks are preserved for callers to skip or keep.
    /// - Parameter text: Raw text carrying mixed line endings.
    /// - Returns: Lines without terminators, empty when the input is empty.
    public static func splitLines(_ text: String) -> [String] {
        if text.isEmpty {
            return []
        }
        let normalized = normalizedLineEndings(text)
        var parts = normalized.components(separatedBy: "\n")
        if parts.last?.isEmpty == true {
            parts.removeLast()
        }
        return parts
    }
}
