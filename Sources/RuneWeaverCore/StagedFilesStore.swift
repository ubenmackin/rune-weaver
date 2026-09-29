// Rune Weaver Core — SQLite persistence for staged files metadata.
//
// Purpose: DB-backed staged inbox tracking live paths awaiting review.
// Scope: record/remove/list plus self-healing prune only; filesystem walking stays with callers.
// Architectural role: `StagedFilesStore` actor plus `SQLiteSerialIO` source of truth beside scheduler/runs, `episodes.db` `staged_files` table.

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

    /// Removes a staged file by its live path or staging path (used when accepted or discarded).
    public func removeStaged(pathOrStagingPath: String) async {
        let trimmed = pathOrStagingPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await SQLiteSerialIO.runUncancellable {
            SQLiteStagedFilesStore.delete(pathOrStagingPath: trimmed, dbPath: self.dbPath)
        }
    }

    /// Removes multiple staged files in a batch.
    public func removeStaged(paths: [String]) async {
        guard !paths.isEmpty else { return }
        await SQLiteSerialIO.runUncancellable {
            SQLiteStagedFilesStore.deleteBatch(paths: paths, dbPath: self.dbPath)
        }
    }

    /// Clears all staged file records.
    public func clearAll() async {
        await SQLiteSerialIO.runUncancellable {
            SQLiteStagedFilesStore.deleteAll(dbPath: self.dbPath)
        }
    }

    /// Lists staged file records, optionally filtered by root directory prefix.
    /// Prunes stale records whose staging files no longer exist on disk.
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
}

// MARK: - SQLite Helpers

private struct StagedFilesStoreDBError: Error {
    let message: String
}

private enum SQLiteStagedFilesStore {
    static func open(dbPath: String) throws -> OpaquePointer? {
        #if canImport(SQLite3)
            let handle = try SQLiteHelpers.openHandle(dbPath: dbPath, unavailable: { StagedFilesStoreDBError(message: $0) })
            try SQLiteHelpers.exec(
                handle: handle,
                sql: """
                CREATE TABLE IF NOT EXISTS staged_files(
                    path TEXT PRIMARY KEY,
                    staging_path TEXT NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_staged_files_updated_at ON staged_files(updated_at);
                """,
                failure: { StagedFilesStoreDBError(message: $0) }
            )
            return handle
        #else
            throw StagedFilesStoreDBError(message: "SQLite unavailable")
        #endif
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

            let sql = """
            SELECT path, staging_path, updated_at
            FROM staged_files
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

            let sql = """
            INSERT INTO staged_files(path, staging_path, updated_at)
            VALUES(?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET
                staging_path = excluded.staging_path,
                updated_at = excluded.updated_at;
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

    static func delete(pathOrStagingPath: String, dbPath: String) {
        deleteBatch(paths: [pathOrStagingPath], dbPath: dbPath)
    }

    static func deleteAll(dbPath: String) {
        #if canImport(SQLite3)
            let handle: OpaquePointer?
            do {
                handle = try open(dbPath: dbPath)
            } catch {
                return
            }
            guard let handle else { return }
            defer { sqlite3_close(handle) }
            _ = try? SQLiteHelpers.exec(handle: handle, sql: "DELETE FROM staged_files;", failure: { StagedFilesStoreDBError(message: $0) })
        #endif
    }
}
