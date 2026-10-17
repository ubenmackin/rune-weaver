// Rune Weaver Core — Value types for the local document index.

import Foundation

/// Origin corpus for one indexed document.
public enum IndexSource: String, Sendable, Codable, CaseIterable, Equatable {
    /// Local filesystem documents (markdown, PDF, plain text).
    case files
    /// Mail messages read from a configured mailbox.
    case mail
    /// Chat/message transcripts.
    case messages
    /// Calendar event occurrences.
    case calendars
    /// Reminder rows.
    case reminders
}

/// How completely a document's body was extracted at index time.
public enum ExtractStatus: String, Sendable, Codable, CaseIterable, Equatable {
    /// Full body text was extracted.
    case extracted
    /// Some body text was extracted, but the document was truncated or partly unreadable.
    case partial
    /// Only headers/metadata were extracted; no body text is available.
    case metadataOnly
    /// The format is not supported for text extraction.
    case unsupported
    /// The source was evicted from its origin before extraction.
    case skippedEvicted
    /// Extraction failed.
    case failed
}

/// One indexed document, keyed by its source-scoped external identifier.
public struct IndexedDocument: Sendable, Codable, Equatable, Identifiable {
    /// Stable local identifier used to link chunks.
    public let id: UUID
    /// Origin corpus.
    public let source: IndexSource
    /// Source-scoped identifier (filesystem path or message identifier).
    public let externalID: String
    /// Human-readable name shown in listings.
    public let displayName: String
    /// Filesystem path for `files` documents, when applicable.
    public let path: String?
    /// Message identifier for `mail`/`messages` documents, when applicable.
    public let messageID: String?
    /// Owning mailbox for message-backed documents, when applicable.
    public let mailbox: String?
    /// Last modification time of the source, when known.
    public let mtime: Date?
    /// Source size in bytes, when known.
    public let sizeBytes: Int64?
    /// Content hash that gates re-indexing of unchanged sources.
    public let contentHash: String
    /// MIME type of the source, when known.
    public let mime: String?
    /// How completely the body was extracted.
    public let extractStatus: ExtractStatus
    /// When this revision was indexed.
    public let indexedAt: Date
    /// Caller-supplied key/value annotations (never secrets).
    public let metadata: [String: String]

    /// Creates an indexed document.
    public init(
        id: UUID = UUID(),
        source: IndexSource,
        externalID: String,
        displayName: String,
        path: String? = nil,
        messageID: String? = nil,
        mailbox: String? = nil,
        mtime: Date? = nil,
        sizeBytes: Int64? = nil,
        contentHash: String,
        mime: String? = nil,
        extractStatus: ExtractStatus = .extracted,
        indexedAt: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.source = source
        self.externalID = externalID
        self.displayName = displayName
        self.path = path
        self.messageID = messageID
        self.mailbox = mailbox
        self.mtime = mtime
        self.sizeBytes = sizeBytes
        self.contentHash = contentHash
        self.mime = mime
        self.extractStatus = extractStatus
        self.indexedAt = indexedAt
        self.metadata = metadata
    }
}

/// Stored size, modification time, content hash, and extraction outcome for one indexed document.
public struct DocStoredFingerprint: Sendable, Codable, Equatable {
    /// Last modification time of the source at index time, when known.
    public let mtime: Date?
    /// Source size in bytes at index time, when known.
    public let sizeBytes: Int64?
    /// How completely the body was extracted.
    public let extractStatus: ExtractStatus
    /// Stored content hash for fast in-memory reindex checks, when loaded.
    public let contentHash: String?

    /// Creates a stored fingerprint. mtime: Last modification time at index time,
    /// when known.
    public init(
        mtime: Date? = nil,
        sizeBytes: Int64? = nil,
        extractStatus: ExtractStatus,
        contentHash: String? = nil
    ) {
        self.mtime = mtime
        self.sizeBytes = sizeBytes
        self.extractStatus = extractStatus
        self.contentHash = contentHash
    }
}

