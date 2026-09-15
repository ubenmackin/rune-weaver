// RuneWeaver - Core - Semantic store maintenance for MemoryEngine.
//
// Houses the vector-store maintenance surface (counts, dimension reads,
// clearing, reindexing, and embedding backfill) plus its outcome value so
// the main engine file stays within style budgets. Backfill gives
// keyword-only rows vectors without losing identity: it preserves fact
// identifiers, metadata, and creation order, leaves already-embedded rows
// alone, refuses to mix store and backend widths without an explicit reset,
// isolates per-row width rejections as skips, and throws the same reset
// guidance when a pass rejects every pending row (a systematic width
// disagreement that would otherwise masquerade as a silent all-skip).

import Foundation

/// Outcome of one embedding-backfill pass over keyword-only rows.
///
/// A struct (rather than a tuple) keeps the three counts name-addressable
/// at call sites while satisfying the tuple-arity style budget. Counts
/// partition the pending rows: every pending row lands in exactly one
/// bucket per pass.
public struct EmbeddingBackfillResult: Sendable, Equatable {
    /// Rows that gained a vector and were persisted.
    public let embedded: Int
    /// Rows skipped for per-row width mismatch.
    ///
    /// Never fatal when at least one row embeds, but a pass that skips every
    /// pending row is a systematic mismatch that throws instead of returning.
    public let skipped: Int
    /// Rows lost to batch-level embedding or store failures.
    public let failed: Int

    /// Creates a backfill outcome.
    /// - Parameters:
    ///   - embedded: Rows that gained a vector.
    ///   - skipped: Rows skipped for width mismatch.
    ///   - failed: Rows lost to embedding or store failures.
    public init(embedded: Int, skipped: Int, failed: Int) {
        self.embedded = embedded
        self.skipped = skipped
        self.failed = failed
    }
}

public extension MemoryEngine {
    /// Total stored semantic fact count from the shared vector store.
    /// - Returns: Fact count.
    func semanticFactCount() async -> Int {
        await semanticStoreCount()
    }

    /// All semantic facts, oldest first, from the shared vector store.
    /// - Returns: Stored facts for display commands.
    func allSemanticFacts() async -> [StoredFact] {
        await semanticStoreAllFacts().sorted { $0.createdAt < $1.createdAt }
    }

    /// Active embedding width of the semantic store, if known.
    ///
    /// Derived from stored vectors (a single width wins while mixed or
    /// empty widths clear to nil) so backfill can refuse to mix a new
    /// backend width with an old store width instead of silently
    /// comparing incomparable vectors.
    /// - Returns: Store dimension, or nil when unknown or empty.
    func semanticDimension() async -> Int? {
        await semanticStoreDimension()
    }

    /// Clears every semantic row and resets the derived store width.
    ///
    /// The file persists empty first, then the in-memory width is
    /// recomputed from disk so a stale derived width never blocks the next
    /// backend: without the reload the old dimension would linger and
    /// reject the first row of the new width even though the store is empty.
    /// An init-configured expectation survives the empty.
    /// - Throws: `MemoryEngineError/semanticFailed(_:)` when the clear fails.
    func clearSemanticStore() async throws {
        do {
            try await semanticStoreClear()
        } catch let error as VectorStoreError {
            throw MemoryEngineError.semanticFailed(String(describing: error))
        } catch {
            throw MemoryEngineError.semanticFailed(error.localizedDescription)
        }
    }

    /// Compacts the semantic store and revalidates its dimension.
    ///
    /// Reloads externally added rows, drops exact duplicates, and rewrites
    /// the file so manual edits converge; mixed widths throw instead of
    /// silently keeping the first width so operators notice the drift.
    /// - Returns: Fact count after compaction.
    /// - Throws: `MemoryEngineError/semanticFailed(_:)` when the file is
    ///   corrupt or stored rows have mixed widths.
    @discardableResult
    func reindexSemantic() async throws -> Int {
        do {
            return try await semanticStoreReindex()
        } catch let error as VectorStoreError {
            throw MemoryEngineError.semanticFailed(String(describing: error))
        } catch {
            throw MemoryEngineError.semanticFailed(error.localizedDescription)
        }
    }

    /// Gives keyword-only rows vectors while preserving identity and order.
    ///
    /// Only rows with empty embeddings are embedded; already-vectorized rows
    /// are never re-embedded so stable similarities and profile mirrors keep
    /// pointing at the same identifiers. Each replacement reuses the original
    /// `id`, `metadata`, and `createdAt` so profile mirrors stay linked and
    /// chronological ordering survives the rewrite. Work proceeds in batches
    /// to bound model round-trips, and failures stay isolated: a batch-level
    /// embedding failure marks its whole batch failed, while a per-row width
    /// rejection counts as skipped so one stale row cannot abort the rest.
    /// A pass that skips every pending row is not per-row noise but a
    /// systematic store/backend disagreement, so it throws the explicit-reset
    /// guidance instead of reporting a silent all-skip.
    /// - Parameters:
    ///   - embedder: Vector producer for fact contents.
    ///   - batchSize: Texts per embedding call. Defaults to 32. Non-positive
    ///     values clamp to one so callers never deadlock on an empty batch.
    /// - Returns: Counts of embedded, skipped (width-mismatched), and failed rows.
    /// - Throws: `MemoryEngineError/semanticFailed(_:)` when the store and
    ///   backend widths differ, either from the backend's advertised width
    ///   before any work or from every pending row being rejected at upsert
    ///   time; the message names both widths and requires an explicit reset.
    func backfillEmbeddings(
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
    ///
    /// Single-sourced so the advertised-width guard and the all-rows-skipped
    /// guard emit identical guidance; a nil backend width (only possible when
    /// nothing was produced) renders as `unknown`.
    /// - Parameters:
    ///   - storeDimension: Width already fixed by the store.
    ///   - backendDimension: Observed backend width, or nil when unknown.
    /// - Returns: Guidance requiring an explicit reset.
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
