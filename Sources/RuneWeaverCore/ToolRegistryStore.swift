// Rune Weaver Core — SQLite persistence for installed and discovered plugins.
//
// Maintains the durable registry of runes in `episodes.db` (`plugin_registry` table).
// Tracks discovery metadata, enabled/disabled states, cryptographic integrity hashes,
// and user permission overrides. Discovered plugins start disabled by default
// until explicitly enabled by a human in the loop.

import Foundation
#if canImport(SQLite3)
    import SQLite3
#endif

/// State of a plugin within Rune Weaver.
public enum PluginStatus: String, Sendable, Codable, CaseIterable {
    /// Newly discovered on disk, initially disabled awaiting human-in-the-loop review.
    case discovered
    /// Explicitly approved and enabled by the user; active on the live tool bus.
    case enabled
    /// Explicitly turned off by the user; preserved on disk but omitted from tool bus and prompt.
    case disabled
    /// Modified on disk since human approval; quarantined and disabled until re-verified.
    case tampered
}

/// Durable record of an installed or discovered plugin package.
public struct PluginRecord: Sendable, Codable, Equatable, Identifiable {
    /// Unique identifier matching `PluginManifest.id`.
    public let id: String
    /// Display name.
    public var name: String
    /// Semantic version string.
    public var version: String
    /// Origin of the plugin (`"builtin"`, `"local_disk"`, `"marketplace"`, `"agent_generated"`).
    public var source: String
    /// Current lifecycle state.
    public var status: PluginStatus
    /// Cryptographic SHA-256 tree hash recorded upon human enablement.
    public var integrityHash: String?
    /// User-specified permission overrides mapping tool name to level string.
    public var permissionOverrides: [String: String]
    /// Timestamp when first discovered.
    public var discoveredAt: Date
    /// Timestamp of most recent state modification.
    public var updatedAt: Date

    /// Creates a plugin record.
    public init(
        id: String,
        name: String,
        version: String,
        source: String = "local_disk",
        status: PluginStatus = .discovered,
        integrityHash: String? = nil,
        permissionOverrides: [String: String] = [:],
        discoveredAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.source = source
        self.status = status
        self.integrityHash = integrityHash
        self.permissionOverrides = permissionOverrides
        self.discoveredAt = discoveredAt
        self.updatedAt = updatedAt
    }

    /// Whether this plugin's tools are allowed to execute on the live bus.
    public var isEnabled: Bool {
        status == .enabled
    }
}

