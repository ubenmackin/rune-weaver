// Rune Weaver Server — Local index control request/response DTOs.

import Foundation
import RuneWeaverCore
import Vapor

/// Outcome of `POST /index/run`.
public struct IndexRunResponse: Content, Equatable {
    /// Per-run session identifier used to tag the run log row.
    public let sessionID: UUID
    /// What caused the run (`"nightly"`, `"catchUp"`, or `"onDemand"`).
    public let trigger: String
    /// Terminal (or in-flight) state token.
    public let status: String
    /// Documents written across every source.
    public let documentsIndexed: Int
    /// Chunks written carrying an embedding.
    public let vectorChunks: Int
    /// Chunks written without an embedding.
    public let keywordChunks: Int
    /// Items examined.
    public let scanned: Int
    /// Items deliberately skipped.
    public let skipped: Int
    /// Items that could not be processed.
    public let errors: Int
    /// Documents retired (deleted as unseen) across every source.
    public let retiredCount: Int
    /// Documents where the vector cap left tail chunks keyword-only.
    public let truncatedCount: Int
    /// Non-fatal problems, without any content or secret.
    public let warnings: [String]
    /// Instant the run began.
    public let startedAt: Date
    /// Instant the run finished.
    public let finishedAt: Date
    /// Recorded watermark on success, or nil when the run did not succeed.
    public let indexAsOf: Date?
    /// Why the run did not execute, when it was skipped.
    public let skippedReason: String?
    /// Per-source outcomes in canonical run order. Optional for back-compat;
    /// absent degrades to no per-source notes instead of failing.
    public let sources: [IndexSourceRunOutcome]?

    /// Coding keys for the version-tolerant run contract.
    private enum CodingKeys: String, CodingKey {
        case sessionID
        case trigger
        case status
        case documentsIndexed
        case vectorChunks
        case keywordChunks
        case scanned
        case skipped
        case errors
        case retiredCount
        case retired
        case truncatedCount
        case truncated
        case warnings
        case startedAt
        case finishedAt
        case indexAsOf
        case skippedReason
        case sources
    }

    /// Maps a coordinator summary onto the wire shape.
    /// - Parameter summary: Completed run summary.
    public init(_ summary: IndexRunSummary) {
        self.sessionID = summary.sessionID
        self.trigger = summary.trigger.rawValue
        self.status = summary.status.rawValue
        self.documentsIndexed = summary.documentsIndexed
        self.vectorChunks = summary.vectorChunks
        self.keywordChunks = summary.keywordChunks
        self.scanned = summary.scanned
        self.skipped = summary.skipped
        self.errors = summary.errors
        self.retiredCount = summary.retired
        self.truncatedCount = summary.truncated
        self.warnings = summary.warnings
        self.startedAt = summary.startedAt
        self.finishedAt = summary.finishedAt
        self.indexAsOf = summary.indexAsOf
        self.skippedReason = summary.skippedReason
        let mapped = summary.sources.map(IndexSourceRunOutcome.init)
        self.sources = mapped.isEmpty ? nil : mapped
    }

    /// Maps a coordinator summary onto the wire shape with explicit outcomes.
    public init(_ summary: IndexRunSummary, sources: [IndexSourceRunOutcome]?) {
        self.sessionID = summary.sessionID
        self.trigger = summary.trigger.rawValue
        self.status = summary.status.rawValue
        self.documentsIndexed = summary.documentsIndexed
        self.vectorChunks = summary.vectorChunks
        self.keywordChunks = summary.keywordChunks
        self.scanned = summary.scanned
        self.skipped = summary.skipped
        self.errors = summary.errors
        self.retiredCount = summary.retired
        self.truncatedCount = summary.truncated
        self.warnings = summary.warnings
        self.startedAt = summary.startedAt
        self.finishedAt = summary.finishedAt
        self.indexAsOf = summary.indexAsOf
        self.skippedReason = summary.skippedReason
        self.sources = sources
    }

