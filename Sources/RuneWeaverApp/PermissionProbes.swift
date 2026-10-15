// Rune Weaver App — Live permission probes and system actions.
//
// Reads the current TCC posture without prompting on any status call and
// initiates consent only from an explicit request call wired to a button.
// Status reads stay silent so background refreshes and window-appear checks
// never steal focus; request calls use the prompting variants because the
// owner just pressed Enable. Full Disk Access has no prompt API, so its
// request re-reads the snapshot probe and lets the rationale point at
// System Settings instead.
//
// Scope: live reads plus explicit requests plus Settings deep links and
// relaunch. No window layout, no persistence, no copy — those belong to the
// vocabulary and the onboarding store.
// Architectural role: the single TCC-query owner in the app target, keeping
// every consent prompt behind explicit user intent while tools and background
// work never initiate prompts.

import AppKit
import ApplicationServices
import Contacts
import EventKit
import Foundation
import RuneWeaverCore
import RuneWeaverTools

/// Silent reads plus explicit requests behind one seam for tests.
public protocol PermissionProbing: Sendable {
    func status(_ kind: PermissionKind) async -> PermissionStatus
    func request(_ kind: PermissionKind) async -> PermissionStatus
}

/// Settings navigation plus relaunch behind one seam for tests.
public protocol PermissionSystemActing: Sendable {
    @MainActor func open(_ pane: PermissionPane)
    @MainActor func relaunchApp()
}

/// Live Settings navigation and relaunch.
///
/// Opening jumps straight to the privacy pane so the owner never hunts from
/// the top level; relaunch spawns a fresh instance before terminating so a
/// newly granted Screen Recording or Accessibility grant takes effect.
struct LivePermissionSystemActions: PermissionSystemActing {
    @MainActor
    func open(_ pane: PermissionPane) {
        // A missing link shape opens nothing rather than a wrong section;
        // the pane URLs are versioned by the vocabulary file.
        guard let url = pane.url else { return }
        NSWorkspace.shared.open(url)
    }

    @MainActor
    func relaunchApp() {
        // A new instance first, then terminate: Screen Recording and
        // Accessibility grants only apply at launch, so terminating without
        // spawning would leave the owner with no running app.
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config)
        NSApp.terminate(nil)
    }
}

/// Live TCC reads honoring the no-prompt-on-status invariant.
///
/// Contacts reads the cached authorization; Calendars and Reminders read the
/// silent EventKit authorization; Accessibility and Screen Recording
/// use their silent preflights; Full Disk Access snapshots the Messages
/// database in an isolated probe; Automation queries Messages without asking.
/// Request paths switch to the prompting variants, except Full Disk Access
/// which has no prompt and simply re-reads.
struct LivePermissionProbes: PermissionProbing {
    func status(_ kind: PermissionKind) async -> PermissionStatus {
        switch kind {
        case .contacts:
            // Cached authorization only; never prompts, so safe on appear
            // and on activation refresh.
            let current = CNContactStore.authorizationStatus(for: .contacts)
            return PermissionStatusMapping.contacts(current)
        case .calendars:
            // Silent EventKit read; never prompts, so safe on appear
            // and on activation refresh.
            return eventKitStatus(for: .event)
        case .reminders:
            // Silent EventKit read; never prompts, so safe on appear
            // and on activation refresh.
            return eventKitStatus(for: .reminder)
        case .accessibility:
            // Silent trust query on the main actor because the underlying
            // TCC call expects main-thread execution.
            let trusted = await MainActor.run {
                DesktopPermissionCheck.isAccessibilityTrusted()
            }
            return PermissionStatusMapping.accessibility(trusted: trusted)
        case .screenRecording:
            let hasAccess = await MainActor.run {
                DesktopCaptureBridge.hasScreenRecordingAccess()
            }
            return PermissionStatusMapping.screenRecording(hasAccess: hasAccess)
        case .fullDiskAccess:
            return await fullDiskAccessStatus()
        case .messagesAutomation:
            return Self.automationStatus(askUserIfNeeded: false)
        }
    }

    func request(_ kind: PermissionKind) async -> PermissionStatus {
        switch kind {
        case .contacts:
            // Prompt once, then re-read the cached state so the row reflects
            do {
                _ = try await CNContactStore().requestAccess(for: .contacts)
            } catch is CancellationError {
                return await status(.contacts)
            } catch {
                RuneWeaverLog.app.debug("CNContactStore requestAccess failed: \(error.localizedDescription)")
            }
            return await status(.contacts)
        case .calendars:
            // Prompting full-access variant reserved for the explicit Enable
            // press, then re-read so the row reflects the recorded grant.
            return await requestEventKitAccess(for: .event)
        case .reminders:
            // Prompting full-access variant reserved for the explicit Enable
            // press, then re-read so the row reflects the recorded grant.
            return await requestEventKitAccess(for: .reminder)
        case .accessibility:
            // Prompting variant reserved for the explicit Enable press; the
            // return reflects trust at call time, so map it directly.
            let trusted = await MainActor.run {
                DesktopPermissionCheck.requestAccessibilityTrust()
            }
            return PermissionStatusMapping.accessibility(trusted: trusted)
        case .screenRecording:
            let granted = await MainActor.run {
                DesktopCaptureBridge.requestScreenRecordingAccess()
            }
            return PermissionStatusMapping.screenRecording(hasAccess: granted)
        case .fullDiskAccess:
            // macOS exposes no prompt for Full Disk Access; re-running the
            // probe keeps the row honest while the rationale points at
            // System Settings.
            return await status(.fullDiskAccess)
        case .messagesAutomation:
            // Automation prompting hops to the main actor because TCC dialogs
            // expect main-thread execution, matching the Accessibility and
            // Screen Recording prompting paths that hop via MainActor.
            return await MainActor.run {
                Self.automationStatus(askUserIfNeeded: true)
            }
        }
    }

