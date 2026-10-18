// Rune Weaver Core — SQLite persistence for staged files and live-write review state.

import Foundation
#if canImport(SQLite3)
    import SQLite3
#endif

/// Record of an edited file waiting in staging review.
public struct StagedFileRecord: Sendable, Equatable {
    public let path: String
    public let stagingPath: String
    public let updatedAt: Date

    public init(path: String, stagingPath: String, updatedAt: Date = Date()) {
        self.path = path
        self.stagingPath = stagingPath
        self.updatedAt = updatedAt
    }
}

/// Durable review resolution for one file path. Terminal states persist so a reloaded dashboard can
/// still answer how a review ended; only `pending` — a row whose `resolution` column is NULL —
/// belongs to the review inbox.
public enum FileReviewState: String, Sendable, Codable, Equatable, CaseIterable {
    case pending
    case accepted
    case discarded
    case superseded
    case reverted
}

/// Record of a live write awaiting review, backed by its rollback copy. A nil `resolution` means
/// the review is still pending; `resolvedAt` is only populated once the row reaches a terminal
/// state.
public struct LiveReviewRecord: Sendable, Equatable {
    public let path: String
    public let backupPath: String?
    public let createdAt: Date
    public let resolution: FileReviewState?
    public let resolvedAt: Date?

    public init(
        path: String,
        backupPath: String?,
        createdAt: Date,
        resolution: FileReviewState?,
        resolvedAt: Date?
    ) {
        self.path = path
        self.backupPath = backupPath
        self.createdAt = createdAt
        self.resolution = resolution
        self.resolvedAt = resolvedAt
    }
}

/// Result of the rollback snapshot a fresh live review runs inside the
/// store's start critical section.
public enum LiveReviewSnapshot: Sendable, Equatable {
    /// The live file did not exist, so the review owns no rollback copy.
    case noCopy
    /// The rollback copy was captured at this path.
    case captured(backupPath: String)
    /// The snapshot was refused or failed; `reason` is the complete
    /// caller-facing refusal sentence.
    case refused(reason: String)
}

/// Outcome of an atomic live-review start attempt.
public enum LiveReviewStart: Sendable, Equatable {
    /// This call started the fresh series; the associated path is the recorded
    /// rollback copy, nil when the series owns no copy (a newly created file).
    case started(backupPath: String?)
    /// A peer's pending review already owned the path; the associated path is
    /// its recorded rollback copy, which this call left untouched.
    case joined(backupPath: String?)
    /// The ledger could not be read or the fresh row could not be recorded; the caller must fail
    /// the write closed.
    case unreadable
    /// The snapshot refused or failed; `reason` is the caller-facing sentence.
    case refused(reason: String)
    /// The caller's live write failed inside the critical section; `reason` is
    /// the underlying error description. The review claim (and any captured
    /// copy) remains, mirroring a write that failed just after a snapshot.
    case writeFailed(reason: String)
}

