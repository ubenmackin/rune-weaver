// Rune Weaver Core — Durable goal model for long-horizon pursuit tracking.
//
// Defines the value types behind steady goal pursuit: lifecycle states for
// goals and their ordered steps, the audit events that explain every
// transition, and the Codable snapshots the store round-trips. These are
// storage-agnostic value objects so schedulers, engines, and tools can
// assemble goals before the SQLite sidecar exists; `GoalStore` owns
// persistence alongside the existing episode, session, and run-log tables.

import Foundation

/// Lifecycle state for a long-horizon goal.
///
/// Raw values are the stable wire and SQLite strings, so renaming a case
/// never silently rewrites persisted rows. The `needsInput` pause exists so
/// the engine can park a goal awaiting the owner instead of churning due
/// checks while blocked.
public enum GoalStatus: String, Sendable, Codable, CaseIterable, Equatable {
    /// Actively pursued; eligible for due advancement.
    case active
    /// Temporarily parked by the owner or engine.
    case paused
    /// Parked awaiting owner input; excluded from due advancement until resumed.
    case needsInput = "needs_input"
    /// All actionable work finished; terminal.
    case achieved
    /// Dropped by the owner or engine; terminal.
    case abandoned
}

/// Lifecycle state for one ordered step within a goal plan.
///
/// Only `pending` and `inProgress` count as actionable; every other state is
/// a resting place the engine must look past when deriving the next move.
public enum StepStatus: String, Sendable, Codable, CaseIterable, Equatable {
    /// Planned but not yet started; the only state `replacePlan` removes.
    case pending
    /// Currently underway.
    case inProgress = "in_progress"
    /// Finished; never actionable again.
    case done
    /// Stalled on an obstacle; skipped by the actionable-step scan so a later
    /// step can still move while the blockage awaits attention.
    case blocked
    /// Deliberately omitted; never actionable again.
    case skipped
}

/// Audit reason for one row in the goal event log.
///
/// The log is append-only institutional memory: status flips, plan swaps,
/// and step moves each leave a typed breadcrumb so later turns can explain
/// why a goal looks the way it does without replaying tool history.
public enum GoalEventKind: String, Sendable, Codable, CaseIterable, Equatable {
    /// Goal row first created.
    case created
    /// Plan inserted or replaced.
    case planReady = "plan_ready"
    /// A step moved into progress.
    case stepStarted = "step_started"
    /// A step moved to done.
    case stepDone = "step_done"
    /// A step moved to blocked.
    case stepBlocked = "step_blocked"
    /// Goal parked awaiting owner input.
    case needsInput = "needs_input"
    /// Goal reached its terminal achieved state.
    case completed
    /// Goal resumed back to active.
    case resumed
    /// Goal paused.
    case paused
    /// Freeform annotation that carries no lifecycle transition.
    case note
}

/// One long-horizon goal: the durable unit of steady pursuit.
public struct Goal: Sendable, Codable, Equatable, Identifiable {
    /// Stable identifier shared by steps and events.
    public let id: UUID
    /// Short human-readable title.
    public let title: String
    /// Fuller statement of intent shown to the owner and model.
    public let statement: String
    /// Current lifecycle state.
    public var status: GoalStatus
    /// Cadence hint in minutes between due advancements.
    public var stepIntervalMinutes: Int
    /// Next time the goal becomes due; nil means no schedule.
    public var nextDueAt: Date?
    /// Session that originated the goal, when known.
    public let originSessionID: UUID?
    /// When the goal was first persisted.
    public let createdAt: Date
    /// When the goal row last changed.
    public var updatedAt: Date

