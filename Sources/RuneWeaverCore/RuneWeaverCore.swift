// Rune Weaver Core — Core module entry point.
//
// Single-sources the engine version so User-Agent strings and API versions
// cannot drift across tools, providers, and the service surface.

/// Canonical engine version shared by User-Agent strings and API versions.
public enum RuneWeaverVersion: Sendable {
    /// Engine release version served on `/health` and sent as User-Agent.
    public static let current = "0.1.0"
    /// User-Agent identifying engine fetches to origin servers.
    public static var userAgent: String {
        "rune-weaver/\(current)"
    }
}
