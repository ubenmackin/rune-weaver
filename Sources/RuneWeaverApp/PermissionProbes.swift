// Rune Weaver App — Live permission probes and system actions.

import AppKit
import ApplicationServices
import Contacts
import EventKit
import Foundation
import RuneWeaverCore
import RuneWeaverTools
import Speech

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
        case .speechRecognition:
            let current = SFSpeechRecognizer.authorizationStatus()
            return PermissionStatusMapping.speechRecognition(current)
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
        case .speechRecognition:
            let authStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { result in
                    continuation.resume(returning: result)
                }
            }
            return PermissionStatusMapping.speechRecognition(authStatus)
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
    private func eventKitStatus(for entity: EKEntityType) -> PermissionStatus {
        let current = EKEventStore.authorizationStatus(for: entity)
        return PermissionStatusMapping.eventKit(current)
    }

    /// Requests one EventKit capability from the explicit Enable press.
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
