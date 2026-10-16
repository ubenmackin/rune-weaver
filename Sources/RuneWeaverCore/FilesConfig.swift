// Rune Weaver Core — Files tool access policy (`[files]`).

import Foundation

/// Write posture for the `files.write` tool. A forced write is never rejected for contradicting the
/// setting — it proceeds in the forced mode and names the override in its envelope so the outcome
/// stays honest.
public enum FilesWriteMode: String, Sendable, Codable, Equatable, CaseIterable {
    /// The agent picks per call; an omitted call mode stages for review.
    case model
    /// Every write is staged for review, even when the call asks for live.
    case staged
    /// Every write applies live with a `.rune_backup_` rollback copy.
    case live
}

/// Per-path write posture from a `[[files.write_paths]]` entry.
public enum FilesWritePathPosture: String, Sendable, Codable, Equatable, CaseIterable {
    /// Applies the write live with a `.rune_backup_` rollback copy.
    case live
    /// Stages the write for review in a `.rune_` sibling.
    case stage
    /// Parks an approval request before any disk mutation.
    case ask
    /// Refuses the write.
    case deny
}

/// One `[[files.write_paths]]` entry: a path and the posture a matching write takes.
public struct FilesWritePathRule: Sendable, Equatable, Codable {
    /// Path the rule covers (`~` expands to home); descendants match too.
    public var path: String
    /// Posture a matching write takes.
    public var posture: FilesWritePathPosture

    /// Per-path postures seeded when `write_paths` is absent: the
    /// personal-data directories ask, while the working directories stage.
    public static let defaultRules: [FilesWritePathRule] = [
        FilesWritePathRule(path: "~/Library", posture: .ask),
        FilesWritePathRule(path: "~/Photos", posture: .ask),
        FilesWritePathRule(path: "~/Documents", posture: .stage),
        FilesWritePathRule(path: "~/Desktop", posture: .stage),
        FilesWritePathRule(path: "~/Downloads", posture: .stage)
    ]

    /// Largest rule list `[[files.write_paths]]` may carry.
    public static let maxRuleCount = 50
    /// Longest path one rule may carry.
    public static let maxPathLength = 1024

    /// Creates a write-path rule.
    public init(path: String, posture: FilesWritePathPosture) {
        self.path = path
        self.posture = posture
    }
}

/// `[files]` — file-tool access policy.
public struct FilesConfig: Sendable, Equatable {
    /// Glob deny patterns enforced by the shared file access guard.
    public var denyPatterns: [String]
    /// Allowed root directories for file reads (`~` expands to home).
    public var allowRoots: [String]
    /// Whether deny hits escalate to approval instead of hard denial.
    public var requireApprovalOnDeny: Bool
    /// Forced write posture for `files.write`; `.model` defers to the per-call mode.
    public var writeMode: FilesWriteMode
    /// Per-path write postures evaluated above the global `write_mode`.
    public var writePathRules: [FilesWritePathRule]

    /// Default deny patterns enforced by the shared file access guard.
    public static let defaultDenyPatterns = [
        ".env*",
        ".netrc",
        "secrets.json",
        "config.toml",
        "*.pem",
        "*.key",
        "*keychain*",
        ".ssh/*",
        ".aws/*",
        ".runeweaver/memory/*",
        ".runeweaver/memory/vectors/*",
        ".runeweaver/browser_profiles/*",
        ".runeweaver/policy.toml",
        ".runeweaver/auth_token",
        ".runeweaver/searxng/*",
        ".git-credentials",
        ".gitcookies",
        ".rclone.conf",
        ".npmrc",
        ".pypirc",
        ".Xauthority",
        ".emulator_console_auth_token",
        ".gnupg/*",
        ".kube/*",
        ".docker/*",
        ".config/gcloud/*",
        ".chia_keys/*",
        "*_history",
        ".zsh_sessions/*"
    ]
    /// Default allowed roots (home directory).
    public static let defaultAllowRoots = ["~"]
    /// Default escalation for deny hits.
    public static let defaultRequireApprovalOnDeny = true
    /// Default write posture: the agent chooses the mode per call.
    public static let defaultWriteMode: FilesWriteMode = .model

    /// Creates a files config.
    public init(
        denyPatterns: [String] = defaultDenyPatterns,
        allowRoots: [String] = defaultAllowRoots,
        requireApprovalOnDeny: Bool = defaultRequireApprovalOnDeny,
        writeMode: FilesWriteMode = defaultWriteMode,
        writePathRules: [FilesWritePathRule] = FilesWritePathRule.defaultRules
    ) {
        self.denyPatterns = denyPatterns
        self.allowRoots = allowRoots
        self.requireApprovalOnDeny = requireApprovalOnDeny
        self.writeMode = writeMode
        self.writePathRules = writePathRules
    }

    private enum CodingKeys: String, CodingKey {
        case denyPatterns
        case allowRoots
        case requireApprovalOnDeny
        case writeMode
        case writePathRules
    }
}

extension FilesConfig: Codable {
    /// Decodes a files config, defaulting omitted keys.
    /// - Parameter decoder: Decoder for the config document.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        denyPatterns = try container.decodeIfPresent([String].self, forKey: .denyPatterns) ?? Self.defaultDenyPatterns
        allowRoots = try container.decodeIfPresent([String].self, forKey: .allowRoots) ?? Self.defaultAllowRoots
        requireApprovalOnDeny = try container.decodeIfPresent(Bool.self, forKey: .requireApprovalOnDeny) ?? Self.defaultRequireApprovalOnDeny
        writeMode = try container.decodeIfPresent(FilesWriteMode.self, forKey: .writeMode) ?? Self.defaultWriteMode
        // An absent list seeds the documented defaults while an explicit empty
        // array stays empty: an owner who cleared every rule opted out.
        writePathRules = try container.decodeIfPresent([FilesWritePathRule].self, forKey: .writePathRules) ?? FilesWritePathRule.defaultRules
    }

    /// Encodes a files config including deny patterns and roots.
    /// - Parameter encoder: Encoder for the config document.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(denyPatterns, forKey: .denyPatterns)
        try container.encode(allowRoots, forKey: .allowRoots)
        try container.encode(requireApprovalOnDeny, forKey: .requireApprovalOnDeny)
        try container.encode(writeMode, forKey: .writeMode)
        try container.encode(writePathRules, forKey: .writePathRules)
    }
}
