// Rune Weaver Core — Scheduled-send booking seam for delayed email and Messages sends.
//
// Lets the send tools book a fire time at the approval moment without depending
// on the scheduler store: the serving process injects a store-backed booking,
// while direct-core contexts leave it unwired and fail closed with guidance.

import Foundation

/// Delivery channel for a booked scheduled send.
public enum ScheduledSendChannel: String, Sendable, Codable, Equatable {
    /// Books through the email channel.
    case email
    /// Books through the Messages channel.
    case messages
}

/// Payload booking one approved scheduled send: exact bytes, recipient, and fire time.
public struct ScheduledSendDraft: Sendable, Equatable {
    /// Delivery channel the stored bytes replay through.
    public let channel: ScheduledSendChannel
    /// Recipient exactly as approved.
    public let recipient: String
    /// Subject exactly as approved; nil for the messages channel.
    public let subject: String?
    /// Stored plain-body bytes; nil when the approval carried HTML only.
    public let text: String?
    /// Stored HTML bytes; nil when the approval carried text only.
    public let html: String?
    /// Approved fire time, minute-aligned.
    public let fireAt: Date
    /// Account nickname the email channel dials; nil for messages.
    public let account: String?

    /// Creates a booking payload.
    public init(
        channel: ScheduledSendChannel,
        recipient: String,
        subject: String? = nil,
        text: String? = nil,
        html: String? = nil,
        fireAt: Date,
        account: String? = nil
    ) {
        self.channel = channel
        self.recipient = recipient
        self.subject = subject
        self.text = text
        self.html = html
        self.fireAt = fireAt
        self.account = account
    }
}

/// Receipt for a stored booking.
public struct BookedScheduledSend: Sendable, Equatable {
    /// Stable scheduled-send identifier.
    public let id: UUID
    /// Stored fire time the send fires at.
    public let fireAt: Date

    /// Creates a booking receipt.
    public init(id: UUID, fireAt: Date) {
        self.id = id
        self.fireAt = fireAt
    }
}

/// Books approved scheduled sends. Booking-unavailable and validation errors
/// propagate to the caller, never swallowing into a silent success.
public protocol ScheduledSendBooking: Sendable {
    /// Stores one approved draft and returns its receipt.
    /// - Parameter draft: Exact approved bytes, recipient, and fire time.
    /// - Returns: Receipt carrying the stored identifier and fire time.
    func book(_ draft: ScheduledSendDraft) async throws -> BookedScheduledSend
}

/// Owner-facing rendering of a booked fire time, local plus UTC.
public enum ScheduledSendFireTimeText: Sendable {
    /// Describes one fire time for booking confirmations and dry-run previews.
    /// - Parameter fireAt: Stored fire time.
    /// - Returns: Local rendering followed by the UTC instant in parentheses.
    public static func describe(_ fireAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "\(formatter.string(from: fireAt)) (\(SharedDateFormatters.isoInternetTimeUTCString(from: fireAt)))"
    }
}
