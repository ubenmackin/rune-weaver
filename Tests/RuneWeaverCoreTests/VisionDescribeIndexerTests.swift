// Rune Weaver Core Tests — Opt-in vision-describe enrichment for the document index.
//
// Exercises the gates on `VisionDescribeIndexer` end to end against an isolated
// temporary index database: operator opt-out, the text-only provider skip, the
// per-file byte cap, the nightly call budget, provider unavailability, the
// never-overwrite-extracted-text invariant, and the provenance recorded on a
// successful description. A stub provider records every call so each gate can be
// asserted to have prevented the provider from ever seeing image content.

import Foundation
@testable import RuneWeaverCore
import Testing

/// Creates an isolated temporary database path and its parent directory.
/// - Returns: The database path plus the base directory to remove on teardown.
private func makeIndexPath() -> (path: String, base: URL) {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("runeweaver-vision-describe-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return (base.appendingPathComponent("docindex.db").path, base)
}

/// One-pixel PNG used as a real, decodable image fixture.
private let tinyPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

/// Decodes the shared image fixture.
/// - Returns: Decodable PNG bytes.
private func tinyImageData() throws -> Data {
    try #require(Data(base64Encoded: tinyPNGBase64))
}

/// Builds a bodyless document, the only kind the vision path may describe.
/// - Parameter externalID: Source-scoped identifier.
/// - Returns: A `.metadataOnly` document.
private func metadataOnlyDocument(externalID: String) -> IndexedDocument {
    IndexedDocument(
        source: .files,
        externalID: externalID,
        displayName: "scan-\(externalID).pdf",
        path: "/tmp/\(externalID).pdf",
        contentHash: "hash-\(externalID)",
        mime: "application/pdf",
        extractStatus: .metadataOnly
    )
}

/// Vision provider stub that records calls and returns a canned description.
private actor StubVisionProvider: VisionDescribeProvider {
    /// Model metadata; the vision flag drives the capability gate.
    nonisolated let modelInfo: ModelInfo
    /// Canned response, or nil to simulate a provider that answers nothing.
    private let response: String?
    /// Whether the health probe reports the provider reachable.
    private let available: Bool
    /// Bounded image URLs the provider was handed.
    private var receivedImageDataURLs: [String] = []

    /// Creates a stub provider.
    /// - Parameters:
    ///   - supportsVision: Whether the stub model accepts images.
    ///   - modelName: Model name recorded as provenance.
    ///   - response: Canned description, or nil for no answer.
    ///   - available: Whether the provider is reachable.
    init(
        supportsVision: Bool,
        modelName: String = "stub-vision",
        response: String? = "A scanned document showing an invoice table.",
        available: Bool = true
    ) {
        self.modelInfo = ModelInfo(
            name: modelName,
            provider: "stub",
            contextLength: 8192,
            supportsTools: false,
            supportsVision: supportsVision
        )
        self.response = response
        self.available = available
    }

    /// Reports the configured reachability.
    /// - Returns: True when the stub should answer.
    func isAvailable() async -> Bool {
        available
    }

    /// Records the image URL and returns the canned response.
    /// - Parameters:
    ///   - imageDataURL: Bounded image content handed over by the indexer.
    ///   - prompt: Description instruction.
    /// - Returns: The canned description, or nil.
    func describeImage(_ imageDataURL: String, prompt _: String) async -> String? {
        receivedImageDataURLs.append(imageDataURL)
        return response
    }

    /// Number of describe calls received.
    /// - Returns: Call count.
    func callCount() -> Int {
        receivedImageDataURLs.count
    }

    /// Most recent image URL handed to the provider.
    /// - Returns: The last bounded image URL, or nil when never called.
    func lastImageDataURL() -> String? {
        receivedImageDataURLs.last
    }
}

@Suite("Vision Describe Indexer")
struct VisionDescribeIndexerTests {
    @Test
    func `Opt-out never calls the provider and leaves the document unindexed`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)
        let provider = StubVisionProvider(supportsVision: true)
        var config = IndexConfig()
        config.describeImagesWithLLM = false
        let indexer = VisionDescribeIndexer(config: config, store: store, provider: provider)

        let outcome = try await indexer.enrich(
            document: metadataOnlyDocument(externalID: "opt-out"),
            imageData: tinyImageData()
        )

        #expect(outcome == .skipped(.disabled))
        let calls = await provider.callCount()
        #expect(calls == 0)
        let stored = try await store.document(source: .files, externalID: "opt-out")
        #expect(stored == nil)
    }

    @Test
    func `Text-only provider is skipped and never receives image content`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)
        let provider = StubVisionProvider(supportsVision: false)
        var config = IndexConfig()
        config.describeImagesWithLLM = true
        let indexer = VisionDescribeIndexer(config: config, store: store, provider: provider)

        let outcome = try await indexer.enrich(
            document: metadataOnlyDocument(externalID: "text-only"),
            imageData: tinyImageData()
        )

        #expect(outcome == .skipped(.textOnlyProvider))
        let calls = await provider.callCount()
        #expect(calls == 0)
    }

    @Test
    func `Nightly budget stops further calls once spent`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)
        let provider = StubVisionProvider(supportsVision: true)
        var config = IndexConfig()
        config.describeImagesWithLLM = true
        config.nightlyBudget = 1
        let indexer = VisionDescribeIndexer(config: config, store: store, provider: provider)

        let first = try await indexer.enrich(
            document: metadataOnlyDocument(externalID: "budget-one"),
            imageData: tinyImageData()
        )
        guard case .described = first else {
            Issue.record("expected the first call to be described, got \(first)")
            return
        }
        let second = try await indexer.enrich(
            document: metadataOnlyDocument(externalID: "budget-two"),
            imageData: tinyImageData()
        )

        #expect(second == .skipped(.budgetExhausted))
        let calls = await provider.callCount()
        #expect(calls == 1)
    }

    @Test
    func `Successful description stores an additive chunk with provenance`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let provider = StubVisionProvider(
            supportsVision: true,
            modelName: "vision-stub",
            response: "An invoice with a total of 42 dollars."
        )
        var config = IndexConfig()
        config.describeImagesWithLLM = true
        let indexer = VisionDescribeIndexer(
            config: config,
            store: store,
            provider: provider,
            now: { fixedDate }
        )

        let outcome = try await indexer.enrich(
            document: metadataOnlyDocument(externalID: "provenance"),
            imageData: tinyImageData()
        )

        guard case let .described(description) = outcome else {
            Issue.record("expected a description, got \(outcome)")
            return
        }
        #expect(description.origin == VisionDescribeProvenance.originAIDescribed)
        #expect(description.model == "vision-stub")
        #expect(description.promptVersion == VisionDescribeProvenance.promptVersion)
        #expect(description.describedAt == fixedDate)
        #expect(description.text == "An invoice with a total of 42 dollars.")

        let loaded = try await store.document(source: .files, externalID: "provenance")
        let stored = try #require(loaded)
        #expect(stored.extractStatus == .metadataOnly)
        #expect(stored.metadata[VisionDescribeProvenance.originKey] == VisionDescribeProvenance.originAIDescribed)
        #expect(stored.metadata[VisionDescribeProvenance.modelKey] == "vision-stub")
        #expect(stored.metadata[VisionDescribeProvenance.promptVersionKey] == VisionDescribeProvenance.promptVersion)
        #expect(stored.metadata[VisionDescribeProvenance.describedAtKey]?.isEmpty == false)

        let hits = try await store.searchKeyword(query: "invoice", limit: 10)
        #expect(hits.contains(where: { $0.text == description.text }))

        let imageURL = await provider.lastImageDataURL()
        #expect(imageURL?.hasPrefix("data:image/jpeg;base64,") == true)
    }

    @Test
    func `Document with extracted text is skipped and its body survives`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)
        let extracted = IndexedDocument(
            source: .files,
            externalID: "report",
            displayName: "report.pdf",
            contentHash: "hash-report",
            mime: "application/pdf",
            extractStatus: .extracted
        )
        let storedDocument = try await store.upsertDocument(extracted)
        _ = try await store.upsertChunks(
            documentID: storedDocument.id,
            chunks: [IndexedChunk(documentID: storedDocument.id, ordinal: 0, text: "the real extracted body")]
        )
        let provider = StubVisionProvider(supportsVision: true)
        var config = IndexConfig()
        config.describeImagesWithLLM = true
        let indexer = VisionDescribeIndexer(config: config, store: store, provider: provider)

        let outcome = try await indexer.enrich(document: storedDocument, imageData: tinyImageData())

        #expect(outcome == .skipped(.notMetadataOnly))
        let calls = await provider.callCount()
        #expect(calls == 0)
        let hits = try await store.searchKeyword(query: "extracted", limit: 10)
        #expect(hits.count == 1)
        #expect(hits.first?.text == "the real extracted body")
    }

    @Test
    func `Image beyond the per-file byte cap is skipped before any provider call`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)
        let provider = StubVisionProvider(supportsVision: true)
        var config = IndexConfig()
        config.describeImagesWithLLM = true
        let indexer = VisionDescribeIndexer(config: config, store: store, provider: provider, maxImageBytes: 4)

        let outcome = try await indexer.enrich(
            document: metadataOnlyDocument(externalID: "oversized"),
            imageData: Data(repeating: 0, count: 64)
        )

        #expect(outcome == .skipped(.imageTooLarge))
        let calls = await provider.callCount()
        #expect(calls == 0)
    }

    @Test
    func `Unavailable provider leaves the document metadata-only`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)
        let provider = StubVisionProvider(supportsVision: true, available: false)
        var config = IndexConfig()
        config.describeImagesWithLLM = true
        let indexer = VisionDescribeIndexer(config: config, store: store, provider: provider)

        let outcome = try await indexer.enrich(
            document: metadataOnlyDocument(externalID: "offline"),
            imageData: tinyImageData()
        )

        #expect(outcome == .skipped(.providerUnavailable))
        let calls = await provider.callCount()
        #expect(calls == 0)
        let stored = try await store.document(source: .files, externalID: "offline")
        #expect(stored == nil)
    }

    @Test
    func `Undecodable image fails closed without reaching the provider`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)
        let provider = StubVisionProvider(supportsVision: true)
        var config = IndexConfig()
        config.describeImagesWithLLM = true
        let indexer = VisionDescribeIndexer(config: config, store: store, provider: provider)

        let outcome = try await indexer.enrich(
            document: metadataOnlyDocument(externalID: "bogus"),
            imageData: Data("not an image".utf8)
        )

        #expect(outcome == .skipped(.imageUnreadable))
        let calls = await provider.callCount()
        #expect(calls == 0)
    }

    @Test
    func `Already described document is not described twice`() async throws {
        let (path, base) = makeIndexPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocIndexStore(dbPath: path)
        let provider = StubVisionProvider(supportsVision: true)
        var config = IndexConfig()
        config.describeImagesWithLLM = true
        let indexer = VisionDescribeIndexer(config: config, store: store, provider: provider)
        let described = IndexedDocument(
            source: .files,
            externalID: "described",
            displayName: "scan.pdf",
            contentHash: "hash-described",
            mime: "application/pdf",
            extractStatus: .metadataOnly,
            metadata: [VisionDescribeProvenance.originKey: VisionDescribeProvenance.originAIDescribed]
        )

        let outcome = try await indexer.enrich(document: described, imageData: tinyImageData())

        #expect(outcome == .skipped(.alreadyDescribed))
        let calls = await provider.callCount()
        #expect(calls == 0)
    }

    @Test
    func `Settings disclosure names remote providers and off-device delivery`() {
        let copy = VisionDescribeIndexer.settingsDisclosure.lowercased()
        #expect(copy.contains("remote"))
        #expect(copy.contains("off-device"))
    }
}
