// Rune Weaver Server — Fan-out settings patch and merge logic.
//
// Extracted from ServerDTOs.swift to keep file length within lint bounds.
// The partial `[fanout]` patch for `PUT /settings` and the merge helper
// live beside the fan-out DTOs so the settings surface stays single-sourced.

import Foundation
import RuneWeaverCore
import Vapor

/// Partial `[fanout]` patch for `PUT /settings`.
///
/// Every field stays optional so a request carrying only one key leaves the
/// rest of the stored swarm policy untouched instead of resetting it.
/// Mirrors the shared Arr patch shape: omitted keys preserve their stored
/// values, and range checks stay single-sourced in `RuneWeaverConfig.validate`
/// so the file-load and settings-save paths refuse the same out-of-range
/// values with an honest 400.
public struct FanOutSettingsUpdate: Content, Sendable, Equatable {
    /// Maximum workers running at once (`1...8`). Nil preserves the stored value.
    public var maxWorkers: Int?
    /// Wall-clock budget for one worker turn in seconds. Nil preserves the stored value.
    public var workerTimeoutSeconds: Int?
    /// Whether workers may call the full tool registry. Nil preserves the stored value.
    public var fullTools: Bool?

    /// Creates a partial fan-out patch.
    /// - Parameters:
    ///   - maxWorkers: Maximum workers running at once.
    ///   - workerTimeoutSeconds: Wall-clock budget for one worker turn.
    ///   - fullTools: Whether workers may call the full tool registry.
    public init(
        maxWorkers: Int? = nil,
        workerTimeoutSeconds: Int? = nil,
        fullTools: Bool? = nil
    ) {
        self.maxWorkers = maxWorkers
        self.workerTimeoutSeconds = workerTimeoutSeconds
        self.fullTools = fullTools
    }

    /// Populates a patch from a full snapshot so programmatic callers holding
    /// a complete `FanOutConfig` reuse the same merge path.
    /// - Parameter config: Complete fan-out policy.
    public init(_ config: FanOutConfig) {
        self.maxWorkers = config.maxWorkers
        self.workerTimeoutSeconds = config.workerTimeoutSeconds
        self.fullTools = config.fullTools
    }

    private enum CodingKeys: String, CodingKey {
        case maxWorkers = "max_workers"
        case workerTimeoutSeconds = "worker_timeout_seconds"
        case fullTools = "full_tools"
    }
}

extension UpdateSettingsRequest {
    /// Builds a request from a full fan-out snapshot, routing through the same
    /// merge path so snapshot callers keep working without hand-mapping fields.
    /// - Parameter fanout: Complete fan-out policy.
    public init(fanout: FanOutConfig) {
        self.init(fanout: FanOutSettingsUpdate(fanout))
    }
}

// MARK: - Fan-out Settings Merge

extension UpdateSettingsRequest {
    /// Merges a partial fan-out patch onto the stored policy, preserving every
    /// field the request omits. A nil patch is a no-op, so a dashboard edit
    /// elsewhere never resets the `[fanout]` section. Values land verbatim
    /// because range checks stay single-sourced in `RuneWeaverConfig.validate`,
    /// which runs before the merged config persists; the live engine clamps
    /// again in `updateConfig` so a hand-built config still degrades safely.
    ///
    /// Internal so the shared settings `apply(to:)` keeps one merge path while
    /// the fan-out-specific logic lives beside its DTOs.
    func applyFanOut(to fanout: inout FanOutConfig) {
        guard let update = self.fanout else { return }
        if let maxWorkers = update.maxWorkers {
            fanout.maxWorkers = maxWorkers
        }
        if let workerTimeoutSeconds = update.workerTimeoutSeconds {
            fanout.workerTimeoutSeconds = workerTimeoutSeconds
        }
        if let fullTools = update.fullTools {
            fanout.fullTools = fullTools
        }
    }
}