/// One document and its chunks queued for a batched SQLite commit.
public struct DocBatchUpsertEntry: Sendable, Equatable {
    /// Document metadata to insert or update.
    public let document: IndexedDocument
    /// Chunks belonging to `document`.
    public let chunks: [IndexedChunk]
    /// Optional run identifier stamped into `last_seen_run` when non-nil.
    public let runID: String?
    /// When true, replaces chunks even if `contentHash` matches an existing non-failed row.
    public let replaceChunksWhenUnchanged: Bool

    /// Creates a batched document-and-chunks upsert entry.
    public init(
        document: IndexedDocument,
        chunks: [IndexedChunk],
        runID: String? = nil,
        replaceChunksWhenUnchanged: Bool = false
    ) {
        self.document = document
        self.chunks = chunks
        self.runID = runID
        self.replaceChunksWhenUnchanged = replaceChunksWhenUnchanged
    }
}

/// One text chunk of an indexed document, optionally carrying a vector.
public struct IndexedChunk: Sendable, Codable, Equatable, Identifiable {
    /// Stable chunk identifier.
    public let id: UUID
    /// Owning document.
    public let documentID: UUID
    /// Zero-based position of this chunk within the document.
    public let ordinal: Int
    /// Chunk text, also the full-text indexed payload.
    public let text: String
    /// Embedding vector; empty for keyword-only chunks.
    public let embedding: [Float]
    /// Whether an embedding is present.
    public let isVector: Bool

    /// Creates an indexed chunk.
    /// - Parameter isVector: Explicit vector flag; derived from `embedding` when omitted.
    public init(
        id: UUID = UUID(),
        documentID: UUID,
        ordinal: Int,
        text: String,
        embedding: [Float] = [],
        isVector: Bool? = nil
    ) {
        self.id = id
        self.documentID = documentID
        self.ordinal = ordinal
        self.text = text
        self.embedding = embedding
        self.isVector = isVector ?? !embedding.isEmpty
    }
}

/// Single definition of logical content bytes for the local document index.
public enum IndexContentBytes {
    /// Sums text and vector bytes into one logical content total. textBytes: Chunk
    /// text bytes.
    public static func contentBytes(textBytes: Int64, vectorBytes: Int64) -> Int64 {
        max(textBytes, 0) + max(vectorBytes, 0)
    }
}

/// Per-source aggregate counts describing one origin corpus.
public struct IndexSourceStats: Sendable, Codable, Equatable {
    /// Origin corpus these counts belong to.
    public let source: IndexSource
    /// Number of indexed documents from this source.
    public let documents: Int
    /// Number of stored chunks belonging to this source.
    public let chunks: Int
    /// Total chunk text bytes belonging to this source.
    public let bytes: Int64

    /// Creates a per-source aggregate snapshot.
    public init(source: IndexSource, documents: Int, chunks: Int, bytes: Int64) {
        self.source = source
        self.documents = documents
        self.chunks = chunks
        self.bytes = bytes
    }
}

/// Extraction-outcome breakdown describing one status bucket.
public struct IndexExtractStatusStats: Sendable, Codable, Equatable {
    /// Extraction outcome these counts belong to.
    public let status: ExtractStatus
    /// Number of indexed documents with this outcome.
    public let documents: Int

    /// Creates an extraction-outcome aggregate snapshot.
    public init(status: ExtractStatus, documents: Int) {
        self.status = status
        self.documents = documents
    }
}

