// Rune Weaver Server — Scheduled-send booking surface and sovereign re-attestation.

import Foundation
import RuneWeaverCore
import Vapor

/// Booking payload for `POST /scheduler/sends`.
public struct NewScheduledSendRequest: Content, Sendable {
    /// Delivery channel (`email` or `messages`).
    public let channel: String
    /// Account nickname for the email channel.
    public let account: String?
    /// Recipient exactly as approved.
    public let recipient: String
    /// Subject exactly as approved, required for the email channel.
    public let subject: String?
    /// Stored plain-body bytes; at least one body is required.
    public let bodyText: String?
    /// Stored HTML bytes; at least one body is required.
    public let bodyHtml: String?
    /// Approved fire time as epoch seconds.
    public let fireAt: Double

    /// Creates a booking request.
    public init(
        channel: String,
        account: String? = nil,
        recipient: String,
        subject: String? = nil,
        bodyText: String? = nil,
        bodyHtml: String? = nil,
        fireAt: Double
    ) {
        self.channel = channel
        self.account = account
        self.recipient = recipient
        self.subject = subject
        self.bodyText = bodyText
        self.bodyHtml = bodyHtml
        self.fireAt = fireAt
    }
}

extension ScheduledSend: Content {}

/// Re-attestation response mirroring the ceremony verdict.
public struct SovereignReattestResponse: Content, Sendable {
    /// Closed outcome of the ceremony.
    public let outcome: String
    /// Recomputed primary ledger head.
    public let primaryTip: String
    /// Sovereign head under test, if any.
    public let sovereignTip: String?
    /// Tip of the last signed checkpoint, if any.
    public let checkpointTip: String?
    /// Episodes the recomputed chain covered.
    public let episodeCount: Int
    /// How the signed vote resolved a disagreement.
    public let decision: String

    /// Creates a response from a ceremony verdict.
    /// - Parameter verdict: Ceremony verdict to project.
    public init(verdict: SovereignVerdict) {
        outcome = verdict.outcome.rawValue
        primaryTip = verdict.primaryTip
        sovereignTip = verdict.sovereignTip
        checkpointTip = verdict.checkpointTip
        episodeCount = verdict.episodeCount
        decision = verdict.decision.rawValue
    }
}

/// List response for `GET /scheduler/sends`.
public struct ScheduledSendsResponse: Content, Sendable {
    /// Every booked send, earliest fire time first.
    public let sends: [ScheduledSend]
    /// Number of sends in `sends`.
    public let count: Int

    /// Creates a list response.
    public init(sends: [ScheduledSend]) {
        self.sends = sends
        self.count = sends.count
    }
}

/// Maps a booking request onto the store payload, failing closed on shape drift.
private func bookingPayload(from body: NewScheduledSendRequest) throws -> NewScheduledSend {
    let channel: ScheduledSend.Channel
    switch body.channel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "email":
        channel = .email
    case "messages":
        channel = .messages
    default:
        throw Abort(.badRequest, reason: "channel must be 'email' or 'messages'")
    }
    guard body.fireAt.isFinite else {
        throw Abort(.badRequest, reason: "fireAt must be epoch seconds")
    }
    return NewScheduledSend(
        channel: channel,
        account: body.account,
        recipient: body.recipient,
        subject: body.subject,
        bodyText: body.bodyText,
        bodyHtml: body.bodyHtml,
        fireAt: Date(timeIntervalSince1970: body.fireAt)
    )
}

/// Registers the scheduled-send booking surface: list, book, and cancel.
func registerScheduledSendRoutes(_ app: Application) {
    let sends = app.grouped(PathComponent.constant(ServerPaths.scheduler), PathComponent.constant(ServerPaths.sends))
    sends.get { req async -> ScheduledSendsResponse in
        await ScheduledSendsResponse(sends: req.application.runeWeaver.scheduler.listScheduledSends())
    }
    sends.post { req async throws -> ScheduledSend in
        let body = try req.content.decode(NewScheduledSendRequest.self)
        let payload = try bookingPayload(from: body)
        do {
            return try await req.application.runeWeaver.scheduler.scheduleSend(payload)
        } catch let error as SchedulerStoreError {
            switch error {
            case let .invalidField(detail):
                throw Abort(.badRequest, reason: detail)
            case let .unknownJob(detail):
                throw Abort(.notFound, reason: detail)
            }
        }
    }
    sends.delete(PathComponent.parameter("id")) { req async throws -> ScheduledSend in
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "id must be a UUID")
        }
        // A fresh owner-authenticated cancel is the fresh approval the
        // immutable-payload contract requires; only a queued row can stop.
        guard let cancelled = await req.application.runeWeaver.scheduler.cancelScheduledSend(id: id) else {
            throw Abort(.notFound, reason: "No cancellable scheduled send \(raw)")
        }
        return cancelled
    }
}

/// Registers the explicit sovereign re-attestation route.
func registerSovereignReattestRoute(_ app: Application) {
    app.post(
        PathComponent.constant(ServerPaths.health),
        PathComponent.constant(ServerPaths.sovereign),
        PathComponent.constant(ServerPaths.reattest)
    ) { req async throws -> SovereignReattestResponse in
        let sink = sovereignCeremonySink(app: req.application)
        guard let verdict = await reattestSovereign(sink: sink) else {
            throw Abort(.badGateway, reason: "Sovereign re-attestation failed; see the server log.")
        }
        return SovereignReattestResponse(verdict: verdict)
    }
}
