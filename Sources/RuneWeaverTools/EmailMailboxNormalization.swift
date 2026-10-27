// Rune Weaver Tools — Shared mailbox-name normalization for email args.

import Foundation
import RuneWeaverCore

/// Shared mailbox-name normalization for email args and envelopes.
public enum EmailMailboxNormalization: Sendable {
    /// Trims an optional mailbox, returning nil when omitted or blank.
    /// - Parameter value: Raw mailbox value, if any.
    /// - Returns: Trimmed mailbox, or nil when omitted or blank.
    public static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Normalizes a mailbox to a non-empty canonical value.
    public static func normalizedMailbox(_ value: String?) -> String {
        guard let trimmed = trimmed(value), !trimmed.isEmpty else { return "INBOX" }
        return trimmed
    }

    /// Returns the first alias that is present and non-blank after trimming. Blank strings behave
    /// as omitted so a valid later alias still wins.
    public static func firstNonBlank(_ candidates: [String?]) -> String? {
        for candidate in candidates {
            guard let candidate else { continue }
            if candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            return candidate
        }
        return nil
    }

    /// Variadic convenience over the array form.
    /// - Parameter candidates: Aliases in priority order.
    /// - Returns: First non-blank alias, or nil when all are omitted or blank.
    public static func firstNonBlank(_ candidates: String?...) -> String? {
        firstNonBlank(candidates)
    }
}
