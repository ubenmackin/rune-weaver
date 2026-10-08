// Rune Weaver Core — SQLite-backed durable store for learned recipient aliases.
//
// Purpose: remember the name-to-handle mappings the owner confirms through
// Messages sends, so a later "Rebecca" resolves to the handle she was actually
// messaged at instead of re-deriving it from the address book every time. The
// table lives in the shared `episodes.db` beside sessions, goals, and run logs.
//
// Scope: upsert-and-read only. The send flow calls `recordAlias` after a
// confirmed resolved-name send, the resolver calls `aliases` while ranking
// candidates, and nothing here deletes or rewrites a row beyond the
// use-count/timestamp upsert. Blocking SQLite work runs off the actor executor
// through the shared serial store queue, and the additive table migration runs
// on every open, so an existing conversations database is never disturbed.
//
// Architectural role: the production `MessageAliasStoring` implementation the
// recipient-resolution surface reads and the Messages send tool learns from,
// keeping learned mappings durable across process restarts.
//
// Contract: both actor methods are non-throwing. An unreadable store answers
// "no aliases known" rather than failing a resolution, and a failed write is
// swallowed because alias learning must never turn a completed send into a
// reported error. No names or handles are ever logged from this file.

import Foundation

#if canImport(SQLite3)
    import SQLite3
#endif

/// Actor-isolated SQLite store for the recipient aliases the send flow learns.
public actor RecipientAliasStore: MessageAliasStoring {
    /// Filesystem path of the shared SQLite database.
    ///
    /// Held `nonisolated` so paired stores over the same file can be built
    /// synchronously without an actor hop for an immutable path; the value
    /// never mutates after initialization, so no isolation protects it.
    public nonisolated let dbPath: String

    /// Creates a store over the shared database file.
    /// - Parameter dbPath: SQLite file path (the same `episodes.db` used by sessions and run logs).
    public init(dbPath: String = MemoryConfig.defaultEpisodesDBPath) {
        self.dbPath = dbPath
    }

    /// Returns stored alias candidates for a normalized name key.
    ///
    /// An unreadable store degrades to "no aliases known" so a resolution
    /// never fails because the alias table is missing, locked, or unopenable.
    /// - Parameters:
    ///   - nameKey: Normalized name (see ``MessageRecipientNameNormalizer/normalize(_:)``).
    ///   - limit: Maximum candidates requested.
    /// - Returns: Alias candidates, or an empty array when none are stored.
    public func aliases(nameKey: String, limit: Int) async -> [MessageRecipientCandidate] {
        let dbPath = self.dbPath
        do {
            return try await SQLiteSerialIO.run {
                try SQLiteRecipientAliasStore.aliases(nameKey: nameKey, limit: limit, dbPath: dbPath)
            }
        } catch is CancellationError {
            return []
        } catch {
            RuneWeaverLog.stores.error("RecipientAliasStore: failed to read aliases: \(error.localizedDescription)")
            return []
        }
    }

    /// Records one name-to-handle alias after a send.
    ///
    /// The normalized key is what a later name lookup reads, so blank names
    /// (nothing alphanumeric remains) and blank handles teach nothing and are
    /// dropped before any disk access. A write failure is swallowed because
    /// the caller has already completed the send it is reporting on.
    /// - Parameters:
    ///   - name: Raw name the owner typed.
    ///   - handle: Canonical handle the message was sent to.
    ///   - service: Messaging service label, when known.
    ///   - displayName: Friendly name to show on later resolutions.
    public func recordAlias(name: String, handle: String, service: String?, displayName: String?) async {
        let nameKey = MessageRecipientNameNormalizer.normalize(name)
        let trimmedHandle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nameKey.isEmpty, !trimmedHandle.isEmpty else { return }
        let dbPath = self.dbPath
        do {
            _ = try await SQLiteSerialIO.run {
                try SQLiteRecipientAliasStore.recordAlias(
                    nameKey: nameKey,
                    handle: trimmedHandle,
                    service: service,
                    displayName: displayName,
                    dbPath: dbPath
                )
            }
        } catch is CancellationError {
            return
        } catch {
            RuneWeaverLog.stores.error("RecipientAliasStore: failed to record alias: \(error.localizedDescription)")
        }
    }
}

// MARK: - SQLite Helpers

/// Internal failures raised by the alias store's SQLite helpers.
///
/// The public actor never throws, so this stays file-private: open, migration,
/// and statement failures are mapped to the reader's empty result or the
/// writer's no-op at the actor boundary.
private struct RecipientAliasStoreDBError: Error {
    let message: String
}