/// Actor managing staged file metadata in SQLite.
public actor StagedFilesStore {
    private let dbPath: String

    /// Creates a staged files store pointing to a SQLite database.
    /// - Parameter dbPath: SQLite database file path (e.g. `episodes.db`).
    public init(dbPath: String = (MemoryConfig.defaultEpisodesDBPath as NSString).expandingTildeInPath) {
        self.dbPath = dbPath
    }

    /// Records or updates a staged file in SQLite.
    public func recordStaged(path: String, stagingPath: String, updatedAt: Date = Date()) async {
        let record = StagedFileRecord(path: path, stagingPath: stagingPath, updatedAt: updatedAt)
        await SQLiteSerialIO.runUncancellable {
            SQLiteStagedFilesStore.upsert(record: record, dbPath: self.dbPath)
        }
    }

    /// Marks a pending staged row as reviewed. The terminal state is durable: replayed actions and
    /// racing resolutions only ever transition NULL -> terminal, never overwrite an answer.
    @discardableResult
    public func resolveStaged(pathOrStagingPath: String, resolution: FileReviewState, at date: Date = Date()) async -> Bool {
        let trimmed = pathOrStagingPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, resolution != .pending else { return false }
        return await SQLiteSerialIO.runUncancellable {
            SQLiteStagedFilesStore.resolve(pathOrStagingPath: trimmed, resolution: resolution, at: date, dbPath: self.dbPath)
        }
    }

    /// Returns the durable review state for an exact live path.
    /// - Returns: nil when no row exists, `.pending` while the row is
    ///   unresolved, otherwise the stored terminal state.
    public func state(forPath path: String) async -> FileReviewState? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return await SQLiteSerialIO.runUncancellable {
            SQLiteStagedFilesStore.state(forPath: trimmed, table: .staged, dbPath: self.dbPath)
        }
    }

    /// Returns durable review states for the known subset of `paths`.
    public func states(forPaths paths: [String]) async throws -> [String: FileReviewState] {
        let trimmed = paths.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !trimmed.isEmpty else { return [:] }
        return try await SQLiteSerialIO.run {
            try SQLiteStagedFilesStore.states(forPaths: trimmed, table: .staged, dbPath: self.dbPath)
        }
    }

    /// Clears all staged file records.
    public func clearAll() async {
        await SQLiteSerialIO.runUncancellable {
            SQLiteStagedFilesStore.deleteAll(dbPath: self.dbPath)
        }
    }

    /// Lists pending staged file records, optionally filtered by root directory prefix.
    public func list(under rootPath: String? = nil) async -> [StagedFileRecord] {
        let rawRecords = await SQLiteSerialIO.runUncancellable {
            SQLiteStagedFilesStore.read(dbPath: self.dbPath)
        }

        var valid: [StagedFileRecord] = []
        var stalePaths: [String] = []

        let prefix: String?
        let normalizedRoot: String?
        if let rootPath, !rootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let normalized = URL(fileURLWithPath: rootPath).standardized.path
            normalizedRoot = normalized
            prefix = normalized.hasSuffix("/") ? normalized : normalized + "/"
        } else {
            normalizedRoot = nil
            prefix = nil
        }

        for record in rawRecords {
            // Check disk existence: if staging file no longer exists, prune it
            guard FileManager.default.fileExists(atPath: record.stagingPath) else {
                stalePaths.append(record.path)
                continue
            }

            if let prefix, let normalizedRoot {
                let standardPath = URL(fileURLWithPath: record.path).standardized.path
                if standardPath == normalizedRoot || standardPath.hasPrefix(prefix) {
                    valid.append(record)
                }
            } else {
                valid.append(record)
            }
        }

        if !stalePaths.isEmpty {
            let pathsToDelete = stalePaths
            let databasePath = self.dbPath
            await SQLiteSerialIO.runUncancellable {
                SQLiteStagedFilesStore.deleteBatch(paths: pathsToDelete, dbPath: databasePath)
            }
        }

        return valid
    }

    // MARK: - Live review ledger

    /// Reads the live-write review row for an exact path.
    public func liveReview(forPath path: String) async throws -> LiveReviewRecord? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try await SQLiteSerialIO.run {
            try SQLiteStagedFilesStore.liveReview(forPath: trimmed, dbPath: self.dbPath)
        }
    }

    /// Atomically starts a fresh live review and applies the live write, or joins a peer's pending
    /// one. A refused or failed snapshot leaves no pending row, so the ledger never claims a copy
    /// that does not exist.
    public func startLiveReview(
        path: String,
        applyingWrite write: (@Sendable () throws -> Void)? = nil,
        snapshot: @Sendable @escaping (_ previousSeriesSettled: Bool) -> LiveReviewSnapshot
    ) async -> LiveReviewStart {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unreadable }
        return await SQLiteSerialIO.runUncancellable { [dbPath] in
            // Every ledger write runs on this serial lane, so a peer's start
            // cannot slip between the read below and the row write.
            let existing: LiveReviewRecord?
            do {
                existing = try SQLiteStagedFilesStore.liveReview(forPath: trimmed, dbPath: dbPath)
            } catch {
                return .unreadable
            }
            // A pending row owns its copy: joining must not re-clone the live file or touch the
            // recorded rollback point.
            if let existing, existing.resolution == nil {
                if let writeFailure = Self.applyLiveWrite(write) {
                    return writeFailure
                }
                return .joined(backupPath: existing.backupPath)
            }
            let backupPath: String?
            switch snapshot(existing != nil) {
            case .noCopy:
                backupPath = nil
            case let .captured(capturedPath):
                backupPath = capturedPath
            case let .refused(reason):
                return .refused(reason: reason)
            }
            // The snapshot precedes the row write so a failed clone never
            // leaves a pending review claiming a copy that never materialised.
            switch SQLiteStagedFilesStore.claimLiveReview(
                path: trimmed,
                backupPath: backupPath,
                at: Date(),
                dbPath: dbPath
            ) {
            case .inserted:
                if let writeFailure = Self.applyLiveWrite(write) {
                    return writeFailure
                }
                return .started(backupPath: backupPath)
            case .pendingExists:
                // Zero changes means the conflict gate skipped the write because a pending row
                // already owns the path — possibly one recorded by another process, since
                // `episodes.db` is shared while the serial lane is per-process.
                let winner: LiveReviewRecord
                do {
                    guard let found = try SQLiteStagedFilesStore.liveReview(forPath: trimmed, dbPath: dbPath),
                          found.resolution == nil
                    else {
                        return .unreadable
                    }
                    winner = found
                } catch {
                    RuneWeaverLog.stores.error("StagedFilesStore: liveReview failed for \(trimmed): \(error.localizedDescription)")
                    return .unreadable
                }
                if let writeFailure = Self.applyLiveWrite(write) {
                    return writeFailure
                }
                return .joined(backupPath: winner.backupPath)
            case .failed:
                // The row write itself failed.
                do {
                    if let existingRow = try SQLiteStagedFilesStore.liveReview(forPath: trimmed, dbPath: dbPath),
                       existingRow.resolution == nil
                    {
                        if let writeFailure = Self.applyLiveWrite(write) {
                            return writeFailure
                        }
                        return .joined(backupPath: existingRow.backupPath)
                    }
                } catch {
                    return .unreadable
                }
                // The re-read proves no row owns the copy this call captured,
                // so it is removed rather than orphaned.
                if let backupPath {
                    try? FileManager.default.removeItem(atPath: backupPath)
                }
                return .unreadable
            }
        }
    }

    /// Applies the caller's live write inside a start critical section.
    /// - Parameter write: Live write to run, or nil when the caller only claims the review.
    private static func applyLiveWrite(_ write: (@Sendable () throws -> Void)?) -> LiveReviewStart? {
        guard let write else { return nil }
        do {
            try write()
            return nil
        } catch {
            return .writeFailed(reason: error.localizedDescription)
        }
    }

    /// Atomically resolves a pending live review around its filesystem mutation.
    public func resolveLiveReviewAtomically(
        path: String,
        _ mutate: @Sendable @escaping (LiveReviewRecord) throws -> FileReviewState
    ) async throws -> FileReviewState? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try await SQLiteSerialIO.run { [dbPath] in
            guard let record = try SQLiteStagedFilesStore.liveReview(forPath: trimmed, dbPath: dbPath),
                  record.resolution == nil
            else {
                return nil
            }
            let resolution = try mutate(record)
            guard resolution == .accepted || resolution == .reverted || resolution == .discarded else {
                return nil
            }
            _ = SQLiteStagedFilesStore.resolveLiveReview(
                path: trimmed,
                resolution: resolution,
                at: Date(),
                dbPath: dbPath
            )
            return resolution
        }
    }

    /// Starts a fresh pending live review. A pending row owns its decision, so a second start is a
    /// no-op; only a terminal row is replaced by the new review.
    public func beginLiveReview(path: String, backupPath: String?, at date: Date = Date()) async -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return await SQLiteSerialIO.runUncancellable {
            SQLiteStagedFilesStore.beginLiveReview(path: trimmed, backupPath: backupPath, at: date, dbPath: self.dbPath)
        }
    }

    /// Resolves a pending live review to a terminal state. Only `accepted`, `reverted`, and
    /// `discarded` are valid live resolutions; pending -> terminal happens once and a replayed call
    /// is a no-op.
    public func resolveLiveReview(path: String, resolution: FileReviewState, at date: Date = Date()) async -> Bool {
        guard resolution == .accepted || resolution == .reverted || resolution == .discarded else { return false }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return await SQLiteSerialIO.runUncancellable {
            SQLiteStagedFilesStore.resolveLiveReview(path: trimmed, resolution: resolution, at: date, dbPath: self.dbPath)
        }
    }

    /// Best-effort live review state for hydration: nil when unknown or unreadable.
    public func liveState(forPath path: String) async -> FileReviewState? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return await SQLiteSerialIO.runUncancellable {
            SQLiteStagedFilesStore.state(forPath: trimmed, table: .live, dbPath: self.dbPath)
        }
    }

    /// Returns durable live review states for the known subset of `paths`. Throwing for the same
    /// reason as `states(forPaths:)`: a store failure must reach the caller as a failure, never as
    /// absent rows.
    public func liveStates(forPaths paths: [String]) async throws -> [String: FileReviewState] {
        let trimmed = paths.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !trimmed.isEmpty else { return [:] }
        return try await SQLiteSerialIO.run {
            try SQLiteStagedFilesStore.states(forPaths: trimmed, table: .live, dbPath: self.dbPath)
        }
    }
}

