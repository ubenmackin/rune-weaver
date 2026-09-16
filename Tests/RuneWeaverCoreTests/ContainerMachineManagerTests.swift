// Rune Weaver Core Tests — Container machine lifecycle manager tests.

import Foundation
@testable import RuneWeaverCore
import Testing

@Suite("Container Machine Manager")
struct ContainerMachineManagerTests {
    @Test
    func `Parses tabular list output accurately`() {
        let sampleOutput = """
        NAME                           STATUS   IMAGE
        runeweaver-attach-12345        running  alpine:latest
        runeweaver-session-abcdef      stopped  alpine:latest
        other-container                running  ubuntu:latest
        """

        let parsed = ContainerMachineManager.parseMachineListOutput(sampleOutput, prefix: "runeweaver-")

        #expect(parsed.count == 2)
        #expect(parsed[0].name == "runeweaver-attach-12345")
        #expect(parsed[0].status == "running")
        #expect(parsed[1].name == "runeweaver-session-abcdef")
        #expect(parsed[1].status == "stopped")
    }

    @Test
    func `Runtime detection handles missing executable cleanly`() {
        let isAvailable = ContainerMachineManager.isRuntimeAvailable(runtime: "nonexistent-container-runtime-123")
        #expect(isAvailable == false)
    }

    @Test
    func `Parses creation timestamps from list output`() {
        // Timestamped listings must age correctly so TTL can fire; the header
        // row is not a machine and must never enter the candidate set.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let staleStamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-3600))
        let sampleOutput = """
        NAME                           STATUS   IMAGE
        runeweaver-session-old         running  alpine:latest \(staleStamp)
        runeweaver-session-fresh       running  alpine:latest \(ISO8601DateFormatter().string(from: now.addingTimeInterval(-60)))
        other-container                running  ubuntu:latest \(staleStamp)
        """

        let parsed = ContainerMachineManager.parseMachineListOutput(sampleOutput, prefix: "runeweaver-")

        #expect(parsed.count == 2)
        #expect(parsed[0].createdAt != nil)
        #expect(parsed[1].createdAt != nil)
        #expect(ContainerMachineManager.isStaleMachine(parsed[0], maxAgeSeconds: 900, now: now) == true)
        #expect(ContainerMachineManager.isStaleMachine(parsed[1], maxAgeSeconds: 900, now: now) == false)
    }

    @Test
    func `TTL reaps stale machines and keeps fresh ones`() {
        // End-to-end TTL boundary through the injectable prune core, without
        // requiring the container CLI binary.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stale = ContainerMachineInfo(
            name: "runeweaver-session-\(UUID().uuidString.prefix(8))",
            status: "running",
            image: "alpine:latest",
            createdAt: now.addingTimeInterval(-3600)
        )
        let fresh = ContainerMachineInfo(
            name: "runeweaver-session-\(UUID().uuidString.prefix(8))",
            status: "running",
            image: "alpine:latest",
            createdAt: now.addingTimeInterval(-60)
        )
        var stopped: [String] = []
        var deleted: [String] = []

        let result = ContainerMachineManager.pruneMachines(
            [stale, fresh],
            maxAgeSeconds: 900,
            now: now,
            stop: { stopped.append($0) },
            delete: { deleted.append($0) }
        )

