// Rune Weaver Server — Active turn tracking and cooperative cancellation.
//
// Tracks in-flight interactive chat turn tasks across sessions, bounding
// concurrency and enabling cooperative cancellation.

import Foundation
import os
import RuneWeaverCore

/// Receipt binding one registered turn to its tracker slot.
public struct TurnRegistration: Sendable, Equatable {
    /// Identity of this registration.
    public let token: UUID
    /// Whether a prior turn was replaced by this registration.
    public let replaced: Bool

    /// Creates a registration receipt.
    public init(token: UUID, replaced: Bool) {
        self.token = token
        self.replaced = replaced
    }
}

/// In-flight turn snapshot for an active session.
public struct LiveTurnSnapshot: Sendable, Equatable {
    public let sessionID: UUID
    public let text: String
    public let reasoning: String
    public let toolActions: [ToolAction]
    public let totalTokens: Int?

    public init(
        sessionID: UUID,
        text: String,
        reasoning: String,
        toolActions: [ToolAction],
        totalTokens: Int? = nil
    ) {
        self.sessionID = sessionID
        self.text = text
        self.reasoning = reasoning
        self.toolActions = toolActions
        self.totalTokens = totalTokens
    }
}

/// Manages in-flight chat turn tasks so they can be cancelled cooperatively.
public actor ActiveTurnTracker {
    /// One slot: registration identity plus its cooperative cancel action.
    private struct Entry {
        /// Identity of the registered turn.
        let token: UUID
        /// Cooperative cancel action for the registered turn.
        let cancel: @Sendable () -> Void
    }

    /// Active turns indexed by session identifier.
    private var entries: [UUID: Entry] = [:]
    /// Live snapshot providers for in-flight turns indexed by session identifier.
    private var snapshotProviders: [UUID: @Sendable () -> LiveTurnSnapshot] = [:]
    /// Cancel marks waiting for a turn that has not registered yet.
    private var pendingCancels: [UUID: Date] = [:]
    /// Last registration per session, bounding idle-cancel poisoning.
    private var recentRegistrations: [UUID: Date] = [:]
    /// How long a pending cancel survives before it expires.
    private static let pendingCancelTTL: TimeInterval = 2

    /// Bounds how many interactive turns may run at once across sessions.
    /// Local inference degrades past a couple of concurrent evaluations, so a
    /// fresh session past the cap fails with an honest busy notice instead of
    /// stacking turns that would all look hung. Kept namespaced here (not as
    /// a module global) so REST and WebSocket share one cap. This is the
    /// authoritative single source: every health probe advertises it so the
    /// dashboard prefers the server value and only falls back to its mirrored
    /// constant for older engines, keeping admit and reject in agreement.
    public static let maxConcurrentTurns = 3

    /// Response header carrying the authoritative turn cap on every health probe.
    /// A header keeps the JSON contract stable while still giving the dashboard
    /// one server-owned value to prefer over its fallback constant.
    public static let turnCapHeaderName = "X-RuneWeaver-Max-Concurrent-Turns"

    public init() {}

    /// Registers an active turn task for a session.
    @discardableResult
    public func register(sessionID: UUID, task: Task<some Sendable, some Error>) -> TurnRegistration {
        store(sessionID: sessionID, cancel: { task.cancel() })
    }

    /// Registers a custom cancel closure for a session.
    @discardableResult
    public func register(sessionID: UUID, onCancel: @Sendable @escaping () -> Void) -> TurnRegistration {
        store(sessionID: sessionID, cancel: onCancel)
    }

    /// Atomically acquires a turn slot when capacity allows.
    /// A replacement turn for the same session always fits (it supersedes the
    /// prior slot); a fresh session past the cap returns nil instead of
    /// registering. The check and the store run in one actor hop so concurrent
    /// fresh sessions cannot both slip past the cap between a separate
    /// contains/count probe and a later register. The cap stays fixed here so
    /// no caller can widen it and silently stack slow inference turns.
    /// - Parameters:
    ///   - sessionID: Owning session.
    ///   - onCancel: Cooperative cancel action for the turn.
    /// - Returns: Registration receipt, or nil when a fresh session is over cap.
    public func tryAcquire(
        sessionID: UUID,
        onCancel: @Sendable @escaping () -> Void
    ) -> TurnRegistration? {
        if entries[sessionID] == nil, entries.count >= Self.maxConcurrentTurns {
            return nil
        }
        return store(sessionID: sessionID, cancel: onCancel)
    }

    /// Stores one entry, cancelling any prior turn for the session first.
    private func store(sessionID: UUID, cancel: @Sendable @escaping () -> Void) -> TurnRegistration {
        let replaced: Bool
        if let existing = entries[sessionID] {
            existing.cancel()
            LLMCancelRegistry.shared.cancel(sessionID: sessionID)
            snapshotProviders.removeValue(forKey: sessionID)
            replaced = true
        } else {
            replaced = false
        }
        let token = UUID()
        entries[sessionID] = Entry(token: token, cancel: cancel)
        recentRegistrations[sessionID] = Date()
        pruneRecentRegistrations()
        if let marked = pendingCancels[sessionID] {
            pendingCancels.removeValue(forKey: sessionID)
            if Date().timeIntervalSince(marked) <= Self.pendingCancelTTL {
                cancel()
                LLMCancelRegistry.shared.cancel(sessionID: sessionID)
            } else {
                pruneExpiredPendingCancels()
            }
        }
        return TurnRegistration(token: token, replaced: replaced)
    }

    /// Returns true if an active turn is currently running for the session.
    public func isActive(sessionID: UUID) -> Bool {
        entries[sessionID] != nil
    }

    /// Returns the session identifiers of all active turns currently in flight.
    public func runningSessionIDs() -> [UUID] {
        Array(entries.keys)
    }

    /// Registers a snapshot provider for an active turn so in-flight state can be queried.
    public func registerSnapshotProvider(sessionID: UUID, provider: @Sendable @escaping () -> LiveTurnSnapshot) {
        snapshotProviders[sessionID] = provider
    }

    /// Returns the live snapshot for an in-flight session, if active.
    public func liveSnapshot(for sessionID: UUID) -> LiveTurnSnapshot? {
        guard entries[sessionID] != nil else { return nil }
        return snapshotProviders[sessionID]?()
    }

    /// Unregisters the turn for a session when it completes.
    public func unregister(sessionID: UUID, token: UUID) {
        guard let entry = entries[sessionID] else {
            // No active slot (already cancelled): drop any late-registered provider
            // so a cancelled turn cannot resurrect a stale live-turn snapshot.
            snapshotProviders.removeValue(forKey: sessionID)
            return
        }
        guard entry.token == token else { return }
        entries.removeValue(forKey: sessionID)
        snapshotProviders.removeValue(forKey: sessionID)
    }

    /// Cancels the in-flight turn for a session.
    @discardableResult
    public func cancel(sessionID: UUID) -> Bool {
        LLMCancelRegistry.shared.cancel(sessionID: sessionID)
        snapshotProviders.removeValue(forKey: sessionID)
        if let entry = entries.removeValue(forKey: sessionID) {
            entry.cancel()
            return true
        }
        if let lastSeen = recentRegistrations[sessionID],
           Date().timeIntervalSince(lastSeen) <= Self.pendingCancelTTL
        {
            pendingCancels[sessionID] = Date()
            pruneExpiredPendingCancels()
        }
        return false
    }

    /// Drops stale registration timestamps so abandoned identifiers never accumulate.
    private func pruneRecentRegistrations() {
        let now = Date()
        for (id, marked) in recentRegistrations where now.timeIntervalSince(marked) > Self.pendingCancelTTL {
            recentRegistrations.removeValue(forKey: id)
        }
        while recentRegistrations.count > Self.maxPendingCancels {
            guard let oldest = recentRegistrations.min(by: { $0.value < $1.value })?.key else { break }
            recentRegistrations.removeValue(forKey: oldest)
        }
    }

    /// Drops expired pending cancels so abandoned session identifiers never accumulate.
    private func pruneExpiredPendingCancels() {
        let now = Date()
        for (id, marked) in pendingCancels where now.timeIntervalSince(marked) > Self.pendingCancelTTL {
            pendingCancels.removeValue(forKey: id)
        }
        while pendingCancels.count > Self.maxPendingCancels {
            guard let oldest = pendingCancels.min(by: { $0.value < $1.value })?.key else { break }
            pendingCancels.removeValue(forKey: oldest)
        }
    }

    /// Bounds pending cancel marks so random identifiers never grow memory without bound.
    private static let maxPendingCancels = 500
}

// MARK: - Behavior Watchdog Brake Parking

/// The tracker is the production owner of behavior-brake parking: the watchdog
/// reads the running roster through this seam and parks every turn through it,
/// reusing the identical cooperative cancel contract the REST and WebSocket
/// cancel paths already run.
extension ActiveTurnTracker: TurnParking {}

/// Bridges a tracker cancel action to a chat task created just after registration.
final class TurnTaskBox: Sendable {
    private struct State: Sendable {
        var cancelAction: (@Sendable () -> Void)?
        var cancelled = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Creates an empty box.
    init() {}

    /// Publishes the chat task, cancelling it when a cancel already arrived.
    /// - Parameter task: In-flight chat turn task.
    func set(_ task: Task<some Sendable, some Error>) {
        let shouldCancel = state.withLock { boxState -> Bool in
            boxState.cancelAction = { task.cancel() }
            return boxState.cancelled
        }
        if shouldCancel {
            task.cancel()
        }
    }

    /// Cancels the chat task, or flags the box when it is not set yet.
    func cancel() {
        let action = state.withLock { boxState -> (@Sendable () -> Void)? in
            boxState.cancelled = true
            return boxState.cancelAction
        }
        action?()
    }
}
