// Rune Weaver App Tests — Permissions onboarding store, gate, and mappings.
//
// Pins the first-run contract without touching real TCC state: the completion
// flag round-trips through an isolated defaults suite, the auto-open gate
// respects token posture, every pure status mapping matches the platform
// truth table, and every status maps to its row affordance. Live probes are
// deliberately absent here so the suite never prompts for Contacts,
// Automation, or Full Disk Access on the machine running it.
//
// Scope: store persistence with injected suites, the four-row gate table,
// contacts including limited, accessibility and screen recording booleans,
// Full Disk Access success versus denial versus environmental failure,
// Automation across its documented OSStatus outcomes, and the
// action-for-status table.
// Shared Contract:
// - Store key round-trips completion across instances sharing one suite.
// - shouldAutoOpen is true only when no token is needed and onboarding is incomplete.
// - Contacts: authorized grants; denied, restricted, and limited deny; notDetermined stays unasked.
// - Accessibility and Screen Recording: true grants, false stays unasked.
// - Full Disk Access: success grants; permissionDenied denies; any other error is unavailable.
// - Automation: noErr grants; -1743 denies; -1744 stays unasked; -600 defers; anything else is unavailable.
// - Actions: granted and deferred need nothing; notDetermined enables; denied and unavailable open Settings.
// Owner: Sources/RuneWeaverApp/PermissionTypes.swift mappings plus
// Sources/RuneWeaverApp/PermissionsOnboardingStore.swift persistence.

import Contacts
import Foundation
@testable import RuneWeaverApp
import RuneWeaverCore
import Testing

