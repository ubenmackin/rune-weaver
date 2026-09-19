// Rune Weaver Core — Mid-turn steering queue.
// Allows users to inject guidance mid-stream into an active multi-round turn loop
// without cancelling the turn or losing executed tool history. Both the queued
// steering texts and the cooperative interrupt registrations are bounded so a
// fast producer (repeated UI steering taps or leaked stream registrations) can
// never grow memory without bound; the bounds mirror the session-count caps
// used elsewhere in the engine.

import Foundation

/// Actor managing pending mid-turn steering inputs and cooperative stream interruption.
public actor SteeringQueue {
    /// Maximum steering messages retained for one session. The newest guidance
    /// reflects the latest user intent, so overflow discards the oldest entry
    /// rather than rejecting the fresh steer.
    public static let maxPendingPerSession = 20
    /// Maximum interrupt callbacks retained for one session. A session normally
    /// holds one live streaming round, so this is headroom for overlapping
    /// registrations whose unregister never arrived, not a concurrency target.
    public static let maxInterruptsPerSession = 20
    /// Maximum sessions tracked per map. Matches the engine's session-count
    /// discipline so abandoned identifiers evict instead of accumulating.
    public static let maxTrackedSessions = 500

    /// Pending steering messages indexed by session.
    private var pending: [UUID: [String]] = [:]
    /// Session recency for pending steering, oldest first. Write-touched only so
    /// reads never keep an abandoned session alive past eviction.
    private var pendingOrder: [UUID] = []
    /// Cooperative stream interrupt callbacks for active streaming rounds.
    private var interruptTokens: [UUID: [UUID: @Sendable () -> Void]] = [:]
    /// Session recency for interrupt registrations, oldest first.
    private var interruptOrder: [UUID] = []
    /// Per-session token insertion order, oldest first, so per-session overflow
    /// evicts deterministically instead of dropping an arbitrary callback.
    private var interruptInsertionOrder: [UUID: [UUID]] = [:]

    /// Creates a steering queue.
    public init() {}

    /// Enqueues a mid-turn steering message and notifies any active streaming round.
    /// - Parameters:
    ///   - text: User steering instruction.
    ///   - sessionID: Target session.
    public func enqueue(text: String, sessionID: UUID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = pending[sessionID] ?? []
        if list.count >= Self.maxPendingPerSession {
            // Mid-turn consumption is oldest-first, so shedding the oldest keeps
            // the queue pinned to the user's latest direction instead of going
            // stale behind a backlog the turn will never drain in time.
            list.removeFirst()
        }
        list.append(trimmed)
        pending[sessionID] = list
        markPendingTouched(sessionID)
        evictPendingSessionsIfNeeded(preferring: sessionID)

        // Cooperatively interrupt active generation so the model pivots immediately
        // instead of waiting for a long generation to complete.
        if let listeners = interruptTokens[sessionID]?.values {
            for callback in listeners {
                callback()
            }
        }
    }

    /// Dequeues the next steering message for a session, if any.
    /// - Parameter sessionID: Target session.
    /// - Returns: The oldest queued steering text, or nil.
    public func dequeue(for sessionID: UUID) -> String? {
        guard var list = pending[sessionID], !list.isEmpty else { return nil }
        let next = list.removeFirst()
        if list.isEmpty {
            // Drop the key so drained sessions release their slot instead of
            // lingering as an empty entry that still counts toward the cap.
            pending.removeValue(forKey: sessionID)
            pendingOrder.removeAll(where: { $0 == sessionID })
        } else {
            pending[sessionID] = list
        }
        return next
    }

    /// Returns whether a session has pending steering messages.
    /// - Parameter sessionID: Target session.
    public func hasSteer(for sessionID: UUID) -> Bool {
        !(pending[sessionID]?.isEmpty ?? true)
    }

    /// Number of queued steering messages for a session.
    /// - Parameter sessionID: Target session.
    /// - Returns: Queued count, or zero when untracked.
    public func pendingCount(for sessionID: UUID) -> Int {
        pending[sessionID]?.count ?? 0
    }

    /// Number of sessions currently holding queued steering messages.
    /// - Returns: Tracked session count.
    public func pendingSessionCount() -> Int {
        pending.count
    }

    /// Clears any pending steering messages for a session.
    /// - Parameter sessionID: Target session.
    public func clear(for sessionID: UUID) {
        pending.removeValue(forKey: sessionID)
        pendingOrder.removeAll(where: { $0 == sessionID })
    }

    /// Drops one copy of a just-enqueued steering text for a session.
    /// - Parameters:
    ///   - text: Steering text to withdraw.
    ///   - sessionID: Target session.
    public func remove(text: String, sessionID: UUID) {
        guard var list = pending[sessionID], !list.isEmpty else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Remove the newest match so a race-loss withdraws the entry that just
        // arrived instead of an older sibling still waiting its turn.
        guard let index = list.lastIndex(of: trimmed) else { return }
        list.remove(at: index)
        if list.isEmpty {
            // Drop the key so drained sessions release their slot instead of
            // lingering as an empty entry that still counts toward the cap.
            pending.removeValue(forKey: sessionID)
            pendingOrder.removeAll(where: { $0 == sessionID })
        } else {
            pending[sessionID] = list
        }
    }

    /// Registers a cooperative interrupt callback for an active streaming round.
    /// - Parameters:
    ///   - sessionID: Target session.
    ///   - onInterrupt: Closure invoked when a steer message arrives.
    /// - Returns: Registration token for unregistering.
    public func registerInterrupt(sessionID: UUID, onInterrupt: @Sendable @escaping () -> Void) -> UUID {
        let token = UUID()
        var tokens = interruptTokens[sessionID] ?? [:]
        var order = interruptInsertionOrder[sessionID] ?? []
        // Shed only within this session so one leaking session cannot evict a
        // sibling's live stream callback.
        order.removeAll(where: { tokens[$0] == nil })
        while tokens.count >= Self.maxInterruptsPerSession {
            guard let victim = order.first ?? tokens.keys.first else { break }
            tokens.removeValue(forKey: victim)
            order.removeAll(where: { $0 == victim })
        }
        tokens[token] = onInterrupt
        order.append(token)
        interruptTokens[sessionID] = tokens
        interruptInsertionOrder[sessionID] = order
        markInterruptTouched(sessionID)
        evictInterruptSessionsIfNeeded(preferring: sessionID)
        return token
    }

    /// Unregisters an interrupt callback.
    /// - Parameters:
    ///   - sessionID: Target session.
    ///   - token: Registration token.
    public func unregisterInterrupt(sessionID: UUID, token: UUID) {
        guard var tokens = interruptTokens[sessionID] else { return }
        tokens.removeValue(forKey: token)
        if var order = interruptInsertionOrder[sessionID] {
            order.removeAll(where: { $0 == token })
            if tokens.isEmpty {
                interruptInsertionOrder.removeValue(forKey: sessionID)
            } else {
                interruptInsertionOrder[sessionID] = order
            }
        }
        if tokens.isEmpty {
            // Drop the key so finished streams release their slot instead of
            // lingering as an empty entry that still counts toward the cap.
            interruptTokens.removeValue(forKey: sessionID)
            interruptOrder.removeAll(where: { $0 == sessionID })
        } else {
            interruptTokens[sessionID] = tokens
        }
    }

    /// Number of registered interrupt callbacks for a session.
    /// - Parameter sessionID: Target session.
    /// - Returns: Registered callback count, or zero when untracked.
    public func interruptCount(for sessionID: UUID) -> Int {
        interruptTokens[sessionID]?.count ?? 0
    }

    /// Number of sessions currently holding interrupt registrations.
    /// - Returns: Tracked session count.
    public func interruptSessionCount() -> Int {
        interruptTokens.count
    }

    /// Moves a pending session to the most-recent position.
    /// - Parameter sessionID: Touched session.
    private func markPendingTouched(_ sessionID: UUID) {
        if let prior = pendingOrder.firstIndex(of: sessionID) {
            pendingOrder.remove(at: prior)
        }
        pendingOrder.append(sessionID)
    }

    /// Moves an interrupt session to the most-recent position.
    /// - Parameter sessionID: Touched session.
    private func markInterruptTouched(_ sessionID: UUID) {
        if let prior = interruptOrder.firstIndex(of: sessionID) {
            interruptOrder.remove(at: prior)
        }
        interruptOrder.append(sessionID)
    }

    /// Evicts least-recently-touched pending sessions past the session cap.
    /// - Parameter preferring: Session that just wrote; never the eviction victim.
    private func evictPendingSessionsIfNeeded(preferring sessionID: UUID) {
        while pending.count > Self.maxTrackedSessions {
            let victim = pendingOrder.first(where: { $0 != sessionID })
                ?? pending.keys.first(where: { $0 != sessionID })
                ?? pendingOrder.first
            guard let victim else { break }
            pending.removeValue(forKey: victim)
            pendingOrder.removeAll(where: { $0 == victim })
        }
    }

    /// Evicts least-recently-touched interrupt sessions past the session cap.
    /// - Parameter preferring: Session that just registered; never the victim.
    private func evictInterruptSessionsIfNeeded(preferring sessionID: UUID) {
        while interruptTokens.count > Self.maxTrackedSessions {
            let victim = interruptOrder.first(where: { $0 != sessionID })
                ?? interruptTokens.keys.first(where: { $0 != sessionID })
                ?? interruptOrder.first
            guard let victim else { break }
            interruptTokens.removeValue(forKey: victim)
            interruptInsertionOrder.removeValue(forKey: victim)
            interruptOrder.removeAll(where: { $0 == victim })
        }
    }
}