/// Aggregate counts describing the current index contents.
public struct IndexStats: Sendable, Codable, Equatable {
    /// Number of indexed documents.
    public let documents: Int
    /// Number of stored chunks.
    public let chunks: Int
    /// Number of chunks carrying an embedding.
    public let vectorChunks: Int
    /// Number of chunks searchable by keyword only.
    public let keywordChunks: Int
    /// Total chunk text bytes held by the index.
    public let bytes: Int64
    /// When this snapshot was taken.
    public let indexAsOf: Date
    /// Per-source document/chunk/byte aggregates, one row per origin corpus.
    public let bySource: [IndexSourceStats]
    /// Document counts grouped by extraction outcome.
    public let byExtractStatus: [IndexExtractStatusStats]
    /// On-disk database file size in bytes (`page_count` times `page_size`).
    public let dbFileBytes: Int64
    /// Write-ahead log size in bytes (`dbPath` plus `-wal` when present).
    public let walBytes: Int64
    /// Logical chunk text bytes (`SUM(LENGTH(chunk_text))`), reported when the
    /// `dbstat` probe is available and nil otherwise; not on-disk page bytes.
    public let textBytes: Int64?
    /// Logical embedding bytes (`SUM(LENGTH(embedding))` over vector chunks),
    /// reported when the `dbstat` probe is available and nil otherwise; not
    /// on-disk page bytes.
    public let vectorBytes: Int64?
    /// Full-text index bytes as on-disk page bytes summed via the grouped
    /// `dbstat` split, nil when unavailable.
    public let ftsBytes: Int64?
    /// Unused freelist bytes reclaimable by `VACUUM` (`freelist_count` times `page_size`).
    public let freeBytes: Int64
    /// Logical content bytes (chunk text plus embedding bytes via `IndexContentBytes`).
    public let contentBytes: Int64

    /// Coding keys for the statistics snapshot.
    private enum CodingKeys: String, CodingKey {
        case documents
        case chunks
        case vectorChunks
        case keywordChunks
        case bytes
        case indexAsOf
        case bySource
        case byExtractStatus
        case dbFileBytes
        case walBytes
        case textBytes
        case vectorBytes
        case ftsBytes
        case freeBytes
        case contentBytes
    }

    /// Creates an index statistics snapshot. documents: Indexed document count.
    public init(
        documents: Int,
        chunks: Int,
        vectorChunks: Int,
        keywordChunks: Int,
        bytes: Int64,
        indexAsOf: Date,
        bySource: [IndexSourceStats] = [],
        byExtractStatus: [IndexExtractStatusStats] = [],
        dbFileBytes: Int64 = 0,
        walBytes: Int64 = 0,
        textBytes: Int64? = nil,
        vectorBytes: Int64? = nil,
        ftsBytes: Int64? = nil,
        freeBytes: Int64 = 0,
        contentBytes: Int64? = nil
    ) {
        self.documents = documents
        self.chunks = chunks
        self.vectorChunks = vectorChunks
        self.keywordChunks = keywordChunks
        self.bytes = bytes
        self.indexAsOf = indexAsOf
        self.bySource = bySource
        self.byExtractStatus = byExtractStatus
        self.dbFileBytes = dbFileBytes
        self.walBytes = walBytes
        self.textBytes = textBytes
        self.vectorBytes = vectorBytes
        self.ftsBytes = ftsBytes
        self.freeBytes = freeBytes
        self.contentBytes = contentBytes ?? bytes
    }

