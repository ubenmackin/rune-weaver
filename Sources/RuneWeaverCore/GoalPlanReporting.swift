// Rune Weaver Core — Goal plan lifecycle reporting seam.

import Foundation

/// Snapshot carrying the state of a goal planning run.
public struct GoalPlanRunEvent: Sendable, Equatable {
    /// Stable run entry identifier.
    public let id: UUID
    /// Associated goal identifier.
    public let goalID: UUID
    /// Title of the goal being planned.
    public let goalTitle: String
    /// Status string (`"running"`, `"ok"`, `"error"`, or `"cancelled"`).
    public let status: String
    /// Description or prompt summary for the run.
    public let message: String
    /// Output or response summary, if finished.
    public let response: String?
    /// Execution duration in milliseconds, if finished.
    public let durationMs: Int?
    /// Timestamp for this event.
    public let timestamp: Date

    /// Creates a planning run event.
    public init(
        id: UUID = UUID(),
        goalID: UUID,
        goalTitle: String,
        status: String,
        message: String,
        response: String? = nil,
        durationMs: Int? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.goalID = goalID
        self.goalTitle = goalTitle
        self.status = status
        self.message = message
        self.response = response
        self.durationMs = durationMs
        self.timestamp = timestamp
    }
}

/// Seam that `GoalEngine` reports planning runs through.
public protocol GoalPlanReporting: Sendable {
    /// Reports that planning has started for a goal.
    func planStarted(_ event: GoalPlanRunEvent) async

    /// Reports that planning has reached a terminal outcome (success, error, or cancelled).
    func planCompleted(_ event: GoalPlanRunEvent) async
}

extension GoalPlanReporting {
    public func planStarted(_: GoalPlanRunEvent) async {}
    public func planCompleted(_: GoalPlanRunEvent) async {}
}

/// Default no-op reporter used when no transport or audit store is wired.
public struct NullGoalPlanReporter: GoalPlanReporting {
    public init() {}
}