    /// Memberwise initializer for custom or in-flight run responses.
    public init(
        sessionID: UUID,
        trigger: String,
        status: String,
        documentsIndexed: Int,
        vectorChunks: Int,
        keywordChunks: Int,
        scanned: Int,
        skipped: Int,
        errors: Int,
        retiredCount: Int,
        truncatedCount: Int,
        warnings: [String],
        startedAt: Date,
        finishedAt: Date,
        indexAsOf: Date? = nil,
        skippedReason: String? = nil,
        sources: [IndexSourceRunOutcome]? = nil
    ) {
        self.sessionID = sessionID
        self.trigger = trigger
        self.status = status
        self.documentsIndexed = documentsIndexed
        self.vectorChunks = vectorChunks
        self.keywordChunks = keywordChunks
        self.scanned = scanned
        self.skipped = skipped
        self.errors = errors
        self.retiredCount = retiredCount
        self.truncatedCount = truncatedCount
        self.warnings = warnings
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.indexAsOf = indexAsOf
        self.skippedReason = skippedReason
        self.sources = sources
    }

    /// Builds an in-flight run response for an asynchronously started run.
    public static func started(sessionID: UUID, trigger: IndexRunTrigger, startedAt: Date) -> IndexRunResponse {
        IndexRunResponse(
            sessionID: sessionID,
            trigger: trigger.rawValue,
            status: "running",
            documentsIndexed: 0,
            vectorChunks: 0,
            keywordChunks: 0,
            scanned: 0,
            skipped: 0,
            errors: 0,
            retiredCount: 0,
            truncatedCount: 0,
            warnings: [],
            startedAt: startedAt,
            finishedAt: startedAt,
            indexAsOf: nil,
            skippedReason: nil,
            sources: nil
        )
    }

    /// Builds a skipped run response when a run cannot be started.
    public static func skipped(trigger: IndexRunTrigger, reason: String, now: Date = Date()) -> IndexRunResponse {
        IndexRunResponse(
            sessionID: UUID(),
            trigger: trigger.rawValue,
            status: IndexRunStatus.skipped.rawValue,
            documentsIndexed: 0,
            vectorChunks: 0,
            keywordChunks: 0,
            scanned: 0,
            skipped: 0,
            errors: 0,
            retiredCount: 0,
            truncatedCount: 0,
            warnings: [],
            startedAt: now,
            finishedAt: now,
            indexAsOf: nil,
            skippedReason: reason,
            sources: nil
        )
    }

