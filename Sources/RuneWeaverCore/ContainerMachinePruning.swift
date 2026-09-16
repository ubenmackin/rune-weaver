// Rune Weaver Core — Container machine TTL pruning companion.

import Foundation

public extension ContainerMachineManager {
    /// Reports whether a machine has outlived its idle time-to-live.
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
    static func staleMachines(
        in machines: [ContainerMachineInfo],
        maxAgeSeconds: TimeInterval,
        now: Date = Date()
    ) -> [ContainerMachineInfo] {
        machines.filter { isStaleMachine($0, maxAgeSeconds: maxAgeSeconds, now: now) }
    }

    /// Prunes an explicit machine list with injectable stop/delete operations.
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
    static func pruneStaleMachines(
        prefix: String = machinePrefix,
        maxAgeSeconds: TimeInterval = TimeInterval(SandboxConfig.defaultArchiveSessionTTLMinutes * 60),
        now: Date = Date(),
        runtime: String = "container"
    ) async -> ContainerPruneResult {
        pruneStaleMachinesSync(prefix: prefix, maxAgeSeconds: maxAgeSeconds, now: now, runtime: runtime)
    }
}
