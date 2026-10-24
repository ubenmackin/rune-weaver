// Rune Weaver Core — Shared notification identifier normalization.

import Foundation

/// Single owner for scheduler notification identifier normalization.
public enum NotifyID: Sendable {
    /// Trims whitespace and mints a UUID when blank so retries replace rather than duplicate banners.
    public static func normalize(_ identifier: String?) -> String {
        let trimmed = identifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? UUID().uuidString : trimmed
    }
}
