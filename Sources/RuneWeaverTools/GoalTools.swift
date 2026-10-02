// Rune Weaver Tools — Goal pursuit tools for the shared ToolBus (`goal.create`, `goal.status`, `goal.progress`).
//
// Purpose: exposes long-horizon goals to the model as three tools: approval-gated creation with session
// linkage, read-only status showing plans plus dues plus recent events, and approval-gated ledger progress
// that records step outcomes without performing real-world actions.
// Scope: argument decoding, default-goal resolution, and engine/store dispatch only; persistence lives
// in GoalStore and planning in GoalEngine. Architectural role: the agent's cross-session memory of
// commitments — creation links the chat so the dashboard can badge it, status recalls promises, and
// progress mutates only the local ledger while real actions still ride their own permission-gated tools.

import Foundation
import RuneWeaverCore

// MARK: - Arguments

/// Arguments for `goal.create`.
public struct GoalCreateArgs: Sendable, Equatable, Decodable {
    /// Short human-readable title stored verbatim.
    public let title: String
    /// Fuller intent shown to the owner and model.
    public let statement: String
    /// Cadence hint in minutes; nil keeps the configured default.
    public let stepIntervalMinutes: Int?
    /// Event wake-ups to arm alongside the goal; nil arms none.
    public let triggers: [GoalTriggerArgs]?

    /// Creates create args.
    public init(title: String, statement: String, stepIntervalMinutes: Int? = nil, triggers: [GoalTriggerArgs]? = nil) {
        self.title = title
        self.statement = statement
        self.stepIntervalMinutes = stepIntervalMinutes
        self.triggers = triggers
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case statement
        case stepIntervalMinutes
        case stepIntervalSnake = "step_interval_minutes"
        case cadence
        case triggers
    }

