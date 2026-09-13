// Rune Weaver App — macOS Menu Bar Agent Application.
//
// Native menu bar extra (LSUIElement = 1) providing quick status,
// one-click dashboard launch, interactive approval decisions,
// scheduler status, settings link, and clean shutdown.

import SwiftUI

@main
struct RuneWeaverApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            AppMenuView(model: model)
        } label: {
            AppMenuLabel(model: model)
        }
        .menuBarExtraStyle(.menu)
    }
}

struct AppMenuLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: model.pendingApprovals.isEmpty ? "sparkles" : "exclamationmark.triangle.fill")
            if !model.pendingApprovals.isEmpty {
                Text("\(model.pendingApprovals.count)")
            }
        }
        .onAppear {
            model.start()
        }
    }
}

struct AppMenuView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Text("Rune Weaver Engine")
            .font(.headline)
        Text(model.serverStatus)
            .font(.caption)
        Text("Provider: \(model.providerName)")
            .font(.caption)

        Divider()

        Button("Open Web Dashboard") {
            model.openDashboard()
        }
        .keyboardShortcut("o", modifiers: [.command])

        Divider()

        Section("Pending Approvals (\(model.pendingApprovals.count))") {
            if model.pendingApprovals.isEmpty {
                Text("No pending approvals")
                    .disabled(true)
            } else {
                ForEach(model.pendingApprovals, id: \.id) { approval in
                    Menu("\(approval.toolName): \(approval.description.isEmpty ? "Requires confirmation" : approval.description)") {
                        Button("Approve") {
                            model.approve(id: approval.id)
                        }
                        Button("Deny") {
                            model.deny(id: approval.id)
                        }
                    }
                }
            }
        }

        Divider()

        Section("Scheduler") {
            Text("Next: \(model.nextScheduleText)")
            Text("Last: \(model.lastRunSummaryText)")
        }

        Divider()

        Button("Settings...") {
            model.openSettings()
        }
        .keyboardShortcut(",", modifiers: [.command])

        Divider()

        Button("Quit Rune Weaver") {
            model.quit()
        }
        .keyboardShortcut("q", modifiers: [.command])
    }
}
