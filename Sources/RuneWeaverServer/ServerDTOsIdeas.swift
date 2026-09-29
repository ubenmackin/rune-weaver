// Rune Weaver Server — Ideas settings patch and merge logic.
//
// Extracted from ServerDTOs.swift to keep file length within lint bounds.
// The partial `[ideas]` patch for `PUT /settings` and the merge helper
// live beside the Ideas DTOs so the settings surface stays single-sourced.

import Foundation
import RuneWeaverCore
import Vapor

/// Partial `[ideas]` patch for `PUT /settings`.
///
/// Every field stays optional so a request carrying only the enable flag leaves
/// the rest of the stored suggestion policy untouched instead of resetting it.
/// The dashboard-owned subset is the enable toggle: the per-cycle cap and
/// review timeout stay file-owned planning bounds, matching the goals patch so
/// the settings surface cannot widen execution cost.
public struct IdeasUpdate: Content, Sendable, Equatable {
    /// Whether proactive idea generation runs at all. Nil preserves the stored value.
    public var enabled: Bool?

    /// Creates a partial ideas patch.
    /// - Parameter enabled: Whether suggestion generation runs.
    public init(enabled: Bool? = nil) {
        self.enabled = enabled
    }

    /// Populates a patch from a full snapshot so programmatic callers holding a
    /// complete `IdeasConfig` reuse the same merge path.
    /// - Parameter config: Complete suggestion policy.
    public init(_ config: IdeasConfig) {
        self.enabled = config.enabled
    }
}

extension UpdateSettingsRequest {
    /// Merges a partial ideas patch onto the stored policy, preserving every
    /// field the request omits. A nil patch is a no-op, so a dashboard edit
    /// elsewhere never resets the `[ideas]` section.
    ///
    /// Internal so the shared settings `apply(to:)` keeps one merge path while
    /// the ideas-specific logic lives beside its DTOs.
    func applyIdeas(to ideas: inout IdeasConfig) {
        guard let update = self.ideas else { return }
        if let enabled = update.enabled {
            ideas.enabled = enabled
        }
    }
}
