// Rune Weaver Core — Durable model for proactive Wayfinder idea suggestions.

import Foundation

/// Category of one proactive idea. Raw values are the stable wire, SQLite, and model-facing
/// strings, so renaming a case never silently rewrites persisted rows or a prompt that asked the
/// model for that spelling.
public enum IdeaKind: String, Sendable, Codable, CaseIterable, Equatable {
    /// A suggested change to an existing goal's plan or cadence.
    case planAdjustment = "plan_adjustment"
    /// A suggested new goal worth pursuing.
    case newGoal = "new_goal"
    /// A general tip or onboarding nudge that is not tied to a goal.
    case tip
}

/// Lifecycle state of one proactive idea. Only a non-dismissed idea blocks a duplicate title, so a
/// dismissed suggestion may resurface if the owner later asks for it again.
public enum IdeaStatus: String, Sendable, Codable, CaseIterable, Equatable {
    /// Generated and awaiting an owner decision.
    case proposed
    /// Owner accepted the suggestion.
    case accepted
    /// Owner dismissed the suggestion.
    case dismissed
}

/// One proactive idea suggested by the Wayfinder engine.
public struct Idea: Sendable, Codable, Equatable, Identifiable {
    /// Stable identifier shared across reads and status changes.
    public let id: UUID
    /// Which family of suggestion this is.
    public let kind: IdeaKind
    /// Short human-readable title; the dedup key across generations.
    public let title: String
    /// Fuller explanation shown to the owner.
    public let body: String
    /// Goal this idea relates to, when the suggestion targets one.
    public let goalID: UUID?
    /// Current lifecycle state.
    public var status: IdeaStatus
    /// When the idea was first persisted.
    public let createdAt: Date
    /// When the idea row last changed.
    public var updatedAt: Date

    /// Creates an idea snapshot.
    public init(
        id: UUID = UUID(),
        kind: IdeaKind,
        title: String,
        body: String,
        goalID: UUID? = nil,
        status: IdeaStatus = .proposed,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.goalID = goalID
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
