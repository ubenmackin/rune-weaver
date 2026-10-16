// Rune Weaver Tools — Accessibility trust check for desktop control.

import Foundation

#if canImport(ApplicationServices)
    import ApplicationServices
#endif

/// Queries macOS Accessibility trust for the calling process.
public enum DesktopPermissionCheck: Sendable {
    /// Returns true when the process is trusted for Accessibility input.
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
        private static func trustOptions(prompt: Bool) -> CFDictionary {
            // The SDK exposes this option key as shared mutable state, which Swift 6 treats as
            // unsafe to read from a concurrency-safe context even though the underlying string never
            // changes.
            ["AXTrustedCheckOptionPrompt" as CFString: prompt] as CFDictionary
        }
    #endif
}
