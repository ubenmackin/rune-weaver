// Rune Weaver Server — Bash settings DTOs for the settings API.
//
// Purpose: carries the partial bash patch for `PUT /settings` so dashboard
// edits preserve untouched fields while shell policy applies without a restart.
// Scope: REST patch bodies only; the settings request type owns merge policy
// while validation and persistence stay with the config layer.
// Architectural role: keeps bash Codable contracts version-tolerant and
// decoupled from the broader settings surface.

import Foundation
import RuneWeaverCore
import Vapor

/// Partial bash patch for `PUT /settings`.
///
/// Every field stays optional so a request carrying only one key leaves the
/// stored shell policy untouched instead of resetting it. Rules stay ordered
/// top-to-bottom last-match-wins, matching the stored `BashConfig` order. Put the catch-all first and specifics after.
/// Covers the same field set as the full `BashConfig` snapshot, so a caller
/// holding a complete policy can build the patch through `init(bash:)` and
/// reuse the merge path without hand-mapping fields.
public struct BashSettingsUpdate: Content, Equatable {
    /// Whether the bash tool is enabled. Nil preserves the stored value.
    public var enabled: Bool?
    /// Default action when no rule matches (`allow|ask|deny`). Nil preserves the stored value.
    public var defaultAction: String?
    /// Ordered permission rules evaluated last-match-wins (last matching rule decides). Nil preserves the stored value.
    public var rules: [BashRule]?
    /// Default execution timeout in seconds (1-3600). Nil preserves the stored value.
    public var timeoutSeconds: Int?
    /// CPU time budget in seconds applied via `ulimit -t` (1-3600). Nil preserves the stored value.
    public var cpuSeconds: Int?
    /// Address-space budget in megabytes applied via `ulimit -v` (64-8192). Nil preserves the stored value.
    public var memoryMb: Int?
    /// Whether network access is permitted in the sandbox. Nil preserves the stored value.
    public var allowNetwork: Bool?
    /// Sandbox execution tier (`strictContainer|machineScoped|hostSeatbelt`). Nil preserves the stored value.
    public var sandboxMode: String?
    /// Fnmatch/prefix allow patterns gating `hostSeatbelt` execution. Nil preserves the stored value.
    public var hostAllowPatterns: [String]?

    /// Creates a partial bash patch.
    /// - Parameters:
    ///   - enabled: Whether the bash tool is enabled.
    ///   - defaultAction: Default action when no rule matches.
    ///   - rules: Ordered permission rules.
    ///   - timeoutSeconds: Default execution timeout in seconds.
    ///   - cpuSeconds: CPU time budget in seconds.
    ///   - memoryMb: Address-space budget in megabytes.
    ///   - allowNetwork: Whether network access is permitted.
    ///   - sandboxMode: Sandbox execution tier.
    ///   - hostAllowPatterns: Fnmatch/prefix allow patterns gating `hostSeatbelt` execution.
    public init(
        enabled: Bool? = nil,
        defaultAction: String? = nil,
        rules: [BashRule]? = nil,
        timeoutSeconds: Int? = nil,
        cpuSeconds: Int? = nil,
        memoryMb: Int? = nil,
        allowNetwork: Bool? = nil,
        sandboxMode: String? = nil,
        hostAllowPatterns: [String]? = nil
    ) {
        self.enabled = enabled
        self.defaultAction = defaultAction
        self.rules = rules
        self.timeoutSeconds = timeoutSeconds
        self.cpuSeconds = cpuSeconds
        self.memoryMb = memoryMb
        self.allowNetwork = allowNetwork
        self.sandboxMode = sandboxMode
        self.hostAllowPatterns = hostAllowPatterns
    }

    /// Populates a patch from a full snapshot so programmatic callers holding
    /// a complete `BashConfig` reuse the same merge path.
    /// - Parameter bash: Complete bash policy.
    public init(bash: BashConfig) {
        self.enabled = bash.enabled
        self.defaultAction = bash.defaultAction.rawValue
        self.rules = bash.rules
        self.timeoutSeconds = bash.timeoutSeconds
        self.cpuSeconds = bash.cpuSeconds
        self.memoryMb = bash.memoryMB
        self.allowNetwork = bash.allowNetwork
        self.sandboxMode = bash.sandboxMode.rawValue
        self.hostAllowPatterns = bash.hostAllowPatterns
    }

