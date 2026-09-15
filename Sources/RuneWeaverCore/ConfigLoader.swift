// Rune Weaver Core — Hot-reloading config.toml loader with snapshot semantics.
//
// Holds the last validated snapshot behind a lock so readers always see a
// consistent configuration even while the file watcher reloads. Invalid
// reloads keep the previous good snapshot and surface through onError, so
// a broken edit never replaces working config.

import Foundation
import os

// MARK: - Hot-reloading loader

/// Loads `config.toml` and keeps the snapshot fresh via a file watcher.
///
/// The loader holds the last validated snapshot. Call ``ConfigLoader/load()``
/// to re-read on demand, or ``ConfigLoader/startWatching()`` to reload
/// automatically when the file changes. Invalid reloads keep the previous
/// good snapshot and report the error through `onError` instead of
/// replacing working config with a broken one.
public final class ConfigLoader: Sendable {
    /// File being watched.
    public let fileURL: URL

    private struct State: Sendable {
        var snapshot: RuneWeaverConfig
        var changeHandler: (@Sendable (RuneWeaverConfig) -> Void)?
        var errorHandler: (@Sendable (Error) -> Void)?
        var source: (any DispatchSourceFileSystemObject)?
        var fileDescriptor: CInt = -1
        var isStartingWatch = false
    }

    private let state: OSAllocatedUnfairLock<State>
    private let queue = DispatchQueue(label: "com.runeweaver.config-watcher")

    /// Last validated snapshot. Thread-safe via an internal lock.
    public var config: RuneWeaverConfig {
        state.withLock { $0.snapshot }
    }

    /// Called on the watcher queue after a successful reload.
    /// Set before calling `startWatching()`.
    public var onChange: (@Sendable (RuneWeaverConfig) -> Void)? {
        get { state.withLock { $0.changeHandler } }
        set { state.withLock { $0.changeHandler = newValue } }
    }

    /// Called on the watcher queue when a reload fails. The previous
    /// snapshot stays in effect. Set before calling `startWatching()`.
    public var onError: (@Sendable (Error) -> Void)? {
        get { state.withLock { $0.errorHandler } }
        set { state.withLock { $0.errorHandler = newValue } }
    }

    /// Creates a loader and performs the initial load.
    ///
    /// A missing file yields ``RuneWeaverConfig/default``; an existing
    /// but invalid file throws.
    /// - Parameter fileURL: Config file. Defaults to
    ///   `~/.runeweaver/config.toml`.
    public init(fileURL: URL? = nil) throws {
        let resolved = fileURL ?? RuneWeaverConfig.defaultConfigFileURL()
        self.fileURL = resolved
        let initialSnapshot: RuneWeaverConfig = if FileManager.default.fileExists(atPath: resolved.path) {
            try RuneWeaverConfig.load(from: resolved)
        } else {
            .default
        }
        self.state = OSAllocatedUnfairLock(initialState: State(snapshot: initialSnapshot))
    }

    deinit {
        stopWatching()
    }

    /// Re-reads the file, validates, and replaces the snapshot.
    /// - Returns: The new snapshot.
    /// - Throws: ``ConfigError`` on failure. The old snapshot is kept.
    @discardableResult
    public func load() throws -> RuneWeaverConfig {
        let fresh: RuneWeaverConfig = if FileManager.default.fileExists(atPath: fileURL.path) {
            try RuneWeaverConfig.load(from: fileURL)
        } else {
            .default
        }
        state.withLock { $0.snapshot = fresh }
        return fresh
    }

    /// Starts hot-reloading. Safe to call repeatedly; the second call
    /// is a no-op. Set `onChange`/`onError` before calling.
    ///
    /// Creation is serialized: a lock-guarded `isStartingWatch` flag is
    /// set synchronously so concurrent callers collapse into one watcher
    /// instead of each passing the `source == nil` check and leaking a
    /// `DispatchSource` plus file descriptor. All `source` /
    /// `fileDescriptor` mutations happen under the lock on the watcher
    /// queue.
    public func startWatching() {
        let shouldStart = state.withLock { state -> Bool in
            guard state.source == nil, !state.isStartingWatch else { return false }
            state.isStartingWatch = true
            return true
        }
        guard shouldStart else { return }

        queue.async { [weak self] in
            guard let self else { return }
            let path = self.fileURL.path
            guard FileManager.default.fileExists(atPath: path) else {
                self.state.withLock { $0.isStartingWatch = false }
                return
            }
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else {
                self.state.withLock { $0.isStartingWatch = false }
                return
            }
            let alreadyWatching = self.state.withLock { state -> Bool in
                if state.source != nil {
                    state.isStartingWatch = false
                    return true
                }
                return false
            }
            if alreadyWatching {
                close(fd)
                return
            }
            let watcher = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .attrib, .rename, .revoke, .delete],
                queue: self.queue
            )
            watcher.setEventHandler { [weak self] in
                guard let self else { return }
                do {
                    let fresh = try self.load()
                    let handler = self.onChange
                    handler?(fresh)
                } catch {
                    let handler = self.onError
                    handler?(error)
                }
            }
            watcher.setCancelHandler { [fd] in
                close(fd)
            }
            watcher.resume()
            self.state.withLock { state in
                state.source = watcher
                state.fileDescriptor = fd
                state.isStartingWatch = false
            }
        }
    }

    /// Stops hot-reloading. Safe to call when not watching.
    public func stopWatching() {
        // Cancel off the watcher queue to avoid a sync deadlock when
        // invoked from deinit or from within the event handler.
        let watcher: (any DispatchSourceFileSystemObject)? = state.withLock { state in
            let existing = state.source
            state.source = nil
            state.fileDescriptor = -1
            state.isStartingWatch = false
            return existing
        }
        watcher?.cancel()
    }
}
