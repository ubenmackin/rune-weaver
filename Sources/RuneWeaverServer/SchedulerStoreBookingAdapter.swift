// Rune Weaver Server — SchedulerStore-backed scheduled-send booking for the send tools.
//
// Bridges the tools' booking seam onto the scheduler store so an approved
// scheduled send lands as an immutable row the fire worker replays exactly once.

import Foundation
import RuneWeaverCore

/// Books scheduled sends through the scheduler store.
public struct SchedulerStoreBookingAdapter: ScheduledSendBooking, Sendable {
    /// Registry owning the scheduled-send rows.
    private let store: SchedulerStore

    /// Creates an adapter over a scheduler store.
    /// - Parameter store: Registry receiving the booked rows.
    public init(store: SchedulerStore) {
        self.store = store
    }

    /// Books one approved draft as an immutable scheduled-send row.
    ///
    /// Store validation and capacity errors propagate to the tool caller, so an
    /// unavailable booking is always visible, never a silent success.
    /// - Parameter draft: Exact approved bytes, recipient, and fire time.
    /// - Returns: Receipt carrying the stored identifier and fire time.
    public func book(_ draft: ScheduledSendDraft) async throws -> BookedScheduledSend {
        let channel: ScheduledSend.Channel = draft.channel == .email ? .email : .messages
        let row = try await store.scheduleSend(NewScheduledSend(
            channel: channel,
            account: draft.account,
            recipient: draft.recipient,
            subject: draft.subject,
            bodyText: draft.text,
            bodyHtml: draft.html,
            fireAt: draft.fireAt
        ))
        return BookedScheduledSend(id: row.id, fireAt: row.fireAt)
    }
}