// MARK: - SQLite Helpers

private struct StagedFilesStoreDBError: Error {
    let message: String
}

/// The two review ledgers sharing the `resolution` read shape.
private enum ReviewLedgerTable: String {
    /// Staged-edit ledger written by `recordStaged`/`resolveStaged`.
    case staged = "staged_files"
    /// Live-write ledger written by the atomic review start/decision.
    case live = "live_reviews"
}

private enum SQLiteStagedFilesStore {
    static func open(dbPath: String) throws -> OpaquePointer? {
        #if canImport(SQLite3)
            let handle = try SQLiteHelpers.openHandle(dbPath: dbPath, unavailable: { StagedFilesStoreDBError(message: $0) })
            do {
                try SQLiteHelpers.exec(
                    handle: handle,
                    sql: """
                    CREATE TABLE IF NOT EXISTS staged_files(
                        path TEXT PRIMARY KEY,
                        staging_path TEXT NOT NULL,
                        updated_at REAL NOT NULL
                    );
                    CREATE INDEX IF NOT EXISTS idx_staged_files_updated_at ON staged_files(updated_at);
                    CREATE TABLE IF NOT EXISTS live_reviews(
                        path TEXT PRIMARY KEY,
                        backup_path TEXT,
                        created_at REAL NOT NULL,
                        resolution TEXT,
                        resolved_at REAL
                    );
                    """,
                    failure: { StagedFilesStoreDBError(message: $0) }
                )
                try migrateResolutionColumns(handle: handle)
                return handle
            } catch {
                sqlite3_close(handle)
                throw error
            }
        #else
            throw StagedFilesStoreDBError(message: "SQLite unavailable")
        #endif
    }

