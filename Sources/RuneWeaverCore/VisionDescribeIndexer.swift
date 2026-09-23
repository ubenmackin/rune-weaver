// Rune Weaver Core — Opt-in vision description enrichment for the local document index.
//
// When the operator enables `index.describe_images_with_llm`, documents whose
// text extraction produced no body (scanned PDFs, images) may be described by
// the configured multimodal provider. This actor is the single seam for that
// work: it reuses the shared vision gate so a text-only provider never receives
// pixels, bounds each image before it leaves the process, enforces the nightly
// call budget, and stores the returned description as an additive chunk with
// provenance metadata. It never overwrites extracted text: only documents whose
// extraction status is `.metadataOnly` are eligible, and the original body
// status is preserved.
//
// The provider is a protocol seam rather than a concrete router so this core
// target stays free of a dependency cycle; the adapter that wraps the active
// router provider and forwards bounded image content is wired at the
// application boundary. No secret, credential, or token is ever placed in the
// prompt or the stored description.

import Foundation

// MARK: - Provenance

/// Stable provenance recorded on a document when the vision path runs.
///
/// Keys are plain strings so diagnostics and callers can read them from the
/// document metadata dictionary without decoding a structure. They exist so an
/// AI-authored description is always distinguishable from extracted body text.
public enum VisionDescribeProvenance: Sendable {
    /// Origin marker written for every AI-authored description.
    public static let originAIDescribed = "ai-described"
    /// Document metadata key holding the origin marker.
    public static let originKey = "origin"
    /// Document metadata key holding the describing model name.
    public static let modelKey = "model"
    /// Document metadata key holding the ISO-8601 description instant.
    public static let describedAtKey = "describedAt"
    /// Document metadata key holding the prompt revision.
    public static let promptVersionKey = "promptVersion"
    /// Prompt revision recorded for every description this component writes.
    /// Bumping it lets a later run tell descriptions apart from an older prompt.
    public static let promptVersion = "vision-describe-v1"
}

// MARK: - Provider seam

/// A provider able to describe a document image with a multimodal model.
///
/// The seam mirrors the router provider's ``ModelInfo`` so the capability gate
/// is the same one screenshots use, and it keeps image transport in the adapter:
/// the component hands over a bounded `data:image/jpeg;base64,...` URL and never
/// the raw file, so an adapter only has to forward what it is given.
public protocol VisionDescribeProvider: Sendable {
    /// Metadata for the active model. `supportsVision` decides whether image
    /// content may be sent at all.
    var modelInfo: ModelInfo { get }

    /// Whether the provider can answer right now.
    /// - Returns: True when a description request may be attempted.
    func isAvailable() async -> Bool

    /// Describes one bounded image.
    /// - Parameters:
    ///   - imageDataURL: Bounded `data:image/jpeg;base64,...` content.
    ///   - prompt: Instruction describing the desired output.
    /// - Returns: Description text, or nil when the provider cannot answer.
    func describeImage(_ imageDataURL: String, prompt: String) async -> String?
}

public extension VisionDescribeProvider {
    /// Default availability so adapters without a health probe compile without
    /// boilerplate while still allowing a real probe to override it.
    /// - Returns: True.
    func isAvailable() async -> Bool {
        true
    }
}

// MARK: - Results

/// One stored AI description plus the provenance that produced it.
public struct VisionDescription: Sendable, Equatable {
    /// Document the description belongs to.
    public let documentID: UUID
    /// Description text stored as the additive chunk body.
    public let text: String
    /// Model that produced the description.
    public let model: String
    /// Instant the description was produced.
    public let describedAt: Date
    /// Prompt revision used for the request.
    public let promptVersion: String
    /// Origin marker, always ``VisionDescribeProvenance/originAIDescribed``.
    public let origin: String
    /// Ordinal the description chunk was stored under.
    public let chunkOrdinal: Int

    /// Creates a description record.
    public init(
        documentID: UUID,
        text: String,
        model: String,
        describedAt: Date,
        promptVersion: String,
        origin: String,
        chunkOrdinal: Int
    ) {
        self.documentID = documentID
        self.text = text
        self.model = model
        self.describedAt = describedAt
        self.promptVersion = promptVersion
        self.origin = origin
        self.chunkOrdinal = chunkOrdinal
    }
}

