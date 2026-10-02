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