    /// Decodes create args; `step_interval_minutes` and `cadence` are compatibility-only aliases kept out
    /// of the strict schema, which advertises `stepIntervalMinutes` only, so the wire stays fail-closed
    /// while older callers still decode.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        statement = try container.decode(String.self, forKey: .statement)
        if let direct = try container.decodeIfPresent(Int.self, forKey: .stepIntervalMinutes) {
            stepIntervalMinutes = direct
        } else if let snake = try container.decodeIfPresent(Int.self, forKey: .stepIntervalSnake) {
            stepIntervalMinutes = snake
        } else if let cadence = try container.decodeIfPresent(Int.self, forKey: .cadence) {
            stepIntervalMinutes = cadence
        } else {
            stepIntervalMinutes = nil
        }
        triggers = try container.decodeIfPresent([GoalTriggerArgs].self, forKey: .triggers)
    }

    /// Trimmed title.
    public var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trimmed statement.
    public var trimmedStatement: String {
        statement.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One event wake-up supplied to `goal.create`.
///
/// The kind is required so a trigger can never be armed against an unspecified
/// event; the pattern and cooldown stay optional so the common "wake me when
/// this event kind happens" case needs only one field.
public struct GoalTriggerArgs: Sendable, Equatable, Decodable {
    /// Event kind to watch (a goal audit kind or a bridge event kind).
    public let eventKind: String
    /// Optional substring the event message must contain.
    public let pattern: String?
    /// Optional debounce window in minutes; nil inherits the configured default.
    public let cooldownMinutes: Int?

    /// Creates trigger args.
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

    /// Decodes trigger args; `event_kind`/`kind` and `cooldown_minutes`/`cooldown` are compatibility-only
    /// aliases kept out of the strict schema, which advertises `eventKind` and `cooldownMinutes` only,
    /// so the wire stays fail-closed while older callers still decode.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let direct = try container.decodeIfPresent(String.self, forKey: .eventKind) {
            eventKind = direct
        } else if let snake = try container.decodeIfPresent(String.self, forKey: .eventKindSnake) {
            eventKind = snake
        } else if let kind = try container.decodeIfPresent(String.self, forKey: .kind) {
            eventKind = kind
        } else {
            eventKind = ""
        }
        pattern = try container.decodeIfPresent(String.self, forKey: .pattern)
        if let direct = try container.decodeIfPresent(Int.self, forKey: .cooldownMinutes) {
            cooldownMinutes = direct
        } else if let snake = try container.decodeIfPresent(Int.self, forKey: .cooldownSnake) {
            cooldownMinutes = snake
        } else if let cooldown = try container.decodeIfPresent(Int.self, forKey: .cooldown) {
            cooldownMinutes = cooldown
        } else {
            cooldownMinutes = nil
        }
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

/// Arguments for `goal.status`.
public struct GoalStatusArgs: Sendable, Equatable, Decodable {
    /// Goal identifier, when requesting one goal.
    public let goalID: String?
    /// When true, lists goals up to `limit`.
    public let all: Bool
    /// Maximum goals returned when `all` is true. The per-goal event tail is
    /// capped separately (see `eventLimit`) so a wide listing cannot fan out
    /// `limit` events times `limit` goals of context.
    public let limit: Int

    /// Default event/goal cap keeping status payloads small.
    public static let defaultLimit = 10
    /// Upper bound so status never fans out unbounded context.
    public static let maxLimit = 50
    /// Upper bound on recent events quoted per goal, independent of `limit`.
    public static let maxEventsPerGoal = 10

    /// Creates status args with limit clamping.
    public init(goalID: String? = nil, all: Bool = false, limit: Int = defaultLimit) {
        self.goalID = goalID
        self.all = all
        self.limit = min(max(limit, 1), Self.maxLimit)
    }

    private enum CodingKeys: String, CodingKey {
        case goalID
        case goalId
        case goalSnake = "goal_id"
        case id
        case all
        case limit
    }

    /// Decodes status args; `goalId`/`goal_id`/`id` are compatibility-only aliases kept out of the strict
    /// schema, which advertises `goalID` only, so the wire stays fail-closed while older callers still decode.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let resolvedGoalID: String? =
            if let direct = try container.decodeIfPresent(String.self, forKey: .goalID) {
                direct
            } else if let camel = try container.decodeIfPresent(String.self, forKey: .goalId) {
                camel
            } else if let snake = try container.decodeIfPresent(String.self, forKey: .goalSnake) {
                snake
            } else if let short = try container.decodeIfPresent(String.self, forKey: .id) {
                short
            } else {
                nil
            }
        let resolvedAll = try container.decodeIfPresent(Bool.self, forKey: .all) ?? false
        let rawLimit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? Self.defaultLimit
        self.init(goalID: resolvedGoalID, all: resolvedAll, limit: rawLimit)
    }

    /// Trimmed goal identifier, nil when absent or blank.
    public var trimmedGoalID: String? {
        guard let goalID else { return nil }
        let trimmed = goalID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Per-goal event tail bound: the caller's `limit` caps the goal count,
    /// while the quoted audit trail per goal never exceeds this bound.
    public var eventLimit: Int {
        min(limit, Self.maxEventsPerGoal)
    }
}

/// Arguments for `goal.progress`.
public struct GoalProgressArgs: Sendable, Equatable, Decodable {
    /// Goal identifier; nil resolves from the session link or the single active goal.
    public let goalID: String?
    /// Zero-based step position within the plan.
    public let stepOrdinal: Int?
    /// New step state (`done`, `blocked`, `in_progress`, `skipped`).
    public let status: String?
    /// Operator or engine annotation; a blocked note may park the goal awaiting input.
    public let note: String?

    /// Creates progress args.
    public init(goalID: String? = nil, stepOrdinal: Int? = nil, status: String? = nil, note: String? = nil) {
        self.goalID = goalID
        self.stepOrdinal = stepOrdinal
        self.status = status
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case goalID
        case goalId
        case goalSnake = "goal_id"
        case id
        case stepOrdinal
        case stepOrdinalSnake = "step_ordinal"
        case ordinal
        case step
        case status
        case state
        case note
        case notes
        case message
        case reason
    }

    /// Decodes progress args; goal, step, status, and note aliases are compatibility-only and kept out of
    /// the strict schema, which advertises `goalID`/`stepOrdinal`/`status`/`note` only, so the wire stays
    /// fail-closed while older callers still decode.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let direct = try container.decodeIfPresent(String.self, forKey: .goalID) {
            goalID = direct
        } else if let camel = try container.decodeIfPresent(String.self, forKey: .goalId) {
            goalID = camel
        } else if let snake = try container.decodeIfPresent(String.self, forKey: .goalSnake) {
            goalID = snake
        } else if let short = try container.decodeIfPresent(String.self, forKey: .id) {
            goalID = short
        } else {
            goalID = nil
        }
        if let direct = try container.decodeIfPresent(Int.self, forKey: .stepOrdinal) {
            stepOrdinal = direct
        } else if let snake = try container.decodeIfPresent(Int.self, forKey: .stepOrdinalSnake) {
            stepOrdinal = snake
        } else if let ordinal = try container.decodeIfPresent(Int.self, forKey: .ordinal) {
            stepOrdinal = ordinal
        } else if let step = try container.decodeIfPresent(Int.self, forKey: .step) {
            stepOrdinal = step
        } else {
            stepOrdinal = nil
        }
        if let direct = try container.decodeIfPresent(String.self, forKey: .status) {
            status = direct
        } else if let alias = try container.decodeIfPresent(String.self, forKey: .state) {
            status = alias
        } else {
            status = nil
        }
        if let direct = try container.decodeIfPresent(String.self, forKey: .note) {
            note = direct
        } else if let plural = try container.decodeIfPresent(String.self, forKey: .notes) {
            note = plural
        } else if let message = try container.decodeIfPresent(String.self, forKey: .message) {
            note = message
        } else if let reason = try container.decodeIfPresent(String.self, forKey: .reason) {
            note = reason
        } else {
            note = nil
        }
    }

    /// Trimmed goal identifier, nil when absent or blank.
    public var trimmedGoalID: String? {
        guard let goalID else { return nil }
        let trimmed = goalID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Trimmed status text, nil when absent or blank.
    public var trimmedStatus: String? {
        guard let status else { return nil }
        let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Trimmed note, nil when absent or blank.
    public var trimmedNote: String? {
        guard let note else { return nil }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Envelopes

/// Envelope wrapping `goal.create` output.
public struct GoalCreateEnvelope: Sendable, Equatable, Codable {
    /// Created goal identifier.
    public let goalID: String
    /// Stored title.
    public let title: String
    /// Stored statement.
    public let statement: String
    /// Lifecycle state after creation.
    public let status: String
    /// Cadence hint stored on the goal.
    public let stepIntervalMinutes: Int
    /// Next due time, when scheduled.
    public let nextDueAt: Date?
    /// Session linked to the goal, when the creating chat was known.
    public let sessionID: String?

    /// Creates a create envelope.
    public init(
        goalID: String,
        title: String,
        statement: String,
        status: String,
        stepIntervalMinutes: Int,
        nextDueAt: Date? = nil,
        sessionID: String? = nil
    ) {
        self.goalID = goalID
        self.title = title
        self.statement = statement
        self.status = status
        self.stepIntervalMinutes = stepIntervalMinutes
        self.nextDueAt = nextDueAt
        self.sessionID = sessionID
    }
}

/// One step within a `goal.status` detail.
public struct GoalStatusStep: Sendable, Equatable, Codable {
    /// Zero-based position.
    public let ordinal: Int
    /// Step title.
    public let title: String
    /// Step state.
    public let status: String
    /// Annotation, when present.
    public let notes: String?

    /// Creates a status step.
    public init(ordinal: Int, title: String, status: String, notes: String? = nil) {
        self.ordinal = ordinal
        self.title = title
        self.status = status
        self.notes = notes
    }
}

/// One armed event wake-up within a `goal.status` detail.
///
/// Carries the debounce stamp so the model can tell an armed-but-never-fired
/// trigger apart from one that has already pulled its goal forward.
public struct GoalStatusTrigger: Sendable, Equatable, Codable {
    /// Event kind the trigger watches.
    public let eventKind: String
    /// Optional substring filter on the event message.
    public let pattern: String?
    /// Debounce window in minutes.
    public let cooldownMinutes: Int
    /// When the trigger last fired; nil means never.
    public let lastFiredAt: Date?

    /// Creates a status trigger.
    public init(eventKind: String, pattern: String? = nil, cooldownMinutes: Int, lastFiredAt: Date? = nil) {
        self.eventKind = eventKind
        self.pattern = pattern
        self.cooldownMinutes = cooldownMinutes
        self.lastFiredAt = lastFiredAt
    }

    /// Builds a status trigger from a stored trigger.
    /// - Parameter trigger: Stored trigger snapshot.
    public init(_ trigger: GoalTrigger) {
        self.init(
            eventKind: trigger.eventKind,
            pattern: trigger.trimmedPattern,
            cooldownMinutes: trigger.cooldownMinutes,
            lastFiredAt: trigger.lastFiredAt
        )
    }
}

/// One audit entry within a `goal.status` detail.
public struct GoalStatusEvent: Sendable, Equatable, Codable {
    /// Audit reason.
    public let kind: String
    /// Human-readable detail.
    public let message: String
    /// When recorded.
    public let createdAt: Date

    /// Creates a status event.
    public init(kind: String, message: String, createdAt: Date) {
        self.kind = kind
        self.message = message
        self.createdAt = createdAt
    }
}

/// One goal with its plan and recent history for `goal.status`.
public struct GoalStatusDetail: Sendable, Equatable, Codable {
    /// Goal identifier.
    public let goalID: String
    /// Stored title.
    public let title: String
    /// Stored statement.
    public let statement: String
    /// Lifecycle state.
    public let status: String
    /// Cadence hint in minutes.
    public let stepIntervalMinutes: Int
    /// Next due time, when scheduled.
    public let nextDueAt: Date?
    /// Ordered plan.
    public let steps: [GoalStatusStep]
    /// Armed event wake-ups for this goal, oldest first.
    public let triggers: [GoalStatusTrigger]
    /// Recent audit trail, oldest first.
    public let recentEvents: [GoalStatusEvent]

    /// Creates a status detail.
    public init(
        goalID: String,
        title: String,
        statement: String,
        status: String,
        stepIntervalMinutes: Int,
        nextDueAt: Date? = nil,
        steps: [GoalStatusStep] = [],
        triggers: [GoalStatusTrigger] = [],
        recentEvents: [GoalStatusEvent] = []
    ) {
        self.goalID = goalID
        self.title = title
        self.statement = statement
        self.status = status
        self.stepIntervalMinutes = stepIntervalMinutes
        self.nextDueAt = nextDueAt
        self.steps = steps
        self.triggers = triggers
        self.recentEvents = recentEvents
    }
}

/// Envelope wrapping `goal.status` output.
public struct GoalStatusEnvelope: Sendable, Equatable, Codable {
    /// Goal details, oldest first.
    public let goals: [GoalStatusDetail]
    /// Number of goals in `goals`.
    public let count: Int

    /// Creates a status envelope.
    public init(goals: [GoalStatusDetail]) {
        self.goals = goals
        self.count = goals.count
    }
}

/// Envelope wrapping `goal.progress` output.
public struct GoalProgressEnvelope: Sendable, Equatable, Codable {
    /// Owning goal.
    public let goalID: String
    /// Step position that moved.
    public let stepOrdinal: Int
    /// Step title that moved.
    public let stepTitle: String
    /// New step state.
    public let status: String
    /// Annotation recorded on the move, when present.
    public let note: String?
    /// Whether the move parked the goal awaiting owner input.
    public let needsInput: Bool

    /// Creates a progress envelope.
    public init(
        goalID: String,
        stepOrdinal: Int,
        stepTitle: String,
        status: String,
        note: String? = nil,
        needsInput: Bool = false
    ) {
        self.goalID = goalID
        self.stepOrdinal = stepOrdinal
        self.stepTitle = stepTitle
        self.status = status
        self.note = note
        self.needsInput = needsInput
    }
}

/// Pure JSON encoding for the goal tool output documents.
public enum GoalToolEncoding {
    /// Encodes any goal envelope as the tool output document.
    public static func encode(_ envelope: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(envelope)
        return String(bytes: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Shared helpers

/// Honest fail-closed copy returned when goal pursuit is off.
///
/// Kept in one place so create, status, and progress refuse identically instead of
/// each inventing its own disabled wording; it mirrors the engine's disabled error
/// so tool and direct-engine callers hear the same guidance.
private enum GoalDisabledMessage {
    /// Disabled copy naming the `[goals]` opt-in.
    static let text = "Goal pursuit is disabled. Enable [goals] to create goals."
}

/// Maps caller-supplied progress text onto a ledger state.
///
/// Accepts the wire `in_progress` spelling plus the camel and dashed variants the model
/// sometimes emits, case-insensitively, so `inProgress` lands instead of failing. Pending
/// never maps: the ledger only records forward movement, and replanning stays with status.
/// - Parameter raw: Caller status text.
/// - Returns: Ledger state, or nil when the text names nothing actionable.
private func goalLedgerStatus(from raw: String) -> StepStatus? {
    let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch normalized {
    case "done":
        return .done
    case "blocked":
        return .blocked
    case "in_progress", "inprogress", "in-progress":
        return .inProgress
    case "skipped":
        return .skipped
    default:
        return nil
    }
}

// MARK: - Create tool

/// `goal.create` tool: starts one long-horizon goal with background planning.
public struct GoalCreateTool: Tool, Sendable {
    /// Stable tool name referenced by the LLM and scheduler prompts.
    public let name = "goal.create"
    /// When the LLM should use this tool.
    public let description =
        "Creates a long-horizon goal and starts background planning. "
            + "Use when the user asks to track a commitment over time. "
            + "Pass triggers to also wake the goal when matching events (goal steps, tool runs, or mirrored episodes) arrive. "
            + "The new goal links to the current chat session so it shows a chip."
    /// Function-calling contract for title, statement, cadence, and triggers.
    public let inputSchema = JSONSchema(
        rawValue: #"{"type":"object","properties":{"#
            + #""title":{"type":"string","description":"Short human-readable goal title"},"#
            + #""statement":{"type":"string","description":"Fuller intent shown to the owner and model"},"#
            + #""stepIntervalMinutes":{"type":"integer","#
            + #""description":"Cadence hint in minutes between advancements (default daily, 5-20160)","minimum":5,"maximum":20160},"#
            + #""triggers":{"type":"array","description":"Optional event wake-ups that pull the goal forward when a matching event arrives","#
            + #""maxItems":32,"items":{"type":"object","properties":{"#
            + #""eventKind":{"type":"string","description":"Event kind to watch, for example step_done, completed, needs_input, tool, or episode"},"#
            + #""pattern":{"type":"string","description":"Optional substring the event message must contain"},"#
            + #""cooldownMinutes":{"type":"integer","description":"Debounce window in minutes (default 60)","minimum":1}},"#
            + #""required":["eventKind"],"additionalProperties":false}}},"#
            + #""required":["title","statement"],"additionalProperties":false}"#
    )
    /// Creation changes durable state, so every call parks for approval.
    public let permissionLevel = PermissionLevel.requiresApproval

    /// Engine creating and planning the goal.
    private let engine: GoalEngine
    /// Sessions owner for chip linkage; nil keeps creation usable without a manager.
    private let conversations: ConversationManager?
    /// Whether `[goals]` is on; off fails closed before touching the store.
    private let goalsEnabled: Bool

    /// Creates a create tool.
    public init(engine: GoalEngine, conversations: ConversationManager? = nil, goalsEnabled: Bool = true) {
        self.engine = engine
        self.conversations = conversations
        self.goalsEnabled = goalsEnabled
    }

    /// Creates the goal, links the creating chat, and returns its snapshot.
    public func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput {
        guard goalsEnabled else {
            return .failure(GoalDisabledMessage.text, callID: input.callID)
        }
        let args: GoalCreateArgs
        do {
            args = try JSONDecoder().decode(GoalCreateArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            return .failure("Invalid goal.create arguments: expected {\"title\": \"<short>\", \"statement\": \"<intent>\"}.", callID: input.callID)
        }
        guard !args.trimmedTitle.isEmpty, !args.trimmedStatement.isEmpty else {
            return .failure("Invalid goal.create arguments: 'title' and 'statement' must not be empty.", callID: input.callID)
        }
        // Cadence single-sources the engine clamp: out-of-range hints fold to the
        // nearest GoalsConfig bound instead of failing, so tool and direct-engine
        // entry paths share one posture.
        let cadence = args.stepIntervalMinutes.map {
            min(max($0, GoalsConfig.minStepIntervalMinutes), GoalsConfig.maxStepIntervalMinutes)
        }
        // A trigger without an event kind can never match, so it is rejected
        // here instead of being armed as dead weight. The engine still clamps
        // the list to the configured per-goal budget.
        let triggerArgs = args.triggers ?? []
        if triggerArgs.contains(where: \.trimmedEventKind.isEmpty) {
            return .failure("Invalid goal.create arguments: each trigger requires a non-empty 'eventKind'.", callID: input.callID)
        }
        let drafts = triggerArgs.map {
            GoalTriggerDraft(eventKind: $0.trimmedEventKind, pattern: $0.trimmedPattern, cooldownMinutes: $0.cooldownMinutes)
        }
        if context.dryRun {
            let suffix = drafts.isEmpty ? "" : " with \(drafts.count) trigger(s)"
            return .success("Dry run: would create goal '\(args.trimmedTitle)'\(suffix).", callID: input.callID)
        }
        do {
            // The creation placeholder plans in the background inside the engine, so the
            // tool returns the snapshot immediately while decomposition lands shortly after;
            // status reads observe the plan without the tool paying the planning timeout.
            let goal = try await engine.create(
                title: args.trimmedTitle,
                statement: args.trimmedStatement,
                cadence: cadence,
                originSessionID: context.conversationID,
                triggers: drafts
            )
            // Link the creating chat so the dashboard chip resolves from the session alone.
            // Unknown sessions stay a no-op inside the manager, so creation never conjures ghosts.
            var linkedSessionID: String?
            if let conversations {
                await conversations.linkSession(context.conversationID, toGoal: goal.id)
                if await conversations.session(id: context.conversationID)?.goalID == goal.id {
                    linkedSessionID = context.conversationID.uuidString
                }
            }
            let envelope = GoalCreateEnvelope(
                goalID: goal.id.uuidString,
                title: goal.title,
                statement: goal.statement,
                status: goal.status.rawValue,
                stepIntervalMinutes: goal.stepIntervalMinutes,
                nextDueAt: goal.nextDueAt,
                sessionID: linkedSessionID
            )
            let content = try GoalToolEncoding.encode(envelope)
            return .success(content, callID: input.callID)
        } catch let error as GoalEngineError {
            return .failure(error.localizedDescription, callID: input.callID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failure("Could not create goal: \(error.localizedDescription)", callID: input.callID)
        }
    }
}

// MARK: - Status tool

/// `goal.status` tool: reads plans, dues, and recent events across sessions.
public struct GoalStatusTool: Tool, Sendable {
    /// Stable tool name referenced by the LLM.
    public let name = "goal.status"
    /// When the LLM should use this tool.
    public let description =
        "Shows goal plans with step statuses, next due times, and recent events — the agent's cross-session memory of commitments. "
            + "Use to recall what was promised without re-reading history."
    /// Function-calling contract for one goal or the full list.
    public let inputSchema = JSONSchema(
        rawValue: #"{"type":"object","properties":{"#
            + #""goalID":{"type":"string","description":"Goal identifier for one goal"},"#
            + #""all":{"type":"boolean","description":"When true, list goals up to limit"},"#
            + #""limit":{"type":"integer","#
            + #""description":"Maximum goals when all is true (1-50, default 10); recent events per goal capped separately at 10","#
            + #""minimum":1,"maximum":50}},"#
            + #""required":[],"additionalProperties":false}"#
    )
    /// Pure reads never park.
    public let permissionLevel = PermissionLevel.readOnly

    /// Durable goal, step, and event persistence.
    private let store: GoalStore
    /// Whether `[goals]` is on; off fails closed with the same honest copy as creation.
    private let goalsEnabled: Bool

    /// Creates a status tool.
    public init(store: GoalStore, goalsEnabled: Bool = true) {
        self.store = store
        self.goalsEnabled = goalsEnabled
    }

    /// Returns one goal or the capped list, each with its plan and recent trail.
    public func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        guard goalsEnabled else {
            return .failure(GoalDisabledMessage.text, callID: input.callID)
        }
        let args: GoalStatusArgs
        do {
            args = try JSONDecoder().decode(GoalStatusArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            return .failure("Invalid goal.status arguments: provide \"goalID\" or \"all\": true.", callID: input.callID)
        }
        do {
            if let rawID = args.trimmedGoalID {
                guard let uuid = UUID(uuidString: rawID) else {
                    return .failure("Invalid goal.status arguments: 'goalID' must be a UUID.", callID: input.callID)
                }
                guard let goal = try await store.goal(id: uuid) else {
                    return .failure("No goal \(rawID).", callID: input.callID)
                }
                let detail = try await statusDetail(for: goal, eventLimit: args.eventLimit)
                let content = try GoalToolEncoding.encode(GoalStatusEnvelope(goals: [detail]))
                return .success(content, callID: input.callID)
            }
            guard args.all else {
                return .failure("Invalid goal.status arguments: provide \"goalID\" or \"all\": true.", callID: input.callID)
            }
            // Oldest first mirrors the store listing so the cross-session memory reads chronologically.
            // The goal count honors `limit` in SQL while each goal's event tail honors the separate
            // `eventLimit` bound, so `all:true limit:50` quotes at most 10 events per goal.
            let goals = try await store.list(status: nil, limit: args.limit)
            var details: [GoalStatusDetail] = []
            details.reserveCapacity(goals.count)
            for goal in goals {
                let detail = try await statusDetail(for: goal, eventLimit: args.eventLimit)
                details.append(detail)
            }
            let content = try GoalToolEncoding.encode(GoalStatusEnvelope(goals: details))
            return .success(content, callID: input.callID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failure("Could not read goal status: \(error.localizedDescription)", callID: input.callID)
        }
    }

    /// Assembles one goal detail with its ordered plan and bounded recent trail.
    private func statusDetail(for goal: Goal, eventLimit: Int) async throws -> GoalStatusDetail {
        let steps = try await store.steps(goalID: goal.id)
        let events = try await store.events(goalID: goal.id, limit: eventLimit)
        let wires = steps
            .sorted { $0.ordinal < $1.ordinal }
            .map { GoalStatusStep(ordinal: $0.ordinal, title: $0.title, status: $0.status.rawValue, notes: $0.notes) }
        let trails = events.map { GoalStatusEvent(kind: $0.kind.rawValue, message: $0.message, createdAt: $0.createdAt) }
        // Triggers read best-effort: a store hiccup degrades the list to the
        // plan alone instead of failing a read-only status call.
        let armed = await (try? store.triggers(for: goal.id))?.map(GoalStatusTrigger.init) ?? []
        return GoalStatusDetail(
            goalID: goal.id.uuidString,
            title: goal.title,
            statement: goal.statement,
            status: goal.status.rawValue,
            stepIntervalMinutes: goal.stepIntervalMinutes,
            nextDueAt: goal.nextDueAt,
            steps: wires,
            triggers: armed,
            recentEvents: trails
        )
    }
}

// MARK: - Progress tool

/// `goal.progress` tool: records one step outcome in the local goal ledger.
public struct GoalProgressTool: Tool, Sendable {
    /// Stable tool name referenced by the LLM and advancement prompts.
    public let name = "goal.progress"
    /// When the LLM should use this tool.
    public let description =
        "Records one goal step outcome (done, blocked, in_progress, skipped) in the local ledger. "
            + "goal.progress mutates only the local ledger; real-world actions still ride their own permission-gated tools. "
            + "Omit goalID to use the session's linked goal, or the single active goal; ambiguous cases return guidance instead of guessing."
    /// Function-calling contract for the ledger move.
    public let inputSchema = JSONSchema(
        rawValue: #"{"type":"object","properties":{"#
            + #""goalID":{"type":"string","description":"Goal identifier; omit to use the session linked goal or the single active goal"},"#
            + #""stepOrdinal":{"type":"integer","description":"Zero-based step position within the plan"},"#
            + #""status":{"type":"string","description":"New step state: done, blocked, in_progress, or skipped"},"#
            + #""note":{"type":"string","description":"Annotation; a blocked note may park the goal awaiting owner input"}},"#
            + #""required":["stepOrdinal","status"],"additionalProperties":false}"#
    )
    /// Step moves mutate durable pursuit state, so every call parks for approval.
    ///
    /// This deliberately differs from the `memories.store` bargain (trusted per the owner
    /// memory-write ruling): a remembered fact appends one semantic note, while
    /// `goal.progress` moves step lifecycle state and can park the whole goal into
    /// `needs_input` via the engine, changing what the scheduler advances next. That is a
    /// state transition on shared pursuit — not note-taking — so the Security Model
    /// read-by-default/write-with-permission boundary requires approval here. Graduated
    /// trust still applies, so steady use approves once per target instead of every turn.
    public let permissionLevel = PermissionLevel.requiresApproval

    /// Durable step persistence.
    private let store: GoalStore
    /// Engine parking blocked goals awaiting input.
    private let engine: GoalEngine
    /// Sessions owner resolving the linked-goal default; nil keeps single-active fallback only.
    private let conversations: ConversationManager?
    /// Whether `[goals]` is on; off fails closed with the same honest copy as creation.
    private let goalsEnabled: Bool

    /// Creates a progress tool.
    public init(store: GoalStore, engine: GoalEngine, conversations: ConversationManager? = nil, goalsEnabled: Bool = true) {
        self.store = store
        self.engine = engine
        self.conversations = conversations
        self.goalsEnabled = goalsEnabled
    }

    /// Resolves the goal, moves one step, and parks blocked work with a note.
    public func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput {
        guard goalsEnabled else {
            return .failure(GoalDisabledMessage.text, callID: input.callID)
        }
        let args: GoalProgressArgs
        do {
            args = try JSONDecoder().decode(GoalProgressArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            return .failure(
                "Invalid goal.progress arguments: expected {\"stepOrdinal\": <int>,"
                    + " \"status\": \"done|blocked|in_progress|skipped\"}.",
                callID: input.callID
            )
        }
        guard let stepOrdinal = args.stepOrdinal else {
            return .failure("Invalid goal.progress arguments: 'stepOrdinal' is required.", callID: input.callID)
        }
        guard stepOrdinal >= 0 else {
            return .failure("Invalid goal.progress arguments: 'stepOrdinal' must not be negative.", callID: input.callID)
        }
        guard let rawStatus = args.trimmedStatus, let ledgerStatus = goalLedgerStatus(from: rawStatus) else {
            return .failure("Invalid goal.progress arguments: 'status' must be one of done, blocked, in_progress, skipped.", callID: input.callID)
        }
        let note = args.trimmedNote
        do {
            let goalID = try await resolveGoalID(explicit: args.trimmedGoalID, context: context)
            guard try await store.goal(id: goalID) != nil else {
                return .failure("No goal \(goalID.uuidString).", callID: input.callID)
            }
            let steps = try await store.steps(goalID: goalID)
            guard let step = steps.first(where: { $0.ordinal == stepOrdinal }) else {
                let known = steps.map(\.ordinal).sorted().map(String.init).joined(separator: ", ")
                let hint = known.isEmpty ? "this goal has no steps yet" : "known ordinals: \(known)"
                return .failure("No step \(stepOrdinal) for goal \(goalID.uuidString) (\(hint)).", callID: input.callID)
            }
            if context.dryRun {
                return .success("Dry run: would mark step \(stepOrdinal) ('\(step.title)') as \(ledgerStatus.rawValue).", callID: input.callID)
            }
            // The originating session tags the ledger row so later turns can tell
            // which chat moved the step. The field stays session-tagged by design:
            // server goal runs keep distinct run-log and session IDs, and the tool
            // context carries only the conversation identifier to stamp.
            try await store.setStepStatus(
                goalID: goalID,
                stepID: step.id,
                status: ledgerStatus,
                notes: note,
                lastRunID: context.conversationID
            )
            // A blocked note carries the owner's next question, so park the goal with it
            // instead of leaving the ledger blocked while the scheduler keeps firing dues.
            var parked = false
            if ledgerStatus == .blocked, let note, !note.isEmpty {
                try await engine.needsInput(goalID: goalID, reason: note)
                parked = true
            }
            let envelope = GoalProgressEnvelope(
                goalID: goalID.uuidString,
                stepOrdinal: stepOrdinal,
                stepTitle: step.title,
                status: ledgerStatus.rawValue,
                note: note,
                needsInput: parked
            )
            let content = try GoalToolEncoding.encode(envelope)
            return .success(content, callID: input.callID)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GoalProgressResolutionError {
            return .failure(error.message, callID: input.callID)
        } catch {
            return .failure("Could not record goal progress: \(error.localizedDescription)", callID: input.callID)
        }
    }

    /// Resolves the explicit goal or the session-linked and single-goal defaults.
    ///
    /// Explicit identifiers win untouched. Otherwise the session link resolves first so the
    /// creating chat keeps addressing its own goal without naming it; a lone non-terminal
    /// goal is the only safe guess, and anything else returns guidance listing the choice
    /// instead of moving a step on the wrong commitment.
    private func resolveGoalID(explicit: String?, context: ToolContext) async throws -> UUID {
        if let explicit {
            guard let uuid = UUID(uuidString: explicit) else {
                throw GoalProgressResolutionError(message: "Invalid goal.progress arguments: 'goalID' must be a UUID.")
            }
            return uuid
        }
        if let conversations {
            if let linked = await conversations.session(id: context.conversationID)?.goalID {
                // A deleted goal leaves a dangling link; fall through to the parked-aware scan
                // rather than failing a turn that could still address the lone survivor.
                if try await store.goal(id: linked) != nil {
                    return linked
                }
            }
        }
        let active = try await store.list(status: .active)
        if active.count == 1, let lone = active.first {
            return lone.id
        }
        if active.count > 1 {
            let preview = active
                .prefix(5)
                .map { "\($0.title) (\($0.id.uuidString))" }
                .joined(separator: "; ")
            throw GoalProgressResolutionError(message: "Multiple active goals exist (\(active.count)). Pass goalID explicitly to disambiguate: \(preview).")
        }
        // Zero active but one parked goal is still unambiguous: resume guidance names
        // the parked target instead of claiming no goal exists.
        let paused = try await store.list(status: .paused)
        let parked = try await store.list(status: .needsInput)
        let nonTerminal = paused + parked
        if nonTerminal.count == 1, let lone = nonTerminal.first {
            return lone.id
        }
        if nonTerminal.isEmpty {
            throw GoalProgressResolutionError(
                message: "No goal is linked to this session and no active goals exist. "
                    + "Create one with goal.create or pass goalID explicitly."
            )
        }
        let preview = nonTerminal
            .prefix(5)
            .map { "\($0.title) (\($0.id.uuidString)) [\($0.status.rawValue)]" }
            .joined(separator: "; ")
        throw GoalProgressResolutionError(
            message: "No active goals exist, but \(nonTerminal.count) parked goals await input or resume. "
                + "Resume one or pass goalID explicitly to disambiguate: \(preview)."
        )
    }
}

/// Typed guidance returned instead of guessing across ambiguous goals.
private struct GoalProgressResolutionError: Error, Sendable {
    /// Owner-visible guidance naming the safe next action.
    let message: String
}

// MARK: - Factory

/// Factory registering the LLM-invokable goal tools on a `ToolBus`.
public enum GoalTools {
    /// Tool names in registration order.
    public static let toolNames = ["goal.create", "goal.status", "goal.progress"]

    /// Builds the goal tools for a shared engine and store.
    ///
    /// The tools always build so they stay visible when wired; enablement lives in
    /// `goalsConfig` (disabled fails closed inside each tool) while `ToolBus` enablement
    /// stays on, so a disabled install reports the honest `[goals]` copy instead of a
    /// generic bus-disabled line. Session linkage and linked-goal defaults ride the
    /// optional conversations manager; nil keeps creation unlinked and progress on the
    /// single-active fallback so store-only callers still work.
    /// - Parameters:
    ///   - engine: Goal lifecycle owner (creation plus blocked parking).
    ///   - store: Durable goal, step, and event persistence.
    ///   - conversations: Sessions owner for chip linkage and linked-goal defaults.
    ///   - goalsConfig: Pursuit policy; `enabled == false` fails every call closed.
    /// - Returns: Tools in registration order.
    public static func makeTools(
        engine: GoalEngine,
        store: GoalStore,
        conversations: ConversationManager? = nil,
        goalsConfig: GoalsConfig = GoalsConfig()
    ) -> [any Tool] {
        let enabled = goalsConfig.enabled
        let create: any Tool = GoalCreateTool(engine: engine, conversations: conversations, goalsEnabled: enabled)
        let status: any Tool = GoalStatusTool(store: store, goalsEnabled: enabled)
        let progress: any Tool = GoalProgressTool(store: store, engine: engine, conversations: conversations, goalsEnabled: enabled)
        return [create, status, progress]
    }

    /// Registers the goal tools, replacing same-named entries.
    public static func register(
        on bus: ToolBus,
        engine: GoalEngine,
        store: GoalStore,
        conversations: ConversationManager? = nil,
        goalsConfig: GoalsConfig = GoalsConfig()
    ) async {
        for tool in makeTools(engine: engine, store: store, conversations: conversations, goalsConfig: goalsConfig) {
            await bus.register(tool: tool)
        }
    }
}
