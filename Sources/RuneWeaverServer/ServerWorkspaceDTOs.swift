// Rune Weaver Server — Workspace settings DTOs for the settings API.

import Foundation
import RuneWeaverCore
import Vapor

/// Partial `[workspace]` patch for `PUT /settings`. Every field stays optional so a request
/// carrying only one key leaves the rest of the stored scratch quotas untouched instead of resetting
/// them.
public struct WorkspaceUpdate: Content, Sendable, Equatable {
    /// Total bytes permitted under the workspace root, in megabytes. Nil preserves the stored value.
    public var quotaMB: Int?
    /// Total files permitted under the workspace root. Nil preserves the stored value.
    public var quotaFiles: Int?
    /// Days `tmp/` entries survive before pruning. Nil preserves the stored value.
    public var tmpTTLDays: Int?

    /// Creates a partial workspace patch. quotaMB: Total bytes permitted under the
    /// workspace root, in megabytes.
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
}

extension UpdateSettingsRequest {
    /// Builds a request from a full workspace snapshot, routing through the same
    /// merge path so snapshot callers keep working without hand-mapping fields.
    /// - Parameter workspace: Complete workspace policy.
    public init(workspace: WorkspaceConfig) {
        self.init(workspace: WorkspaceUpdate(workspace))
    }
}

// MARK: - Workspace Machine

/// Machine status for `GET /workspace/machine`.
public struct WorkspaceMachineResponse: Content, Sendable, Equatable {
    /// Whether the machine container entry exists.
    public let exists: Bool
    /// Whether the machine container is running.
    public let running: Bool
    /// Image reference reported by the machine, empty when unknown.
    public let image: String
    /// Whether the machine label matches the current workspace root, nil when unknown.
    public let configMatch: Bool?

    /// Creates a machine status response.
    public init(exists: Bool, running: Bool, image: String, configMatch: Bool?) {
        self.exists = exists
        self.running = running
        self.image = image
        self.configMatch = configMatch
    }
}

// MARK: - Workspace Settings Merge

extension UpdateSettingsRequest {
    /// Merges a partial workspace patch onto the stored quotas, preserving every field the request
    /// omits. A nil patch is a no-op, so a dashboard edit to one knob never resets the rest of the
    /// `[workspace]` section.
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
