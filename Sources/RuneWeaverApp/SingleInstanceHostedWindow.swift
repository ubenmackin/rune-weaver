// Rune Weaver App — Shared single-instance hosted window helpers.
//
// Purpose: Presents native single-instance windows hosting SwiftUI content
// from the menu-bar app, without duplicating creation, frame persistence, or
// activation across each controller.
// Scope: One factory for a retained NSWindow plus one frontmost helper;
// per-window titles, sizes, autosave names, hosted roots, and delegates stay
// in their owning controllers so each window keeps its own content.
// Architectural role: The single AppKit window-lifecycle owner shared by the
// Permissions and Owner Access controllers, keeping frame autosave plus
// centering fallback plus activation identical while content stays separate.

import AppKit
import Foundation

/// Shared factory for single-instance hosted windows.
///
/// Both the Permissions and Owner Access windows are singletons retaining one
/// NSWindow, re-rooted on every show so state stays fresh; centralizing the
/// style mask, autosave, centering fallback, and activation keeps the two
/// windows behaving identically without copy-paste.
@MainActor
enum SingleInstanceHostedWindow {
    /// Creates a retained single-instance window hosting the given view.
    ///
    /// Sets the shared titled plus closable plus miniaturizable plus resizable
    /// mask, persists the frame under the autosave name with centering as the
    /// fallback, and keeps the window retained for fast re-opening.
    /// - Parameters:
    ///   - title: Window title shown in the title bar.
    ///   - autosaveName: Frame autosave name for persistence.
    ///   - initialRect: Initial content rect before any saved frame applies.
    ///   - minSize: Minimum window size.
    ///   - contentView: Hosted SwiftUI root already wrapped for AppKit.
    /// - Returns: Configured window awaiting delegate assignment by the caller.
    static func makeWindow(
        title: String,
        autosaveName: String,
        initialRect: NSRect,
        minSize: NSSize,
        contentView: NSView
    ) -> NSWindow {
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let window = NSWindow(contentRect: initialRect, styleMask: styleMask, backing: .buffered, defer: false)
        window.title = title
        window.minSize = minSize
        window.setFrameAutosaveName(autosaveName)
        window.isReleasedWhenClosed = false
        window.contentView = contentView
        if !window.setFrameUsingName(autosaveName) {
            window.center()
        }
        return window
    }

    /// Brings a single-instance window frontmost.
    ///
    /// Orders front regardless plus makes key plus activates the app, so the
    /// window appears above other windows when opened from the menu.
    /// - Parameter window: Window to show.
    static func show(_ window: NSWindow) {
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
