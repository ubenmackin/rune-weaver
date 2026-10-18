// Rune Weaver Core — Types and policy protocols for the local files indexer.

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
public protocol FilesIndexAccessGuard: Sendable {
    /// Evaluates one candidate path. path: Raw candidate path.
    func evaluate(path: String, homeDirectoryURL: URL?) -> FilesIndexAccessDecision
}

// MARK: - Vector policy

/// Decides whether an extracted document's chunks are vectorized.
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

    /// Reports whether a document is inside the vector policy. status: Extraction
    /// outcome.
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
    public static func cappedEmbeddingTexts(_ texts: [String], cap: Int) -> [String] {
        guard cap > 0, texts.count > cap else { return texts }
        return Array(texts.prefix(cap))
    }

    /// File extensions representing structured data, configuration, or machine logs that are
    /// indexed into FTS5 keyword search directly without spending `llama-server` vector passes.
    public static let keywordOnlyExtensions: Set<String> = [
        "json", "jsonl", "yaml", "yml", "toml", "xml", "plist",
        "csv", "tsv", "lock", "ini", "cfg", "conf", "env", "log"
    ]

    /// Reports whether a filename belongs to the structured keyword-only fast lane.
    public static func isKeywordOnlyFile(fileName: String) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        return keywordOnlyExtensions.contains(ext)
    }

    /// Classifies a discovered file into its modality processing queue.
    public static func modalityLane(
        fileName: String,
        byteCount: Int,
        maxVectorBytes: Int = defaultMaxBytes
    ) -> FilesModalityLane {
        let format = DocumentTextExtractor.detectFormat(fileName: fileName, contentType: nil)
        switch format {
        case .audio, .video:
            // The speech lane admits allowlisted containers only; anything else
            // stays keyword-only instead of reaching the transcriber.
            return MediaTextExtractor.isAudioOrVideoFile(fileName: fileName) ? .mediaSpeech : .keywordData
        case .image:
            // The OCR lane admits allowlisted images only; anything else stays
            // keyword-only instead of reaching Vision.
            return MediaTextExtractor.isImageFile(fileName: fileName) ? .imageOCR : .keywordData
        case .pdf:
            return .imageOCR
        default:
            if isKeywordOnlyFile(fileName: fileName) || byteCount > maxVectorBytes {
                return .keywordData
            }
            return .fastText
        }
    }
}

/// Modality priority lane used to queue discovered file candidates so slow media
/// and image/OCR files never head-of-line block fast text files.
public enum FilesModalityLane: Int, Sendable, Comparable, CaseIterable {
    /// Structured data and oversized text indexed via FTS5 keyword-only without calling llama-server.
    case keywordData = 0
    /// Prose and source-code text documents embedded in cross-file batches.
    case fastText = 1
    /// Image and PDF files processed through Vision OCR + visual embeddings.
    case imageOCR = 2
    /// Audio and video files processed through SFSpeechRecognizer.
    case mediaSpeech = 3

    public static func < (lhs: FilesModalityLane, rhs: FilesModalityLane) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Canonical wire identifier for the modality queue lane.
    public var key: String {
        switch self {
        case .keywordData: "keywordData"
        case .fastText: "fastText"
        case .imageOCR: "imageOCR"
        case .mediaSpeech: "mediaSpeech"
        }
    }

    /// Human-readable display label for the modality queue lane.
    public var label: String {
        switch self {
        case .keywordData: "Keyword Data"
        case .fastText: "Fast Text"
        case .imageOCR: "Image & PDF OCR"
        case .mediaSpeech: "Media Speech"
        }
    }
}

/// Live progress for one modality queue lane inside the files indexer.
public struct IndexQueueLaneProgress: Sendable, Codable, Equatable {
    /// Canonical lane identifier (`"keywordData"`, `"fastText"`, `"imageOCR"`, `"mediaSpeech"`).
    public let lane: String
    /// Human-readable lane title.
    public let label: String
    /// Total candidate files queued in this lane after discovery.
    public var queued: Int
    /// Candidate files finished (indexed, unchanged, skipped, or errored).
    public var processed: Int
    /// Candidate files newly written to the index in this lane.
    public var indexed: Int

    /// Creates a modality queue lane progress snapshot.
    public init(lane: String, label: String, queued: Int = 0, processed: Int = 0, indexed: Int = 0) {
        self.lane = lane
        self.label = label
        self.queued = max(0, queued)
        self.processed = max(0, processed)
        self.indexed = max(0, indexed)
    }
}
