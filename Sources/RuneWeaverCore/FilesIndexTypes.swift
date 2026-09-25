// Rune Weaver Core — Types and policy protocols for the local files indexer.
//
// Encapsulates the public run report, access policy evaluation seam, and vector
// eligibility policy. Decoupled from the indexer actor so consumers and test
// suites can inspect reports and configure policy without importing actor internals.

import Foundation

// MARK: - Report

/// Outcome of one files indexing run.
public struct FilesIndexRunReport: Sendable, Equatable {
    /// Files examined, including those later skipped.
    public var filesScanned = 0
    /// Documents written during the run.
    public var filesIndexed = 0
    /// Files skipped because their stored body hash was already current.
    public var filesUnchanged = 0
    /// Files deliberately skipped (excluded, denied, symlinked, alias, oversized, or unsupported).
    public var filesSkipped = 0
    /// Files that could not be read, extracted, or written.
    public var errors = 0
    /// Text chunks written during the run.
    public var chunksWritten = 0
    /// Chunks written carrying an embedding during the run.
    public var vectorsWritten = 0
    /// Documents where chunks beyond the vector cap stayed keyword-only.
    public var truncatedVectorDocuments = 0
    /// Documents retired because they were not seen by this run.
    public var retiredCount = 0
    /// Non-fatal per-file problems, without any file content.
    public var warnings: [String] = []
    /// Set when the run did not execute because file indexing is disabled.
    public var skippedReason: String?
    /// Set when the run stopped early on cancellation.
    public var cancelled = false

    /// Creates a run report.
    /// - Parameter skippedReason: Set when the run was skipped.
    public init(skippedReason: String? = nil) {
        self.skippedReason = skippedReason
    }

    /// Whether the indexer actually ran.
    public var didRun: Bool {
        skippedReason == nil
    }
}

// MARK: - Access seam

/// Outcome of evaluating one path against the file access policy.
public struct FilesIndexAccessDecision: Sendable, Equatable {
    /// Whether the path may be read without escalation.
    public let allowed: Bool
    /// Whether the caller should surface an approval escalation hint.
    public let requiresApproval: Bool
    /// Human-readable policy reason (never file content).
    public let reason: String?
    /// Canonical path the decision was made against.
    public let resolvedPath: String

    /// Creates a decision.
    public init(allowed: Bool, requiresApproval: Bool = false, reason: String? = nil, resolvedPath: String) {
        self.allowed = allowed
        self.requiresApproval = requiresApproval
        self.reason = reason
        self.resolvedPath = resolvedPath
    }
}

/// Protocol seam over the shared file access policy.
///
/// The concrete guard lives in the tools layer beside the file tools; the
/// indexer depends only on this seam so a policy change never reaches into the
/// core, and a test can deny one path without touching the real filesystem
/// policy. Implementations must never resolve or read a denied path.
public protocol FilesIndexAccessGuard: Sendable {
    /// Evaluates one candidate path.
    /// - Parameters:
    ///   - path: Raw candidate path.
    ///   - homeDirectoryURL: Home boundary override, or nil for the real home.
    /// - Returns: The policy decision for the path.
    func evaluate(path: String, homeDirectoryURL: URL?) -> FilesIndexAccessDecision
}

// MARK: - Vector policy

/// Decides whether an extracted document's chunks are vectorized.
///
/// A vector is a semantic claim about the whole document, so a truncated body
/// is keyword-only by default: surfacing half a document as a nearest neighbour
/// would mislead recall more than it helps. The byte bound keeps a large source
/// that is technically extractable from fanning an outsized embedding batch.
public struct FilesVectorPolicy: Sendable, Equatable {
    /// Whether an injected embeddings backend is consulted at all.
    public var enabled: Bool
    /// Whether partially extracted documents are also vectorized.
    public var includePartial: Bool
    /// Largest document, in bytes, that is vectorized.
    public var maxBytes: Int

    /// Default byte bound for vectorized documents (2 MB).
    public static let defaultMaxBytes = 2 * 1024 * 1024

    /// Creates a vector policy.
    public init(enabled: Bool = true, includePartial: Bool = false, maxBytes: Int = defaultMaxBytes) {
        self.enabled = enabled
        self.includePartial = includePartial
        self.maxBytes = max(0, maxBytes)
    }

    /// Reports whether a document is inside the vector policy.
    /// - Parameters:
    ///   - status: Extraction outcome.
    ///   - byteCount: Bytes considered for the document.
    /// - Returns: True when the document's chunks should be vectorized.
    public func shouldEmbed(status: ExtractStatus, byteCount: Int) -> Bool {
        guard enabled, byteCount <= maxBytes else { return false }
        switch status {
        case .extracted:
            return true
        case .partial:
            return includePartial
        default:
            return false
        }
    }

    /// Returns the leading chunk texts to send for embedding under a per-document cap.
    ///
    /// Chunks beyond the cap keep an empty embedding so they stay fully
    /// keyword-searchable while the run skips their embedding work.
    /// - Parameters:
    ///   - texts: Chunk texts in extraction order.
    ///   - cap: Maximum vectors for the document; values at or below zero mean unlimited.
    /// - Returns: The first `cap` texts, or all texts when unlimited.
    public static func cappedEmbeddingTexts(_ texts: [String], cap: Int) -> [String] {
        guard cap > 0, texts.count > cap else { return texts }
        return Array(texts.prefix(cap))
    }
}
