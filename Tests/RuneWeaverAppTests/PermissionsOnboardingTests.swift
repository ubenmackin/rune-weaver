// Rune Weaver App Tests — Permissions onboarding completion through AppModel.
//
// Pins the first-run window contract through the menu model seam without
// touching real TCC state or the owner's defaults: a fresh isolated suite
// reads incomplete, marking completion flips the published flag and persists,
// and a second model over the same suite stays complete so the next launch
// does not auto-open. The auto-open gate is exercised through the model's
// flags so token posture plus completion together decide the launch.
//
// Scope: AppModel construction with an injected store, mark-completed
// persistence, cross-instance durability, and the shouldAutoOpen verdicts
// derived from model state. No window presentation, no live probes, no snapshot
// assertions.
// Shared Contract:
// - A fresh store reads incomplete; markCompleted persists across stores.
// - shouldAutoOpen is true only when no token is needed and onboarding is incomplete.
// Owner: Sources/RuneWeaverApp/AppModel.swift onboarding seam plus
// Sources/RuneWeaverApp/PermissionsOnboardingStore.swift persistence.

import EventKit
import Foundation
@testable import RuneWeaverApp
import Testing

@Suite("Permissions onboarding through AppModel")
@MainActor
struct PermissionsOnboardingTests {
    /// Isolated defaults suite so the run never touches the owner's real flag.
    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "test-permissions-onboarding-\(UUID().uuidString)"
        // A UUID suite always resolves; the guard keeps the failure legible
        // instead of force-unwrapping in every test body.
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Could not create UserDefaults(suiteName: \(suiteName))")
            return (UserDefaults.standard, suiteName)
        }
        return (defaults, suiteName)
    }

    @Test
    func `fresh model reads incomplete and auto-opens when no token needed`() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // A fresh suite has no flag, so the first model must read incomplete
        // and the launch gate must favor opening the guidance window.
        let store = PermissionsOnboardingStore(defaults: defaults)
        let model = AppModel(permissionsOnboardingStore: store)
        #expect(model.hasCompletedPermissionsOnboarding == false)
        #expect(store.isCompleted == false)
        #expect(
            PermissionsOnboarding.shouldAutoOpen(
                needsOwnerToken: model.needsOwnerToken,
                hasCompleted: model.hasCompletedPermissionsOnboarding
            ) == true
        )
    }

    @Test
    func `marking completed flips the flag and closes the gate`() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = AppModel(permissionsOnboardingStore: PermissionsOnboardingStore(defaults: defaults))
        #expect(model.hasCompletedPermissionsOnboarding == false)

        // Closing the window marks completion once; the published flag must
        // flip in the same hop so the gate below reads the fresh value.
        model.markPermissionsOnboardingCompleted()
        #expect(model.hasCompletedPermissionsOnboarding == true)
        #expect(
            PermissionsOnboarding.shouldAutoOpen(
                needsOwnerToken: model.needsOwnerToken,
                hasCompleted: model.hasCompletedPermissionsOnboarding
            ) == false
        )
    }

    @Test
    func `completion persists across a second model instance`() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = AppModel(permissionsOnboardingStore: PermissionsOnboardingStore(defaults: defaults))
        first.markPermissionsOnboardingCompleted()

        // A relaunch builds a new model over the same suite; the durable flag
        // must survive instead of resetting to incomplete in memory.
        let second = AppModel(permissionsOnboardingStore: PermissionsOnboardingStore(defaults: defaults))
        #expect(second.hasCompletedPermissionsOnboarding == true)
        #expect(
            PermissionsOnboarding.shouldAutoOpen(
                needsOwnerToken: second.needsOwnerToken,
                hasCompleted: second.hasCompletedPermissionsOnboarding
            ) == false
        )
    }

    @Test
    func `store round-trips through the model seam`() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // The model owns the only write path the window uses, so a fresh
        // store over the same suite must observe the model's write directly.
        let model = AppModel(permissionsOnboardingStore: PermissionsOnboardingStore(defaults: defaults))
        model.markPermissionsOnboardingCompleted()

        let reloaded = PermissionsOnboardingStore(defaults: defaults)
        #expect(reloaded.isCompleted == true)
    }
}

/// Probe stub isolating the Calendars plus Reminders rows from real TCC.
///
/// Seeded statuses answer `status(_:)` reads while `requestResults` answer
/// `request(_:)` prompts, so the suite proves silent reads never take the
/// prompting path. A distinct name avoids colliding with the view-model stub
/// in the same test target.
@MainActor
final class CalendarsRemindersProbeStub: PermissionProbing {
    var seededStatuses: [PermissionKind: PermissionStatus]
    var requestResults: [PermissionKind: PermissionStatus]
    var statusCalls: [PermissionKind] = []
    var requestCalls: [PermissionKind] = []