    /// Adds the review-resolution columns to databases created before the review ledger existed.
    private static func migrateResolutionColumns(handle: OpaquePointer?) throws {
        let existing = columnNames(handle: handle, pragma: "PRAGMA table_info(staged_files);")
        let pendingMigrations: [(column: String, sql: String)] = [
            ("resolution", "ALTER TABLE staged_files ADD COLUMN resolution TEXT;"),
            ("resolved_at", "ALTER TABLE staged_files ADD COLUMN resolved_at REAL;")
        ]
        for migration in pendingMigrations where !existing.contains(migration.column) {
            do {
                try SQLiteHelpers.exec(
                    handle: handle,
                    sql: migration.sql,
                    failure: { StagedFilesStoreDBError(message: $0) }
                )
            } catch {
                // Concurrent opens can race the probe onto the same `ALTER`;
                // only that duplicate-column case is safe to ignore.
                var engineDetail = ""
                if let message = sqlite3_errmsg(handle) {
                    engineDetail = String(cString: message)
                }
                let combined = (engineDetail + " " + String(describing: error)).lowercased()
                if combined.contains("duplicate column") {
                    continue
                }
                let code = sqlite3_errcode(handle)
                RuneWeaverLog.stores.warning(
                    "StagedFilesStore: migration failed for column '\(migration.column)' (code \(code)): \(error)"
                )
                throw error
            }
        }
    }

