// Rune Weaver App — macOS Menu Bar Agent Application.

import RuneWeaverCore
import SwiftUI

@main
struct RuneWeaverApp: App {
    @State private var model = AppModel()

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
    var model: AppModel

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
    var model: AppModel

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
                        Menu("Approve (This Target)") {
                            ForEach(TrustDuration.allCases, id: \.self) { duration in
                                Button(duration.displayName) {
                                    model.approve(id: approval.id, duration: duration, widen: false)
                                }
                            }
                        }
                        Menu("Approve for Any Target") {
                            // Widening grants trust beyond the single target, which
                            // only a durable tier can express; "only this time"
                            // stores no grant at all, so it is excluded by
                            // construction. Deriving the eligible set from allCases
                            // keeps a future durable tier widen-eligible here
                            // without a second list to keep in sync.
                            ForEach(TrustDuration.allCases.filter { $0 != .thisTime }, id: \.self) { duration in
                                Button(duration.displayName) {
                                    model.approve(id: approval.id, duration: duration, widen: true)
                                }
                            }
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