    init(
        seededStatuses: [PermissionKind: PermissionStatus],
        requestResults: [PermissionKind: PermissionStatus] = [:]
    ) {
        self.seededStatuses = seededStatuses
        self.requestResults = requestResults
    }

    func status(_ kind: PermissionKind) async -> PermissionStatus {
        statusCalls.append(kind)
        return seededStatuses[kind] ?? .unavailable
    }

    func request(_ kind: PermissionKind) async -> PermissionStatus {
        requestCalls.append(kind)
        return requestResults[kind] ?? seededStatuses[kind] ?? .unavailable
    }
}

@Suite("Calendars plus Reminders onboarding rows")
@MainActor
struct CalendarsRemindersOnboardingTests {
    @Test
    func `kinds keep calendars then reminders after contacts`() {
        // Declaration order is the presentation order; the two EventKit rows
        // sit directly after Contacts so first-run owners meet them together.
        let kinds = PermissionKind.allCases.map(\.rawValue)
        #expect(
            kinds == [
                "fullDiskAccess", "contacts", "calendars", "reminders", "accessibility",
                "screenRecording", "messagesAutomation"
            ]
        )
    }

    @Test
    func `titles rationales images and panes map`() {
        #expect(PermissionKind.calendars.title == "Calendars")
        #expect(PermissionKind.reminders.title == "Reminders")

        // Each rationale names its search plus creation pair so the owner
        // knows why the row matters before pressing Enable.
        let calendarsRationale = PermissionKind.calendars.rationale.lowercased()
        #expect(calendarsRationale.contains("calendar"))
        #expect(calendarsRationale.contains("search"))
        #expect(calendarsRationale.contains("event"))
        #expect(calendarsRationale.contains("creat"))
        let remindersRationale = PermissionKind.reminders.rationale.lowercased()
        #expect(remindersRationale.contains("reminder"))
        #expect(remindersRationale.contains("search"))
        #expect(remindersRationale.contains("task"))
        #expect(remindersRationale.contains("creat"))

        #expect(PermissionKind.calendars.systemImage == "calendar")
        #expect(PermissionKind.reminders.systemImage == "checklist")

        #expect(PermissionKind.calendars.pane == .calendars)
        #expect(PermissionKind.reminders.pane == .reminders)
        #expect(PermissionPane.calendars.url?.absoluteString.contains("Privacy_Calendars") == true)
        #expect(PermissionPane.reminders.url?.absoluteString.contains("Privacy_Reminders") == true)
    }

    @Test
    func `calendars mapping covers all five states`() {
        #expect(PermissionStatusMapping.calendars(.fullAccess) == .granted)
        #expect(PermissionStatusMapping.calendars(.denied) == .denied)
        // Restricted and write-only withhold the search the event path needs,
        // so both fail closed to denied rather than claiming a usable grant.
        #expect(PermissionStatusMapping.calendars(.restricted) == .denied)
        #expect(PermissionStatusMapping.calendars(.writeOnly) == .denied)
        #expect(PermissionStatusMapping.calendars(.notDetermined) == .notDetermined)
    }

    @Test
    func `reminders mapping covers all five states`() {
        #expect(PermissionStatusMapping.reminders(.fullAccess) == .granted)
        #expect(PermissionStatusMapping.reminders(.denied) == .denied)
        // Restricted and write-only withhold the search the task path needs,
        // so both fail closed to denied rather than claiming a usable grant.
        #expect(PermissionStatusMapping.reminders(.restricted) == .denied)
        #expect(PermissionStatusMapping.reminders(.writeOnly) == .denied)
        #expect(PermissionStatusMapping.reminders(.notDetermined) == .notDetermined)
    }

    @Test
    func `probe seam returns mapped statuses without prompting on status`() async {
        let probes = CalendarsRemindersProbeStub(
            seededStatuses: [.calendars: .granted, .reminders: .denied]
        )

        // Silent reads resolve from the seeded map, matching what the live
        // EventKit authorizationStatus read would return through the mapping.
        #expect(await probes.status(.calendars) == .granted)
        #expect(await probes.status(.reminders) == .denied)
        // No status read takes the prompting requestAccess path.
        #expect(probes.requestCalls.isEmpty)
        #expect(probes.statusCalls == [.calendars, .reminders])
    }
}
