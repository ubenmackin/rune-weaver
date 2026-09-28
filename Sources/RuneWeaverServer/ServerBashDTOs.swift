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
/// top-to-bottom first-match-wins, matching the stored `BashConfig` order.
/// Covers the same field set as the full `BashConfig` snapshot, so a caller
/// holding a complete policy can build the patch through `init(bash:)` and
/// reuse the merge path without hand-mapping fields.
public struct BashSettingsUpdate: Content, Equatable {
    /// Whether the bash tool is enabled. Nil preserves the stored value.
    public var enabled: Bool?
    /// Default action when no rule matches (`allow|ask|deny`). Nil preserves the stored value.
    public var defaultAction: String?
    /// Ordered permission rules evaluated first-match-wins. Nil preserves the stored value.
    public var rules: [BashRule]?
    /// Default execution timeout in seconds (1-3600). Nil preserves the stored value.
    public var timeoutSeconds: Int?
    /// Whether network access is permitted in the sandbox. Nil preserves the stored value.
    public var allowNetwork: Bool?

    /// Creates a partial bash patch.
    /// - Parameters:
    ///   - enabled: Whether the bash tool is enabled.
    ///   - defaultAction: Default action when no rule matches.
    ///   - rules: Ordered permission rules.
    ///   - timeoutSeconds: Default execution timeout in seconds.
    ///   - allowNetwork: Whether network access is permitted.
    public init(
        enabled: Bool? = nil,
        defaultAction: String? = nil,
        rules: [BashRule]? = nil,
        timeoutSeconds: Int? = nil,
        allowNetwork: Bool? = nil
    ) {
        self.enabled = enabled
        self.defaultAction = defaultAction
        self.rules = rules
        self.timeoutSeconds = timeoutSeconds
        self.allowNetwork = allowNetwork
    }

    /// Populates a patch from a full snapshot so programmatic callers holding
    /// a complete `BashConfig` reuse the same merge path.
    /// - Parameter bash: Complete bash policy.
    public init(bash: BashConfig) {
        self.enabled = bash.enabled
        self.defaultAction = bash.defaultAction.rawValue
        self.rules = bash.rules
        self.timeoutSeconds = bash.timeoutSeconds
        self.allowNetwork = bash.allowNetwork
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case defaultAction = "default_action"
        case defaultActionCamel = "defaultAction"
        case rules
        case timeoutSeconds = "timeout_seconds"
        case timeoutSecondsCamel = "timeoutSeconds"
        case allowNetwork = "allow_network"
        case allowNetworkCamel = "allowNetwork"
    }

    /// Decodes a partial bash patch accepting snake_case and camelCase aliases.
    ///
    /// Snake_case stays canonical so persisted files round-trip unchanged; the
    /// camelCase spellings mirror the dashboard contract and fall back only
    /// when the snake key is absent. When both spellings arrive the snake value
    /// wins so the two contracts cannot fork the stored policy.
    /// - Parameter decoder: Decoder carrying the patch.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        let snakeDefaultAction = try container.decodeIfPresent(String.self, forKey: .defaultAction)
        let camelDefaultAction = try container.decodeIfPresent(String.self, forKey: .defaultActionCamel)
        defaultAction = snakeDefaultAction ?? camelDefaultAction
        rules = try container.decodeIfPresent([BashRule].self, forKey: .rules)
        let snakeTimeout = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds)
        let camelTimeout = try container.decodeIfPresent(Int.self, forKey: .timeoutSecondsCamel)
        timeoutSeconds = snakeTimeout ?? camelTimeout
        let snakeAllowNetwork = try container.decodeIfPresent(Bool.self, forKey: .allowNetwork)
        let camelAllowNetwork = try container.decodeIfPresent(Bool.self, forKey: .allowNetworkCamel)
        allowNetwork = snakeAllowNetwork ?? camelAllowNetwork
    }

    /// Encodes a partial bash patch using canonical snake_case keys.
    ///
    /// CamelCase aliases decode but never encode so saved payloads keep the
    /// file shape and a round-trip never invents a second spelling.
    /// - Parameter encoder: Encoder receiving the patch.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(enabled, forKey: .enabled)
        try container.encodeIfPresent(defaultAction, forKey: .defaultAction)
        try container.encodeIfPresent(rules, forKey: .rules)
        try container.encodeIfPresent(timeoutSeconds, forKey: .timeoutSeconds)
        try container.encodeIfPresent(allowNetwork, forKey: .allowNetwork)
    }

    /// Merges this patch onto the stored policy, preserving every field the
    /// request omits. A nil field is a no-op, so a dashboard edit to one knob
    /// never resets the rest of the `[bash]` section.
    /// - Parameter bash: Stored bash policy to mutate in place.
    /// - Throws: `ConfigError.validationError` when the rule list is empty,
    ///   a rule pattern is blank, the default action is unknown, or the
    ///   timeout falls outside 1-3600.
    public func applyBash(to bash: inout BashConfig) throws {
        if let enabled {
            bash.enabled = enabled
        }
        if let defaultAction {
            guard let action = BashPermissionAction(rawValue: defaultAction.lowercased()) else {
                throw ConfigError.validationError(
                    field: "bash.default_action",
                    message: "must be allow, ask, or deny (got '\(defaultAction)')"
                )
            }
            bash.defaultAction = action
        }
        if let rules {
            try BashConfig.validateRules(rules)
            bash.rules = rules
        }
        if let timeoutSeconds {
            try BashConfig.validateTimeoutSeconds(timeoutSeconds)
            bash.timeoutSeconds = timeoutSeconds
        }
        if let allowNetwork {
            bash.allowNetwork = allowNetwork
        }
    }
}

public extension UpdateSettingsRequest {
    /// Builds a request from a full bash snapshot, routing through the same
    /// merge path so snapshot callers keep working without hand-mapping fields.
    /// - Parameter bash: Complete bash policy.
    init(bash: BashConfig) {
        self.init(bash: BashSettingsUpdate(bash: bash))
    }
}

// MARK: - Bash Settings Merge

extension UpdateSettingsRequest {
    /// Merges a partial bash patch onto the stored policy, preserving every
    /// field the request omits. A nil patch is a no-op, so a dashboard edit
    /// elsewhere never resets the `[bash]` section. Validation stays
    /// single-sourced in `BashSettingsUpdate.applyBash(to:)` so the PUT and
    /// direct-merge paths agree with a clear 400 instead of persisting bad values.
    ///
    /// Internal so the shared settings `apply(to:)` keeps one merge path while
    /// the bash-specific logic lives beside its DTOs.
    func applyBash(to bash: inout BashConfig) throws {
        guard let update = self.bash else { return }
        try update.applyBash(to: &bash)
    }
}
