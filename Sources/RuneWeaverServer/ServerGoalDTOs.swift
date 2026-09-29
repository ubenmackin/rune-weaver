// Rune Weaver Server — Goal pursuit DTOs for the engine API.
//
// Purpose: carries the goal, step, event, and summary wire shapes so list,
// detail, advancement, and live-push payloads encode identically on both ends
// of the wire.
// Scope: goal REST and WebSocket contracts only; route registration, auth
// gating, and persistence stay with the route and store layers.
// Architectural role: keeps the goal adapters decoupled from the engine core
// in version-tolerant Codable contracts, so a dashboard built against an
// older engine still decodes.

import Foundation
import RuneWeaverCore
import Vapor

// MARK: - Goals DTOs

/// Finished-versus-planned tally nested under one goal.
///
/// Single-sourced from the core live-push tally so REST rows and WebSocket
/// frames share one field set and one clamping rule instead of drifting
/// field-for-field. Done counts only `done` steps so blocked work never
/// inflates progress; an empty plan reads as 0/0.
public typealias GoalProgressDTO = RuneWeaverCore.WSGoalProgress

/// Wire shape of one goal for list, detail, and `goal_updated` pushes.
///
/// Single-sourced from the core snapshot so REST rows and live pushes share
/// one JSON shape: progress rides nested so the row stays self-contained,
/// dates travel as server instants, and the origin session stays optional
/// because headless and imported goals may have no owning conversation.
/// The alias keeps existing `GoalDTO` call sites compiling while the struct
/// lives once in core.
public typealias GoalDTO = RuneWeaverCore.WSGoalSnapshot

extension RuneWeaverCore.WSGoalProgress: Content {}
extension RuneWeaverCore.WSGoalSnapshot: Content {}

public extension RuneWeaverCore.WSGoalSnapshot {
    /// Builds a DTO from a stored goal plus its plan, deriving progress locally
    /// so list fan-out never issues a second query per row for counts.
    /// - Parameters:
    ///   - goal: Stored goal snapshot.
    ///   - steps: Full plan ordered by ordinal.
    init(goal: Goal, steps: [GoalStep]) {
        let done = steps.filter { $0.status == .done }.count
        self.init(
            id: goal.id,
            title: goal.title,
            statement: goal.statement,
            status: goal.status.rawValue,
            progress: RuneWeaverCore.WSGoalProgress(done: done, total: steps.count),
            stepIntervalMinutes: goal.stepIntervalMinutes,
            nextDueAt: goal.nextDueAt,
            originSessionID: goal.originSessionID,
            createdAt: goal.createdAt,
            updatedAt: goal.updatedAt
        )
    }

    /// Live-push snapshot for this DTO.
    ///
    /// Identity now that the REST row aliases the core snapshot; kept so
    /// existing broadcast call sites keep compiling without a second fetch.
    /// - Returns: This snapshot.
    func wsSnapshot() -> RuneWeaverCore.WSGoalSnapshot {
        self
    }
}

/// Wire shape of one ordered step within a goal plan.
///
/// Ordinal decides display order; status rides as its raw value so dashboards
/// never branch on unknown cases. Notes stay optional because most moves carry
/// no annotation.
public struct GoalStepDTO: Content, Sendable, Equatable {
    /// Stable step identifier.
    public let id: UUID
    /// Owning goal.
    public let goalID: UUID
    /// Zero-based position.
    public let ordinal: Int
    /// Short human-readable step title.
    public let title: String
    /// Step state raw value.
    public let status: String
    /// Operator or engine annotation, when present.
    public let notes: String?
    /// Session-scoped correlation tagging the chat that last moved this step.
    public let lastRunID: UUID?
    /// When the step was first persisted.
    public let createdAt: Date
    /// When the step last changed.
    public let updatedAt: Date

