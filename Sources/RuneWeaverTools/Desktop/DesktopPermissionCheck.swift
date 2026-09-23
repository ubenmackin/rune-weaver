// Rune Weaver Tools — Accessibility trust check for desktop control.
//
// Desktop control synthesizes input through CGEvent, which macOS gates behind
// the Accessibility trust database. This helper isolates that TCC query so the
// control bridge can fail closed before posting any event, and so the menu-bar
// app can surface the system prompt on explicit user intent instead of
// interrupting an autonomous turn mid-batch.

import Foundation

#if canImport(ApplicationServices)
    import ApplicationServices
#endif

/// Queries macOS Accessibility trust for the calling process.
///
/// The two entry points differ only in prompting behavior: the silent check
/// keeps autonomous turns dialog-free, while the requesting variant is
/// reserved for moments when the operator has just asked for desktop control.
///
/// TCC prompt calls are isolated to the main actor because the system dialog
/// takes focus and the underlying AppKit query expects main-thread execution;
/// hopping here keeps arbitrary async executors from invoking TCC off-thread
/// under Swift 6.
public enum DesktopPermissionCheck: Sendable {
    /// Returns true when the process is trusted for Accessibility input.
    ///
    /// Uses a non-prompting query so merely attempting a batch never pops a
    /// system dialog mid-turn; passing `false` still registers the app in the
    /// Privacy & Security pane so the operator can approve it later.
    @MainActor
    public static func isAccessibilityTrusted() -> Bool {
        #if canImport(ApplicationServices)
            return AXIsProcessTrustedWithOptions(trustOptions(prompt: false))
        #else
            // Platforms without TCC have no Accessibility gate; returning true
            // here lets the control bridge fall through to its
            // unsupported-platform error, which remains the fail-closed signal.
            return true
        #endif
    }

    /// Requests Accessibility trust, showing the macOS system prompt when needed.
    ///
    /// Call this only in direct response to the operator enabling desktop
    /// control (for example the menu-bar toggle), because the system dialog
    /// takes focus and would derail an in-flight turn. The prompt is
    /// asynchronous from the caller's perspective: the return value reflects
    /// trust at call time, so callers re-check after the user responds.
    /// - Returns: Whether the process is trusted right now.
    @MainActor
    @discardableResult
    public static func requestAccessibilityTrust() -> Bool {
        #if canImport(ApplicationServices)
            return AXIsProcessTrustedWithOptions(trustOptions(prompt: true))
        #else
            // No TCC gate off macOS; mirror the silent check so both paths
            // agree and downstream platform handling stays authoritative.
            return true
        #endif
    }

    #if canImport(ApplicationServices)
        /// Builds the options dictionary for the Accessibility trust query.
        ///
        /// The prompt flag selects between the silent check used mid-turn and the
        /// user-visible request used on explicit operator intent, so both entry
        /// points share one construction path instead of duplicating it.
        private static func trustOptions(prompt: Bool) -> CFDictionary {
            // The SDK exposes this option key as shared mutable state, which Swift 6
            // treats as unsafe to read from a concurrency-safe context even though
            // the underlying string never changes. Spelling the documented key value
            // directly keeps the query on the sanctioned Accessibility API with the
            // same key it always had, without touching shared mutable state.
            ["AXTrustedCheckOptionPrompt" as CFString: prompt] as CFDictionary
        }
    #endif
}
