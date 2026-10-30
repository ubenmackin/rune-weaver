// Rune Weaver Core — Memory-mapped Float16 vector matrix storage.
// Modeled directly after DigUp's VectorStorage.swift.

import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

#if canImport(SQLite3)
    import SQLite3
#endif

/// Corrupt counts fail closed to error so reads return empty instead of trapping.
private enum VectorStorageBoundsError: Error {
    case outOfBounds
}

/// Contiguous Float16 matrix scored in `blockRows` blocks via `vDSP_mmul`.
/// Actor-confined to `AcceleratedVectorIndex`; shared scratch is sequenced by the actor.
/// Live count lives in the actor's row metadata, not here.
public final class VectorStorage {
    public static let blockRows = 1024
    private let rowCount: Int
    private let halvesPtr: UnsafeMutablePointer<Float16>
    private let blockPtr: UnsafeMutablePointer<Float>
    private let raw: UnsafeMutableRawPointer
    private let bytes: Int

    fileprivate init?(rows: Int) {
        guard rows > 0 else { return nil }
        // Overflow fails closed to nil so the next reload retries.
        let (rowFloats, rowOverflow) = rows.multipliedReportingOverflow(by: AcceleratedVectorMath.dimension)
        guard !rowOverflow else { return nil }
        let (halfBytes, halfOverflow) = rowFloats.multipliedReportingOverflow(by: MemoryLayout<Float16>.stride)
        guard !halfOverflow else { return nil }
        let (blockFloats, blockOverflow) = Self.blockRows.multipliedReportingOverflow(by: AcceleratedVectorMath.dimension)
        guard !blockOverflow else { return nil }
        let (blockBytes, blockByteOverflow) = blockFloats.multipliedReportingOverflow(by: MemoryLayout<Float>.stride)
        guard !blockByteOverflow else { return nil }
        let (total, totalOverflow) = halfBytes.addingReportingOverflow(blockBytes)
        guard !totalOverflow else { return nil }
        self.bytes = total

        #if os(Linux)
            let mapped = mmap(nil, total, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0)
        #else
            let mapped = mmap(nil, total, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
        #endif
        guard let mapped, mapped != MAP_FAILED else {
            return nil
        }
        self.raw = mapped

        self.rowCount = rows
        // Invariant: halves own the prefix so scratch never overlaps rows; even dimension keeps Float base aligned.
        self.halvesPtr = raw.bindMemory(to: Float16.self, capacity: rows * AcceleratedVectorMath.dimension)
        self.blockPtr = (raw + halfBytes).bindMemory(to: Float.self, capacity: Self.blockRows * AcceleratedVectorMath.dimension)
    }

    /// Borrows mutable halves for one row; pointer valid only during `body`.
    fileprivate func withMutableHalvesRow<T>(row: Int, _ body: (UnsafeMutablePointer<Float16>) throws -> T) throws -> T {
        guard row >= 0, row < rowCount else { throw VectorStorageBoundsError.outOfBounds }
        return try body(halvesPtr + (row * AcceleratedVectorMath.dimension))
    }

    /// Borrows one halves slice plus scratch block; pointers valid only during `body`.
    fileprivate func withBlockBuffers<T>(row: Int, count: Int, _ body: (UnsafePointer<Float16>, UnsafeMutablePointer<Float>) throws -> T) throws -> T {
        guard row >= 0, count >= 0, count <= rowCount, row <= rowCount - count else { throw VectorStorageBoundsError.outOfBounds }
        let base = UnsafePointer(halvesPtr + (row * AcceleratedVectorMath.dimension))
        return try body(base, blockPtr)
    }

    deinit {
        munmap(raw, bytes)
    }
}

/// Actor that caches and scores the global vector index.
public actor AcceleratedVectorIndex {
    public static let shared = AcceleratedVectorIndex()
    /// Default window when callers omit a limit.
    public static let defaultSearchLimit = 100

    private struct StagedVectorRow: Sendable {
        let chunkID: UUID
        let documentID: UUID
        let mtime: Double?
        let source: IndexSource
        let modality: VectorModality
        let blob: Data
    }

    private var storage: VectorStorage?
    private var rowChunkID: [UUID] = []
    private var rowDocumentID: [UUID] = []
    private var rowMTime: [Double?] = []
    private var rowSource: [IndexSource] = []
    private var rowModality: [VectorModality] = []
    private var isLoaded = false
    private var loadedDBPath: String?
    private var lastLoadedAt: Date?
    private var loadedGeneration: UInt64 = 0

    private init() {}

    /// Number of loaded vectors.
    public var vectorCount: Int {
        rowChunkID.count
    }

    /// Whether vectors are loaded in memory.
    public var hasLoadedVectors: Bool {
        isLoaded && storage != nil
    }

    /// Releases vector storage from memory.
    public func release() {
        storage = nil
        rowChunkID = []
        rowDocumentID = []
        rowMTime = []
        rowSource = []
        rowModality = []
        isLoaded = false
        loadedDBPath = nil
        lastLoadedAt = nil
        loadedGeneration &+= 1
    }

    /// Invalidates cache so the next search reloads fresh vectors.
    public func invalidate() {
        isLoaded = false
        loadedGeneration &+= 1
    }

    /// Ensures vector storage is loaded from the SQLite database.
    public func ensureLoaded(dbPath: String) async throws {
        try Task.checkCancellation()
        let expanded = (dbPath as NSString).expandingTildeInPath
        if isLoaded, loadedDBPath == expanded {
            return
        }
        try await reload(dbPath: dbPath)
    }

    /// Reloads vectors from `indexed_chunks` in SQLite into contiguous Float16 storage.
    /// Blocking SQLite runs on the indexing lane; actor state mutates only after the hop.
    public func reload(dbPath: String) async throws {
        try Task.checkCancellation()
        release()
        let generationAtDispatch = loadedGeneration
        #if canImport(SQLite3)
            let expanded = (dbPath as NSString).expandingTildeInPath
            let staged: [StagedVectorRow]
            do {
                let path = expanded
                staged = try await SQLiteSerialIO.run(lane: .indexing) {
                    try Self.loadStagedRowsBlocking(dbPath: path)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Transient I/O leaves cache unloaded so the next search retries.
                return
            }
            try Task.checkCancellation()
            // Invalidation during the off-actor load makes staged rows stale; drop them.
            guard generationAtDispatch == loadedGeneration else {
                return
            }
            // Zero rows cache as empty so later searches skip the COUNT pass.
            guard !staged.isEmpty else {
                markLoadedEmpty(expanded: expanded)
                return
            }
            // Allocation failure retries next time instead of caching empty.
            guard let newStorage = VectorStorage(rows: staged.count) else {
                return
            }
            rowChunkID.reserveCapacity(staged.count)
            rowDocumentID.reserveCapacity(staged.count)
            rowMTime.reserveCapacity(staged.count)
            rowSource.reserveCapacity(staged.count)
            rowModality.reserveCapacity(staged.count)
            var row = 0
            for stagedRow in staged {
                // Cooperative cancel keeps a large decode from pinning the actor.
                try Task.checkCancellation()
                guard decodeVectorRow(blob: stagedRow.blob, into: newStorage, row: row) else {
                    continue
                }
                rowChunkID.append(stagedRow.chunkID)
                rowDocumentID.append(stagedRow.documentID)
                rowMTime.append(stagedRow.mtime)
                rowSource.append(stagedRow.source)
                rowModality.append(stagedRow.modality)
                row += 1
            }
            // Every blob malformed means an empty matrix, not a scored one.
            guard row > 0 else {
                markLoadedEmpty(expanded: expanded)
                return
            }
            storage = newStorage
            markLoadedEmpty(expanded: expanded)
        #else
            throw DocIndexError.storeUnavailable("SQLite3 is unavailable on this platform")
        #endif
    }

    /// Marks the index loaded-but-empty so recall fails closed without retry storms.
    private func markLoadedEmpty(expanded: String) {
        isLoaded = true
        loadedDBPath = expanded
        lastLoadedAt = Date()
        loadedGeneration &+= 1
    }

    #if canImport(SQLite3)
        /// Collects vector rows off the actor; malformed and orphan rows are skipped here.
        private static func loadStagedRowsBlocking(dbPath: String) throws -> [StagedVectorRow] {
            try Task.checkCancellation()
            let expanded = (dbPath as NSString).expandingTildeInPath
            // Missing database reads as an empty matrix so recall fails closed.
            guard FileManager.default.fileExists(atPath: expanded) else {
                return []
            }
            let handle: OpaquePointer?
            do {
                handle = try SQLiteDocIndexStore.open(dbPath: dbPath)
            } catch {
                return []
            }
            guard let handle else {
                return []
            }
            defer { sqlite3_close(handle) }
            let dim = AcceleratedVectorMath.dimension
            let expectedBytes = dim * MemoryLayout<Float>.stride
            var staged: [StagedVectorRow] = []
            let countSQL = "SELECT COUNT(*) FROM indexed_chunks WHERE is_vector = 1 AND embedding IS NOT NULL;"
            var countStmt: OpaquePointer?
            var totalVectors = 0
            if sqlite3_prepare_v2(handle, countSQL, -1, &countStmt, nil) == SQLITE_OK {
                if sqlite3_step(countStmt) == SQLITE_ROW {
                    totalVectors = Int(sqlite3_column_int(countStmt, 0))
                }
                sqlite3_finalize(countStmt)
            }
            guard totalVectors > 0 else {
                return []
            }
            staged.reserveCapacity(totalVectors)
            let sql = """
            SELECT c.id, c.document_id, d.mtime, d.source, c.embedding, d.mime
            FROM indexed_chunks c
            LEFT JOIN indexed_documents d ON d.id = c.document_id
            WHERE c.is_vector = 1 AND c.embedding IS NOT NULL
            ORDER BY c.rowid ASC;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                return []
            }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let chunkIDStr = SQLiteHelpers.columnText(statement, index: 0),
                      let chunkID = UUID(uuidString: chunkIDStr),
                      let docIDStr = SQLiteHelpers.columnText(statement, index: 1),
                      let docID = UUID(uuidString: docIDStr),
                      let blobPtr = sqlite3_column_blob(statement, 4)
                else {
                    continue
                }
                let blobBytes = Int(sqlite3_column_bytes(statement, 4))
                guard blobBytes == expectedBytes else { continue }
                let mtime: Double? = sqlite3_column_type(statement, 2) != SQLITE_NULL ? sqlite3_column_double(statement, 2) : nil
                // Orphan chunks (LEFT JOIN missed) carry NULL source; skipping preserves attribution.
                guard let sourceStr = SQLiteHelpers.columnText(statement, index: 3),
                      let source = IndexSource(rawValue: sourceStr)
                else {
                    continue
                }
                let mime = SQLiteHelpers.columnText(statement, index: 5)?.lowercased() ?? ""
                let modality: VectorModality = if mime.hasPrefix("image/") {
                    .image
                } else if mime.hasPrefix("audio/") {
                    .audio
                } else {
                    .text
                }
                let copied = Data(bytes: blobPtr, count: blobBytes)
                staged.append(StagedVectorRow(
                    chunkID: chunkID,
                    documentID: docID,
                    mtime: mtime,
                    source: source,
                    modality: modality,
                    blob: copied
                ))
            }
            return staged
        }

        /// Normalizes one blob into the matrix; false skips zero/non-finite norms.
        private func decodeVectorRow(
            blob: Data,
            into newStorage: VectorStorage,
            row: Int
        ) -> Bool {
            let dim = AcceleratedVectorMath.dimension
            let floatWidth = MemoryLayout<Float>.size
            guard blob.count == dim * floatWidth else {
                return false
            }
            return blob.withUnsafeBytes { rawBuf -> Bool in
                guard let base = rawBuf.baseAddress else {
                    return false
                }
                let raw = UnsafeRawBufferPointer(start: base, count: blob.count)
                // Unit-normalize rows so the dot product equals cosine similarity.
                var normSq: Double = 0
                for index in 0 ..< dim {
                    let bits = raw.loadUnaligned(fromByteOffset: index * floatWidth, as: UInt32.self)
                    let value = Double(Float(bitPattern: UInt32(littleEndian: bits)))
                    normSq += value * value
                }
                let norm = normSq.squareRoot()
                // Zero/non-finite norms carry no direction; skipping keeps cosine valid.
                guard norm > 0, norm.isFinite else {
                    return false
                }
                let scale = 1.0 / norm
                // Unaligned little-endian copy: SQLite blob alignment is not guaranteed.
                do {
                    try newStorage.withMutableHalvesRow(row: row) { destHalves in
                        for index in 0 ..< dim {
                            let bits = raw.loadUnaligned(fromByteOffset: index * floatWidth, as: UInt32.self)
                            let value = Float(bitPattern: UInt32(littleEndian: bits))
                            destHalves[index] = Float16(Float(Double(value) * scale))
                        }
                    }
                } catch {
                    return false
                }
                return true
            }
        }
    #endif

    public struct ScoredVectorHit: Sendable {
        public let chunkID: UUID
        public let documentID: UUID
        public let cosine: Double
        public let zScore: Double
        public let mtime: Double?
        public let source: IndexSource
        public let modality: VectorModality
    }

    /// Evaluates `queryVector` against all loaded vectors using `vDSP_mmul`, computes Z-scores,
    /// and returns hits with Z >= zGate. Both sides are unit-normalized so dots equal cosines.
    public func search(
        queryVector: [Float],
        zGate: Double = AcceleratedVectorMath.defaultZGate,
        limit: Int = AcceleratedVectorIndex.defaultSearchLimit,
        since: Date? = nil,
        until: Date? = nil
    ) throws -> [ScoredVectorHit] {
        let effectiveLimit = max(0, min(limit, DocIndexStore.maxVectorWindowResults))
        guard effectiveLimit > 0,
              let storage, isLoaded,
              queryVector.count == AcceleratedVectorMath.dimension,
              !rowChunkID.isEmpty,
              let normalizedQuery = AcceleratedVectorMath.normalized(queryVector)
        else {
            return []
        }
        let total = rowChunkID.count
        var rawScores = [Float](repeating: 0, count: total)

        do {
            try normalizedQuery.withUnsafeBufferPointer { queryBuf in
                try rawScores.withUnsafeMutableBufferPointer { scoresBuf in
                    guard let queryAddr = queryBuf.baseAddress, let scoresAddr = scoresBuf.baseAddress else { return }
                    var row = 0
                    while row < total {
                        // Cooperative cancel keeps a large scan from pinning the actor.
                        try Task.checkCancellation()
                        let count = min(VectorStorage.blockRows, total - row)
                        try storage.withBlockBuffers(row: row, count: count) { halvesBase, blockBase in
                            AcceleratedVectorMath.floats(
                                fromHalf: halvesBase,
                                count: count * AcceleratedVectorMath.dimension,
                                to: blockBase
                            )
                            AcceleratedVectorMath.scores(
                                of: blockBase,
                                count: count,
                                query: queryAddr,
                                into: scoresAddr + row
                            )
                        }
                        row += count
                    }
                }
            }
        } catch let error as CancellationError {
            throw error
        } catch {
            return []
        }
        try Task.checkCancellation()

        let zScores = AcceleratedVectorMath.modalityCenteredMeaningScores(rawScores, modalities: rowModality)
        var qualifying: [CandidateMatch] = []
        qualifying.reserveCapacity(min(effectiveLimit * 2, total))

        let sinceSec = since?.timeIntervalSince1970
        let untilSec = until?.timeIntervalSince1970
        let isBounded = sinceSec != nil || untilSec != nil

        for row in 0 ..< total {
            try Task.checkCancellation()
            let zScore = zScores[row]
            if zScore >= zGate {
                // Bounded recall gates calendar items to future event bounds, while
                // past documents/mail discussing future events remain recallable.
                if isBounded {
                    if rowSource[row] == .calendars {
                        guard let mtime = rowMTime[row] else { continue }
                        if let sinceSec, mtime < sinceSec {
                            continue
                        }
                        if let untilSec, mtime >= untilSec {
                            continue
                        }
                    } else if let untilSec, let mtime = rowMTime[row], mtime >= untilSec {
                        continue
                    }
                }
                // Clamp keeps float drift inside the valid cosine range.
                let cosine = min(max(Double(rawScores[row]), -1.0), 1.0)
                qualifying.append(CandidateMatch(index: row, cosine: cosine, zScore: zScore))
            }
        }

        qualifying.sort { $0.zScore > $1.zScore }

        var results: [ScoredVectorHit] = []
        results.reserveCapacity(min(qualifying.count, effectiveLimit))

        for item in qualifying.prefix(effectiveLimit) {
            let idx = item.index
            results.append(ScoredVectorHit(
                chunkID: rowChunkID[idx],
                documentID: rowDocumentID[idx],
                cosine: item.cosine,
                zScore: item.zScore,
                mtime: rowMTime[idx],
                source: rowSource[idx],
                modality: rowModality[idx]
            ))
        }

        return results
    }
}

private struct CandidateMatch {
    let index: Int
    let cosine: Double
    let zScore: Double
}
