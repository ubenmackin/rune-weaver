// Rune Weaver Server — Durable trust grant DTOs for the approvals API.

import Foundation
import RuneWeaverCore
import Vapor

/// One durable trust grant for `GET /approvals/grants`.
public struct TrustGrantResponse: Content, Equatable {
    /// Stable grant identifier.
    public let id: UUID
    /// Trusted tool name.
    public let toolName: String
    /// Trusted target. Empty means the grant covers the whole tool.
    public let target: String
    /// When the grant was created.
    public let grantedAt: Date
    /// When the grant expires, or nil for grants that never expire.
    public let expiresAt: Date?
    /// Duration tier the grant was created with.
    public let duration: TrustDuration
    /// Human-readable target for dashboards.
    public let displayTarget: String
    /// How many times this grant has allowed a call without prompting.
    /// Exposed so dashboards can prove liveness: a steadily advancing counter
    /// shows the grant is actively relied upon, while a long-lived zero
    /// singles out untested trust that is safe to prune.
    public let useCount: Int
    /// When this grant last allowed a call, or nil when never exercised.
    /// Carried alongside the counter so recency stays visible even for grants
    /// that never expire; a nil value keeps untouched legacy grants
    /// distinguishable from recently relied-upon ones.
    public let lastUsedAt: Date?

    /// Creates a trust grant row.
    /// - Parameters:
    ///   - id: Stable grant identifier.
    ///   - toolName: Trusted tool name.
    ///   - target: Trusted target, empty when tool-wide.
    ///   - grantedAt: Creation date.
    ///   - expiresAt: Expiry date, or nil when it never expires.
    ///   - duration: Duration tier the grant was created with.
    ///   - useCount: Times the grant has allowed a call; zero marks untouched legacy rows.
    ///   - lastUsedAt: Last allow time, nil when never used so legacy rows encode null.
    public init(
        id: UUID,
        toolName: String,
        target: String,
        grantedAt: Date,
        expiresAt: Date?,
        duration: TrustDuration,
        useCount: Int = 0,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.toolName = toolName
        self.target = target
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.duration = duration
        // An empty target covers every target for the tool, so dashboards
        // need an explicit label instead of rendering a blank cell.
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayTarget = trimmed.isEmpty ? "all targets" : trimmed
        // Counters never go negative on dashboards; clamp direct construction
        // so a corrupt caller cannot seed a negative baseline.
        self.useCount = max(0, useCount)
        self.lastUsedAt = lastUsedAt
    }

    /// Creates a row from a stored grant, deriving the display target so
    /// tool-wide grants stay unambiguous on dashboards.
    /// - Parameter grant: Stored grant.
    public init(_ grant: TrustGrant) {
        self.init(
            id: grant.id,
            toolName: grant.actionDescriptor.toolName,
            target: grant.actionDescriptor.target,
            grantedAt: grant.grantedAt,
            expiresAt: grant.expiresAt,
            duration: grant.duration,
            useCount: grant.useCount,
            lastUsedAt: grant.lastUsedAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case toolName
        case target
        case grantedAt
        case expiresAt
        case duration
        case displayTarget
        case useCount
        case lastUsedAt
    }

    /// Decodes a grant row, tolerating payloads written before usage
    /// counters existed so legacy rows still read as untouched grants.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        toolName = try container.decode(String.self, forKey: .toolName)
        target = try container.decode(String.self, forKey: .target)
        grantedAt = try container.decode(Date.self, forKey: .grantedAt)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        duration = try container.decode(TrustDuration.self, forKey: .duration)
        // Older payloads predate usage tracking, so a missing counter
        // means the grant was never observed in use rather than a corrupt row.
        // Clamp negatives so legacy or hand-edited payloads cannot seed a
        // negative baseline on dashboards.
        let decodedCount = try container.decodeIfPresent(Int.self, forKey: .useCount) ?? 0
        useCount = max(0, decodedCount)
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        // Older payloads predate the derived display label, so fall back to
        // the target-derived label instead of failing the whole row.
        // A blank stored label would render as an empty cell, so derive then.
        if let stored = try container.decodeIfPresent(String.self, forKey: .displayTarget),
           !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            displayTarget = stored
        } else {
            let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
            displayTarget = trimmed.isEmpty ? "all targets" : trimmed
        }
    }

    /// Encodes a grant row including its usage counters.
    /// - Parameter encoder: Destination encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(toolName, forKey: .toolName)
        try container.encode(target, forKey: .target)
        try container.encode(grantedAt, forKey: .grantedAt)
        try container.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try container.encode(duration, forKey: .duration)
        try container.encode(displayTarget, forKey: .displayTarget)
        try container.encode(useCount, forKey: .useCount)
        try container.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt)
    }
}

/// Durable trust grants response for `GET /approvals/grants`.
public struct TrustGrantsResponse: Content, Equatable {
    /// Grants, newest first.
    public let grants: [TrustGrantResponse]
    /// Number of grants in `grants`.
    public let count: Int

    /// Creates a grants response.
    /// - Parameter grants: Grant rows, already in display order.
    public init(grants: [TrustGrantResponse]) {
        self.grants = grants
        self.count = grants.count
    }
}

/// Duration re-arm request for `PATCH /approvals/grants/:id`.
///
/// Carries only the replacement tier so the permission gate stays the single
/// owner of expiry math; a re-arm must extend trust to a durable tier, never
/// collapse it back to a one-shot approval that stores no grant.
public struct RearmGrantRequest: Content, Equatable {
    /// Replacement duration tier.
    public let duration: TrustDuration

    /// Creates a re-arm request.
    /// - Parameter duration: Replacement duration tier.
    public init(duration: TrustDuration) {
        self.duration = duration
    }
}
