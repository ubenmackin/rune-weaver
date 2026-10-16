// Rune Weaver App Tests — Permissions view model over stubbed seams.

import Foundation
@testable import RuneWeaverApp
import Testing

/// Main-actor stub probes recording every read and prompt.
@MainActor
final class StubPermissionProbes: PermissionProbing {
    var seededStatuses: [PermissionKind: PermissionStatus]
    var requestResults: [PermissionKind: PermissionStatus]
    var statusCalls: [PermissionKind] = []
    var requestCalls: [PermissionKind] = []
    var callLog: [String] = []

    init(
        seededStatuses: [PermissionKind: PermissionStatus],
        requestResults: [PermissionKind: PermissionStatus] = [:]
    ) {
        self.seededStatuses = seededStatuses
        self.requestResults = requestResults
    }

    func status(_ kind: PermissionKind) async -> PermissionStatus {
        statusCalls.append(kind)
        callLog.append("status:\(kind.rawValue)")
        return seededStatuses[kind] ?? .unavailable
    }

    func request(_ kind: PermissionKind) async -> PermissionStatus {
        requestCalls.append(kind)
        callLog.append("request:\(kind.rawValue)")
        return requestResults[kind] ?? seededStatuses[kind] ?? .unavailable
    }
}

/// Main-actor recorder for Settings navigation and relaunch.
@MainActor
final class StubPermissionActions: PermissionSystemActing {
    var openedPanes: [PermissionPane] = []
    var relaunchCount = 0

    func open(_ pane: PermissionPane) {
        openedPanes.append(pane)
    }

    func relaunchApp() {
        relaunchCount += 1
    }
}

@Suite("Permissions view model")
@MainActor
struct PermissionsViewModelTests {
    /// One seeded status per row so refresh coverage proves every kind resolved.
    private func fullSeed() -> [PermissionKind: PermissionStatus] {
        [
            .fullDiskAccess: .denied,
            .contacts: .granted,
            .calendars: .granted,
            .reminders: .denied,
            .speechRecognition: .notDetermined,
            .accessibility: .notDetermined,
            .screenRecording: .deferred,
            .messagesAutomation: .unavailable
        ]
    }

    @Test
    func `status falls back to unavailable before first refresh`() {
        let probes = StubPermissionProbes(seededStatuses: [.contacts: .granted])
        let actions = StubPermissionActions()
        let model = PermissionsViewModel(probes: probes, actions: actions)

        // No refresh has run, so even a seeded kind must read unavailable
        // rather than leaking stub state into an unread row.
        #expect(model.status(for: .contacts) == .unavailable)
        #expect(model.status(for: .fullDiskAccess) == .unavailable)
        #expect(model.statuses.isEmpty)
        #expect(model.isRefreshing == false)
    }

    @Test
    func `ordered kinds follow declaration order`() {
        let probes = StubPermissionProbes(seededStatuses: [:])
        let actions = StubPermissionActions()
        let model = PermissionsViewModel(probes: probes, actions: actions)

        // The window binds row order to this list, so any drift from allCases
        // would silently reshuffle presentation.
        #expect(model.orderedKinds == PermissionKind.allCases)
    }

    @Test
    func `refresh populates all seven rows without prompting`() async {
        let seed = fullSeed()
        let probes = StubPermissionProbes(seededStatuses: seed)
        let actions = StubPermissionActions()
        let model = PermissionsViewModel(probes: probes, actions: actions)

        await model.refresh()

        // Every row resolves from the live read, including the environmental
        // and deferred shapes that keep their distinct affordances.
        for kind in PermissionKind.allCases {
            #expect(model.status(for: kind) == seed[kind])
        }
        #expect(model.statuses.count == PermissionKind.allCases.count)
        // A silent refresh must never take the prompting path, even once.
        #expect(probes.requestCalls.isEmpty)
        #expect(Set(probes.statusCalls) == Set(PermissionKind.allCases))
        #expect(model.isRefreshing == false)
    }

    @Test
    func `request stores prompt result then reconciles every row in order`() async {
        // The prompt claims granted while the live re-read still denies, so
        // the final row proves the trailing refresh overwrote the prompt write.
        var seed = fullSeed()
        seed[.contacts] = .denied
        let probes = StubPermissionProbes(
            seededStatuses: seed,
            requestResults: [.contacts: .granted]
        )
        let actions = StubPermissionActions()
        let model = PermissionsViewModel(probes: probes, actions: actions)

        await model.request(.contacts)

        #expect(probes.requestCalls == [.contacts])
        #expect(Set(probes.statusCalls) == Set(PermissionKind.allCases))
        #expect(model.status(for: .contacts) == .denied)
        // The prompt write precedes the reconciling re-read; without that
        // order the row would keep the transient granted value.
        guard
            let requestIndex = probes.callLog.firstIndex(of: "request:contacts"),
            let reconcileIndex = probes.callLog.lastIndex(of: "status:contacts")
        else {
            Issue.record("Expected request then status entries for contacts in \(probes.callLog)")
            return
        }
        #expect(requestIndex < reconcileIndex)
        #expect(model.isRefreshing == false)
    }

    @Test
    func `perform enable invokes request path and rereads all rows`() async {
        var seed = fullSeed()
        seed[.contacts] = .denied
        let probes = StubPermissionProbes(
            seededStatuses: seed,
            requestResults: [.contacts: .granted]
        )
        let actions = StubPermissionActions()
        let model = PermissionsViewModel(probes: probes, actions: actions)

        await model.perform(.enable, for: .contacts)

        // Enable is the only affordance that may prompt; it must take the
        // request path exactly once and then reconcile every row.
        #expect(probes.requestCalls == [.contacts])
        #expect(Set(probes.statusCalls) == Set(PermissionKind.allCases))
        #expect(model.status(for: .contacts) == .denied)
        #expect(actions.openedPanes.isEmpty)
    }

    @Test
    func `perform openSettings opens allFiles pane and prompts nothing`() async {
        let probes = StubPermissionProbes(seededStatuses: fullSeed())
        let actions = StubPermissionActions()
        let model = PermissionsViewModel(probes: probes, actions: actions)

        await model.perform(.openSettings, for: .fullDiskAccess)

        // Full Disk Access has no prompt API, so the Settings route must open
        // the exact All Files pane while both probe paths stay untouched.
        #expect(actions.openedPanes == [.allFiles])
        #expect(probes.requestCalls.isEmpty)
        #expect(probes.statusCalls.isEmpty)
    }

    @Test
    func `perform none touches neither seam`() async {
        let probes = StubPermissionProbes(seededStatuses: fullSeed())
        let actions = StubPermissionActions()
        let model = PermissionsViewModel(probes: probes, actions: actions)

        await model.perform(.none, for: .contacts)

        // Granted and deferred rows carry no affordance; invoking it must be
        // indistinguishable from never pressing anything.
        #expect(probes.requestCalls.isEmpty)
        #expect(probes.statusCalls.isEmpty)
        #expect(actions.openedPanes.isEmpty)
        #expect(model.statuses.isEmpty)
    }

    @Test
    func `relaunch delegates to the actions seam`() {
        let probes = StubPermissionProbes(seededStatuses: [:])
        let actions = StubPermissionActions()
        let model = PermissionsViewModel(probes: probes, actions: actions)

        model.relaunchApp()

        #expect(actions.relaunchCount == 1)
        #expect(actions.openedPanes.isEmpty)
    }
}
