// Rune Weaver Tools — Structured field-scoped filters for IMAP mailbox search.

import Foundation
import RuneWeaverCore

/// Structured field-scoped filters for one mailbox search.
public struct EmailStructuredSearchFilters: Sendable, Equatable {
    /// Attachment presence filter (nil means no filtering).
    public var hasAttachment: Bool?
    /// Temporal window (nil means unbounded).
    public var range: TemporalRange?
    /// Sender substring filter (nil means no scoping).
    public var from: String?
    /// Subject substring filter (nil means no scoping).
    public var subject: String?
    /// Whether to restrict to unread mail only.
    public var unreadOnly: Bool
    /// Relative lookback in days (nil means no bound).
    public var sinceDays: Int?

    /// Empty filters matching every message in the window.
    public static let none = EmailStructuredSearchFilters()

    /// Creates a filter set for structured search.
    public init(
        hasAttachment: Bool? = nil,
        range: TemporalRange? = nil,
        from: String? = nil,
        subject: String? = nil,
        unreadOnly: Bool = false,
        sinceDays: Int? = nil
    ) {
        self.hasAttachment = hasAttachment
        self.range = range
        self.from = from
        self.subject = subject
        self.unreadOnly = unreadOnly
        self.sinceDays = sinceDays
    }
}
