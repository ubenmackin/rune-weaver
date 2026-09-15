// Rune Weaver Core — Container machine TTL pruning companion.
//
// Extends the ephemeral detonation lifecycle with time-to-live aging and
// crash-orphan reclamation. Keeps the core manager focused on process
// spawning and listing while this companion owns staleness decisions and
// the injectable prune pass shared by the sweeper and direct callers.

import Foundation

public extension ContainerMachineManager {
    /// Reports whether a machine has outlived its idle time-to-live.
    ///
    /// Aging prefers the listing timestamp and falls back to the local
    /// creation registry, so timestamp-less listings for locally spawned
    /// machines still expire. Machines with no timestamp from either source
    /// are treated as stale: without a proven youth there is no safe basis to
    /// keep an ephemeral detonation VM, and keeping it would let untracked
    /// fleets accumulate silently across restarts.
    /// - Parameters:
    ///   - machine: Machine to evaluate.
    ///   - maxAgeSeconds: Idle TTL. Ages strictly greater than this are stale.
    ///   - now: Reference date for age checks.
    /// - Returns: Whether the machine should be reclaimed.
    static func isStaleMachine(
        _ machine: ContainerMachineInfo,
        maxAgeSeconds: TimeInterval,
        now: Date = Date()
    ) -> Bool {
        let effective = machine.createdAt ?? trackedCreationDate(for: machine.name)
        guard let created = effective else {
            return true
        }
        return now.timeIntervalSince(created) > maxAgeSeconds
    }

    /// Filters a listing down to the machines that have outlived their TTL.
    /// - Parameters:
    ///   - machines: Candidate machines (already prefix-filtered by the listing).
    ///   - maxAgeSeconds: Idle TTL.
    ///   - now: Reference date for age checks.
    /// - Returns: Stale subset in listing order.
    static func staleMachines(
        in machines: [ContainerMachineInfo],
        maxAgeSeconds: TimeInterval,
        now: Date = Date()
    ) -> [ContainerMachineInfo] {
        machines.filter { isStaleMachine($0, maxAgeSeconds: maxAgeSeconds, now: now) }
    }

    /// Prunes an explicit machine list with injectable stop/delete operations.
    ///
    /// Exists so TTL decisions and error propagation stay unit-testable without
    /// the container CLI: production passes inject the real `stopMachineSync`
    /// / `deleteMachineSync`, while tests inject fakes. Stop is attempted for
    /// every non-stopped stale machine so runtimes that require stop-before-
    /// delete reach delete in a stoppable state; delete is attempted even when
    /// stop fails so a stuck VM still gets a reclamation attempt. Every stop
    /// or delete failure is recorded with the machine name instead of being
    /// swallowed, and counts only increment on success.
    /// - Parameters:
    ///   - machines: Candidate machines.
    ///   - maxAgeSeconds: Idle TTL.
    ///   - now: Reference date for age checks.
    ///   - stop: Stops the named machine, throwing on failure.
    ///   - delete: Deletes the named machine, throwing on failure.
    /// - Returns: Stop/delete counts plus per-machine failure messages.
    static func pruneMachines(
        _ machines: [ContainerMachineInfo],
        maxAgeSeconds: TimeInterval,
        now: Date,
        stop: (String) throws -> Void,
        delete: (String) throws -> Void
    ) -> ContainerPruneResult {
        var stoppedCount = 0
        var destroyedCount = 0
        var errors: [String] = []

        for machine in staleMachines(in: machines, maxAgeSeconds: maxAgeSeconds, now: now) {
            if machine.status.lowercased() != "stopped" {
                do {
                    try stop(machine.name)
                    stoppedCount += 1
                } catch {
                    errors.append("Failed to stop machine \(machine.name): \(error.localizedDescription)")
                }
            }
            do {
                try delete(machine.name)
                destroyedCount += 1
                forgetTrackedMachine(name: machine.name)
            } catch {
                errors.append("Failed to delete machine \(machine.name): \(error.localizedDescription)")
            }
        }

        return ContainerPruneResult(stopped: stoppedCount, destroyed: destroyedCount, errors: errors)
    }

    /// Prunes stale or orphaned container machines synchronously.
    ///
    /// Every `runeweaver-`-prefixed machine is aged against the TTL; listing
    /// failures are reported as prune errors rather than mistaken for an
    /// already-clean fleet. The default TTL is single-sourced from the sandbox
    /// config so the sweeper and direct callers cannot drift apart.
    static func pruneStaleMachinesSync(
        prefix: String = machinePrefix,
        maxAgeSeconds: TimeInterval = TimeInterval(SandboxConfig.defaultArchiveSessionTTLMinutes * 60),
        now: Date = Date(),
        runtime: String = "container"
    ) -> ContainerPruneResult {
        let machines: [ContainerMachineInfo]
        do {
            machines = try listMachinesSync(prefix: prefix, runtime: runtime)
        } catch {
            return ContainerPruneResult(
                stopped: 0,
                destroyed: 0,
                errors: ["Failed to list container machines: \(error.localizedDescription)"]
            )
        }

        return pruneMachines(
            machines,
            maxAgeSeconds: maxAgeSeconds,
            now: now,
            stop: { try stopMachineSync(name: $0, runtime: runtime) },
            delete: { try deleteMachineSync(name: $0, runtime: runtime) }
        )
    }

    /// Prunes stale or orphaned container machines matching the prefix.
    ///
    /// Default TTL is single-sourced from the sandbox config (crash-orphan
    /// reclamation for ephemeral detonation machines).
    static func pruneStaleMachines(
        prefix: String = machinePrefix,
        maxAgeSeconds: TimeInterval = TimeInterval(SandboxConfig.defaultArchiveSessionTTLMinutes * 60),
        now: Date = Date(),
        runtime: String = "container"
    ) async -> ContainerPruneResult {
        pruneStaleMachinesSync(prefix: prefix, maxAgeSeconds: maxAgeSeconds, now: now, runtime: runtime)
    }
}
