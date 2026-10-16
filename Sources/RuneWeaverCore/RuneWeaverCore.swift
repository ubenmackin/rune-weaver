// Rune Weaver Core — Core module entry point.

/// Canonical engine version shared by User-Agent strings and API versions.
public enum RuneWeaverVersion: Sendable {
    /// Engine release version served on `/health` and sent as User-Agent.
    public static var current: String {
        RuneWeaverGeneratedVersion.version
    }

    /// User-Agent identifying engine fetches to origin servers.
    public static var userAgent: String {
        "rune-weaver/\(current)"
    }
}