        #expect(result.stopped == 1)
        #expect(result.destroyed == 1)
        #expect(result.errors.isEmpty)
        #expect(stopped == [stale.name])
        #expect(deleted == [stale.name])
    }

    @Test
    func `Running session machines older than TTL are stopped before delete`() {
        // Production session IDs (`runeweaver-session-<hex>`) must not escape
        // reclamation merely by staying `running`; stopped machines skip the
        // stop step and go straight to delete.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let running = ContainerMachineInfo(
            name: "runeweaver-session-\(UUID().uuidString.prefix(8))",
            status: "running",
            createdAt: now.addingTimeInterval(-3600)
        )
        let stoppedMachine = ContainerMachineInfo(
            name: "runeweaver-session-\(UUID().uuidString.prefix(8))",
            status: "stopped",
            createdAt: now.addingTimeInterval(-3600)
        )
        var stopped: [String] = []
        var deleted: [String] = []

        let result = ContainerMachineManager.pruneMachines(
            [running, stoppedMachine],
            maxAgeSeconds: 900,
            now: now,
            stop: { stopped.append($0) },
            delete: { deleted.append($0) }
        )

        #expect(result.stopped == 1)
        #expect(result.destroyed == 2)
        #expect(stopped == [running.name])
        #expect(Set(deleted) == Set([running.name, stoppedMachine.name]))
    }

    @Test
    func `Machines with unknown age are treated as stale`() {
        // Without any timestamp there is no proven youth; failing closed toward reclamation keeps
        // untracked fleets from accumulating across restarts when the listing carries no dates and
        // the local registry has no entry (fresh UUIDs guarantee no registry hit).
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let unknown = ContainerMachineInfo(
            name: "runeweaver-session-\(UUID().uuidString)",
            status: "running",
            createdAt: nil
        )
        var deleted: [String] = []

        let result = ContainerMachineManager.pruneMachines(
            [unknown],
            maxAgeSeconds: 900,
            now: now,
            stop: { _ in },
            delete: { deleted.append($0) }
        )

        #expect(result.destroyed == 1)
        #expect(deleted == [unknown.name])
    }

    @Test
    func `Stop and delete failures surface as prune errors`() {
        // Failures must never read as success: counts only move on success
        // and every failure lands in `errors` with its machine name.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let victim = ContainerMachineInfo(
            name: "runeweaver-session-\(UUID().uuidString.prefix(8))",
            status: "running",
            createdAt: now.addingTimeInterval(-3600)
        )
        struct Boom: Error {}
        let failingStopResult = ContainerMachineManager.pruneMachines(
            [victim],
            maxAgeSeconds: 900,
            now: now,
            stop: { _ in throw Boom() },
            delete: { _ in }
        )
        #expect(failingStopResult.stopped == 0)
        #expect(failingStopResult.destroyed == 1)
        #expect(failingStopResult.errors.count == 1)
        #expect(failingStopResult.errors[0].contains(victim.name))

        let failingDeleteResult = ContainerMachineManager.pruneMachines(
            [victim],
            maxAgeSeconds: 900,
            now: now,
            stop: { _ in },
            delete: { _ in throw Boom() }
        )
        #expect(failingDeleteResult.stopped == 1)
        #expect(failingDeleteResult.destroyed == 0)
        #expect(failingDeleteResult.errors.count == 1)
        #expect(failingDeleteResult.errors[0].contains(victim.name))
    }

    @Test
    func `Locally tracked creation dates age timestamp-less listings`() {
        // Listings without date columns still expire when this process
        // spawned the machine; unique names keep the shared registry isolated
        // between parallel tests.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let trackedName = "runeweaver-session-\(UUID().uuidString)"
        ContainerMachineManager.noteMachineCreated(name: trackedName, at: now.addingTimeInterval(-3600))
        defer { ContainerMachineManager.forgetTrackedMachine(name: trackedName) }

        let parsed = ContainerMachineManager.parseMachineListOutput(
            "\(trackedName) running alpine:latest",
            prefix: "runeweaver-"
        )
        #expect(parsed.count == 1)
        #expect(parsed[0].createdAt != nil)
        #expect(ContainerMachineManager.isStaleMachine(parsed[0], maxAgeSeconds: 900, now: now) == true)
    }

    @Test
    func `Config initialization reflects container machine settings`() {
        // Detonation stays pinned to the Apple Container CLI with Tier-3-only
        // inputs; the runtime accessor always reports the shared default.
        let config = SandboxConfig(
            containerBaseImage: "alpine:latest",
            archiveSessionTTLMinutes: 15,
            maxConcurrentMachines: 5
        )

        #expect(config.containerRuntime == "container")
        #expect(config.containerBaseImage == "alpine:latest")
        #expect(config.archiveSessionTTLMinutes == 15)
        #expect(config.maxConcurrentMachines == 5)
    }
}