/// Why a document was left as-is instead of being described.
public enum VisionDescribeSkipReason: String, Sendable, Equatable {
    /// The operator has not enabled image description.
    case disabled
    /// The document already carries extracted body text, so it is not eligible.
    case notMetadataOnly
    /// The document already carries an AI description.
    case alreadyDescribed
    /// The active provider cannot accept vision input.
    case textOnlyProvider
    /// The provider was unavailable or returned nothing usable.
    case providerUnavailable
    /// The nightly call budget is spent.
    case budgetExhausted
    /// The source image exceeds the per-file byte cap.
    case imageTooLarge
    /// The image could not be decoded and re-encoded within the byte budget.
    case imageUnreadable
    /// The work was cancelled before the provider was called.
    case cancelled
}

/// Outcome of one enrichment attempt.
public enum VisionDescribeOutcome: Sendable, Equatable {
    /// A description was produced and stored.
    case described(VisionDescription)
    /// The document was left untouched, with the reason.
    case skipped(VisionDescribeSkipReason)
}

// MARK: - Indexer

/// Describes `.metadataOnly` documents with the configured multimodal provider.
///
/// The actor is the only place shared budget state lives, so concurrent
/// enrichment work cannot overshoot the nightly call budget. Every gate is
/// checked before any provider call, and the provider is only reached with a
/// bounded image URL, keeping the opt-in send small and explicit.
public actor VisionDescribeIndexer {
    /// Instruction sent with every image. It asks for searchable visual detail
    /// and explicitly forbids reproducing secrets so a description never echoes
    /// credentials that happen to be visible in a document.
    public static let describePrompt = """
    Describe the visual content of this document image in a few sentences. \
    Summarize visible text, tables, charts, and layout so the document can be found by search. \
    Do not reproduce secrets, credentials, or personal identifiers.
    """

    /// Copy a Settings surface can show beside the opt-in. It states plainly
    /// that a remote provider receives document content off-device.
    public static let settingsDisclosure = """
    Describing images with the LLM sends document image content to the configured provider. \
    When that provider is remote, the data is sent off-device.
    """

    /// Index policy carrying the opt-in flag and the nightly call budget.
    private let config: IndexConfig
    /// Store the description chunk and provenance are written to.
    private let store: DocIndexStore
    /// Multimodal provider that answers description requests.
    private let provider: any VisionDescribeProvider
    /// Per-file byte cap applied before any image work.
    private let maxImageBytes: Int
    /// Clock seam so budget windows are deterministic under test.
    private let now: @Sendable () -> Date
    /// Advisory progress sink mirroring the tool progress reporter contract.
    private let progress: ToolProgressReporter

    /// Start of the budget window the call count belongs to.
    private var budgetWindowStart: Date?
    /// Provider calls made in the current budget window.
    private var callsThisWindow = 0

    /// Creates a vision-describe indexer.
    /// - Parameters:
    ///   - config: Index policy; `describeImagesWithLLM` gates all work and
    ///     `nightlyBudget` caps calls per night (0 means unlimited).
    ///   - store: Document index the description and provenance are written to.
    ///   - provider: Multimodal provider, or a stub in tests.
    ///   - maxImageBytes: Per-file byte cap; defaults to the configured
    ///     `max_file_mb` bound so a single image cannot exceed the file policy.
    ///   - now: Clock used to roll the nightly budget window.
    ///   - progress: Advisory progress sink; defaults to a no-op.
    public init(
        config: IndexConfig,
        store: DocIndexStore,
        provider: any VisionDescribeProvider,
        maxImageBytes: Int? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        progress: @escaping ToolProgressReporter = ToolContext.noProgress
    ) {
        self.config = config
        self.store = store
        self.provider = provider
        self.maxImageBytes = max(1, maxImageBytes ?? config.maxFileMB * 1024 * 1024)
        self.now = now
        self.progress = progress
    }

    /// Describes one `.metadataOnly` document and stores the result additively.
    ///
    /// Every gate runs before the provider is reached, so an opted-out or
    /// text-only configuration never sends image content. On success the
    /// description is written as an extra chunk and the provenance is merged
    /// into the document metadata; the document's `.metadataOnly` body status is
    /// preserved because the description is not extracted text.
    /// - Parameters:
    ///   - document: Document whose extraction produced no body text.
    ///   - imageData: Original image bytes for the document.
    /// - Returns: A described outcome, or a skip carrying the reason.
    /// - Throws: ``DocIndexError`` when the store write fails.
    public func enrich(document: IndexedDocument, imageData: Data) async throws -> VisionDescribeOutcome {
        guard config.describeImagesWithLLM else {
            return .skipped(.disabled)
        }
        // Only bodyless documents are eligible; a document with extracted text
        // must never have its chunks replaced by a description.
        guard document.extractStatus == .metadataOnly else {
            return .skipped(.notMetadataOnly)
        }
        guard document.metadata[VisionDescribeProvenance.originKey] != VisionDescribeProvenance.originAIDescribed else {
            return .skipped(.alreadyDescribed)
        }
        // Reuse the shared vision gate: a text-only provider is withheld pixels
        // exactly as screenshots are withheld from it.
        guard VisionGate.shouldAdvertiseScreenshot(supportsVision: provider.modelInfo.supportsVision) else {
            return .skipped(.textOnlyProvider)
        }
        rollBudgetWindowIfNeeded()
        if config.nightlyBudget > 0, callsThisWindow >= config.nightlyBudget {
            return .skipped(.budgetExhausted)
        }
        guard imageData.count <= maxImageBytes else {
            return .skipped(.imageTooLarge)
        }
        guard !Task.isCancelled else {
            return .skipped(.cancelled)
        }
        guard await provider.isAvailable() else {
            return .skipped(.providerUnavailable)
        }
        // Downscale before the bytes leave the process so the provider only ever
        // sees content inside the shared screenshot budget.
        guard let boundedImage = ImageDownscaler.downscaledDataURL(for: imageData) else {
            return .skipped(.imageUnreadable)
        }
        await reportProgress(message: "Describing document image", matched: 0, document: document)
        guard let raw = await provider.describeImage(boundedImage, prompt: Self.describePrompt) else {
            // A cancel racing the LLM turn still stops before commit, bounding
            // overrun to one document instead of storing a late description.
            if Task.isCancelled {
                return .skipped(.cancelled)
            }
            return .skipped(.providerUnavailable)
        }
        // Honor cancellation per document: a description arriving after cancel
        // is dropped instead of committed, so the run stops within one turn.
        if Task.isCancelled {
            return .skipped(.cancelled)
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return .skipped(.providerUnavailable)
        }

        let describedAt = now()
        let model = provider.modelInfo.name
        let enriched = Self.document(document, provenance: (model: model, describedAt: describedAt))
        let stored = try await store.upsertDocument(enriched)
        // The description is an additive chunk: a `.metadataOnly` document has no
        // extracted chunks, so ordinal zero cannot displace body text.
        let chunk = IndexedChunk(documentID: stored.id, ordinal: 0, text: text)
        _ = try await store.upsertChunks(documentID: stored.id, chunks: [chunk])
        callsThisWindow += 1
        await reportProgress(message: "Described document image", matched: 1, document: document)
        return .described(
            VisionDescription(
                documentID: stored.id,
                text: text,
                model: model,
                describedAt: describedAt,
                promptVersion: VisionDescribeProvenance.promptVersion,
                origin: VisionDescribeProvenance.originAIDescribed,
                chunkOrdinal: 0
            )
        )
    }

    /// Resets the call count when the calendar day rolls over.
    private func rollBudgetWindowIfNeeded() {
        let windowStart = Calendar.current.startOfDay(for: now())
        guard budgetWindowStart != windowStart else { return }
        budgetWindowStart = windowStart
        callsThisWindow = 0
    }

    /// Emits an advisory progress frame without disclosing an absolute path.
    /// - Parameters:
    ///   - message: Human-readable status line.
    ///   - matched: Items matched so far.
    ///   - document: Document being processed.
    private func reportProgress(message: String, matched: Int, document: IndexedDocument) async {
        let report = ToolProgress(
            message: message,
            scanned: callsThisWindow,
            matched: matched,
            current: document.displayName
        )
        await progress(report)
    }

    /// Returns a copy of a document carrying the description provenance.
    /// - Parameters:
    ///   - document: Source document.
    ///   - provenance: Model name and description instant to record.
    /// - Returns: A copy whose metadata carries the provenance keys.
    private static func document(
        _ document: IndexedDocument,
        provenance: (model: String, describedAt: Date)
    ) -> IndexedDocument {
        var metadata = document.metadata
        metadata[VisionDescribeProvenance.originKey] = VisionDescribeProvenance.originAIDescribed
        metadata[VisionDescribeProvenance.modelKey] = provenance.model
        metadata[VisionDescribeProvenance.describedAtKey] = ISO8601DateFormatter().string(from: provenance.describedAt)
        metadata[VisionDescribeProvenance.promptVersionKey] = VisionDescribeProvenance.promptVersion
        return IndexedDocument(
            id: document.id,
            source: document.source,
            externalID: document.externalID,
            displayName: document.displayName,
            path: document.path,
            messageID: document.messageID,
            mailbox: document.mailbox,
            mtime: document.mtime,
            sizeBytes: document.sizeBytes,
            contentHash: document.contentHash,
            mime: document.mime,
            extractStatus: document.extractStatus,
            indexedAt: document.indexedAt,
            metadata: metadata
        )
    }
}
