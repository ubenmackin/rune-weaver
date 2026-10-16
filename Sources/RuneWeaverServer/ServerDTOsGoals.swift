// Rune Weaver Server — Goals and proactive settings patches plus merge logic.

import Foundation
import RuneWeaverCore
import Vapor

// MARK: - Goals + Proactive Settings Patches

/// Partial `[goals]` patch for `PUT /settings`. Every field stays optional so a request carrying
/// only one key leaves the rest of the stored pursuit policy untouched instead of resetting it.
public struct GoalsUpdate: Content, Sendable, Equatable {
    /// Whether goal creation and advancement run at all. Nil preserves the stored value.
    public var enabled: Bool?
    /// Cadence hint in minutes stored on each new goal. Nil preserves the stored value.
    public var stepIntervalMinutes: Int?
    /// Maximum goals in the active state at once. Nil preserves the stored value.
    public var maxActiveGoals: Int?
    /// Maximum steps in one decomposed plan. Nil preserves the stored value.
    public var maxStepsPerGoal: Int?
    /// Seconds the planner waits on the model before falling back. Nil preserves the stored value.
    public var planTimeoutSeconds: Int?
    /// Maximum event triggers armed on one goal. Nil preserves the stored value.
    public var maxTriggersPerGoal: Int?

    /// Creates a partial goals patch.
    public init(
        enabled: Bool? = nil,
        stepIntervalMinutes: Int? = nil,
        maxActiveGoals: Int? = nil,
        maxStepsPerGoal: Int? = nil,
        planTimeoutSeconds: Int? = nil,
        maxTriggersPerGoal: Int? = nil
    ) {
        self.enabled = enabled
        self.stepIntervalMinutes = stepIntervalMinutes
        self.maxActiveGoals = maxActiveGoals
        self.maxStepsPerGoal = maxStepsPerGoal
        self.planTimeoutSeconds = planTimeoutSeconds
        self.maxTriggersPerGoal = maxTriggersPerGoal
    }

    /// Populates a patch from a full snapshot so programmatic callers holding
    /// a complete `GoalsConfig` reuse the same merge path.
    /// - Parameter config: Complete pursuit policy.
    public init(_ config: GoalsConfig) {
        self.enabled = config.enabled
        self.stepIntervalMinutes = config.stepIntervalMinutes
        self.maxActiveGoals = config.maxActiveGoals
        self.maxStepsPerGoal = config.maxStepsPerGoal
        self.planTimeoutSeconds = config.planTimeoutSeconds
        self.maxTriggersPerGoal = config.maxTriggersPerGoal
    }
}

/// Partial `[proactive]` patch for `PUT /settings`. Every field stays optional so a request
/// carrying only one key leaves the rest of the stored interruption policy untouched instead of
/// resetting it.
public struct ProactiveUpdate: Content, Sendable, Equatable {
    /// Surfacing mode raw value (`all`, `milestones`, `guarded`, `off`). Nil preserves the stored value.
    public var mode: String?
    /// Seconds the guarded judge may spend before the gate fails open. Nil preserves the stored value.
    public var judgeTimeoutSeconds: Int?

    /// Creates a partial proactive patch.
    public init(
        mode: String? = nil,
        judgeTimeoutSeconds: Int? = nil
    ) {
        self.mode = mode
        self.judgeTimeoutSeconds = judgeTimeoutSeconds
    }

    /// Populates a patch from a full snapshot so programmatic callers holding
    /// a complete `ProactiveConfig` reuse the same merge path.
    /// - Parameter config: Complete interruption policy.
    public init(_ config: ProactiveConfig) {
        self.mode = config.mode.rawValue
        self.judgeTimeoutSeconds = config.judgeTimeoutSeconds
    }
}

extension UpdateSettingsRequest {
    /// Builds a request from a full goals snapshot, routing through the same
    /// merge path so snapshot callers keep working without hand-mapping fields.
    /// - Parameter goals: Complete pursuit policy.
    public init(goals: GoalsConfig) {
        self.init(goals: GoalsUpdate(goals))
    }

    /// Builds a request from a full proactive snapshot, routing through the same merge path so
    /// snapshot callers keep working without hand-mapping fields.
    /// - Parameter proactive: Complete interruption policy.
    public init(proactive: ProactiveConfig) {
        self.init(proactive: ProactiveUpdate(proactive))
    }
}

// MARK: - Goals + Proactive Settings Merge

extension UpdateSettingsRequest {
    /// Merges a partial goals patch onto the stored policy, preserving every field the request
    /// omits. A nil patch is a no-op, so a dashboard edit elsewhere never resets the `[goals]`
    /// section.
    func applyGoals(to goals: inout GoalsConfig) {
        guard let update = self.goals else { return }
        if let enabled = update.enabled {
            goals.enabled = enabled
        }
        if let stepIntervalMinutes = update.stepIntervalMinutes {
            goals.stepIntervalMinutes = stepIntervalMinutes
        }
        if let maxActiveGoals = update.maxActiveGoals {
            goals.maxActiveGoals = maxActiveGoals
        }
        if let maxStepsPerGoal = update.maxStepsPerGoal {
            goals.maxStepsPerGoal = maxStepsPerGoal
        }
        if let planTimeoutSeconds = update.planTimeoutSeconds {
            goals.planTimeoutSeconds = planTimeoutSeconds
        }
        if let maxTriggersPerGoal = update.maxTriggersPerGoal {
            goals.maxTriggersPerGoal = maxTriggersPerGoal
        }
    }

    /// Merges a partial proactive patch onto the stored policy, preserving every field the request
    /// omits. A nil patch is a no-op, so a dashboard edit elsewhere never resets the `[proactive]`
    /// section.
    func applyProactive(to proactive: inout ProactiveConfig) throws {
        guard let update = self.proactive else { return }
        if let mode = update.mode {
            let trimmed = mode.trimmingCharacters(in: .whitespacesAndNewlines)
            // Lowercase before the closed-set lookup so `PUT /settings`
            // accepts the same `ALL`/`All` spellings the file loader accepts;
            // the error still names the original input for diagnosability.
            guard let parsed = ProactiveMode(rawValue: trimmed.lowercased()) else {
                throw ConfigError.validationError(
                    field: "proactive.mode",
                    message: "must be one of \(ProactiveMode.allCases.map(\.rawValue).joined(separator: ", ")) (got '\(mode)')"
                )
            }
            proactive.mode = parsed
        }
        if let judgeTimeoutSeconds = update.judgeTimeoutSeconds {
            proactive.judgeTimeoutSeconds = judgeTimeoutSeconds
        }
    }
}
