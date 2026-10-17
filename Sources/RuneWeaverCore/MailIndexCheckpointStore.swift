// Rune Weaver Core — JSON-backed store for incremental mail indexing checkpoints.

import Foundation

// MARK: - Checkpoint store

/// JSON-backed store for per-mailbox UID watermarks, backfill floors, and seen content hashes.
public actor MailIndexCheckpointStore {
    /// Default checkpoint path, kept beside the other durable memory stores.
    public static let defaultPath = "~/.runeweaver/memory/mail-index-checkpoint.json"
    /// Upper bound on retained content hashes so the sidecar stays bounded.
    public static let maxTrackedHashes = 5000

    /// Filesystem path of the JSON checkpoint.
    public let path: String

    /// Whether the sidecar has been read into memory.
    private var loaded = false
    /// In-memory checkpoint snapshot.
    private var checkpoint = MailIndexCheckpoint()

    /// Creates a checkpoint store.
    /// - Parameter path: JSON sidecar path. `~` is expanded on first load.
    public init(path: String = MailIndexCheckpointStore.defaultPath) {
        self.path = path
    }

    /// Composes the mailbox key used for watermarks.
    public static func key(account: String, mailbox: String) -> String {
        mailboxKey(account: account, mailbox: mailbox)
    }

    /// Highest indexed UID for one mailbox. account: Account nickname.
    public func watermark(account: String, mailbox: String) -> Int {
        loadIfNeeded()
        return checkpoint.watermarks[Self.key(account: account, mailbox: mailbox)] ?? 0
    }

    /// Whether a content hash has already been indexed.
    /// - Parameter hash: Content hash under test.
    /// - Returns: True when the hash is already tracked.
    public func containsContentHash(_ hash: String) -> Bool {
        loadIfNeeded()
        return checkpoint.contentHashes.contains(hash)
    }

    /// Last observed validity token for one mailbox. account: Account nickname.
    public func uidValidity(account: String, mailbox: String) -> Int? {
        loadIfNeeded()
        return checkpoint.uidValidities[Self.key(account: account, mailbox: mailbox)]
    }

    /// Lowest indexed UID reached during backfill for one mailbox. account: Account
    /// nickname.
    public func backfillFloor(account: String, mailbox: String) -> Int? {
        loadIfNeeded()
        return checkpoint.backfillFloors[Self.key(account: account, mailbox: mailbox)]
    }

    /// Records the backfill floor for one mailbox, persisting immediately. Setting floor <= 1 or
    /// nil removes the floor, marking backfill complete.
    public func recordBackfillFloor(account: String, mailbox: String, floor: Int?) throws {
        loadIfNeeded()
        let mailboxKey = Self.key(account: account, mailbox: mailbox)
        if let floor, floor > 1 {
            checkpoint.backfillFloors[mailboxKey] = floor
        } else {
            checkpoint.backfillFloors.removeValue(forKey: mailboxKey)
        }
        try persist()
    }

    /// Reconciles the stored validity token, resetting the watermark on mismatch. A first
    /// observation only records without resetting.
    @discardableResult
    public func synchronizeValidity(account: String, mailbox: String, uidValidity: Int?) throws -> Bool {
        loadIfNeeded()
        guard let uidValidity else { return false }
        let mailboxKey = Self.key(account: account, mailbox: mailbox)
        if let stored = checkpoint.uidValidities[mailboxKey] {
            guard stored != uidValidity else { return false }
            checkpoint.watermarks[mailboxKey] = 0
            checkpoint.backfillFloors.removeValue(forKey: mailboxKey)
            checkpoint.uidValidities[mailboxKey] = uidValidity
            try persist()
            return true
        }
        checkpoint.uidValidities[mailboxKey] = uidValidity
        try persist()
        return false
    }

    /// Updates the in-memory watermark and content hash set without immediately writing to disk.
    public func recordInMemory(account: String, mailbox: String, watermark: Int, contentHash: String?) {
        loadIfNeeded()
        let mailboxKey = Self.key(account: account, mailbox: mailbox)
        if watermark > (checkpoint.watermarks[mailboxKey] ?? 0) {
            checkpoint.watermarks[mailboxKey] = watermark
        }
        if let contentHash, !checkpoint.contentHashes.contains(contentHash) {
            checkpoint.contentHashes.append(contentHash)
            if checkpoint.contentHashes.count > Self.maxTrackedHashes {
                checkpoint.contentHashes.removeFirst(checkpoint.contentHashes.count - Self.maxTrackedHashes)
            }
        }
    }

    /// Persists the current in-memory checkpoint to disk atomically.
    public func flush() throws {
        loadIfNeeded()
        try persist()
    }

    /// Records progress for one mailbox, persisting immediately. account: Account
    /// nickname.
    public func record(account: String, mailbox: String, watermark: Int, contentHash: String?) throws {
        recordInMemory(account: account, mailbox: mailbox, watermark: watermark, contentHash: contentHash)
        try persist()
    }

    /// Returns the current checkpoint snapshot.
    /// - Returns: The in-memory checkpoint.
    public func snapshot() -> MailIndexCheckpoint {
        loadIfNeeded()
        return checkpoint
    }

    /// Drops the watermark, validity token, and backfill floor for one mailbox. Called after a
    /// denied mailbox retires so re-allowing it backfills from zero instead of resuming past mail it
    /// never indexed while denied.
    public func dropMailbox(account: String, mailbox: String) throws {
        loadIfNeeded()
        let key = Self.key(account: account, mailbox: mailbox)
        var changed = false
        if checkpoint.watermarks.removeValue(forKey: key) != nil {
            changed = true
        }
        if checkpoint.uidValidities.removeValue(forKey: key) != nil {
            changed = true
        }
        if checkpoint.backfillFloors.removeValue(forKey: key) != nil {
            changed = true
        }
        if changed {
            try persist()
        }
    }

    /// Forgets content hashes for retired mail so a re-allowed mailbox re-indexes.
    public func removeContentHashes(_ hashes: Set<String>) throws {
        loadIfNeeded()
        guard !hashes.isEmpty else { return }
        let before = checkpoint.contentHashes.count
        checkpoint.contentHashes.removeAll { hashes.contains($0) }
        if checkpoint.contentHashes.count != before {
            try persist()
        }
    }

    /// Resets the checkpoint file at the given path by deleting it if it exists.
    /// - Parameter path: JSON sidecar path. `~` is expanded before deletion.
    public static func reset(path: String = defaultPath) throws {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Resets all in-memory watermarks, validity tokens, and content hashes, removing the sidecar file.
    public func reset() throws {
        checkpoint = MailIndexCheckpoint()
        loaded = true
        try Self.reset(path: path)
    }

    /// Reads the sidecar once, ignoring unreadable or corrupt state.
    /// If the sidecar file does not exist, resets the in-memory state so external deletions take effect.
    private func loadIfNeeded() {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        guard FileManager.default.fileExists(atPath: url.path) else {
            checkpoint = MailIndexCheckpoint()
            loaded = true
            return
        }
        guard !loaded else { return }
        loaded = true
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            RuneWeaverLog.stores.warning("MailIndexCheckpointStore: failed to read checkpoint from '\(expanded)': \(error.localizedDescription)")
            return
        }
        do {
            checkpoint = try JSONDecoder().decode(MailIndexCheckpoint.self, from: data)
        } catch {
            RuneWeaverLog.stores.warning("MailIndexCheckpointStore: failed to decode checkpoint from '\(expanded)': \(error.localizedDescription)")
        }
    }

    /// Writes the checkpoint to disk atomically.
    private func persist() throws {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(checkpoint)
        try data.write(to: url, options: .atomic)
    }
}