    /// Reads one EventKit capability without prompting.
    ///
    /// Calendars and reminders differ only by entity type, so both status
    /// branches funnel through this silent read; the shared mapper keeps the
    /// interpretation identical when the system adds new authorization cases.
    private func eventKitStatus(for entity: EKEntityType) -> PermissionStatus {
        let current = EKEventStore.authorizationStatus(for: entity)
        return PermissionStatusMapping.eventKit(current)
    }

    /// Requests one EventKit capability from the explicit Enable press.
    ///
    /// The prompting variant is reserved for user intent, so status reads stay
    /// silent; re-reading through the shared status helper keeps the row
    /// reflecting what the system recorded rather than the transient Bool.
    private func requestEventKitAccess(for entity: EKEntityType) async -> PermissionStatus {
        switch entity {
        case .event:
            do {
                _ = try await EKEventStore().requestFullAccessToEvents()
            } catch is CancellationError {
                return eventKitStatus(for: entity)
            } catch {
                RuneWeaverLog.app.debug("EKEventStore requestFullAccessToEvents failed: \(error.localizedDescription)")
            }
        case .reminder:
            do {
                _ = try await EKEventStore().requestFullAccessToReminders()
            } catch is CancellationError {
                return eventKitStatus(for: entity)
            } catch {
                RuneWeaverLog.app.debug("EKEventStore requestFullAccessToReminders failed: \(error.localizedDescription)")
            }
        @unknown default:
            return .unavailable
        }
        return eventKitStatus(for: entity)
    }

    /// Snapshots the Messages database to prove Full Disk Access readability.
    ///
    /// Runs on the caller's task with cooperative cancellation checkpoints
    /// before and after the snapshot, and removes the snapshot directory
    /// immediately so the probe leaves no residue. There is no unstructured
    /// task here, so closing the window cancels the awaiting refresh at the
    /// next checkpoint instead of leaving snapshot IO running past close.
    private func fullDiskAccessStatus() async -> PermissionStatus {
        do {
            // Checkpoint before touching the filesystem so a close that lands
            // while queued never starts snapshot IO.
            try Task.checkCancellation()
            let directory = try MessagesIndexer.snapshotDatabase()
            defer { try? FileManager.default.removeItem(at: directory) }
            // Checkpoint after the copy so a close that lands mid-snapshot
            // never records a grant from stale IO.
            try Task.checkCancellation()
            return PermissionStatusMapping.fullDiskAccess(result: .success(()))
        } catch is CancellationError {
            // A cancelled probe never claims a grant; fail closed to
            // unavailable so the next refresh reconciles instead of
            // recording a denial.
            return .unavailable
        } catch {
            // A cancelled probe never claims a grant; fail closed to unavailable
            // so the next refresh reconciles instead of recording a denial.
            if Task.isCancelled {
                return .unavailable
            }
            return PermissionStatusMapping.fullDiskAccess(result: Result<Void, Error>.failure(error))
        }
    }

    /// Queries Automation consent for Messages without touching other targets.
    ///
    /// The address descriptor targets the Messages bundle only; asking stays
    /// false on status reads so activation refreshes never prompt, and true
    /// only on the explicit Enable press hopped to the main actor by the
    /// caller, because TCC dialogs expect main-thread execution.
    private static func automationStatus(askUserIfNeeded ask: Bool) -> PermissionStatus {
        var target = AEAddressDesc()
        let bundleID = "com.apple.MobileSMS"
        // Include the null terminator in the descriptor bytes and fail
        // closed when creation fails, so a malformed descriptor never
        // surfaces as a spurious consent outcome.
        let byteCount = bundleID.utf8.count + 1
        var createStatus: OSStatus = noErr
        bundleID.withCString { pointer in
            createStatus = OSStatus(AECreateDesc(typeApplicationBundleID, pointer, byteCount, &target))
        }
        guard createStatus == noErr else {
            // Dispose defensively even on failure so no partial descriptor leaks.
            AEDisposeDesc(&target)
            return .unavailable
        }
        defer { AEDisposeDesc(&target) }
        let status = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, ask)
        return PermissionStatusMapping.automation(status)
    }
}
