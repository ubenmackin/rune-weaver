// Rune Weaver App — macOS Menu Bar Agent Application.

import AppKit
import RuneWeaverCore
import RuneWeaverTools
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak static var shared: AppDelegate?
    weak var model: AppModel?
    private var isTerminating = false

    override init() {
        super.init()
        Self.shared = self
        atexit {
            LlamaEmbeddingSupervisor.shared.stopSync()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let model {
            if isTerminating || model.isTerminated {
                return .terminateNow
            }
            isTerminating = true
            Task {
                await model.stopForQuit()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        Task {
            await SearXNGEnsurer.bestEffortStop()
            LlamaEmbeddingSupervisor.shared.stopSync()
            await MainActor.run {
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_: Notification) {
        LlamaEmbeddingSupervisor.shared.stopSync()
    }
}

@main
struct RuneWeaverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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

    /// Menu-bar indicator priority, highest first.
    ///
    /// Ordering keeps a refused bind visible in the bar while the dropdown
    /// carries the actionable copy, keeps a parked approval visible above all
    /// liveness, surfaces boot and restart progress above activity, and lets
    /// desktop outrank indexing so Emergency Stop is never hidden behind a
    /// sync mark. Stays internal (not private) so MenuLabelStateTests can pin
    /// the priority table directly; `View` is a struct, never actor-isolated,
    /// so no `nonisolated` is needed.
    enum LabelState {
        case failed
        case approvals
        case starting
        case restarting
        case desktop
        case indexing
        case idle
    }

    /// Selects the single menu-bar indicator for a snapshot of model flags.
    ///
    /// Failure outranks everything, approvals outrank progress and activity,
    /// and boot progress outranks activity so a cold launch never reads as
    /// idle. A restart names the in-flight hop even after the running flag
    /// flips, which is why it ignores `isRunning`. Stays internal alongside
    /// `LabelState` for the priority-table tests.
    static func labelState(
        isRunning: Bool,
        isServerFailed: Bool,
        isRestarting: Bool,
        hasApprovals: Bool,
        isDesktopActive: Bool,
        isIndexing: Bool
    ) -> LabelState {
        if isServerFailed {
            return .failed
        }
        if hasApprovals {
            return .approvals
        }
        if isRestarting {
            return .restarting
        }
        if !isRunning {
            return .starting
        }
        if isDesktopActive {
            return .desktop
        }
        if isIndexing {
            return .indexing
        }
        return .idle
    }

    var body: some View {
        HStack(spacing: 4) {
            switch Self.labelState(
                isRunning: model.isRunning,
                isServerFailed: model.isServerFailed,
                isRestarting: model.isRestarting,
                hasApprovals: !model.pendingApprovals.isEmpty,
                isDesktopActive: model.isDesktopActive,
                isIndexing: model.isIndexing
            ) {
            case .failed:
                // Failure shows a distinct octagon in the bar so a refused bind
                // never reads as healthy idle; the dropdown still owns the
                // actionable copy plus recovery, so the bar stays a mark
                // without duplicating text.
                Image(systemName: "exclamationmark.octagon.fill")
            case .approvals:
                // Approvals outrank every activity indicator so a parked write
                // is never hidden behind desktop or indexing liveness.
                Image(systemName: "exclamationmark.triangle.fill")
                Text("\(model.pendingApprovals.count)")
            case .starting:
                // Cold boot holds the running flag down, so the bar names the
                // wait instead of reading as idle before the bind resolves.
                ProgressView()
                    .controlSize(.small)
                Text("Starting...")
            case .restarting:
                // A token-adopt restart holds the boot flag across the hop, so
                // the bar names the in-flight state regardless of the flag.
                ProgressView()
                    .controlSize(.small)
                Text("Restarting...")
            case .desktop:
                Image(systemName: "eye.fill")
            case .indexing:
                // A run in flight shows the sync indicator plus text; idle
                // falls through to the default mark.
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("Indexing")
            case .idle:
                Image(systemName: "sparkles")
            }
        }
        .onAppear {
            AppDelegate.shared?.model = model
            model.start()
            if model.needsOwnerToken {
                showOnboarding = true
            } else if model.isRunning,
                      PermissionsOnboarding.shouldAutoOpen(
                          needsOwnerToken: model.needsOwnerToken,
                          hasCompleted: model.hasCompletedPermissionsOnboarding
                      )
            {
                // Owner-token onboarding outranks permissions guidance: only
                // a provisioned launch with unseen guidance opens the window,
                // so first run never competes with the blocking token sheet.
                // Gated on isRunning so first launch waits for boot to resolve
                // the token posture instead of reading the pre-boot flag.
                model.openPermissions()
            }
            // First launch with boot still resolving opens nothing here; the
            // isRunning change below auto-opens once provisioning is known.
        }
        .onChange(of: model.needsOwnerToken) { _, newValue in
            if newValue {
                showOnboarding = true
            }
        }
        .onChange(of: model.isRunning) { _, running in
            // Deferred permissions auto-open: boot has resolved, so the token
            // posture is known and guidance opens only for a provisioned
            // launch with unseen onboarding, never ahead of the token sheet.
            if running, !showOnboarding,
               PermissionsOnboarding.shouldAutoOpen(
                   needsOwnerToken: model.needsOwnerToken,
                   hasCompleted: model.hasCompletedPermissionsOnboarding
               )
            {
                model.openPermissions()
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
            // A token sheet that resolved the missing credential unblocks
            // permissions guidance: a still-tokenless dismissal keeps the
            // token path owning this launch instead.
            if PermissionsOnboarding.shouldAutoOpen(needsOwnerToken: model.needsOwnerToken, hasCompleted: model.hasCompletedPermissionsOnboarding) {
                model.openPermissions()
            }
        }, content: {
            OwnerOnboardingView(model: model)
        })
    }
}

struct AppMenuView: View {
    @Bindable var model: AppModel

    var body: some View {
        // A healthy provisioned server needs no menu chrome, so the Server
        // section stays hidden until it earns attention: a failed bind or a
        // tokenless local-only boot. Hiding both the section and its divider
        // keeps the steady-state menu free of a leading separator.
        // The embedded service can refuse a bind (for example an all-interfaces
        // address without an owner token), and that refusal is otherwise only
        // visible in the log. The title stays short via the model helper and
        // the detail stays a one-line summary so the menu keeps a narrow
        // width; token recovery flows through the single bottom Owner Access
        // entry plus a full restart, never a live endpoint.
        if model.isServerFailed || model.needsOwnerToken {
            Section("Server") {
                Text(model.serverStatus)
                if model.isRestarting {
                    // A restart holds the boot flag across the hop, so the menu
                    // names the in-flight state instead of offering a second
                    // concurrent Retry that would race the bind.
                    ProgressView("Restarting…")
                }
                if model.isServerFailed {
                    // Failed banner shows only while the flag holds; the detail is
                    // a short summary so a long bind error never widens the menu.
                    if let detail = model.serverStatusDetail {
                        Text(detail)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                    // Single token path lives at the bottom Owner Access entry;
                    // this hint points there so no duplicate button widens the menu.
                    Text("Add a token in Owner Access below, then Retry.")
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    // A bad hostname has no native editor, so recovery is a config
                    // file edit followed by a full restart via Retry.
                    Text("To fix the hostname, edit config.toml [server] hostname, then Retry.")
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .truncationMode(.tail)
                    // Full restart adopts a new token or hostname; never
                    // live-reloads, and never navigates while the server is down.
                    Button(model.isRestarting ? "Restarting…" : "Retry Server") {
                        model.restartServerToAdoptToken()
                    }
                    .disabled(model.isRestarting)
                } else if model.needsOwnerToken {
                    // Healthy loopback boot without a token stays local-only; the
                    // bottom Owner Access entry remains the sole token action.
                    Text("Local only — add a token in Owner Access to enable LAN binds.")
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Divider()
        }

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
                // Every request kind — including question.ask and desktop.resume
                // — decides in the dashboard inbox through the shared decision
                // contract, so the menu bar owns no approve/deny control: the row
                // reports the parked count and routes there instead of deciding
                // natively.
                Button("Attention required (\(model.pendingApprovals.count))") {
                    model.openInbox()
                }
                .disabled(!model.isDashboardAvailable)
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

        // Armed-but-idle desktop control stays out of the menu; the section
        // appears while a batch runs or while paused waiting for operator resume,
        // so Emergency Stop / Resume is reachable exactly when needed.
        if model.isDesktopActive || model.hasPausedDesktopAutomation {
            Divider()

            Section("Desktop Control") {
                if model.hasPausedDesktopAutomation {
                    HStack {
                        Image(systemName: "pause.circle.fill")
                            .foregroundColor(.yellow)
                        Text("Paused (Operator took over)")
                    }
                    // Resuming or cancelling the parked desktop.resume request
                    // is an approval decision like any other, so the menu only
                    // routes to the inbox where the decision can be made.
                    Button("Open Inbox") {
                        model.openInbox()
                    }
                    .disabled(!model.isDashboardAvailable)
                } else {
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

        Button("Permissions…") {
            model.openPermissions()
        }

        Divider()

        Button("Quit Rune Weaver") {
            model.quit()
        }
    }
}