/// Actor managing the durable plugin registry in SQLite.
public actor ToolRegistryStore {
    private let dbPath: String
    private var cached: [String: PluginRecord] = [:]
    private var isLoaded = false

    /// Creates a plugin registry store pointing to a SQLite database.
    /// - Parameter dbPath: SQLite database file path (e.g. `episodes.db`).
    public init(dbPath: String) {
        self.dbPath = dbPath
    }

    /// Loads all plugin records from disk into memory, initializing tables if needed.
    /// - Parameter forceReload: If true, clears the in-memory cache and re-reads from SQLite.
    public func loadAll(forceReload: Bool = false) async -> [PluginRecord] {
        if isLoaded, !forceReload {
            return Array(cached.values).sorted { $0.id < $1.id }
        }
        if forceReload {
            cached.removeAll()
        }

        let loaded = await SQLiteSerialIO.runUncancellable {
            SQLitePluginRegistryStore.read(dbPath: self.dbPath)
        }

        for record in loaded {
            cached[record.id] = record
        }
        isLoaded = true
        return Array(cached.values).sorted { $0.id < $1.id }
    }

    /// Reloads all plugin records from SQLite, refreshing any external mutations (e.g. from CLI).
    public func reload() async -> [PluginRecord] {
        await loadAll(forceReload: true)
    }

    /// Retrieves a plugin record by identifier.
    public func get(id: String) async -> PluginRecord? {
        _ = await loadAll()
        return cached[id]
    }

    /// Records or updates a discovered plugin.
    ///
    /// If the plugin is already recorded, preserves its current status and
    /// permission overrides unless the version changed or it was tampered.
    /// New plugins always start as `.discovered` (disabled).
    public func recordDiscovered(
        id: String,
        name: String,
        version: String,
        source: String = "local_disk",
        currentHash: String?
    ) async -> PluginRecord {
        _ = await loadAll()

        if var existing = cached[id] {
            existing.name = name
            existing.version = version
            existing.updatedAt = Date()

            // A hash mismatch after approval quarantines the rune; the comparison
            // itself lives in the security helper so store and verifier share
            // one case-handling rule instead of drifting duplicates.
            // If hashing failed (currentHash == nil) or the hash mismatched,
            // fail closed and quarantine the plugin as tampered.
            if existing.status == .enabled, let recordedHash = existing.integrityHash {
                if let currentHash {
                    if !PluginSecurity.hashesEqual(recordedHash, currentHash) {
                        existing.status = .tampered
                    }
                } else {
                    existing.status = .tampered
                }
            }

            cached[id] = existing
            let toSave = existing
            await SQLiteSerialIO.runUncancellable {
                SQLitePluginRegistryStore.upsert(record: toSave, dbPath: self.dbPath)
            }
            return existing
        }

        let newRecord = PluginRecord(
            id: id,
            name: name,
            version: version,
            source: source,
            status: .discovered, // Disabled by default
            integrityHash: nil,
            permissionOverrides: [:],
            discoveredAt: Date(),
            updatedAt: Date()
        )

        cached[id] = newRecord
        await SQLiteSerialIO.runUncancellable {
            SQLitePluginRegistryStore.upsert(record: newRecord, dbPath: self.dbPath)
        }
        return newRecord
    }

    /// Sets the status of a plugin, recording the integrity hash when enabling.
    public func setStatus(
        id: String,
        status: PluginStatus,
        integrityHash: String? = nil
    ) async -> PluginRecord? {
        _ = await loadAll()
        guard var existing = cached[id] else { return nil }

        existing.status = status
        existing.updatedAt = Date()
        if let integrityHash {
            existing.integrityHash = integrityHash
        }

        cached[id] = existing
        let toSave = existing
        await SQLiteSerialIO.runUncancellable {
            SQLitePluginRegistryStore.upsert(record: toSave, dbPath: self.dbPath)
        }
        return existing
    }

    /// Sets or clears a permission override for a tool within a plugin.
    ///
    /// External runes can never escalate to `trusted`; the manifest parser
    /// already rejects that level at install time, and the store rejects it
    /// again here so a tampered database row cannot promote a community tool
    /// past human approval.
    public func setPermissionOverride(
        id: String,
        toolName: String,
        overrideLevel: PermissionLevel?
    ) async throws -> PluginRecord? {
        if let overrideLevel, overrideLevel == .trusted {
            throw PluginManifestError.trustedPermissionProhibited(
                tool: toolName,
                reason: "External plugins may not be overridden to 'trusted'. Only 'readOnly' and 'requiresApproval' are permitted."
            )
        }
        _ = await loadAll()
        guard var existing = cached[id] else { return nil }

        if let overrideLevel {
            existing.permissionOverrides[toolName] = overrideLevel.rawValue
        } else {
            existing.permissionOverrides.removeValue(forKey: toolName)
        }
        existing.updatedAt = Date()

        cached[id] = existing
        let toSave = existing
        await SQLiteSerialIO.runUncancellable {
            SQLitePluginRegistryStore.upsert(record: toSave, dbPath: self.dbPath)
        }
        return existing
    }

    /// Removes a plugin record from the registry.
    public func remove(id: String) async -> Bool {
        _ = await loadAll()
        guard cached.removeValue(forKey: id) != nil else { return false }

        await SQLiteSerialIO.runUncancellable {
            SQLitePluginRegistryStore.delete(id: id, dbPath: self.dbPath)
        }
        return true
    }
}

// MARK: - SQLite Helpers

private struct PluginRegistryStoreDBError: Error {
    let message: String
}

private enum SQLitePluginRegistryStore {
    static func open(dbPath: String) throws -> OpaquePointer? {
        let handle = try SQLiteHelpers.openHandle(dbPath: dbPath, unavailable: { PluginRegistryStoreDBError(message: $0) })
        try SQLiteHelpers.exec(
            handle: handle,
            sql: """
            CREATE TABLE IF NOT EXISTS plugin_registry(
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                version TEXT NOT NULL,
                source TEXT NOT NULL,
                status TEXT NOT NULL,
                integrity_hash TEXT,
                permission_overrides TEXT,
                discovered_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_plugin_registry_status ON plugin_registry(status);
            """,
            failure: { PluginRegistryStoreDBError(message: $0) }
        )
        return handle
    }

