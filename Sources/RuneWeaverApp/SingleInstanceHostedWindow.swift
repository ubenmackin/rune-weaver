// Rune Weaver App — Shared single-instance hosted window helpers.

import AppKit
import Foundation

/// Shared factory for single-instance hosted windows.
@MainActor
enum SingleInstanceHostedWindow {
    /// Creates a retained single-instance window hosting the given view.
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
    static func show(_ window: NSWindow) {
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
