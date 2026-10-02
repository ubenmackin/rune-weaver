// Rune Weaver App — Native macOS Owner Access Window Controller.
//
// Purpose: Presents the owner-token status plus generate/rotate flow from the
// menu-bar app in a native window, without opening Terminal or the dashboard,
// while keeping the raw secret visible exactly once through the hosted section.
// Scope: One retained NSWindow hosting the SwiftUI OwnerTokenSettingsSection,
// shared through the singleton and re-rooted on every show so model state
// stays fresh; frame persistence plus centering fallback plus activation ride
// the shared single-instance helper.
// Architectural role: Keeps AppKit window lifecycle (creation, autosave,
// delegate retention for fast re-opening) separate from the SwiftUI settings
// content, so the menu model stays the sole owner of token state and the raw
// secret never reaches logs, URLs, or any store besides the auth persistence.

import AppKit
import Foundation
import SwiftUI

@MainActor
public final class OwnerAccessWindowController: NSObject {
    public static let shared = OwnerAccessWindowController()

    private var window: NSWindow?

    override private init() {
        super.init()
    }

    /// Displays the native Owner Access window hosting OwnerTokenSettingsSection.
    public func show(model: AppModel) {
        let win = getOrCreateWindow(model: model)
        SingleInstanceHostedWindow.show(win)
    }

    private func getOrCreateWindow(model: AppModel) -> NSWindow {
        if let existing = window {
            // Re-assign hosting view root view so model state remains fresh
            existing.contentView = NSHostingView(rootView: OwnerTokenSettingsSection(model: model).padding(20))
            return existing
        }

        let accessWindow = SingleInstanceHostedWindow.makeWindow(
            title: "Owner Access",
            autosaveName: "RuneWeaverOwnerAccessWindow",
            initialRect: NSRect(x: 0, y: 0, width: 540, height: 460),
            minSize: NSSize(width: 480, height: 380),
            contentView: NSHostingView(rootView: OwnerTokenSettingsSection(model: model).padding(20))
        )
        accessWindow.delegate = self

        self.window = accessWindow
        return accessWindow
    }
}

// MARK: - NSWindowDelegate

extension OwnerAccessWindowController: NSWindowDelegate {
    public func windowWillClose(_: Notification) {
        // Window is hidden and retained for fast re-opening
    }
}
