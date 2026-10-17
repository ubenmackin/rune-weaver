// Rune Weaver Core — System-notice tool-name registry.

/// Single source for the tool names system notices file under. Both surfacing-only tiers key
/// assessment skipping and pending dedup on this registry, never on name prefixes.
public enum SystemNoticeTools {
    /// Fixed tool names carrying surfacing-only system notices.
    public static let toolNames: Set<String> = ["sovereign.mismatch", "security.probe"]

    /// Whether one tool name files a system notice.
    /// - Parameter name: Tool name to test.
    /// - Returns: True when the name is a registered system-notice tier.
    public static func isSystemNotice(_ name: String) -> Bool {
        toolNames.contains(name)
    }
}
