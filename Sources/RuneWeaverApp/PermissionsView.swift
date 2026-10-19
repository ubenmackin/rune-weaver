// Rune Weaver App — Permissions checklist window content.

import AppKit
import SwiftUI

/// Checklist of macOS permissions with live per-row affordances.
struct PermissionsView: View {
    @Bindable var viewModel: PermissionsViewModel
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions")
                    .font(.headline)
                Text("Rune Weaver works locally. These macOS permissions unlock messages, contacts, and desktop control. You can change them anytime.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.orderedKinds, id: \.self) { kind in
                        let status = viewModel.status(for: kind)
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: kind.systemImage)
                                .frame(width: 20)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(kind.title)
                                        .font(.subheadline)
                                        .bold()
                                    Spacer()
                                    Text(status.label)
                                        .font(.caption)
                                        .bold()
                                        .foregroundStyle(statusColor(for: status))
                                }
                                Text(kind.rationale)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            VStack(alignment: .trailing, spacing: 8) {
                                if !viewModel.didLoad {
                                    // Pre-first-read rows render loading instead of the fallback,
                                    // so the initial paint never flashes an affordance
                                    // before any live read lands.
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    switch PermissionActionsMapping.action(for: status) {
                                    case .none:
                                        EmptyView()
                                    case .enable:
                                        Button("Enable") {
                                            Task {
                                                await viewModel.perform(.enable, for: kind)
                                            }
                                        }
                                        .disabled(viewModel.isRefreshing)
                                        .controlSize(.small)
                                    case .openSettings:
                                        Button("Open System Settings") {
                                            Task {
                                                await viewModel.perform(.openSettings, for: kind)
                                            }
                                        }
                                        .disabled(viewModel.isRefreshing)
                                        .controlSize(.small)
                                    }
                                    // Capture, control, and history grants only apply at
                                    // launch, so the row offers a relaunch while missing
                                    // instead of leaving the owner to discover it.
                                    if kind == .fullDiskAccess || kind == .screenRecording || kind == .accessibility, status != .granted {
                                        Button("Relaunch") {
                                            viewModel.relaunchApp()
                                        }
                                        .controlSize(.small)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 20)
                        Divider()
                            .padding(.horizontal, 20)
                    }
                }
            }
            .frame(maxHeight: 420)

            Divider()

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
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 560, idealWidth: 600, maxHeight: 600)
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
