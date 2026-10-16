// Rune Weaver App — Native macOS Permissions Window Controller.

import AppKit
import Foundation
import SwiftUI

@MainActor
public final class PermissionsWindowController: NSObject {
    public static let shared = PermissionsWindowController()

    private var window: NSWindow?
    private weak var model: AppModel?

    override private init() {
        super.init()
    }

    /// Displays the native Permissions window hosting the live checklist.
    public func show(model: AppModel) {
        // Retained weakly so closing the app never keeps the menu model alive
        // through the shared window alone.
        self.model = model
        // Fresh view model on every presentation so statuses re-read live
        // instead of reusing a stale snapshot from the previous open.
        let viewModel = PermissionsViewModel(
            probes: LivePermissionProbes(),
            actions: LivePermissionSystemActions()
        )
        let win = getOrCreateWindow(viewModel: viewModel)
        SingleInstanceHostedWindow.show(win)
    }

    private func getOrCreateWindow(viewModel: PermissionsViewModel) -> NSWindow {
        if let existing = window {
            // Re-root the checklist on every show so a relaunch elsewhere or
            // a Settings grant lands on fresh rows instead of cached state.
            existing.contentView = NSHostingView(
                rootView: PermissionsView(viewModel: viewModel) { [weak self] in
                    self?.window?.close()
                }
            )
            return existing
        }

        let permissionsWindow = SingleInstanceHostedWindow.makeWindow(
            title: "Permissions",
            autosaveName: "RuneWeaverPermissionsWindow",
            initialRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            minSize: NSSize(width: 560, height: 480),
            contentView: NSHostingView(
                rootView: PermissionsView(viewModel: viewModel) { [weak self] in
                    self?.window?.close()
                }
            )
        )
        permissionsWindow.delegate = self

        self.window = permissionsWindow
        return permissionsWindow
    }
}

// MARK: - NSWindowDelegate

extension PermissionsWindowController: NSWindowDelegate {
    public func windowWillClose(_: Notification) {
        // Closing counts as completing first-run guidance so the window opens
        // exactly once per install; the menu entry can still reopen it later.
        model?.markPermissionsOnboardingCompleted()
    }
}