/// Blocking SQLite implementation behind ``RecipientAliasStore``.
private enum SQLiteRecipientAliasStore {
    /// Opens (creating parent directories) and migrates the database.
    ///
    /// The table is created additively on every open, so a shared
    /// `episodes.db` written by older binaries gains the alias table without
    /// disturbing existing rows, and concurrent opens race on `IF NOT EXISTS`
    /// rather than on an `ALTER`.
    /// - Parameter dbPath: SQLite file path. `~` is expanded.
    /// - Returns: Open database handle. Caller must close it.
    static func open(dbPath: String) throws -> OpaquePointer? {
        #if canImport(SQLite3)
            let handle = try SQLiteHelpers.openHandle(
                dbPath: dbPath,
                unavailable: { RecipientAliasStoreDBError(message: $0) }
            )
            do {
                try SQLiteHelpers.exec(
                    handle: handle,
                    sql: """
                    CREATE TABLE IF NOT EXISTS recipient_aliases(
                        name_key TEXT NOT NULL,
                        handle TEXT NOT NULL,
                        service TEXT,
                        display_name TEXT,
                        use_count INTEGER NOT NULL DEFAULT 0,
                        last_used_at REAL NOT NULL,
                        PRIMARY KEY(name_key, handle)
                    );
                    """,
                    failure: { RecipientAliasStoreDBError(message: $0) }
                )
                return handle
            } catch {
                sqlite3_close(handle)
                throw error
            }
        #else
            throw RecipientAliasStoreDBError(message: "SQLite unavailable")
        #endif
    }

    /// Reads the aliases stored under one normalized name key.
    ///
    /// Most-confirmed first, then most-recent: a mapping the owner kept using
    /// outranks one that only appeared once. Every returned candidate carries
    /// the alias source with no history date or contact link, because those
    /// are surfaces the resolver enriches from their own live reads.
    /// - Parameters:
    ///   - nameKey: Normalized name key the table is keyed by.
    ///   - limit: Maximum rows requested; clamped to the SQLite bind range.
    ///   - dbPath: SQLite file path. `~` is expanded.
    /// - Returns: Candidate snapshots, or an empty array when nothing matches.
    static func aliases(nameKey: String, limit: Int, dbPath: String) throws -> [MessageRecipientCandidate] {
        #if canImport(SQLite3)
            let handle = try open(dbPath: dbPath)
            defer { sqlite3_close(handle) }
            let sql = "SELECT handle, service, display_name FROM recipient_aliases "
                + "WHERE name_key = ? ORDER BY use_count DESC, last_used_at DESC LIMIT ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw RecipientAliasStoreDBError(message: "Could not prepare alias read")
            }
            defer { sqlite3_finalize(statement) }
            SQLiteHelpers.bindText(statement, index: 1, value: nameKey)
            sqlite3_bind_int(statement, 2, SQLiteHelpers.sqliteLimit(limit))
            var candidates: [MessageRecipientCandidate] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let handleText = SQLiteHelpers.columnText(statement, index: 0) else { continue }
                candidates.append(MessageRecipientCandidate(
                    displayName: SQLiteHelpers.columnText(statement, index: 2),
                    handle: handleText,
                    service: SQLiteHelpers.columnText(statement, index: 1),
                    lastMessageAt: nil,
                    source: .alias,
                    contactID: nil
                ))
            }
            return candidates
        #else
            return []
        #endif
    }

    /// Upserts one learned alias, counting repeated confirmations of the pair.
    ///
    /// The conflict update only ever fills blanks: `COALESCE` keeps a stored
    /// service or display name when the new record carries nil, so a later
    /// handle-only confirmation cannot erase the friendlier row. The count and
    /// timestamp advance every time, so repeated sends strengthen the mapping.
    /// - Parameters:
    ///   - nameKey: Normalized name key the row is keyed by.
    ///   - handle: Canonical handle the send confirmed.
    ///   - service: Messaging service label, when known.
    ///   - displayName: Friendly name, when known.
    ///   - dbPath: SQLite file path. `~` is expanded.
    static func recordAlias(
        nameKey: String,
        handle: String,
        service: String?,
        displayName: String?,
        dbPath: String
    ) throws {
        #if canImport(SQLite3)
            let dbHandle = try open(dbPath: dbPath)
            defer { sqlite3_close(dbHandle) }
            let sql = "INSERT INTO recipient_aliases(name_key, handle, service, display_name, use_count, last_used_at) "
                + "VALUES(?, ?, ?, ?, 1, ?) "
                + "ON CONFLICT(name_key, handle) DO UPDATE SET "
                + "use_count = use_count + 1, "
                + "last_used_at = excluded.last_used_at, "
                + "service = COALESCE(excluded.service, service), "
                + "display_name = COALESCE(excluded.display_name, display_name);"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(dbHandle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw RecipientAliasStoreDBError(message: "Could not prepare alias write")
            }
            defer { sqlite3_finalize(statement) }
            SQLiteHelpers.bindText(statement, index: 1, value: nameKey)
            SQLiteHelpers.bindText(statement, index: 2, value: handle)
            SQLiteHelpers.bindText(statement, index: 3, value: service)
            SQLiteHelpers.bindText(statement, index: 4, value: displayName)
            sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw RecipientAliasStoreDBError(message: "Could not record alias")
            }
        #endif
    }
}
