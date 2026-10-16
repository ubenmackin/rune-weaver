// Rune Weaver Core — Fan-out worker subagent contract types.

import Foundation

/// One explicit subtask handed to the fan-out engine.
public struct FanOutSubtask: Sendable, Codable, Equatable {
    /// Lifecycle of one worker turn.
    public enum Status: String, Sendable, Codable, Equatable {
        /// Not started yet.
        case pending
        /// Worker turn in flight.
        case running
        /// Worker turn finished without error.
        case done
        /// Worker turn failed or exceeded its wall-clock timeout.
        case failed
        /// The owner stopped the worker before it completed. A deliberate
        /// stop is its own terminal state: it never reads as a failure.
        case cancelled
    }

    /// Stable subtask identifier within its run.
    public let id: UUID
    /// Human-readable title for display and the audit trail. Composed by the
    /// calling agent; the engine never rewrites it.
    public let title: String
    /// Full prompt the worker turn runs. Composed by the calling agent; the
    /// engine never decomposes or rewrites it.
    public let prompt: String
    /// Current lifecycle state.
    public var status: Status

    /// Coding keys matching the wire shape.
    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case prompt
        case status
    }

    /// Creates one subtask. id: Subtask identifier; a fresh UUID when omitted.
    public init(id: UUID = UUID(), title: String, prompt: String, status: Status = .pending) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.status = status
    }

    /// Decodes one subtask, defaulting a missing state to pending so payloads
    /// written by a caller that did not track lifecycle still decode.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.prompt = try container.decode(String.self, forKey: .prompt)
        self.status = try container.decodeIfPresent(Status.self, forKey: .status) ?? .pending
    }

    /// Encodes one subtask.
    /// - Parameter encoder: Destination encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(status, forKey: .status)
    }
}

/// One fan-out run: the parent record over its worker subtasks.
public struct FanOutRun: Sendable, Codable, Equatable {
    /// Lifecycle of the parent run.
    public enum Status: String, Sendable, Codable, Equatable {
        /// Workers in flight.
        case running
        /// Every subtask settled done.
        case completed
        /// At least one subtask settled failed.
        case failed
        /// The owner stopped at least one subtask before it completed; a
        /// cancelled subtask outranks a failed one, because a deliberate stop
        /// must never masquerade as an error.
        case cancelled
    }

    /// Stable run identifier.
    public let id: UUID
    /// Session that spawned the run. The audit trail links the parent row
    /// back to the caller's conversation through this identifier, so a run
    /// stays joinable to the turn that asked for it.
    public let parentSessionID: UUID
    /// Worker subtasks with their live statuses.
    public var subtasks: [FanOutSubtask]
    /// Current parent lifecycle state.
    public var status: Status
    /// Honest outcome digest, composed once every subtask settles; nil while
    /// the run is in flight so clients fall back to subtask statuses instead
    /// of a premature summary.
    public var summary: String?
    /// When the run was created.
    public var createdAt: Date
    /// When the run last settled a subtask or completed.
    public var updatedAt: Date

    /// Coding keys matching the wire shape, with the parent session on the
    /// camelCase spelling the other identifiers use.
    private enum CodingKeys: String, CodingKey {
        case id
        case parentSessionID = "parentSessionId"
        case subtasks
        case status
        case summary
        case createdAt
        case updatedAt
    }

    /// Creates one run over explicit subtasks. id: Run identifier; a fresh UUID
    /// when omitted.
    public init(
        id: UUID = UUID(),
        parentSessionID: UUID,
        subtasks: [FanOutSubtask],
        status: Status = .running,
        summary: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.parentSessionID = parentSessionID
        self.subtasks = subtasks
        self.status = status
        self.summary = summary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Decodes one run, defaulting lifecycle and digest fields so payloads
    /// written without a settled state still decode.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.parentSessionID = try container.decode(UUID.self, forKey: .parentSessionID)
        self.subtasks = try container.decode([FanOutSubtask].self, forKey: .subtasks)
        self.status = try container.decodeIfPresent(Status.self, forKey: .status) ?? .running
        self.summary = try container.decodeIfPresent(String.self, forKey: .summary)
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    /// Encodes one run, omitting an absent digest so clients see no empty key.
    /// - Parameter encoder: Destination encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(parentSessionID, forKey: .parentSessionID)
        try container.encode(subtasks, forKey: .subtasks)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(summary, forKey: .summary)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

/// Typed fan-out rejections surfaced before any worker turn runs.
public enum FanOutError: Error, Equatable, Sendable {
    /// The subtask list exceeds the configured worker cap, so a run can
    /// never oversubscribe the serving model.
    case maxWorkersReached(limit: Int)
    /// A fan-out without subtasks is meaningless; callers get an honest
    /// rejection instead of an empty run.
    case emptySubtasks
}

/// Answer to an owner-requested fan-out cancellation, keyed by an audit-row identifier so the same
/// vocabulary the Runs tab shows is what the owner cancels.
public enum FanOutCancelOutcome: Sendable, Equatable {
    /// The parent row carried the cancel: every in-flight worker was stopped and every
    /// still-running subtask marked cancelled.
    case runCancelled(workerCount: Int)
    /// A child row carried the cancel: that worker was stopped and its subtask
    /// marked cancelled; sibling workers keep running.
    case workerCancelled
    /// No in-flight run or worker owns the row: the identifier is unknown, its
    /// run already settled, or the worker already settled, so no cancel was
    /// applied.
    case notRunning
}