    static func read(dbPath: String) -> [PluginRecord] {
        guard let handle = try? open(dbPath: dbPath) else { return [] }
        defer { sqlite3_close(handle) }

        let sql = """
        SELECT id, name, version, source, status, integrity_hash, permission_overrides, discovered_at, updated_at
        FROM plugin_registry
        ORDER BY id ASC;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var records: [PluginRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = SQLiteHelpers.columnText(statement, index: 0),
                  let name = SQLiteHelpers.columnText(statement, index: 1),
                  let version = SQLiteHelpers.columnText(statement, index: 2),
                  let source = SQLiteHelpers.columnText(statement, index: 3),
                  let statusRaw = SQLiteHelpers.columnText(statement, index: 4),
                  let status = PluginStatus(rawValue: statusRaw)
            else { continue }

            let integrityHash = SQLiteHelpers.columnText(statement, index: 5)
            let overridesJSON = SQLiteHelpers.columnText(statement, index: 6) ?? "{}"
            let discoveredAt = Date(timeIntervalSince1970: SQLiteHelpers.columnDouble(statement, index: 7))
            let updatedAt = Date(timeIntervalSince1970: SQLiteHelpers.columnDouble(statement, index: 8))

            var overrides: [String: String] = [:]
            if let data = overridesJSON.data(using: .utf8),
               let dict = try? JSONDecoder().decode([String: String].self, from: data)
            {
                overrides = dict
            }

            records.append(PluginRecord(
                id: id,
                name: name,
                version: version,
                source: source,
                status: status,
                integrityHash: integrityHash,
                permissionOverrides: overrides,
                discoveredAt: discoveredAt,
                updatedAt: updatedAt
            ))
        }
        return records
    }

    static func upsert(record: PluginRecord, dbPath: String) {
        let handle: OpaquePointer?
        do {
            handle = try open(dbPath: dbPath)
        } catch {
            fputs("[ERROR] ToolRegistryStore: failed opening store at \(dbPath): \(error)\n", stderr)
            return
        }
        guard let handle else { return }
        defer { sqlite3_close(handle) }

        let sql = """
        INSERT INTO plugin_registry(id, name, version, source, status, integrity_hash, permission_overrides, discovered_at, updated_at)
        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            version = excluded.version,
            source = excluded.source,
            status = excluded.status,
            integrity_hash = excluded.integrity_hash,
            permission_overrides = excluded.permission_overrides,
            updated_at = excluded.updated_at;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        let overridesData = (try? JSONEncoder().encode(record.permissionOverrides)) ?? Data()
        let overridesStr = String(data: overridesData, encoding: .utf8) ?? "{}"

        SQLiteHelpers.bindText(statement, index: 1, value: record.id)
        SQLiteHelpers.bindText(statement, index: 2, value: record.name)
        SQLiteHelpers.bindText(statement, index: 3, value: record.version)
        SQLiteHelpers.bindText(statement, index: 4, value: record.source)
        SQLiteHelpers.bindText(statement, index: 5, value: record.status.rawValue)
        SQLiteHelpers.bindText(statement, index: 6, value: record.integrityHash)
        SQLiteHelpers.bindText(statement, index: 7, value: overridesStr)
        sqlite3_bind_double(statement, 8, record.discoveredAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 9, record.updatedAt.timeIntervalSince1970)

        _ = sqlite3_step(statement)
    }

    static func delete(id: String, dbPath: String) {
        let handle: OpaquePointer?
        do {
            handle = try open(dbPath: dbPath)
        } catch {
            fputs("[ERROR] ToolRegistryStore: failed opening store at \(dbPath): \(error)\n", stderr)
            return
        }
        guard let handle else { return }
        defer { sqlite3_close(handle) }

        let sql = "DELETE FROM plugin_registry WHERE id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        SQLiteHelpers.bindText(statement, index: 1, value: id)
        _ = sqlite3_step(statement)
    }
}