@Suite("Permissions onboarding store and mappings")
@MainActor
struct PermissionsOnboardingStoreTests {
    /// Isolated defaults suite so the suite never touches the owner's real flag.
    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "test-permissions-\(UUID().uuidString)"
        // A UUID suite always resolves; the guard keeps the failure legible
        // instead of force-unwrapping in every test body.
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Could not create UserDefaults(suiteName: \(suiteName))")
            return (UserDefaults.standard, suiteName)
        }
        return (defaults, suiteName)
    }

    @Test
    func `store starts incomplete and persists completion across instances`() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // A fresh suite has no flag, so first run must read incomplete.
        let initial = PermissionsOnboardingStore(defaults: defaults)
        #expect(initial.isCompleted == false)

        // Closing the window marks completion once; the write must survive
        // a new store over the same suite, proving UserDefaults persistence
        // rather than in-memory state.
        initial.markCompleted()
        #expect(initial.isCompleted == true)

        let reloaded = PermissionsOnboardingStore(defaults: defaults)
        #expect(reloaded.isCompleted == true)
    }

    @Test
    func `auto-open gate honors token posture and completion`() {
        // Fresh install with no token outstanding opens exactly once.
        #expect(PermissionsOnboarding.shouldAutoOpen(needsOwnerToken: false, hasCompleted: false) == true)
        // Token setup outranks privacy guidance, so a needed token suppresses
        // the window even when onboarding never ran.
        #expect(PermissionsOnboarding.shouldAutoOpen(needsOwnerToken: true, hasCompleted: false) == false)
        // A completed run never reopens on later launches.
        #expect(PermissionsOnboarding.shouldAutoOpen(needsOwnerToken: false, hasCompleted: true) == false)
        // Both blockers together stay closed; the gate is a conjunction, not
        // a disjunction that one input could accidentally satisfy.
        #expect(PermissionsOnboarding.shouldAutoOpen(needsOwnerToken: true, hasCompleted: true) == false)
    }

    @Test
    func `contacts mapping matches authorization states`() throws {
        // Authorized is the only state that proves readability.
        #expect(PermissionStatusMapping.contacts(.authorized) == .granted)
        // Explicit refusals and parental restrictions both withhold lookups,
        // so they read denied rather than unasked.
        #expect(PermissionStatusMapping.contacts(.denied) == .denied)
        #expect(PermissionStatusMapping.contacts(.restricted) == .denied)
        // Limited still withholds arbitrary lookups the send path needs, so
        // it denies instead of claiming a usable grant. Raw value 4 matches
        // limited where the symbol is unavailable, keeping the denied reading
        // pinned on every platform.
        let limited = try #require(CNAuthorizationStatus(rawValue: 4))
        #expect(PermissionStatusMapping.contacts(limited) == .denied)
        // Untouched prompt keeps the Enable affordance.
        #expect(PermissionStatusMapping.contacts(.notDetermined) == .notDetermined)
    }

    @Test
    func `accessibility mapping reflects trust at call time`() {
        // Trusted means usable now; untrusted means unasked, not refused, so
        // the row keeps Enable instead of pointing at Settings.
        #expect(PermissionStatusMapping.accessibility(trusted: true) == .granted)
        #expect(PermissionStatusMapping.accessibility(trusted: false) == .notDetermined)
    }

    @Test
    func `screen recording mapping reflects preflight at call time`() {
        // Same posture as Accessibility: only a verified preflight claims
        // granted, while a miss stays unasked.
        #expect(PermissionStatusMapping.screenRecording(hasAccess: true) == .granted)
        #expect(PermissionStatusMapping.screenRecording(hasAccess: false) == .notDetermined)
    }

    @Test
    func `full disk access mapping separates denial from environment`() {
        // A clean snapshot proves readability.
        #expect(PermissionStatusMapping.fullDiskAccess(result: .success(())) == .granted)
        // An explicit TCC denial proves the grant is missing.
        let denied: Result<Void, Error> = .failure(MessagesIndexError.permissionDenied("Full Disk Access is required."))
        #expect(PermissionStatusMapping.fullDiskAccess(result: denied) == .denied)
        // A missing database is environmental, not a refusal, so it reads
        // unavailable and points at Settings without claiming denial.
        let missing: Result<Void, Error> = .failure(MessagesIndexError.databaseUnavailable("Missing."))
        #expect(PermissionStatusMapping.fullDiskAccess(result: missing) == .unavailable)
        // A non-index error (for example a snapshot copy failure surfaced as
        // a plain NSError) likewise reads unavailable rather than denied.
        let other: Result<Void, Error> = .failure(NSError(domain: "test", code: 1))
        #expect(PermissionStatusMapping.fullDiskAccess(result: other) == .unavailable)
    }

    @Test
    func `automation mapping matches documented outcomes`() {
        // Success proves Messages automation is usable.
        #expect(PermissionStatusMapping.automation(noErr) == .granted)
        // The owner refused this target; numeric literal pins the contract
        // even if the symbolic name ever drifts.
        #expect(PermissionStatusMapping.automation(-1743) == .denied)
        #expect(PermissionStatusMapping.automation(OSStatus(errAEEventNotPermitted)) == .denied)
        // Consent still required keeps the Enable affordance.
        #expect(PermissionStatusMapping.automation(-1744) == .notDetermined)
        #expect(PermissionStatusMapping.automation(OSStatus(errAEEventWouldRequireUserConsent)) == .notDetermined)
        // Target not running defers until first send, needing no row action.
        #expect(PermissionStatusMapping.automation(-600) == .deferred)
        #expect(PermissionStatusMapping.automation(OSStatus(procNotFound)) == .deferred)
        // Anything outside the documented set fails closed to unavailable.
        #expect(PermissionStatusMapping.automation(-50) == .unavailable)
    }

    @Test
    func `action table matches status affordances`() {
        // Usable now or resolving on first send needs no row action.
        #expect(PermissionActionsMapping.action(for: .granted) == .none)
        #expect(PermissionActionsMapping.action(for: .deferred) == .none)
        // An unanswered prompt offers Enable, which wires to the prompting
        // request path rather than a Settings detour.
        #expect(PermissionActionsMapping.action(for: .notDetermined) == .enable)
        // A refusal or an environmental failure points at Settings where the
        // owner can repair the grant by hand.
        #expect(PermissionActionsMapping.action(for: .denied) == .openSettings)
        #expect(PermissionActionsMapping.action(for: .unavailable) == .openSettings)
    }

    @Test
    func `permission kinds keep locked ui order`() {
        // Declaration order is the presentation order; a reorder here would
        // silently reshuffle the window, so the suite pins it.
        let kinds = PermissionKind.allCases.map(\.rawValue)
        #expect(kinds == ["fullDiskAccess", "contacts", "calendars", "reminders", "accessibility", "screenRecording", "messagesAutomation"])
    }

    @Test
    func `permission status labels use locked copy`() {
        #expect(PermissionStatus.granted.label == "Granted")
        #expect(PermissionStatus.denied.label == "Not granted")
        #expect(PermissionStatus.notDetermined.label == "Not yet requested")
        #expect(PermissionStatus.deferred.label == "Asks on first send")
        #expect(PermissionStatus.unavailable.label == "Unavailable")
    }
}
