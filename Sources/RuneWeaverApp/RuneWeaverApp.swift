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
    @Bindable var model: AppModel
    /// Separate presentation state so Esc or swipe dismissal only hides the
    /// sheet while the posture flag keeps the Server-section guidance.
    @State private var showOnboarding = false

    var body: some View {
        HStack(spacing: 4) {
            if !model.pendingApprovals.isEmpty {
                // Approvals outrank every activity indicator so a parked write
                // is never hidden behind desktop or indexing liveness.
                Image(systemName: "exclamationmark.triangle.fill")
                Text("\(model.pendingApprovals.count)")
            } else if model.isDesktopActive {
                Image(systemName: "eye.fill")
            } else if model.isIndexing {
                // A run in flight shows the sync indicator plus text; idle
                // falls through to the default mark.
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("Indexing")
            } else {
                Image(systemName: "sparkles")
            }
        }
        .onAppear {
            model.start()
            if model.needsOwnerToken {
                showOnboarding = true
            }
        }
        .onChange(of: model.needsOwnerToken) { _, newValue in
            if newValue {
                showOnboarding = true
            }
        }
        // First-run onboarding sheet driven by separate presentation state
        // seeded from the boot-time posture flag, so the show-once copy plus
        // adopting restart never require Terminal. Dismissing without minting
        // defers to Settings, which stays one click away in the menu.
        .sheet(isPresented: $showOnboarding, onDismiss: {
            // Dismissal only hides presentation; reassert the posture flag
            // while the service still has no token so the Server section
            // keeps offering generation.
            if model.serverContext?.auth == nil {
                model.needsOwnerToken = true
            }
        }, content: {
            OwnerOnboardingView(model: model)
        })
    }
}

struct AppMenuView: View {
    @Bindable var model: AppModel

    var body: some View {
        // The embedded service can refuse a bind (for example an all-interfaces
        // address without an owner token), and that refusal is otherwise only
        // visible in the log. Surfacing the live status line plus the failure
        // reason keeps token recovery inside the menu: Owner Access, then retry.
        Section("Server") {
            Text(model.serverStatus)
            if model.isRestarting {
                // A restart holds the boot flag across the hop, so the menu
                // names the in-flight state instead of offering a second
                // concurrent Retry that would race the bind.
                ProgressView("Restarting…")
            }
            if model.serverStatus.hasPrefix("Failed") {
                // Token recovery stays Terminal-free through Owner Access plus
                // Retry; a bad hostname has no native editor and Web Settings
                // needs a live loopback server, so it requires a config.toml
                // file edit before Retry.
                Text(
                    "Missing owner token? Add one in Owner Access below, then Retry — no Terminal needed. "
                        + "To fix the hostname, edit ~/.runeweaver/config.toml ([server] hostname), then Retry. "
                        + "Web Settings is unavailable while the server is down."
                )
                .foregroundStyle(.secondary)
                Button("Open Settings") {
                    model.openSettings()
                }
                .disabled(!model.isDashboardAvailable)
                Button("Owner Access...") {
                    model.openOwnerAccess()
                }
                Button(model.isRestarting ? "Restarting…" : "Retry Server") {
                    model.restartServerToAdoptToken()
                }
                .disabled(model.isRestarting)
            } else if model.needsOwnerToken {
                // Loopback stays usable before a token exists, but any LAN bind
                // stays refused; pointing at Settings here keeps first-run
                // onboarding one click away instead of a silent local-only boot.
                Text("Local use only — generate an owner token in Settings to enable LAN binds.")
                    .foregroundStyle(.secondary)
                Button("Open Settings") {
                    model.openSettings()
                }
                .disabled(!model.isDashboardAvailable)
                Button("Set Up Owner Access...") {
                    model.openOwnerAccess()
                }
            }
        }

        Divider()

        Button("Open Web Dashboard") {
            model.openDashboard()
        }
        .disabled(!model.isDashboardAvailable)

        if !model.activeChats.isEmpty || !model.pendingApprovals.isEmpty {
            Divider()

            if !model.activeChats.isEmpty {
                Section(model.activeChats.count == 1 ? "Active Chat" : "Active Chats (\(model.activeChats.count))") {
                    ForEach(model.activeChats) { chat in
                        Button(chat.title) {
                            model.openChat(id: chat.id)
                        }
                        .disabled(!model.isDashboardAvailable)
                    }
                }
            }

            if !model.pendingApprovals.isEmpty {
                Section("Pending Approvals (\(model.pendingApprovals.count))") {
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
        }

        Divider()

        Section("Scheduler") {
            Text("Next: \(model.nextScheduleText)")
            Text("Last: \(model.lastRunSummaryText)")
        }

        if model.isIndexing {
            Divider()

            // Shown only while a run is in flight; the shared refresh tick
            // drives it so no second cadence is needed. Counts prefer the
            // coordinator live snapshot with committed store counts as the
            // fallback, and the current file truncates to menu width.
            Section("Indexing") {
                Text("\(model.indexTriggerText) · \(model.indexElapsedText)")
                Text("Scanned \(model.indexScannedCount) · Indexed \(model.indexIndexedCount)")
                if let current = model.indexCurrentFile {
                    Text(current)
                        .foregroundStyle(.secondary)
                }
                Button("Open Index Status") {
                    model.openIndexStatus()
                }
                .disabled(!model.isDashboardAvailable)
                Button(model.isCancellingIndex ? "Cancelling…" : "Cancel Index Run") {
                    model.cancelIndexRun()
                }
                .disabled(model.isCancellingIndex)
            }
        }

        if model.isDesktopEnabled {
            Divider()

            Section("Desktop Control") {
                HStack {
                    Image(systemName: model.isDesktopActive ? "eye.fill" : "eye.slash")
                    Text(model.isDesktopActive ? "Active" : "Idle")
                }
                if model.isDesktopActive {
                    Button("⛔ Emergency Stop") {
                        model.emergencyStopDesktop()
                    }
                }
            }
        }

        Divider()

        Button("Settings...") {
            model.openSettings()
        }
        .disabled(!model.isDashboardAvailable)

        // Native token authority stays reachable while the service is healthy,
        // when the Server section shows no onboarding affordance: status plus
        // Rotate without Terminal live in the Settings scene.
        Button("Owner Access...") {
            model.openOwnerAccess()
        }

        Divider()

        Button("Quit Rune Weaver") {
            model.quit()
        }
    }
}
