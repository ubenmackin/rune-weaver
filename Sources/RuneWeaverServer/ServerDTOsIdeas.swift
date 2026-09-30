// Rune Weaver Server — Ideas settings patch and merge logic.
//
// Extracted from ServerDTOs.swift to keep file length within lint bounds.
// The partial `[ideas]` patch for `PUT /settings` and the merge helper
// live beside the Ideas DTOs so the settings surface stays single-sourced.

import Foundation
import RuneWeaverCore
import Vapor

/// Partial `[ideas]` patch for `PUT /settings`.
///
/// Every field stays optional so a request carrying only the enable flag leaves
/// the rest of the stored suggestion policy untouched instead of resetting it.
/// The dashboard-owned subset is the enable toggle: the per-cycle cap and
/// review timeout stay file-owned planning bounds, matching the goals patch so
/// the settings surface cannot widen execution cost.
public struct IdeasUpdate: Content, Sendable, Equatable {
    /// Whether proactive idea generation runs at all. Nil preserves the stored value.
    public var enabled: Bool?

    /// Creates a partial ideas patch.
    /// - Parameter enabled: Whether suggestion generation runs.
    public init(enabled: Bool? = nil) {
        self.enabled = enabled
    }

    /// Populates a patch from a full snapshot so programmatic callers holding a
    /// complete `IdeasConfig` reuse the same merge path.
    /// - Parameter config: Complete suggestion policy.
    public init(_ config: IdeasConfig) {
        self.enabled = config.enabled
    }
}

extension UpdateSettingsRequest {
    /// Merges a partial ideas patch onto the stored policy, preserving every
    /// field the request omits. A nil patch is a no-op, so a dashboard edit
    /// elsewhere never resets the `[ideas]` section.
    ///
    /// Internal so the shared settings `apply(to:)` keeps one merge path while
    /// the ideas-specific logic lives beside its DTOs.
    func applyIdeas(to ideas: inout IdeasConfig) {
        guard let update = self.ideas else { return }
        if let enabled = update.enabled {
            ideas.enabled = enabled
        }
    }
}

/// Public representation of one proactive suggestion.
///
/// Plain strings carry kind and status so the client does not couple to the
/// engine's internal enum ordering; the wire values mirror the domain model
/// so the dashboard, server, and episodic-memory layers agree without
/// drifting.
public struct IdeaDTO: Content, Sendable, Equatable {
    /// Stable idea identifier.
    public let id: UUID
    /// Suggestion family raw value (`plan_adjustment`, `new_goal`, `tip`).
    public let kind: String
    /// Short human-readable title.
    public let title: String
    /// Fuller explanation shown to the owner; renders through the sanitized
    /// Markdown path only.
    public let body: String
    /// Goal this idea relates to, when the suggestion targets one.
    public let goalID: UUID?
    /// Lifecycle state raw value (`proposed`, `accepted`, `dismissed`).
    public let status: String
    /// When the idea was first persisted.
    public let createdAt: Date
    /// When the idea row last changed.
    public let updatedAt: Date

    /// Creates an idea DTO.
    public init(
        id: UUID,
        kind: String,
        title: String,
        body: String,
        goalID: UUID? = nil,
        status: String,
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

    /// Builds a DTO from a stored idea snapshot.
    /// - Parameter idea: Stored idea.
    public init(_ idea: Idea) {
        self.init(
            id: idea.id,
            kind: idea.kind.rawValue,
            title: idea.title,
            body: idea.body,
            goalID: idea.goalID,
            status: idea.status.rawValue,
            createdAt: idea.createdAt,
            updatedAt: idea.updatedAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case title
        case body
        case goalId
        case goalID
        case goalSnake = "goal_id"
        case status
        case createdAt
        case updatedAt
    }

    /// Decodes tolerantly across the goal-identifier spellings through the
    /// shared alias helper so a pushed or hand-built payload lands on one field.
    /// A blank title fails decoding fail-closed so whitespace-only rows never
    /// cross the wire.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.kind = try container.decode(String.self, forKey: .kind)
        let rawTitle = try container.decode(String.self, forKey: .title)
        guard !rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .title,
                in: container,
                debugDescription: "title must not be blank"
            )
        }
        self.title = rawTitle
        self.body = try container.decode(String.self, forKey: .body)
        self.goalID = BrowserNavigateWire.decodeFirst(container, keys: [.goalId, .goalID, .goalSnake])
        self.status = try container.decode(String.self, forKey: .status)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    /// Encodes under the canonical `goalId` spelling so older decoders see no new key.
    /// - Parameter encoder: Destination encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(title, forKey: .title)
        try container.encode(body, forKey: .body)
        try container.encodeIfPresent(goalID, forKey: .goalId)
        try container.encode(status, forKey: .status)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

/// Idea list response for `GET /ideas`.
public struct IdeasListResponse: Content, Sendable, Equatable {
    /// Ideas, newest first.
    public let ideas: [IdeaDTO]
    /// Number of ideas in `ideas`.
    public let count: Int

    /// Creates a list response.
    /// - Parameter ideas: Idea DTOs.
    public init(ideas: [IdeaDTO]) {
        self.ideas = ideas
        self.count = ideas.count
    }
}

/// Idea counts for `GET /ideas/summary`.
///
/// Explicit per-status tallies keep the dashboard badge free of key-string
/// branching, mirroring the goals summary shape. `total` is the sum so a
/// dropped status can never leave the per-status counts disagreeing with it.
public struct IdeasSummaryResponse: Content, Sendable, Equatable {
    /// Total ideas across every state.
    public let total: Int
    /// Ideas awaiting a decision.
    public let proposed: Int
    /// Ideas the owner accepted.
    public let accepted: Int
    /// Ideas the owner dismissed.
    public let dismissed: Int

    /// Creates a summary response.
    public init(proposed: Int, accepted: Int, dismissed: Int) {
        self.proposed = proposed
        self.accepted = accepted
        self.dismissed = dismissed
        self.total = proposed + accepted + dismissed
    }
}
