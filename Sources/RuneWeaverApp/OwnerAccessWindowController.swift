// Rune Weaver App — Native macOS Owner Access Window Controller.

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