    /// Whether the patch carries no keys, so the save path can skip live
    /// reloads that would otherwise rebuild tools for a no-op merge.
    public var isEmpty: Bool {
        enabled == nil
            && defaultAction == nil
            && rules == nil
            && timeoutSeconds == nil
            && cpuSeconds == nil
            && memoryMb == nil
            && allowNetwork == nil
            && sandboxMode == nil
            && hostAllowPatterns == nil
    }

    /// Merges this patch onto the stored policy, preserving every field the
    /// request omits. A nil field is a no-op, so a dashboard edit to one knob
    /// never resets the rest of the `[bash]` section.
    /// - Parameter bash: Stored bash policy to mutate in place.
    /// - Throws: `ConfigError.validationError` when the rule list is empty,
    ///   a rule pattern is blank, the default action is unknown, the sandbox
    ///   mode is unknown, the host allowlist is over-limit or malformed, or the
    ///   timeout, CPU, or memory bound falls outside its documented range.
    ///   Range checks reuse the `BashConfig` validators the TOML load path
    ///   enforces, so the PUT and file-load paths refuse the same values with
    ///   the same dotted field.
    public func apply(to bash: inout BashConfig) throws {
        // Every present field validates before anything mutates, so a
        // multi-field patch with one bad value leaves the stored policy
        // untouched instead of half-applying the valid prefix.
        var validatedAction: BashPermissionAction?
        if let defaultAction {
            let trimmedAction = defaultAction.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let action = BashPermissionAction(rawValue: trimmedAction.lowercased()) else {
                throw ConfigError.validationError(
                    field: "bash.default_action",
                    message: "must be allow, ask, or deny (got '\(trimmedAction)')"
                )
            }
            validatedAction = action
        }
        var validatedSandboxMode: BashSandboxMode?
        if let sandboxMode {
            let trimmed = sandboxMode.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let mode = BashSandboxMode(rawValue: trimmed) else {
                throw ConfigError.validationError(
                    field: "bash.sandbox_mode",
                    message: "must be one of \(BashSandboxMode.allCases.map(\.rawValue).joined(separator: ", ")) (got '\(trimmed)')"
                )
            }
            validatedSandboxMode = mode
        }
        if let rules {
            try BashConfig.validateRules(rules)
        }
        if let timeoutSeconds {
            try BashConfig.validateTimeoutSeconds(timeoutSeconds)
        }
        if let cpuSeconds {
            try BashConfig.validateCPUSeconds(cpuSeconds)
        }
        if let memoryMb {
            try BashConfig.validateMemoryMB(memoryMb)
        }
        var validatedHostAllowPatterns: [String]?
        if let hostAllowPatterns {
            let trimmed = hostAllowPatterns.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            try BashConfig.validateHostAllowPatterns(trimmed)
            validatedHostAllowPatterns = trimmed
        }
        if let enabled {
            bash.enabled = enabled
        }
        if let validatedAction {
            bash.defaultAction = validatedAction
        }
        if let rules {
            bash.rules = rules
        }
        if let timeoutSeconds {
            bash.timeoutSeconds = timeoutSeconds
        }
        if let cpuSeconds {
            bash.cpuSeconds = cpuSeconds
        }
        if let memoryMb {
            bash.memoryMB = memoryMb
        }
        if let allowNetwork {
            bash.allowNetwork = allowNetwork
        }
        if let validatedSandboxMode {
            bash.sandboxMode = validatedSandboxMode
        }
        if let validatedHostAllowPatterns {
            bash.hostAllowPatterns = validatedHostAllowPatterns
        }
    }
}

extension UpdateSettingsRequest {
    /// Builds a request from a full bash snapshot, routing through the same
    /// merge path so snapshot callers keep working without hand-mapping fields.
    /// - Parameter bash: Complete bash policy.
    public init(bash: BashConfig) {
        self.init(bash: BashSettingsUpdate(bash: bash))
    }
}

// MARK: - Bash Settings Merge

extension UpdateSettingsRequest {
    /// Merges a partial bash patch onto the stored policy, preserving every
    /// field the request omits. A nil patch is a no-op, so a dashboard edit
    /// elsewhere never resets the `[bash]` section. Validation stays
    /// single-sourced in `BashSettingsUpdate.apply(to:)` so the PUT and
    /// direct-merge paths agree with a clear 400 instead of persisting bad values.
    ///
    /// Internal so the shared settings `apply(to:)` keeps one merge path while
    /// the bash-specific logic lives beside its DTOs.
    func applyBash(to bash: inout BashConfig) throws {
        guard let update = self.bash else { return }
        try update.apply(to: &bash)
    }
}