    /// Lists declared columns for a table, lowercased for case-tolerant probes.
    private static func columnNames(handle: OpaquePointer?, pragma: String) -> Set<String> {
        var names: Set<String> = []
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, pragma, -1, &statement, nil) == SQLITE_OK else {
            return names
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = SQLiteHelpers.columnText(statement, index: 1) {
                names.insert(name.lowercased())
            }
        }
        return names
    }

    static func read(dbPath: String) -> [StagedFileRecord] {
        #if canImport(SQLite3)
            let handle: OpaquePointer?
            do {
                handle = try open(dbPath: dbPath)
            } catch {
                RuneWeaverLog.stores.error("StagedFilesStore: could not open database at \(dbPath): \(error.localizedDescription)")
                return []
            }
            guard let handle else { return [] }
            defer { sqlite3_close(handle) }

            // The inbox is pending-only by design: resolved rows stay durable
            // but never surface, so the prune pass below can never delete them.
            let sql = """
            SELECT path, staging_path, updated_at
            FROM staged_files
            WHERE resolution IS NULL
            ORDER BY updated_at DESC, path ASC;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                return []
            }
            defer { sqlite3_finalize(statement) }

            var records: [StagedFileRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let path = SQLiteHelpers.columnText(statement, index: 0),
                      let stagingPath = SQLiteHelpers.columnText(statement, index: 1)
                else { continue }
                let updatedAt = Date(timeIntervalSince1970: SQLiteHelpers.columnDouble(statement, index: 2))
                records.append(StagedFileRecord(path: path, stagingPath: stagingPath, updatedAt: updatedAt))
            }
            return records
        #else
            return []
        #endif
    }

    static func upsert(record: StagedFileRecord, dbPath: String) {
        #if canImport(SQLite3)
            let handle: OpaquePointer?
            do {
                handle = try open(dbPath: dbPath)
            } catch {
                RuneWeaverLog.stores.error("StagedFilesStore: failed opening store at \(dbPath): \(error)")
                return
            }
            guard let handle else { return }
            defer { sqlite3_close(handle) }

            // The conflict update clears any prior resolution: a fresh staged
            // write is a new review, so its row must read pending again.
            let sql = """
            INSERT INTO staged_files(path, staging_path, updated_at)
            VALUES(?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET
                staging_path = excluded.staging_path,
                updated_at = excluded.updated_at,
                resolution = NULL,
                resolved_at = NULL;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }

            SQLiteHelpers.bindText(statement, index: 1, value: record.path)
            SQLiteHelpers.bindText(statement, index: 2, value: record.stagingPath)
            SQLiteHelpers.bindDouble(statement, index: 3, value: record.updatedAt.timeIntervalSince1970)

            _ = sqlite3_step(statement)
        #endif
    }

    /// Marks a pending row resolved; terminal states are never overwritten.
    /// - Returns: True when the update transitioned a pending row.
    static func resolve(pathOrStagingPath: String, resolution: FileReviewState, at date: Date, dbPath: String) -> Bool {
        #if canImport(SQLite3)
            let handle: OpaquePointer?
            do {
                handle = try open(dbPath: dbPath)
            } catch {
                RuneWeaverLog.stores.error("StagedFilesStore: failed opening store at \(dbPath): \(error)")
                return false
            }
            guard let handle else { return false }
            defer { sqlite3_close(handle) }

            let sql = """
            UPDATE staged_files
            SET resolution = ?, resolved_at = ?
            WHERE (path = ? OR staging_path = ?) AND resolution IS NULL;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(statement) }

            SQLiteHelpers.bindText(statement, index: 1, value: resolution.rawValue)
            SQLiteHelpers.bindDouble(statement, index: 2, value: date.timeIntervalSince1970)
            SQLiteHelpers.bindText(statement, index: 3, value: pathOrStagingPath)
            SQLiteHelpers.bindText(statement, index: 4, value: pathOrStagingPath)
            guard sqlite3_step(statement) == SQLITE_DONE else { return false }
            return sqlite3_changes(handle) > 0
        #else
            return false
        #endif
    }

    /// Best-effort single-row read from one review ledger: nil when no row exists, `.pending` when
    /// the row is unresolved, otherwise the stored terminal state.
    static func state(forPath path: String, table: ReviewLedgerTable, dbPath: String) -> FileReviewState? {
        #if canImport(SQLite3)
            let handle: OpaquePointer?
            do {
                handle = try open(dbPath: dbPath)
            } catch {
                RuneWeaverLog.stores.error("StagedFilesStore: could not open database at \(dbPath): \(error.localizedDescription)")
                return nil
            }
            guard let handle else { return nil }
            defer { sqlite3_close(handle) }
            do {
                return try state(forPath: path, table: table, handle: handle)
            } catch {
                RuneWeaverLog.stores.error("StagedFilesStore: failed reading state for path \(path): \(error.localizedDescription)")
                return nil
            }
        #else
            return nil
        #endif
    }

    /// Throwing batched read from one review ledger, shared by the staged and live tables so a fix
    /// to one read path cannot miss the other.
    static func states(forPaths paths: [String], table: ReviewLedgerTable, dbPath: String) throws -> [String: FileReviewState] {
        #if canImport(SQLite3)
            let handle = try open(dbPath: dbPath)
            guard let handle else {
                throw StagedFilesStoreDBError(message: "unexpected nil handle opening \(dbPath)")
            }
            defer { sqlite3_close(handle) }

            var states: [String: FileReviewState] = [:]
            for path in paths {
                if let state = try state(forPath: path, table: table, handle: handle) {
                    states[path] = state
                }
            }
            return states
        #else
            throw StagedFilesStoreDBError(message: "SQLite unavailable")
        #endif
    }

    /// Single-path probe shared by both ledger reads: nil means no row, `.pending` means the row
    /// exists with a NULL resolution.
    private static func state(forPath path: String, table: ReviewLedgerTable, handle: OpaquePointer?) throws -> FileReviewState? {
        let sql = "SELECT resolution FROM \(table.rawValue) WHERE path = ? LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StagedFilesStoreDBError(message: "could not prepare \(table.rawValue) state read")
        }
        defer { sqlite3_finalize(statement) }
        SQLiteHelpers.bindText(statement, index: 1, value: path)
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else {
            guard step == SQLITE_DONE else {
                throw StagedFilesStoreDBError(message: "could not read \(table.rawValue) state")
            }
            return nil
        }
        guard let raw = SQLiteHelpers.columnText(statement, index: 0) else { return .pending }
        return FileReviewState(rawValue: raw)
    }

    static func deleteBatch(paths: [String], dbPath: String) {
        #if canImport(SQLite3)
            guard !paths.isEmpty else { return }
            let handle: OpaquePointer?
            do {
                handle = try open(dbPath: dbPath)
            } catch {
                return
            }
            guard let handle else { return }
            defer { sqlite3_close(handle) }

            let sql = "DELETE FROM staged_files WHERE path = ? OR staging_path = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }

            for path in paths {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                SQLiteHelpers.bindText(statement, index: 1, value: path)
                SQLiteHelpers.bindText(statement, index: 2, value: path)
                _ = sqlite3_step(statement)
            }
        #endif
    }

    static func deleteAll(dbPath: String) {
        #if canImport(SQLite3)
            let handle: OpaquePointer?
            do {
                handle = try open(dbPath: dbPath)
            } catch {
                RuneWeaverLog.stores.error("StagedFilesStore: could not open database at \(dbPath): \(error.localizedDescription)")
                return
            }
            guard let handle else { return }
            defer { sqlite3_close(handle) }
            do {
                _ = try SQLiteHelpers.exec(handle: handle, sql: "DELETE FROM staged_files;", failure: { StagedFilesStoreDBError(message: $0) })
            } catch {
                RuneWeaverLog.stores.error("StagedFilesStore: failed to clear staged_files table: \(error.localizedDescription)")
            }
        #endif
    }
}

// MARK: - Live review SQLite helpers

extension SQLiteStagedFilesStore {
    /// Throwing read so the tool can distinguish "no row" from "store failed".
    fileprivate static func liveReview(forPath path: String, dbPath: String) throws -> LiveReviewRecord? {
        #if canImport(SQLite3)
            let handle = try open(dbPath: dbPath)
            guard let handle else {
                throw StagedFilesStoreDBError(message: "unexpected nil handle opening \(dbPath)")
            }
            defer { sqlite3_close(handle) }

            let sql = """
            SELECT path, backup_path, created_at, resolution, resolved_at
            FROM live_reviews
            WHERE path = ?
            LIMIT 1;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw StagedFilesStoreDBError(message: "could not prepare live review read")
            }
            defer { sqlite3_finalize(statement) }
            SQLiteHelpers.bindText(statement, index: 1, value: path)
            guard sqlite3_step(statement) == SQLITE_ROW, let recordPath = SQLiteHelpers.columnText(statement, index: 0) else { return nil }
            let backupPath = SQLiteHelpers.columnText(statement, index: 1)
            let createdAt = Date(timeIntervalSince1970: SQLiteHelpers.columnDouble(statement, index: 2))
            let resolution = SQLiteHelpers.columnText(statement, index: 3).flatMap { FileReviewState(rawValue: $0) }
            let resolvedAt: Date? = sqlite3_column_type(statement, 4) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: SQLiteHelpers.columnDouble(statement, index: 4))
            return LiveReviewRecord(
                path: recordPath,
                backupPath: backupPath,
                createdAt: createdAt,
                resolution: resolution,
                resolvedAt: resolvedAt
            )
        #else
            throw StagedFilesStoreDBError(message: "SQLite unavailable")
        #endif
    }

    /// Outcome of one pending-row claim attempt.
    fileprivate enum LiveReviewClaimOutcome: Equatable {
        /// This call wrote the pending row.
        case inserted
        /// A pending row already owned the path: the conflict gate skipped the
        /// write, so the row belongs to another process and the copy at the
        /// derived path must not be deleted.
        case pendingExists
        /// The row could not be written at all.
        case failed
    }

    /// Starts a fresh pending review only when no pending row owns the path.
    fileprivate static func beginLiveReview(path: String, backupPath: String?, at date: Date, dbPath: String) -> Bool {
        claimLiveReview(path: path, backupPath: backupPath, at: date, dbPath: dbPath) == .inserted
    }

    /// Attempts to write the pending review row, keeping "a pending row
    /// already owns the path" distinct from "the row write failed" so a
    /// cross-process loser never mistakes a winning row for an orphan copy.
    fileprivate static func claimLiveReview(path: String, backupPath: String?, at date: Date, dbPath: String) -> LiveReviewClaimOutcome {
        #if canImport(SQLite3)
            let handle: OpaquePointer?
            do {
                handle = try open(dbPath: dbPath)
            } catch {
                RuneWeaverLog.stores.error("StagedFilesStore: failed opening store at \(dbPath): \(error)")
                return .failed
            }
            guard let handle else { return .failed }
            defer { sqlite3_close(handle) }

            // The conflict update is gated on a terminal row: starting twice
            // is a no-op while a decision is still pending, while a fresh
            // live write after a decision replaces the settled row.
            let sql = """
            INSERT INTO live_reviews(path, backup_path, created_at, resolution, resolved_at)
            VALUES(?, ?, ?, NULL, NULL)
            ON CONFLICT(path) DO UPDATE SET
                backup_path = excluded.backup_path,
                created_at = excluded.created_at,
                resolution = NULL,
                resolved_at = NULL
            WHERE live_reviews.resolution IS NOT NULL;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return .failed }
            defer { sqlite3_finalize(statement) }

            SQLiteHelpers.bindText(statement, index: 1, value: path)
            SQLiteHelpers.bindText(statement, index: 2, value: backupPath)
            SQLiteHelpers.bindDouble(statement, index: 3, value: date.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else { return .failed }
            // A completed statement with zero changes is the conflict gate
            // skipping the update: the existing row is still pending.
            return sqlite3_changes(handle) > 0 ? .inserted : .pendingExists
        #else
            return .failed
        #endif
    }

    /// Transitions a pending review once; already-terminal rows are untouched.
    fileprivate static func resolveLiveReview(path: String, resolution: FileReviewState, at date: Date, dbPath: String) -> Bool {
        #if canImport(SQLite3)
            let handle: OpaquePointer?
            do {
                handle = try open(dbPath: dbPath)
            } catch {
                RuneWeaverLog.stores.error("StagedFilesStore: failed opening store at \(dbPath): \(error)")
                return false
            }
            guard let handle else { return false }
            defer { sqlite3_close(handle) }

            let sql = """
            UPDATE live_reviews
            SET resolution = ?, resolved_at = ?
            WHERE path = ? AND resolution IS NULL;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(statement) }

            SQLiteHelpers.bindText(statement, index: 1, value: resolution.rawValue)
            SQLiteHelpers.bindDouble(statement, index: 2, value: date.timeIntervalSince1970)
            SQLiteHelpers.bindText(statement, index: 3, value: path)
            guard sqlite3_step(statement) == SQLITE_DONE else { return false }
            return sqlite3_changes(handle) > 0
        #else
            return false
        #endif
    }
}
