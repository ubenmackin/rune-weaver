// Rune Weaver Core — Shared text normalization for blank copy and line boundaries.

import Foundation

/// Single shared text normalization for blank copy and line boundaries.
public enum NormalizedText: Sendable {
    /// Copy worth rendering, or absent when there is nothing to show. Keeps banners collapsed and
    /// pills honest across health, ensure, and staged progress, which all poll independently and
    /// must agree.
    public static func value(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Copy worth rendering, falling back when there is nothing to show. Shares the same absence
    /// agreement as the optional path so callers that need a string never diverge on what counts as
    /// blank.
    public static func value(_ value: String?, fallback: String) -> String {
        self.value(value) ?? fallback
    }

    /// Folds CRLF and legacy CR line endings to LF so narration parsing agrees with history
    /// coverage, which folds the same shapes before matching plumbing lines.
    public static func normalizedLineEndings(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Splits text into lines with one shared CRLF/CR fold. Folding first keeps "\r\n" as a single
    /// break instead of a phantom blank, so TOML, history, archive, and template parsing agree on
    /// line boundaries.
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

    /// Squashes owner-authored free text to one prompt-injection-safe line.
    public static func singleLineSanitized(_ text: String) -> String {
        let squashed = splitLines(text).joined(separator: " ")
        var sanitized = ""
        for scalar in squashed.unicodeScalars where scalar.value >= 0x20 && scalar.value != 0x7F {
            sanitized.unicodeScalars.append(scalar)
        }
        return sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