    /// Decodes a run response, defaulting retired and truncated counts to zero so payloads built
    /// against an older engine still decode. Accepts the `retired`/`truncated` aliases; the
    /// canonical keys win when both are present.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        trigger = try container.decode(String.self, forKey: .trigger)
        status = try container.decode(String.self, forKey: .status)
        documentsIndexed = try container.decode(Int.self, forKey: .documentsIndexed)
        vectorChunks = try container.decode(Int.self, forKey: .vectorChunks)
        keywordChunks = try container.decode(Int.self, forKey: .keywordChunks)
        scanned = try container.decode(Int.self, forKey: .scanned)
        skipped = try container.decode(Int.self, forKey: .skipped)
        errors = try container.decode(Int.self, forKey: .errors)
        let canonicalRetired = try container.decodeIfPresent(Int.self, forKey: .retiredCount)
        let aliasRetired = try container.decodeIfPresent(Int.self, forKey: .retired)
        retiredCount = canonicalRetired ?? aliasRetired ?? 0
        let canonicalTruncated = try container.decodeIfPresent(Int.self, forKey: .truncatedCount)
        let aliasTruncated = try container.decodeIfPresent(Int.self, forKey: .truncated)
        truncatedCount = canonicalTruncated ?? aliasTruncated ?? 0
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        finishedAt = try container.decode(Date.self, forKey: .finishedAt)
        indexAsOf = try container.decodeIfPresent(Date.self, forKey: .indexAsOf)
        skippedReason = try container.decodeIfPresent(String.self, forKey: .skippedReason)
        sources = try container.decodeIfPresent([IndexSourceRunOutcome].self, forKey: .sources)
    }

    /// Encodes a run response on the canonical keys so current dashboards
    /// render from one fetch; the aliases are not re-emitted.
    /// - Parameter encoder: Encoder receiving the response.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(trigger, forKey: .trigger)
        try container.encode(status, forKey: .status)
        try container.encode(documentsIndexed, forKey: .documentsIndexed)
        try container.encode(vectorChunks, forKey: .vectorChunks)
        try container.encode(keywordChunks, forKey: .keywordChunks)
        try container.encode(scanned, forKey: .scanned)
        try container.encode(skipped, forKey: .skipped)
        try container.encode(errors, forKey: .errors)
        try container.encode(retiredCount, forKey: .retiredCount)
        try container.encode(truncatedCount, forKey: .truncatedCount)
        try container.encode(warnings, forKey: .warnings)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(finishedAt, forKey: .finishedAt)
        try container.encodeIfPresent(indexAsOf, forKey: .indexAsOf)
        try container.encodeIfPresent(skippedReason, forKey: .skippedReason)
        try container.encodeIfPresent(sources, forKey: .sources)
    }
}

/// Outcome of `POST /index/cancel`.
public struct IndexCancelResponse: Content, Equatable {
    /// Whether a run was in flight when cancellation was requested.
    public let cancelled: Bool

    /// Creates a cancellation response.
    /// - Parameter cancelled: Whether a run was in flight.
    public init(cancelled: Bool) {
        self.cancelled = cancelled
    }
}

/// Request body for `POST /index/prune`.
public struct IndexPruneRequest: Content, Equatable {
    /// Cutoff instant; documents indexed before it are removed. Nil is rejected
    /// with 400; the cutoff is required.
    public let before: Date?

    /// Creates a prune request with the required cutoff.
    /// - Parameter before: Required cutoff instant.
    public init(before: Date) {
        self.before = before
    }
}

/// Outcome of `POST /index/prune`.
public struct IndexPruneResponse: Content, Equatable {
    /// Number of documents removed.
    public let removed: Int
    /// Cutoff instant that was applied.
    public let before: Date

    /// Creates a prune response.
    public init(removed: Int, before: Date) {
        self.removed = removed
        self.before = before
    }
}

/// Outcome of `POST /index/reset`.
public struct IndexResetResponse: Content, Equatable {
    /// Always true on success; the route fails instead of claiming a partial clear.
    public let reset: Bool

    /// Creates a reset response.
    /// - Parameter reset: Whether the clear completed.
    public init(reset: Bool) {
        self.reset = reset
    }
}

/// Outcome of `POST /index/reclaim`.
public struct IndexReclaimResponse: Content, Equatable {
    /// On-disk total before `VACUUM`, in bytes.
    public let beforeBytes: Int64
    /// On-disk total after `VACUUM`, in bytes.
    public let afterBytes: Int64
    /// Bytes reclaimed (`beforeBytes` minus `afterBytes`, floored at zero).
    public let reclaimedBytes: Int64

    /// Creates a reclaim response.
    public init(beforeBytes: Int64, afterBytes: Int64, reclaimedBytes: Int64) {
        self.beforeBytes = beforeBytes
        self.afterBytes = afterBytes
        self.reclaimedBytes = reclaimedBytes
    }

    /// Maps a store reclaim outcome onto the wire shape.
    /// - Parameter result: Store reclaim outcome.
    public init(_ result: IndexReclaimResult) {
        self.beforeBytes = result.beforeBytes
        self.afterBytes = result.afterBytes
        self.reclaimedBytes = result.reclaimedBytes
    }
}
