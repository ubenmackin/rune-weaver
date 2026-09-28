import Foundation

// MARK: - Watermark state

/// Persisted coordinator state: the last successful watermark and trigger times.
public struct IndexRunState: Sendable, Codable, Equatable {
    /// Instant of the last successful run, used as the index watermark.
    public var indexAsOf: Date?
    /// Instant the last successful run completed.
    public var lastCompletedAt: Date?
    /// Instant the nightly trigger last started a run.
    public var lastNightlyStart: Date?

    /// Creates run state.
    /// - Parameters:
    ///   - indexAsOf: Last successful watermark.
    ///   - lastCompletedAt: Last successful completion instant.
    ///   - lastNightlyStart: Last nightly trigger instant.
    public init(indexAsOf: Date? = nil, lastCompletedAt: Date? = nil, lastNightlyStart: Date? = nil) {
        self.indexAsOf = indexAsOf
        self.lastCompletedAt = lastCompletedAt
        self.lastNightlyStart = lastNightlyStart
    }
}

/// JSON-backed store for the coordinator watermark and trigger times.
///
/// The state is tiny and read on demand, so a JSON sidecar keeps the watermark
/// independent of the document store schema and survives restarts.
public actor IndexRunStateStore {
    /// Default state path, kept beside the other durable memory stores.
    public static let defaultPath = "~/.runeweaver/index/coordinator-state.json"

    /// Filesystem path of the JSON sidecar.
    public let path: String

    /// Whether the sidecar has been read into memory.
    private var loaded = false
    /// In-memory state snapshot.
    private var state = IndexRunState()

    /// Creates a state store.
    /// - Parameter path: JSON sidecar path. `~` is expanded on first load.
    public init(path: String = IndexRunStateStore.defaultPath) {
        self.path = path
    }

    /// Returns the current state snapshot.
    /// - Returns: The in-memory state.
    public func snapshot() -> IndexRunState {
        loadIfNeeded()
        return state
    }

    /// Records a successful run, advancing the watermark and completion time.
    /// - Parameter date: Completion instant.
    public func recordCompleted(at date: Date) throws {
        loadIfNeeded()
        state.indexAsOf = date
        state.lastCompletedAt = date
        try persist()
    }

    /// Records that the nightly trigger started a run.
    /// - Parameter date: Trigger instant.
    public func recordNightlyStart(at date: Date) throws {
        loadIfNeeded()
        state.lastNightlyStart = date
        try persist()
    }

    /// Clears every recorded field.
    public func reset() throws {
        loadIfNeeded()
        state = IndexRunState()
        try persist()
    }

    /// Reads the sidecar once, ignoring unreadable or corrupt state.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let expanded = (path as NSString).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: expanded)) else { return }
        do {
            state = try JSONDecoder().decode(IndexRunState.self, from: data)
        } catch {
            RuneWeaverLog.scheduler.warning("IndexRunStateStore: failed to decode index run state from '\(expanded)': \(error.localizedDescription)")
        }
    }

    /// Writes the state to disk atomically.
    private func persist() throws {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: .atomic)
    }
}
