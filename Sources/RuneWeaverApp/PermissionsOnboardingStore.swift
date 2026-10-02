// Rune Weaver App — Permissions onboarding completion store and auto-open gate.
//
// Persists whether the owner has dismissed the Permissions window so first
// run shows guidance exactly once, and decides whether a launch should open
// the window at all. Owner-token onboarding outranks permissions onboarding:
// a fresh install without a token must finish token setup before hearing
// about privacy grants, otherwise the window competes with the blocking
// setup step.
//
// Scope: one boolean in UserDefaults plus the two-input auto-open rule. No
// TCC reads, no window presentation, no token state — callers supply the
// inputs and act on the verdict.
// Architectural role: durable first-run memory for the Permissions window,
// keeping show-once logic out of the view layer and directly testable.

import Foundation

/// Durable completion flag for the Permissions onboarding window.
///
/// Injected defaults keep tests hermetic: production passes the standard
/// store while tests pass an isolated suite that is torn down afterwards.
///
/// Unchecked Sendable is sound here because the only shared state is the
/// held UserDefaults, which is thread-safe for concurrent bool reads and
/// writes keyed by an immutable string, and the struct itself holds no
/// other mutable state.
public struct PermissionsOnboardingStore: @unchecked Sendable {
    /// Defaults key holding the completion flag.
    private static let storageKey = "RuneWeaver.permissionsOnboardingCompleted"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether the owner has already completed or dismissed the window.
    ///
    /// Reads live on every access so a relaunch in another process is
    /// visible without caching; absent means never completed.
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
///
/// Auto-open requires both that no owner token is needed and that onboarding
/// has not completed: a needed token means token setup owns this launch,
/// and a completed flag means the owner has already seen the guidance.
public enum PermissionsOnboarding {
    public static func shouldAutoOpen(needsOwnerToken: Bool, hasCompleted: Bool) -> Bool {
        !needsOwnerToken && !hasCompleted
    }
}