    /// Creates a step DTO.
    public init(
        id: UUID,
        goalID: UUID,
        ordinal: Int,
        title: String,
        status: String,
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

    /// Builds a DTO from a stored step.
    /// - Parameter step: Stored step snapshot.
    public init(_ step: GoalStep) {
        self.init(
            id: step.id,
            goalID: step.goalID,
            ordinal: step.ordinal,
            title: step.title,
            status: step.status.rawValue,
            notes: step.notes,
            lastRunID: step.lastRunID,
            createdAt: step.createdAt,
            updatedAt: step.updatedAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case goalId
        case goalID
        case goalSnake = "goal_id"
        case ordinal
        case title
        case status
        case notes
        case lastRunId
        case lastRunID
        case lastRunSnake = "last_run_id"
        case createdAt
        case updatedAt
    }

    /// Decodes tolerantly across the goal and run identifier spellings through
    /// the shared alias helper so the three historical keys converge without
    /// triplicating the fallback chain. Canonical `goalId`/`lastRunId` win
    /// when several spellings ride together.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        guard let goalID: UUID = BrowserNavigateWire.decodeFirst(
            container,
            keys: [.goalId, .goalID, .goalSnake]
        ) else {
            throw DecodingError.keyNotFound(
                CodingKeys.goalId,
                DecodingError.Context(codingPath: container.codingPath, debugDescription: "Missing goal identifier")
            )
        }
        self.goalID = goalID
        self.ordinal = try container.decode(Int.self, forKey: .ordinal)
        self.title = try container.decode(String.self, forKey: .title)
        self.status = try container.decode(String.self, forKey: .status)
        self.notes = try container.decodeIfPresent(String.self, forKey: .notes)
        let lastRunID: UUID? = BrowserNavigateWire.decodeFirst(
            container,
            keys: [.lastRunId, .lastRunID, .lastRunSnake]
        )
        self.lastRunID = lastRunID
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    /// Encodes under the canonical spellings (`goalId`, `lastRunId`) so older
    /// decoders see no new key.
    /// - Parameter encoder: Destination encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(goalID, forKey: .goalId)
        try container.encode(ordinal, forKey: .ordinal)
        try container.encode(title, forKey: .title)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encodeIfPresent(lastRunID, forKey: .lastRunId)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

/// Wire shape of one append-only audit entry for a goal.
///
/// Identifiers ride the SQLite rowid (zero means not-yet-persisted) so the
/// trail stays ordered without inventing a second sequence.
public struct GoalEventDTO: Content, Sendable, Equatable {
    /// SQLite rowid.
    public let id: Int64
    /// Owning goal.
    public let goalID: UUID
    /// Why the entry was recorded.
    public let kind: String
    /// Human-readable detail.
    public let message: String
    /// When the entry was recorded.
    public let createdAt: Date

    /// Creates an event DTO.
    public init(id: Int64, goalID: UUID, kind: String, message: String, createdAt: Date = Date()) {
        self.id = id
        self.goalID = goalID
        self.kind = kind
        self.message = message
        self.createdAt = createdAt
    }

    /// Builds a DTO from a stored event.
    /// - Parameter event: Stored event snapshot.
    public init(_ event: GoalEvent) {
        self.init(id: event.id, goalID: event.goalID, kind: event.kind.rawValue, message: event.message, createdAt: event.createdAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case goalId
        case goalID
        case goalSnake = "goal_id"
        case kind
        case message
        case createdAt
    }

    /// Decodes tolerantly across the goal identifier spellings through the
    /// shared alias helper. Canonical `goalId` wins when several spellings
    /// ride together.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(Int64.self, forKey: .id)
        guard let goalID: UUID = BrowserNavigateWire.decodeFirst(
            container,
            keys: [.goalId, .goalID, .goalSnake]
        ) else {
            throw DecodingError.keyNotFound(
                CodingKeys.goalId,
                DecodingError.Context(codingPath: container.codingPath, debugDescription: "Missing goal identifier")
            )
        }
        self.goalID = goalID
        self.kind = try container.decode(String.self, forKey: .kind)
        self.message = try container.decode(String.self, forKey: .message)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    /// Encodes under the canonical `goalId` spelling.
    /// - Parameter encoder: Destination encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(goalID, forKey: .goalId)
        try container.encode(kind, forKey: .kind)
        try container.encode(message, forKey: .message)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

/// Goal list response for `GET /goals`.
public struct GoalsListResponse: Content, Equatable {
    /// Goals, oldest first.
    public let goals: [GoalDTO]
    /// Number of goals in `goals`.
    public let count: Int

    /// Creates a list response.
    /// - Parameter goals: Goal DTOs.
    public init(goals: [GoalDTO]) {
        self.goals = goals
        self.count = goals.count
    }
}

/// Wire shape of one armed event wake-up on a goal.
///
/// Carries the debounce stamp so the dashboard can show an armed trigger that
/// has not fired yet; the identifier lets a later edit target one trigger.
public struct GoalTriggerDTO: Content, Sendable, Equatable {
    /// Stable trigger identifier.
    public let id: UUID
    /// Owning goal.
    public let goalID: UUID
    /// Event kind the trigger watches.
    public let eventKind: String
    /// Optional substring filter on the event message.
    public let pattern: String?
    /// Debounce window in minutes.
    public let cooldownMinutes: Int
    /// When the trigger last fired; nil means never.
    public let lastFiredAt: Date?
    /// When the trigger was armed.
    public let createdAt: Date

    /// Creates a trigger DTO.
    public init(
        id: UUID,
        goalID: UUID,
        eventKind: String,
        pattern: String? = nil,
        cooldownMinutes: Int,
        lastFiredAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.goalID = goalID
        self.eventKind = eventKind
        self.pattern = pattern
        self.cooldownMinutes = cooldownMinutes
        self.lastFiredAt = lastFiredAt
        self.createdAt = createdAt
    }

    /// Builds a DTO from a stored trigger.
    /// - Parameter trigger: Stored trigger snapshot.
    public init(_ trigger: GoalTrigger) {
        self.init(
            id: trigger.id,
            goalID: trigger.goalID,
            eventKind: trigger.eventKind,
            pattern: trigger.trimmedPattern,
            cooldownMinutes: trigger.cooldownMinutes,
            lastFiredAt: trigger.lastFiredAt,
            createdAt: trigger.createdAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case goalId
        case goalID
        case goalSnake = "goal_id"
        case eventKind
        case eventKindSnake = "event_kind"
        case pattern
        case cooldownMinutes
        case cooldownSnake = "cooldown_minutes"
        case lastFiredAt
        case lastFiredSnake = "last_fired_at"
        case createdAt
        case createdAtSnake = "created_at"
    }

    /// Decodes tolerantly across the goal and trigger identifier spellings,
    /// routing through the shared alias helper so one payload cannot fork the
    /// row shape. Canonical camelCase spellings win when several ride together.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        guard let goalID: UUID = BrowserNavigateWire.decodeFirst(
            container,
            keys: [.goalId, .goalID, .goalSnake]
        ) else {
            throw DecodingError.keyNotFound(
                CodingKeys.goalId,
                DecodingError.Context(codingPath: container.codingPath, debugDescription: "Missing goal identifier")
            )
        }
        self.goalID = goalID
        guard let eventKind: String = BrowserNavigateWire.decodeFirst(
            container,
            keys: [.eventKind, .eventKindSnake]
        ) else {
            throw DecodingError.keyNotFound(
                CodingKeys.eventKind,
                DecodingError.Context(codingPath: container.codingPath, debugDescription: "Missing event kind")
            )
        }
        self.eventKind = eventKind
        self.pattern = try container.decodeIfPresent(String.self, forKey: .pattern)
        self.cooldownMinutes = BrowserNavigateWire.decodeFirst(container, keys: [.cooldownMinutes, .cooldownSnake]) ?? 0
        self.lastFiredAt = BrowserNavigateWire.decodeFirst(container, keys: [.lastFiredAt, .lastFiredSnake])
        self.createdAt = BrowserNavigateWire.decodeFirst(container, keys: [.createdAt, .createdAtSnake]) ?? Date()
    }

    /// Encodes under the canonical spellings so older decoders see no new key.
    /// - Parameter encoder: Destination encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(goalID, forKey: .goalId)
        try container.encode(eventKind, forKey: .eventKind)
        try container.encodeIfPresent(pattern, forKey: .pattern)
        try container.encode(cooldownMinutes, forKey: .cooldownMinutes)
        try container.encodeIfPresent(lastFiredAt, forKey: .lastFiredAt)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

/// One event wake-up supplied when creating or patching a goal over REST.
///
/// The kind is required; the pattern and cooldown stay optional so the common
/// case needs one field. Aliases mirror the dashboard contract so hand-built
/// curls and typed clients agree.
public struct GoalTriggerInput: Content, Sendable, Equatable {
    /// Event kind to watch.
    public let eventKind: String
    /// Optional substring filter on the event message.
    public let pattern: String?
    /// Optional debounce window in minutes; nil inherits the default.
    public let cooldownMinutes: Int?

    /// Creates a trigger input.
    public init(eventKind: String, pattern: String? = nil, cooldownMinutes: Int? = nil) {
        self.eventKind = eventKind
        self.pattern = pattern
        self.cooldownMinutes = cooldownMinutes
    }

    private enum CodingKeys: String, CodingKey {
        case eventKind
        case eventKindSnake = "event_kind"
        case kind
        case pattern
        case cooldownMinutes
        case cooldownSnake = "cooldown_minutes"
        case cooldown
    }

    /// Decodes trigger input, accepting the documented aliases.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let eventKind: String = BrowserNavigateWire.decodeFirst(
            container,
            keys: [.eventKind, .eventKindSnake, .kind]
        ) else {
            throw DecodingError.keyNotFound(
                CodingKeys.eventKind,
                DecodingError.Context(codingPath: container.codingPath, debugDescription: "Missing event kind")
            )
        }
        self.eventKind = eventKind
        self.pattern = try container.decodeIfPresent(String.self, forKey: .pattern)
        self.cooldownMinutes = BrowserNavigateWire.decodeFirst(
            container,
            keys: [.cooldownMinutes, .cooldownSnake, .cooldown]
        )
    }

    /// Encodes under the canonical camelCase spellings.
    /// - Parameter encoder: Destination encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(eventKind, forKey: .eventKind)
        try container.encodeIfPresent(pattern, forKey: .pattern)
        try container.encodeIfPresent(cooldownMinutes, forKey: .cooldownMinutes)
    }

    /// Trimmed event kind.
    public var trimmedEventKind: String {
        eventKind.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trimmed pattern, nil when absent or blank.
    public var trimmedPattern: String? {
        guard let pattern else { return nil }
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Goal detail response for `GET /goals/:id` and mutating goal routes.
///
/// Steps ride whole because plans stay small by config bound; events ride
/// bounded by the caller's limit so long audit trails never crowd the row.
public struct GoalDetailResponse: Content, Equatable {
    /// Goal row.
    public let goal: GoalDTO
    /// Full plan ordered by ordinal.
    public let steps: [GoalStepDTO]
    /// Armed event wake-ups, oldest first.
    public let triggers: [GoalTriggerDTO]
    /// Bounded audit trail, oldest first.
    public let events: [GoalEventDTO]

    /// Creates a detail response.
    public init(
        goal: GoalDTO,
        steps: [GoalStepDTO],
        triggers: [GoalTriggerDTO] = [],
        events: [GoalEventDTO]
    ) {
        self.goal = goal
        self.steps = steps
        self.triggers = triggers
        self.events = events
    }
}

/// Goal creation request for `POST /goals`.
public struct GoalCreateRequest: Content, Equatable {
    /// Short human-readable title.
    public let title: String
    /// Fuller statement of intent.
    public let statement: String
    /// Cadence hint in minutes; defaults to the configured interval when omitted.
    public let stepIntervalMinutes: Int?
    /// Event wake-ups to arm alongside the goal, when supplied.
    public let triggers: [GoalTriggerInput]?

    /// Creates a creation request.
    public init(
        title: String,
        statement: String,
        stepIntervalMinutes: Int? = nil,
        triggers: [GoalTriggerInput]? = nil
    ) {
        self.title = title
        self.statement = statement
        self.stepIntervalMinutes = stepIntervalMinutes
        self.triggers = triggers
    }
}

/// Goal edit request for `PATCH /goals/:id`.
///
/// Every field is optional so one call can rename, restate, retime, or flip
/// lifecycle state; absent keys leave their columns untouched. A blank title or
/// statement is rejected rather than stored, so partial edits cannot wipe a
/// field with whitespace.
public struct GoalPatchRequest: Content, Equatable {
    /// New lifecycle state raw value, when changing state.
    public let status: String?
    /// New title, when renaming.
    public let title: String?
    /// New statement, when restating.
    public let statement: String?
    /// New cadence hint, when retiming.
    public let stepIntervalMinutes: Int?
    /// Replacement set of event wake-ups; present means replace every armed
    /// trigger, absent leaves the armed set untouched.
    public let triggers: [GoalTriggerInput]?

    /// Creates a patch request.
    public init(
        status: String? = nil,
        title: String? = nil,
        statement: String? = nil,
        stepIntervalMinutes: Int? = nil,
        triggers: [GoalTriggerInput]? = nil
    ) {
        self.status = status
        self.title = title
        self.statement = statement
        self.stepIntervalMinutes = stepIntervalMinutes
        self.triggers = triggers
    }
}

/// Manual step move for `PATCH /goals/:id/steps/:stepId`.
///
/// Status rides required because a move without a destination is a no-op that
/// would still log a note; the note stays optional so terse moves need no
/// annotation.
public struct GoalStepPatchRequest: Content, Equatable {
    /// Destination step state raw value.
    public let status: String
    /// Operator annotation, when present.
    public let note: String?

    /// Creates a step patch request.
    public init(status: String, note: String? = nil) {
        self.status = status
        self.note = note
    }
}

/// Goal counts for `GET /goals/summary`.
///
/// Explicit per-status tallies keep the dashboard badge free of key-string
/// branching. The parked badge reads `needsInput` directly.
public struct GoalsSummaryResponse: Content, Equatable {
    /// Total goals across every state.
    public let total: Int
    /// Goals actively pursued.
    public let active: Int
    /// Goals temporarily parked.
    public let paused: Int
    /// Goals parked awaiting owner input.
    public let needsInput: Int
    /// Goals finished.
    public let achieved: Int
    /// Goals dropped.
    public let abandoned: Int

    /// Creates a summary response.
    public init(total: Int, active: Int, paused: Int, needsInput: Int, achieved: Int, abandoned: Int) {
        self.total = total
        self.active = active
        self.paused = paused
        self.needsInput = needsInput
        self.achieved = achieved
        self.abandoned = abandoned
    }

    private enum CodingKeys: String, CodingKey {
        case total
        case active
        case paused
        case needsInput
        case needsInputSnake = "needs_input"
        case achieved
        case abandoned
        // `needsInputCount` is intentionally absent: historical payloads
        // carrying the duplicate decode by ignoring the unknown key, while
        // new payloads never encode it.
    }

    /// Decodes tolerantly across the parked key spellings, ignoring the
    /// retired `needsInputCount` duplicate when present.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.total = try container.decode(Int.self, forKey: .total)
        self.active = try container.decode(Int.self, forKey: .active)
        self.paused = try container.decode(Int.self, forKey: .paused)
        if let camel = try container.decodeIfPresent(Int.self, forKey: .needsInput) {
            self.needsInput = camel
        } else {
            self.needsInput = try container.decodeIfPresent(Int.self, forKey: .needsInputSnake) ?? 0
        }
        self.achieved = try container.decode(Int.self, forKey: .achieved)
        self.abandoned = try container.decode(Int.self, forKey: .abandoned)
    }

    /// Encodes under the canonical camelCase spellings without the retired duplicate.
    /// - Parameter encoder: Destination encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(total, forKey: .total)
        try container.encode(active, forKey: .active)
        try container.encode(paused, forKey: .paused)
        try container.encode(needsInput, forKey: .needsInput)
        try container.encode(achieved, forKey: .achieved)
        try container.encode(abandoned, forKey: .abandoned)
    }
}

/// Manual-advance receipt for `POST /goals/:id/advance`.
///
/// Carries both durable identifiers so the dashboard can link the fresh run row
/// and its session without a second lookup: the run row supplies the audit
/// trail while the session supplies the conversation.
public struct GoalAdvanceResponse: Content, Equatable {
    /// Run-log row for the advancement turn.
    public let runID: UUID
    /// Per-run session the turn executed under.
    public let sessionID: UUID
    /// Goal that was advanced.
    public let goalID: UUID

    /// Creates an advance receipt.
    public init(runID: UUID, sessionID: UUID, goalID: UUID) {
        self.runID = runID
        self.sessionID = sessionID
        self.goalID = goalID
    }

    private enum CodingKeys: String, CodingKey {
        case runID
        case runId
        case runSnake = "run_id"
        case sessionID
        case sessionId
        case sessionSnake = "session_id"
        case goalId
        case goalID
        case goalSnake = "goal_id"
    }

    /// Decodes tolerantly across the run, session, and goal identifier
    /// spellings through the shared alias helper. Canonical keys
    /// (`runID`, `sessionID`, `goalId`) win when several spellings ride
    /// together.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let runID: UUID = BrowserNavigateWire.decodeFirst(
            container,
            keys: [.runID, .runId, .runSnake]
        ) else {
            throw DecodingError.keyNotFound(
                CodingKeys.runID,
                DecodingError.Context(codingPath: container.codingPath, debugDescription: "Missing run identifier")
            )
        }
        self.runID = runID
        guard let sessionID: UUID = BrowserNavigateWire.decodeFirst(
            container,
            keys: [.sessionID, .sessionId, .sessionSnake]
        ) else {
            throw DecodingError.keyNotFound(
                CodingKeys.sessionID,
                DecodingError.Context(codingPath: container.codingPath, debugDescription: "Missing session identifier")
            )
        }
        self.sessionID = sessionID
        guard let goalID: UUID = BrowserNavigateWire.decodeFirst(
            container,
            keys: [.goalId, .goalID, .goalSnake]
        ) else {
            throw DecodingError.keyNotFound(
                CodingKeys.goalId,
                DecodingError.Context(codingPath: container.codingPath, debugDescription: "Missing goal identifier")
            )
        }
        self.goalID = goalID
    }

    /// Encodes under the canonical spellings per identifier family: runs as
    /// `runID`, sessions as `sessionID`, goals as `goalId`. Tolerant decode
    /// keeps every historical spelling landing.
    /// - Parameter encoder: Destination encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(runID, forKey: .runID)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(goalID, forKey: .goalId)
    }
}

/// Goal change broadcast, single-sourced from core.
public typealias WSGoalUpdatedFrame = RuneWeaverCore.WSGoalUpdatedFrame
/// Goal snapshot for live pushes, single-sourced from core.
public typealias WSGoalSnapshot = RuneWeaverCore.WSGoalSnapshot
/// Goal progress tally for live pushes, single-sourced from core.
public typealias WSGoalProgress = RuneWeaverCore.WSGoalProgress
/// Owner-visible nudge volunteered outside any turn, single-sourced from core.
public typealias WSProactiveMessageFrame = RuneWeaverCore.WSProactiveMessageFrame
