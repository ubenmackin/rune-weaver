// Rune Weaver Core — Scoped and full reset for the document index.

import Foundation

extension DocIndexStore {
    /// Removes a sidecar file when present, logging failures without failing the reset.
    /// Only files inside the index directory or test scratch are removed; anything
    /// else fails closed so a miswired path cannot delete arbitrary files.
    private static func removeStateFileIfPresent(at path: String, label: String) {
        let expanded = (path as NSString).expandingTildeInPath
        guard isRemovableStatePath(expanded) else {
            RuneWeaverLog.stores.error("DocIndexStore: refusing to reset \(label) outside index directory")
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) else { return }
        guard !isDirectory.boolValue else {
            RuneWeaverLog.stores.error("DocIndexStore: refusing to reset \(label) directory")
            return
        }
        do {
            try FileManager.default.removeItem(atPath: expanded)
        } catch {
            RuneWeaverLog.stores.error("DocIndexStore: failed to reset \(label): \(error.localizedDescription)")
        }
    }

    /// Reports whether a sidecar path is safe to delete: a file inside the index
    /// directory or the test scratch directory, so production clears stay hermetic
    /// and route tests can still target isolated scratch files.
    private static func isRemovableStatePath(_ expanded: String) -> Bool {
        guard !expanded.isEmpty else { return false }
        let standardized = (expanded as NSString).standardizingPath
        let indexBase = (("~/.runeweaver/index" as NSString).expandingTildeInPath as NSString).standardizingPath
        let tempBaseA = (NSTemporaryDirectory() as NSString).standardizingPath
        let tempBaseB = (FileManager.default.temporaryDirectory.path as NSString).standardizingPath
        if standardized == indexBase || standardized == tempBaseA || standardized == tempBaseB {
            return false
        }
        if !indexBase.isEmpty, standardized.hasPrefix(indexBase + "/") {
            return true
        }
        // Test scratch lives under the temporary directory with isolated leaf files.
        if !tempBaseA.isEmpty, standardized.hasPrefix(tempBaseA + "/") {
            return true
        }
        if !tempBaseB.isEmpty, standardized.hasPrefix(tempBaseB + "/") {
            return true
        }
        return false
    }

    /// Clears every document, chunk, and search-index entry, plus the sidecars named by explicit
    /// paths. Calendar and reminder sidecars clear only when an explicit path is passed; a nil
    /// path skips that sidecar so the live default is never touched by omission.
    public func reset(
        mailCheckpointPath: String,
        messagesStatePath: String,
        calendarsStatePath: String? = nil,
        remindersStatePath: String? = nil
    ) async throws {
        let dbPath = self.dbPath
        try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.reset(dbPath: dbPath)
        }
        do {
            try MailIndexCheckpointStore.reset(path: mailCheckpointPath)
        } catch {
            RuneWeaverLog.stores.error("DocIndexStore: failed to reset MailIndexCheckpointStore: \(error.localizedDescription)")
        }
        do {
            try MessagesIndexer.resetWatermark(statePath: messagesStatePath)
        } catch {
            RuneWeaverLog.stores.error("DocIndexStore: failed to reset MessagesIndexer watermark: \(error.localizedDescription)")
        }
        // Full reset clears only explicitly named sidecars so no stale knownIDs survive to
        // drive wasted prune passes on the next run; absent files are a no-op and nil paths
        // skip that sidecar entirely instead of falling back to the live default.
        if let calendarsStatePath {
            Self.removeStateFileIfPresent(at: calendarsStatePath, label: "calendars state")
        }
        if let remindersStatePath {
            Self.removeStateFileIfPresent(at: remindersStatePath, label: "reminders state")
        }
        await invalidateStatusCache()
        // A full clear leaves no run to refresh the persisted rows, so persist
        // the emptied aggregates now. A failure keeps the previous row.
        await refreshAggregatesIgnoringFailure()
    }

    /// Clears documents and chunks for a specific source (e.g. `.mail`), preserving all other
    /// indexed sources. Each sidecar clears only when its explicit path is passed; a nil path
    /// skips that sidecar so omission never touches the live default.
    @discardableResult
    public func clearSource(
        _ source: IndexSource,
        mailCheckpointPath: String? = nil,
        messagesStatePath: String? = nil,
        calendarsStatePath: String? = nil,
        remindersStatePath: String? = nil
    ) async throws -> Int {
        let dbPath = self.dbPath
        let removed = try await SQLiteSerialIO.run(lane: .indexing) {
            try DocIndexStoreIO.clearSource(source: source.rawValue, dbPath: dbPath)
        }
        if source == .mail, let mailCheckpointPath {
            do {
                try MailIndexCheckpointStore.reset(path: mailCheckpointPath)
            } catch {
                RuneWeaverLog.stores.error("DocIndexStore: failed to reset MailIndexCheckpointStore: \(error.localizedDescription)")
            }
        }
        if source == .messages, let messagesStatePath {
            do {
                try MessagesIndexer.resetWatermark(statePath: messagesStatePath)
            } catch {
                RuneWeaverLog.stores.error("DocIndexStore: failed to reset MessagesIndexer watermark: \(error.localizedDescription)")
            }
        }
        if source == .calendars, let calendarsStatePath {
            Self.removeStateFileIfPresent(at: calendarsStatePath, label: "calendars state")
        }
        if source == .reminders, let remindersStatePath {
            Self.removeStateFileIfPresent(at: remindersStatePath, label: "reminders state")
        }
        await invalidateStatusCache()
        // A source clear changes the persisted counts with no run-end refresh to
        // follow, so persist fresh aggregates now. A failure keeps prior rows.
        await refreshAggregatesIgnoringFailure()
        return removed
    }

    /// Verifies that the store's embedded vectors match the active embedder's dimension.
    /// Calendar and reminder sidecars reset only when explicit paths are passed; nil skips
    /// them so a dimension reset from a source without those paths never touches live state.
    public func ensureEmbeddingDimensionMatch(
        activeModelID: String,
        activeDimension: Int,
        mailCheckpointPath: String,
        messagesStatePath: String,
        calendarsStatePath: String? = nil,
        remindersStatePath: String? = nil
    ) async throws -> Bool {
        let meta = try await readEmbeddingMeta()
        if let storedDimension = meta.dimension, storedDimension != activeDimension {
            RuneWeaverLog.stores.warning(
                "DocIndexStore: embedding dimension mismatch (stored: \(storedDimension), active: \(activeDimension)); triggering re-index reset."
            )
            try await reset(
                mailCheckpointPath: mailCheckpointPath,
                messagesStatePath: messagesStatePath,
                calendarsStatePath: calendarsStatePath,
                remindersStatePath: remindersStatePath
            )
            try await writeEmbeddingMeta(modelID: activeModelID, dimension: activeDimension)
            return true
        }
        if meta.dimension == nil {
            let stats = try await SQLiteSerialIO.run(lane: .indexing) {
                try DocIndexStoreIO.fastStats(dbPath: self.dbPath)
            }
            if stats.vectorChunks > 0 {
                RuneWeaverLog.stores.warning(
                    "DocIndexStore: unversioned vector chunks detected without dimension metadata; resetting to dimension \(activeDimension)."
                )
                try await reset(
                    mailCheckpointPath: mailCheckpointPath,
                    messagesStatePath: messagesStatePath,
                    calendarsStatePath: calendarsStatePath,
                    remindersStatePath: remindersStatePath
                )
                try await writeEmbeddingMeta(modelID: activeModelID, dimension: activeDimension)
                return true
            }
            try await writeEmbeddingMeta(modelID: activeModelID, dimension: activeDimension)
        }
        return false
    }
}
