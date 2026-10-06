// Rune Weaver Server — Workspace settings DTOs for the settings API.
//
// Purpose: carries the partial workspace patch for `PUT /settings` so dashboard
// quota edits preserve untouched fields while scratch limits apply without a restart.
// Scope: REST patch bodies only; the settings request type owns merge policy
// while validation and persistence stay with the config layer.
// Architectural role: keeps workspace Codable contracts version-tolerant and
// decoupled from the broader settings surface, mirroring the bash DTO split so
// the settings snapshot file stays within its length budget.

import Foundation
import RuneWeaverCore
import Vapor

/// Partial `[workspace]` patch for `PUT /settings`.
///
/// Every field stays optional so a request carrying only one key leaves the
/// rest of the stored scratch quotas untouched instead of resetting them.
/// Covers the same field set as the full `WorkspaceConfig` snapshot, so a
/// caller holding a complete policy can build the patch through `init(_:)` and
/// reuse the merge path without hand-mapping fields.
public struct WorkspaceUpdate: Content, Sendable, Equatable {
    /// Total bytes permitted under the workspace root, in megabytes. Nil preserves the stored value.
    public var quotaMB: Int?
    /// Total files permitted under the workspace root. Nil preserves the stored value.
    public var quotaFiles: Int?
    /// Days `tmp/` entries survive before pruning. Nil preserves the stored value.
    public var tmpTTLDays: Int?

    /// Creates a partial workspace patch.
    /// - Parameters:
    ///   - quotaMB: Total bytes permitted under the workspace root, in megabytes.
    ///   - quotaFiles: Total files permitted under the workspace root.
    ///   - tmpTTLDays: Days `tmp/` entries survive before pruning.
    public init(
        quotaMB: Int? = nil,
        quotaFiles: Int? = nil,
        tmpTTLDays: Int? = nil
    ) {
        self.quotaMB = quotaMB
        self.quotaFiles = quotaFiles
        self.tmpTTLDays = tmpTTLDays
    }

    /// Populates a patch from a full snapshot so programmatic callers holding
    /// a complete `WorkspaceConfig` reuse the same merge path.
    /// - Parameter workspace: Complete workspace policy.
    public init(_ workspace: WorkspaceConfig) {
        self.quotaMB = workspace.quotaMB
        self.quotaFiles = workspace.quotaFiles
        self.tmpTTLDays = workspace.tmpTTLDays
    }

    /// Whether the patch carries no keys, so the save path can skip live
    /// reloads that would otherwise rebuild tools for a no-op merge.
    public var isEmpty: Bool {
        quotaMB == nil && quotaFiles == nil && tmpTTLDays == nil
    }

    private enum CodingKeys: String, CodingKey {
        case quotaMB = "quota_mb"
        case quotaMBCamel = "quotaMB"
        case quotaFiles = "quota_files"
        case quotaFilesCamel = "quotaFiles"
        case tmpTTLDays = "tmp_ttl_days"
        case tmpTTLDaysCamel = "tmpTTLDays"
    }

    /// Decodes a partial workspace patch accepting snake_case and camelCase aliases.
    ///
    /// Snake_case stays canonical so persisted files round-trip unchanged; the
    /// camelCase spellings mirror the dashboard contract and fall back only
    /// when the snake key is absent. When both spellings arrive the snake value
    /// wins so the two contracts cannot fork the stored quotas.
    /// - Parameter decoder: Decoder carrying the patch.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let snakeQuotaMB = try container.decodeIfPresent(Int.self, forKey: .quotaMB)
        let camelQuotaMB = try container.decodeIfPresent(Int.self, forKey: .quotaMBCamel)
        quotaMB = snakeQuotaMB ?? camelQuotaMB
        let snakeQuotaFiles = try container.decodeIfPresent(Int.self, forKey: .quotaFiles)
        let camelQuotaFiles = try container.decodeIfPresent(Int.self, forKey: .quotaFilesCamel)
        quotaFiles = snakeQuotaFiles ?? camelQuotaFiles
        let snakeTTL = try container.decodeIfPresent(Int.self, forKey: .tmpTTLDays)
        let camelTTL = try container.decodeIfPresent(Int.self, forKey: .tmpTTLDaysCamel)
        tmpTTLDays = snakeTTL ?? camelTTL
    }

    /// Encodes a partial workspace patch using canonical snake_case keys.
    ///
    /// CamelCase aliases decode but never encode so saved payloads keep the
    /// file shape and a round-trip never invents a second spelling.
    /// - Parameter encoder: Encoder receiving the patch.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(quotaMB, forKey: .quotaMB)
        try container.encodeIfPresent(quotaFiles, forKey: .quotaFiles)
        try container.encodeIfPresent(tmpTTLDays, forKey: .tmpTTLDays)
    }
}

extension UpdateSettingsRequest {
    /// Builds a request from a full workspace snapshot, routing through the same
    /// merge path so snapshot callers keep working without hand-mapping fields.
    /// - Parameter workspace: Complete workspace policy.
    public init(workspace: WorkspaceConfig) {
        self.init(workspace: WorkspaceUpdate(workspace))
    }
}

// MARK: - Workspace Settings Merge

extension UpdateSettingsRequest {
    /// Merges a partial workspace patch onto the stored quotas, preserving every
    /// field the request omits. A nil patch is a no-op, so a dashboard edit to
    /// one knob never resets the rest of the `[workspace]` section. Range checks
    /// route through the single-sourced `WorkspaceConfig` validators the TOML
    /// load path enforces, so the PUT and file-load paths refuse the same values
    /// with the same dotted field instead of persisting a quota the loader rejects.
    ///
    /// Internal so the shared settings `apply(to:)` keeps one merge path while
    /// the workspace-specific logic lives beside its DTO.
    func applyWorkspace(to workspace: inout WorkspaceConfig) throws {
        guard let update = self.workspace else { return }
        // Every present field validates before anything mutates, so a
        // multi-field patch with one bad value leaves the stored quotas
        // untouched instead of half-applying the valid prefix.
        if let quotaMB = update.quotaMB {
            try WorkspaceConfig.validateQuotaMB(quotaMB)
        }
        if let quotaFiles = update.quotaFiles {
            try WorkspaceConfig.validateQuotaFiles(quotaFiles)
        }
        if let tmpTTLDays = update.tmpTTLDays {
            try WorkspaceConfig.validateTmpTTLDays(tmpTTLDays)
        }
        if let quotaMB = update.quotaMB {
            workspace.quotaMB = quotaMB
        }
        if let quotaFiles = update.quotaFiles {
            workspace.quotaFiles = quotaFiles
        }
        if let tmpTTLDays = update.tmpTTLDays {
            workspace.tmpTTLDays = tmpTTLDays
        }
    }
}
