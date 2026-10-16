// Rune Weaver App — Permissions onboarding completion store and auto-open gate.

import Foundation

/// Durable completion flag for the Permissions onboarding window.
@MainActor
public struct PermissionsOnboardingStore {
    /// Defaults key holding the completion flag.
    private static let storageKey = "RuneWeaver.permissionsOnboardingCompleted"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether the owner has already completed or dismissed the window. Reads live on every access
    /// so a relaunch in another process is visible without caching; absent means never completed.
    public var isCompleted: Bool {
        defaults.bool(forKey: Self.storageKey)
    }

    /// Marks onboarding complete; closing the window calls this unconditionally.
    public func markCompleted() {
        // UserDefaults is a reference type, so a non-mutating call persists
        // without copying the struct around the view layer.
        defaults.set(true, forKey: Self.storageKey)
    }
}

/// First-run launch gate for the Permissions window.
enum PermissionsOnboarding {
    static func shouldAutoOpen(needsOwnerToken: Bool, hasCompleted: Bool) -> Bool {
        !needsOwnerToken && !hasCompleted
    }
}
