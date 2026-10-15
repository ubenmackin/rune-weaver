// Rune Weaver App — Permissions checklist window content.
//
// Purpose: Guides the owner through the macOS grants Rune Weaver needs for
// messages, contacts, and desktop control, with one honest affordance per row
// and no surprise prompts outside an explicit Enable press.
// Scope: Header copy plus one row per PermissionKind in declaration order plus
// footer actions; status colors, Enable versus Settings routing, and the
// capture-grant relaunch hint live here. Live reads, prompting, and relaunch
// mechanics stay in the view model and its seams.
// Architectural role: The single SwiftUI owner of Permissions presentation,
// keeping prompting behind user intent while background activation refreshes
// keep every row truthful when the owner returns from System Settings.

import AppKit
import SwiftUI

/// Checklist of macOS permissions with live per-row affordances.
struct PermissionsView: View {
    @Bindable var viewModel: PermissionsViewModel
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permissions")
                .font(.headline)
            Text("Rune Weaver works locally. These macOS permissions unlock messages, contacts, and desktop control. You can change them anytime.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Divider()

            ForEach(viewModel.orderedKinds, id: \.self) { kind in
                let status = viewModel.status(for: kind)
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: kind.systemImage)
                        .frame(width: 24)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(kind.title)
                            .font(.headline)
                        Text(kind.rationale)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(status.label)
                            .font(.callout)
                            .foregroundStyle(statusColor(for: status))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 8) {
                        if !viewModel.didLoad {
                            // Pre-first-read rows render loading instead of
                            // the unavailable fallback, so the initial paint
                            // never flashes Open System Settings before any
                            // live read lands.
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            switch PermissionActionsMapping.action(for: status) {
                            case .none:
                                EmptyView()
                            case .enable:
                                // The literal label stays the generic Enable
                                // per row; tool guidance phrases it as Enable
                                // for Contacts when pointing at this button on
                                // the Contacts row.
                                Button("Enable") {
                                    Task {
                                        await viewModel.perform(.enable, for: kind)
                                    }
                                }
                                .disabled(viewModel.isRefreshing)
                            case .openSettings:
                                Button("Open System Settings") {
                                    Task {
                                        await viewModel.perform(.openSettings, for: kind)
                                    }
                                }
                                .disabled(viewModel.isRefreshing)
                            }
                            // Screen capture, desktop control, and history
                            // grants only apply at launch, so the row offers
                            // a relaunch while the grant is missing instead
                            // of leaving the owner to discover it.
                            if kind == .fullDiskAccess || kind == .screenRecording || kind == .accessibility, status != .granted {
                                Button("Relaunch Rune Weaver") {
                                    viewModel.relaunchApp()
                                }
                            }
                        }
                    }
                }
                Divider()
            }

            HStack {
                Button("Check Again") {
                    Task {
                        await viewModel.refresh()
                    }
                }
                .disabled(viewModel.isRefreshing)
                if viewModel.isRefreshing {
                    // Shown only while a live re-read is in flight so a slow
                    // snapshot probe reads as progress, not a stall.
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("Done") {
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .task {
            // Initial live read plus activation refresh: returning from System
            // Settings re-enters the app, so every row reconciles without a
            // manual Check Again press.
            await viewModel.refresh()
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                await viewModel.refresh()
            }
        }
    }

    /// Row status color with denied emphasized and neutral states dimmed.
    private func statusColor(for status: PermissionStatus) -> Color {
        switch status {
        case .granted:
            .green
        case .denied:
            .red
        case .notDetermined, .deferred, .unavailable:
            .secondary
        }
    }
}
