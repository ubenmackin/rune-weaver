// Rune Weaver Core — Shared ephemeral container ledger.
//
// Purpose: count every live ephemeral container in one place and gate new
// container admission against the configured concurrency cap.
// Scope: registry bookkeeping for admitted names plus admission timestamps,
// CLI census reconciliation, and fail-closed admission denial past the cap
// or on census failure.
// Architectural role: single owner for the ephemeral cap beside the strict
// runner; the machine singleton workspace container stays exempt from counts.

import Foundation
import os

/// Single owner for the shared ephemeral container cap.
///
/// The ledger tracks containers this process admitted and reconciles them
/// against a CLI census so orphaned strict plus detonation containers still
/// consume cap budget while census-proven dead entries release it. Admission
/// denies fail-closed: past the cap, or whenever the census cannot prove the
/// live count, so an unreadable census never over-admits.
public actor EphemeralContainerLedger {
    /// Default cap matching the `[containers] max_concurrent` default,
    /// single-sourced with the containers config.
    public static let defaultMaxConcurrent = ContainersConfig.defaultMaxConcurrent

    /// Names this process admitted, reconciled against the census, each
    /// carrying its first-seen instant so the sweep can age running orphans.
    private var registered: [String: Date] = [:]
    private let runtime: any ContainerHostRuntime
    /// Concurrent-admission cap; excess requests deny fail-closed.
    public private(set) var maxConcurrent: Int

    /// Creates a ledger on an injected runtime, live when nil, with an
    /// explicit or default cap.
    /// - Parameters:
    ///   - runtime: Host runtime behind the CLI census.
    ///   - maxConcurrent: Concurrent-admission cap.
    public init(runtime: (any ContainerHostRuntime)? = nil, maxConcurrent: Int = EphemeralContainerLedger.defaultMaxConcurrent) {
        self.runtime = runtime ?? LiveContainerHostRuntime()
        self.maxConcurrent = StrictContainerRunner.clampedMaxConcurrent(for: ContainersConfig(maxConcurrent: maxConcurrent))
    }

    /// Updates the cap so settings saves apply without rebuilding sharers.
    public func updateMaxConcurrent(_ newValue: Int) {
        maxConcurrent = StrictContainerRunner.clampedMaxConcurrent(for: ContainersConfig(maxConcurrent: newValue))
    }

    /// Registers one admitted container name. Idempotent, so a recreated
    /// same-name container never double-counts; the first-seen instant wins
    /// so a recreated container never reads younger than its admission.
    public func register(name: String, at date: Date = Date()) {
        if registered[name] == nil {
            registered[name] = date
        }
    }

    /// Drops one container name once its container is reaped or swept.
    public func unregister(name: String) {
        registered.removeValue(forKey: name)
    }

    /// Admission instant for one container name, when this process admitted it.
    /// - Parameter name: Container name to look up.
    /// - Returns: First-seen instant, or nil when never admitted here.
    public func registrationDate(for name: String) -> Date? {
        registered[name]
    }

    /// Names currently registered, sorted for deterministic assertions.
    public func registeredNames() -> [String] {
        registered.keys.sorted()
    }

    /// Whether a container name counts against the ephemeral cap.
    ///
    /// Single-sourced on the strict runner so the census and the sweep agree:
    /// strict plus detonation containers share the strict name prefix and the
    /// legacy detonation shapes, while the machine singleton workspace
    /// container stays exempt from counts.
    static func isEphemeralContainerName(_ name: String) -> Bool {
        StrictContainerRunner.isEphemeralContainerName(name)
    }

    /// Runs the CLI census, returning parsed name plus status rows.
    ///
    /// Census failure throws so admission denies fail-closed: a missing
    /// runtime, a failed invocation, or a nonzero exit never reads as an
    /// empty machine. Cancellation propagates so a cancelled turn stops
    /// before any spawn.
    private func census(timeoutSeconds: TimeInterval) async throws -> [(name: String, status: String)] {
        guard runtime.resolveRuntimeURL() != nil else {
            throw ContainerOperationError.runtimeNotFound("container")
        }
        let listed: BoundedProcessResult
        do {
            listed = try await runtime.run(
                arguments: StrictContainerRunner.containerListAllArguments(),
                timeoutSeconds: timeoutSeconds
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            RuneWeaverLog.sandbox.debug("EphemeralContainerLedger: census failed: \(error.localizedDescription)")
            throw ContainerOperationError.operationFailed(
                "Unable to census live containers: \(error.localizedDescription)"
            )
        }
        guard listed.exitCode == 0 else {
            throw ContainerOperationError.operationFailed(
                "Unable to census live containers: \(listed.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
        return StrictContainerRunner.parseContainerListOutput(listed.stdoutString + "\n" + listed.stderrString)
    }

    /// Reconciled live ephemeral container count.
    ///
    /// The CLI census is ground truth for what is actually running; the
    /// registry covers containers this process admitted that the listing may
    /// not yet reflect. Census-proven dead entries leave the registry so
    /// reaped containers release budget, census names never join it so
    /// deleted remote containers cannot linger as ghosts, and names the
    /// listing does not mention keep their registration so a census racing
    /// an in-flight create never frees budget for a container about to run.
    /// - Parameter timeoutSeconds: Wall-clock budget for the census.
    /// - Returns: Live ephemeral containers, machine singleton excluded.
    /// - Throws: Census failure, so callers deny fail-closed.
    public func liveCount(timeoutSeconds: TimeInterval = StrictContainerRunner.defaultProcessTimeoutSeconds) async throws -> Int {
        let rows = try await census(timeoutSeconds: timeoutSeconds)
        var live = Set<String>()
        var listed = Set<String>()
        for row in rows {
            guard Self.isEphemeralContainerName(row.name) else { continue }
            listed.insert(row.name)
            if StrictContainerRunner.isRunningStatus(row.status) {
                live.insert(row.name)
            }
        }
        for name in listed where !live.contains(name) {
            registered.removeValue(forKey: name)
        }
        // Census names stay out of the registry; unlisted registrations are
        // in-flight creates the listing has not observed yet.
        return live.count + Set(registered.keys).subtracting(listed).count
    }

    /// Verifies one more ephemeral container can start under the shared cap.
    ///
    /// Denies fail-closed: past the cap with install-style guidance naming
    /// the limit, or on any census failure without spawning.
    /// - Parameter timeoutSeconds: Wall-clock budget for the census.
    /// - Throws: Cap denial or census failure.
    public func admit(timeoutSeconds: TimeInterval = StrictContainerRunner.defaultProcessTimeoutSeconds) async throws {
        let live = try await liveCount(timeoutSeconds: timeoutSeconds)
        guard live < maxConcurrent else {
            throw ContainerOperationError.operationFailed(
                "Ephemeral container cap reached: \(live) live containers meet the configured "
                    + "max_concurrent limit of \(maxConcurrent). Stop or reap running containers, "
                    + "or raise [containers] max_concurrent, before starting another."
            )
        }
    }
}
