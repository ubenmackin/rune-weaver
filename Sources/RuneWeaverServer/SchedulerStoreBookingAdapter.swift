// Rune Weaver Server — SchedulerStore-backed scheduled-send booking for the send tools.

import Foundation
import RuneWeaverCore

/// Books scheduled sends through the scheduler store.
public struct SchedulerStoreBookingAdapter: ScheduledSendBooking, Sendable {
    /// Registry owning the scheduled-send rows.
    private let store: SchedulerStore
    /// Hub fanning out type-only wake-ups, nil in offline contexts.
    private let hub: WSHub?

    /// Creates an adapter over a scheduler store.
    /// - Parameters:
    ///   - store: Registry receiving the booked rows.
    ///   - hub: Hub receiving the sends-changed wake-up.
    public init(store: SchedulerStore, hub: WSHub? = nil) {
        self.store = store
        self.hub = hub
    }

    /// Books one approved draft as an immutable scheduled-send row. Store validation and capacity
    /// errors propagate to the tool caller, so an unavailable booking is always visible, never a
    /// silent success.
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
        // The row is durable before dashboards refetch, and a dropped
        // frame never fails the booking itself.
        if let hub {
            await hub.broadcastScheduledSendsChanged()
        }
        return BookedScheduledSend(id: row.id, fireAt: row.fireAt)
    }
}
