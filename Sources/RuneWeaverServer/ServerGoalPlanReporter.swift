// Rune Weaver Server — Goal plan run reporter.

import Foundation
import RuneWeaverCore

/// Adapter delivering goal planning lifecycle events onto `RunLogStore` and `WSHub`.
public struct ServerGoalPlanReporter: GoalPlanReporting {
    /// Kind tag applied to goal planning run rows.
    public static let kind = "goal"

    /// Durable run audit trail.
    private let runs: RunLogStore
    /// Live sockets receiving run broadcasts.
    private let hub: WSHub

    /// Creates a reporter.
    public init(runs: RunLogStore, hub: WSHub) {
        self.runs = runs
        self.hub = hub
    }

    /// Persists and broadcasts a planning start event.
    /// - Parameter event: The start event.
    public func planStarted(_ event: GoalPlanRunEvent) async {
        let entry = RunLogEntry(
            id: event.id,
            jobID: nil,
            sessionID: nil,
            goalID: event.goalID,
            kind: Self.kind,
            status: event.status,
            message: event.message,
            timestamp: event.timestamp,
            response: event.response,
            toolActions: [],
            totalTokens: nil,
            durationMs: event.durationMs
        )
        await runs.append(entry)
        await hub.broadcastRun(entry)
    }

    /// Persists and broadcasts a planning completion event.
    /// - Parameter event: The completion event.
    public func planCompleted(_ event: GoalPlanRunEvent) async {
        if let updated = await runs.update(
            id: event.id,
            status: event.status,
            response: event.response,
            durationMs: event.durationMs,
            timestamp: event.timestamp
        ) {
            await hub.broadcastRun(updated)
            return
        }
        let entry = RunLogEntry(
            id: event.id,
            jobID: nil,
            sessionID: nil,
            goalID: event.goalID,
            kind: Self.kind,
            status: event.status,
            message: event.message,
            timestamp: event.timestamp,
            response: event.response,
            toolActions: [],
            totalTokens: nil,
            durationMs: event.durationMs
        )
        await runs.append(entry)
        await hub.broadcastRun(entry)
    }
}
