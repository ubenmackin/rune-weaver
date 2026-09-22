// Rune Weaver Core — Value types for the local document index.
//
// Defines the persisted shape of the searchable local corpus: which origin a
// document came from, how completely its body was extracted, the document and
// chunk records the store round-trips, and the aggregate statistics the index
// reports. These are storage-agnostic value objects so callers can assemble
// them before the SQLite sidecar exists; `DocIndexStore` owns persistence.

import Foundation

/// Origin corpus for one indexed document.
public enum IndexSource: String, Sendable, Codable, CaseIterable, Equatable {
    /// Local filesystem documents (markdown, PDF, plain text).
    case files
    /// Mail messages read from a configured mailbox.
    case mail
    /// Chat/message transcripts.
    case messages
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

    /// Creates an index statistics snapshot.
    public init(
        documents: Int,
        chunks: Int,
        vectorChunks: Int,
        keywordChunks: Int,
        bytes: Int64,
        indexAsOf: Date
    ) {
        self.documents = documents
        self.chunks = chunks
        self.vectorChunks = vectorChunks
        self.keywordChunks = keywordChunks
        self.bytes = bytes
        self.indexAsOf = indexAsOf
    }
}

/// Failures raised by ``DocIndexStore``.
public enum DocIndexError: Error, Sendable, Equatable {
    /// The SQLite store could not be opened or migrated.
    case storeUnavailable(String)
    /// A read or write against the store failed.
    case persistenceFailed(String)
}
