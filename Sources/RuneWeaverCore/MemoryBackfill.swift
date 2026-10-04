// Rune Weaver Core — Semantic store maintenance for MemoryEngine.

import Foundation

/// Outcome of one embedding-backfill pass over keyword-only rows.
public struct EmbeddingBackfillResult: Sendable, Equatable {
    /// Rows that gained a vector and were persisted.
    public let embedded: Int
    /// Rows skipped for per-row width mismatch.
    public let skipped: Int
    /// Rows lost to batch-level embedding or store failures.
    public let failed: Int

    /// Creates a backfill outcome.
    public init(embedded: Int, skipped: Int, failed: Int) {
        self.embedded = embedded
        self.skipped = skipped
        self.failed = failed
    }
}

extension MemoryEngine {
    /// Total stored semantic fact count from the shared vector store.
    /// - Returns: Fact count.
    public func semanticFactCount() async -> Int {
        await semanticStoreCount()
    }

    /// All semantic facts, oldest first, from the shared vector store.
    /// - Returns: Stored facts for display commands.
    public func allSemanticFacts() async -> [StoredFact] {
        await semanticStoreAllFacts().sorted { $0.createdAt < $1.createdAt }
    }

    /// Active embedding width of the semantic store, if known.
    public func semanticDimension() async -> Int? {
        await semanticStoreDimension()
    }

    /// Clears every semantic row and resets the derived store width.
    public func clearSemanticStore() async throws {
        do {
            try await semanticStoreClear()
        } catch let error as VectorStoreError {
            throw MemoryEngineError.semanticFailed(String(describing: error))
        } catch {
            throw MemoryEngineError.semanticFailed(error.localizedDescription)
        }
    }

    /// Compacts the semantic store and revalidates its dimension.
    @discardableResult
    public func reindexSemantic() async throws -> Int {
        do {
            return try await semanticStoreReindex()
        } catch let error as VectorStoreError {
            throw MemoryEngineError.semanticFailed(String(describing: error))
        } catch {
            throw MemoryEngineError.semanticFailed(error.localizedDescription)
        }
    }

    /// Gives keyword-only rows vectors while preserving identity and order.
    public func backfillEmbeddings(
        embedder: any EmbeddingsBackend,
        batchSize: Int = 32
    ) async throws -> EmbeddingBackfillResult {
        let storeDimension = await semanticStoreDimension()
        let backendDimension = await embedder.dimension
        if let storeDimension, let backendDimension, storeDimension != backendDimension {
            throw Self.embeddingDimensionResetError(storeDimension: storeDimension, backendDimension: backendDimension)
        }
        let pending = await semanticStoreAllFacts()
            .filter(\.embedding.isEmpty)
            .sorted { $0.createdAt < $1.createdAt }
        guard !pending.isEmpty else { return EmbeddingBackfillResult(embedded: 0, skipped: 0, failed: 0) }
        let effectiveBatchSize = max(1, batchSize)
        var embedded = 0
        var skipped = 0
        var failed = 0
        var skippedWidth: Int?
        var index = 0
        while index < pending.count {
            let end = min(index + effectiveBatchSize, pending.count)
            let batch = Array(pending[index ..< end])
            index = end
            let contents = batch.map(\.content)
            let vectors: [[Float]]
            do {
                vectors = try await embedder.embed(contents)
            } catch let error as CancellationError {
                throw error
            } catch {
                failed += batch.count
                continue
            }
            guard vectors.count == batch.count else {
                failed += batch.count
                continue
            }
            for (fact, vector) in zip(batch, vectors) {
                guard !vector.isEmpty else {
                    failed += 1
                    continue
                }
                let replacement = StoredFact(
                    id: fact.id,
                    content: fact.content,
                    embedding: vector,
                    metadata: fact.metadata,
                    createdAt: fact.createdAt,
                    updatedAt: Date()
                )
                do {
                    try await semanticStoreUpsert(replacement)
                    embedded += 1
                } catch let error as CancellationError {
                    throw error
                } catch let error as VectorStoreError {
                    if case VectorStoreError.dimensionMismatch = error {
                        skipped += 1
                        skippedWidth = vector.count
                    } else {
                        failed += 1
                    }
                } catch {
                    failed += 1
                }
            }
        }
        // A backend that advertised no width yet rejected every pending row is
        // a systematic width disagreement, not per-row noise: surface the
        // explicit-reset guidance rather than a silent all-skip.
        if let storeDimension, embedded == 0, failed == 0, skipped == pending.count {
            throw Self.embeddingDimensionResetError(storeDimension: storeDimension, backendDimension: skippedWidth)
        }
        return EmbeddingBackfillResult(embedded: embedded, skipped: skipped, failed: failed)
    }

    /// Builds the explicit-reset error naming the store and backend widths.
    private static func embeddingDimensionResetError(
        storeDimension: Int,
        backendDimension: Int?
    ) -> MemoryEngineError {
        let backendText = backendDimension.map(String.init) ?? "unknown"
        return MemoryEngineError.semanticFailed(
            "Embedding dimension mismatch: store dimension is \(storeDimension) " +
                "but backend dimension is \(backendText). " +
                "Run `rune-weaver memory reindex --embed --reset` to clear the vector store " +
                "and re-embed instead of mixing widths."
        )
    }
}