    /// Decodes a snapshot, defaulting additive aggregates to empty so payloads
    /// written before per-source and extract-status breakdowns still decode.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.documents = try container.decode(Int.self, forKey: .documents)
        self.chunks = try container.decode(Int.self, forKey: .chunks)
        self.vectorChunks = try container.decode(Int.self, forKey: .vectorChunks)
        self.keywordChunks = try container.decode(Int.self, forKey: .keywordChunks)
        self.bytes = try container.decode(Int64.self, forKey: .bytes)
        self.indexAsOf = try container.decode(Date.self, forKey: .indexAsOf)
        self.bySource = try container.decodeIfPresent([IndexSourceStats].self, forKey: .bySource) ?? []
        self.byExtractStatus = try container.decodeIfPresent([IndexExtractStatusStats].self, forKey: .byExtractStatus) ?? []
        self.dbFileBytes = try container.decodeIfPresent(Int64.self, forKey: .dbFileBytes) ?? 0
        self.walBytes = try container.decodeIfPresent(Int64.self, forKey: .walBytes) ?? 0
        self.textBytes = try container.decodeIfPresent(Int64.self, forKey: .textBytes)
        self.vectorBytes = try container.decodeIfPresent(Int64.self, forKey: .vectorBytes)
        self.ftsBytes = try container.decodeIfPresent(Int64.self, forKey: .ftsBytes)
        self.freeBytes = try container.decodeIfPresent(Int64.self, forKey: .freeBytes) ?? 0
        self.contentBytes = try container.decodeIfPresent(Int64.self, forKey: .contentBytes) ?? bytes
    }

    /// Encodes a snapshot including the additive aggregates.
    /// - Parameter encoder: Destination encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(documents, forKey: .documents)
        try container.encode(chunks, forKey: .chunks)
        try container.encode(vectorChunks, forKey: .vectorChunks)
        try container.encode(keywordChunks, forKey: .keywordChunks)
        try container.encode(bytes, forKey: .bytes)
        try container.encode(indexAsOf, forKey: .indexAsOf)
        try container.encode(bySource, forKey: .bySource)
        try container.encode(byExtractStatus, forKey: .byExtractStatus)
        try container.encode(dbFileBytes, forKey: .dbFileBytes)
        try container.encode(walBytes, forKey: .walBytes)
        try container.encodeIfPresent(textBytes, forKey: .textBytes)
        try container.encodeIfPresent(vectorBytes, forKey: .vectorBytes)
        try container.encodeIfPresent(ftsBytes, forKey: .ftsBytes)
        try container.encode(freeBytes, forKey: .freeBytes)
        try container.encode(contentBytes, forKey: .contentBytes)
    }
}

/// On-disk and logical size breakdown for the local document index. A missing database reports
/// zeros rather than failing so a stock install renders an honest empty state.
public struct IndexStorageBreakdown: Sendable, Codable, Equatable {
    /// Main SQLite file size in bytes (`index.db`).
    public let dbFileBytes: Int64
    /// Write-ahead log size in bytes (`index.db-wal`), zero when checkpointed.
    public let walBytes: Int64
    /// Total chunk text bytes held by the index.
    public let textBytes: Int64
    /// Total embedding BLOB bytes held by vector chunks.
    public let vectorBytes: Int64
    /// Full-text index bytes (`indexed_chunks_fts`), zero when unavailable.
    public let ftsBytes: Int64
    /// Unused freelist bytes reclaimable by `VACUUM`.
    public let freeBytes: Int64
    /// Logical content bytes (`textBytes` plus `vectorBytes`).
    public let contentBytes: Int64

    /// Creates a storage breakdown. dbFileBytes: Main file size.
    public init(
        dbFileBytes: Int64 = 0,
        walBytes: Int64 = 0,
        textBytes: Int64 = 0,
        vectorBytes: Int64 = 0,
        ftsBytes: Int64 = 0,
        freeBytes: Int64 = 0,
        contentBytes: Int64 = 0
    ) {
        self.dbFileBytes = dbFileBytes
        self.walBytes = walBytes
        self.textBytes = textBytes
        self.vectorBytes = vectorBytes
        self.ftsBytes = ftsBytes
        self.freeBytes = freeBytes
        self.contentBytes = contentBytes
    }
}

/// Outcome of reclaiming index file space with `VACUUM`.
public struct IndexReclaimResult: Sendable, Codable, Equatable {
    /// On-disk total before `VACUUM`, in bytes.
    public let beforeBytes: Int64
    /// On-disk total after `VACUUM`, in bytes.
    public let afterBytes: Int64
    /// Bytes reclaimed (`beforeBytes` minus `afterBytes`, floored at zero).
    public let reclaimedBytes: Int64

    /// Creates a reclaim outcome. beforeBytes: On-disk total before.
    public init(beforeBytes: Int64, afterBytes: Int64, reclaimedBytes: Int64) {
        self.beforeBytes = beforeBytes
        self.afterBytes = afterBytes
        self.reclaimedBytes = reclaimedBytes
    }
}

/// Failures raised by ``DocIndexStore``.
public enum DocIndexError: Error, Sendable, Equatable {
    /// The SQLite store could not be opened or migrated.
    case storeUnavailable(String)
    /// A read or write against the store failed.
    case persistenceFailed(String)
}