    /// Creates a goal snapshot.
    public init(
        id: UUID = UUID(),
        title: String,
        statement: String,
        status: GoalStatus = .active,
        stepIntervalMinutes: Int,
        nextDueAt: Date? = nil,
        originSessionID: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.statement = statement
        self.status = status
        self.stepIntervalMinutes = stepIntervalMinutes
        self.nextDueAt = nextDueAt
        self.originSessionID = originSessionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// One ordered step within a goal plan.
public struct GoalStep: Sendable, Codable, Equatable, Identifiable {
    /// Stable step identifier.
    public let id: UUID
    /// Owning goal.
    public let goalID: UUID
    /// Zero-based position; the actionable scan always favors the smallest.
    public let ordinal: Int
    /// Short human-readable step title.
    public let title: String
    /// Current step state.
    public var status: StepStatus
    /// Operator or engine annotation; never a secret.
    public var notes: String?
    /// Session-scoped correlation tagging the chat that last moved this step.
    ///
    /// Carries the originating conversation (session) identifier rather than a
    /// durable run-log identifier: server goal runs keep distinct run-log and
    /// session IDs, so this stays session-tagged for dashboard linkage instead
    /// of claiming run provenance it cannot observe.
    public var lastRunID: UUID?
    /// When the step was first persisted.
    public let createdAt: Date
    /// When the step last changed.
    public var updatedAt: Date

    /// Creates a step snapshot.
    public init(
        id: UUID = UUID(),
        goalID: UUID,
        ordinal: Int,
        title: String,
        status: StepStatus = .pending,
        notes: String? = nil,
        lastRunID: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.goalID = goalID
        self.ordinal = ordinal
        self.title = title
        self.status = status
        self.notes = notes
        self.lastRunID = lastRunID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// One append-only audit entry for a goal.
public struct GoalEvent: Sendable, Codable, Equatable, Identifiable {
    /// SQLite rowid; zero marks a not-yet-persisted entry.
    public let id: Int64
    /// Owning goal.
    public let goalID: UUID
    /// Why the entry was recorded.
    public let kind: GoalEventKind
    /// Human-readable detail; never a secret.
    public let message: String
    /// When the entry was recorded.
    public let createdAt: Date

    /// Creates an event snapshot.
    public init(
        id: Int64 = 0,
        goalID: UUID,
        kind: GoalEventKind,
        message: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.goalID = goalID
        self.kind = kind
        self.message = message
        self.createdAt = createdAt
    }
}

// MARK: - Shared goal input validation

/// Neutral validation failures for goal inputs shared by the service and CLI.
///
/// Carries only the offending value so each surface keeps its own error idiom:
/// the REST layer maps to `Abort(.badRequest)` while the CLI maps to
/// `ValidationError`. Bounds and alias sets live here once so the two
/// surfaces cannot drift on what counts as valid.
public enum GoalValidationError: Error, Sendable, Equatable {
    /// Title trimmed to empty.
    case emptyTitle
    /// Statement trimmed to empty.
    case emptyStatement
    /// Required goal status trimmed to empty.
    case emptyGoalStatus
    /// Required step status trimmed to empty.
    case emptyStepStatus
    /// Cadence hint outside the steady pursuit bounds.
    case cadenceOutOfRange(Int)
    /// Unknown goal lifecycle value after trimming.
    case unknownGoalStatus(String)
    /// Unknown step lifecycle value after trimming.
    case unknownStepStatus(String)
}

/// Single-sourced validators for goal titles, statements, cadences, and statuses.
///
/// Trims once, accepts only exact `rawValue` spellings plus one documented
/// camelCase alias per lifecycle family (`needsInput` for goals,
/// `inProgress` for steps) so dashboard selects, CLI flags, and REST filters
/// agree. Case-insensitive fallbacks are intentionally absent: `ACTIVE` must
/// fail rather than silently list.
public enum GoalValidation: Sendable {
    /// Validates a goal title, rejecting whitespace-only input.
    /// - Parameter raw: Raw title.
    /// - Returns: Trimmed title.
    public static func validatedTitle(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GoalValidationError.emptyTitle }
        return trimmed
    }

    /// Validates a goal statement, rejecting whitespace-only input.
    /// - Parameter raw: Raw statement.
    /// - Returns: Trimmed statement.
    public static func validatedStatement(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GoalValidationError.emptyStatement }
        return trimmed
    }

    /// Validates an optional cadence hint against the steady pursuit bounds.
    ///
    /// Nil passes through so creation falls back to the configured interval.
    /// - Parameter raw: Raw interval, or nil when omitted.
    /// - Returns: Validated interval, or nil.
    public static func validateCadence(_ raw: Int?) throws -> Int? {
        guard let raw else { return nil }
        guard raw >= GoalsConfig.minStepIntervalMinutes, raw <= GoalsConfig.maxStepIntervalMinutes else {
            throw GoalValidationError.cadenceOutOfRange(raw)
        }
        return raw
    }

    /// Parses a required goal lifecycle state, accepting only the exact
    /// `rawValue` plus the `needsInput` camelCase alias for the parked state.
    /// - Parameter raw: Raw status value.
    /// - Returns: Parsed state.
    public static func parseGoalStatus(_ raw: String) throws -> GoalStatus {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GoalValidationError.emptyGoalStatus }
        if trimmed == "needsInput" {
            return .needsInput
        }
        if let parsed = GoalStatus(rawValue: trimmed) {
            return parsed
        }
        throw GoalValidationError.unknownGoalStatus(trimmed)
    }

    /// Parses an optional goal status filter; blank and absent mean unfiltered.
    /// - Parameter raw: Raw status value, or nil when unfiltered.
    /// - Returns: Parsed filter, or nil.
    public static func parseGoalStatusFilter(_ raw: String?) throws -> GoalStatus? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try parseGoalStatus(trimmed)
    }

    /// Parses a required step state, accepting only the exact `rawValue` plus
    /// the `inProgress` camelCase alias for the underway state.
    /// - Parameter raw: Raw status value.
    /// - Returns: Parsed state.
    public static func parseStepStatus(_ raw: String) throws -> StepStatus {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GoalValidationError.emptyStepStatus }
        if trimmed == "inProgress" {
            return .inProgress
        }
        if let parsed = StepStatus(rawValue: trimmed) {
            return parsed
        }
        throw GoalValidationError.unknownStepStatus(trimmed)
    }
}

public extension GoalsConfig {
    /// Validates an optional cadence hint against the steady pursuit bounds.
    ///
    /// Thin forwarder over the shared validator so routes and CLI call the
    /// config-owned bound without duplicating the range.
    /// - Parameter raw: Raw interval, or nil when omitted.
    /// - Returns: Validated interval, or nil.
    static func validateCadence(_ raw: Int?) throws -> Int? {
        try GoalValidation.validateCadence(raw)
    }
}
