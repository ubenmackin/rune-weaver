// Rune Weaver Core — Machine scoped persistent runner.

import CryptoKit
import Foundation

/// Single owner for machine scoped execution.
public enum MachineScopedRunner: Sendable {
    /// Long-lived workspace container name, single-sourced with the strict sweep exemption.
    public static var workspaceMachineName: String {
        StrictContainerRunner.workspaceContainerName
    }

    /// Label key carrying the expected image plus mount digest.
    public static let configLabel = "runeweaver.config-hash"

    /// Fallback guest memory cap when no containers policy is threaded.
    /// Production machine turns read the threaded `ContainerSeam` memory instead.
    public static var sharedMemoryCap: String {
        StrictContainerRunner.defaultMemory
    }

    /// Derives the expected label value for one workspace root. workspaceRoot:
    /// Workspace root mounted into the machine.
    public static func expectedConfigValue(workspaceRoot: URL, networkDenied: Bool) -> String {
        let mount = workspaceRoot.standardizedFileURL.path
        let seed = StrictContainerRunner.defaultImage + "\n" + mount + "\n" + (networkDenied ? "denied" : "allowed")
        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Builds `container create` arguments for the machine container.
    /// workspaceRoot: Workspace root mounted at the same guest path.
    public static func createArguments(workspaceRoot: URL, networkDenied: Bool, memory: String = sharedMemoryCap) -> [String] {
        let mount = workspaceRoot.standardizedFileURL.path
        // The guest workdir pins to the mounted workspace root so getcwd observes the workspace
        // rather than `/`, matching the exec workdir that runs at the same mounted path.
        return StrictContainerRunner.containerCreateArguments(
            name: workspaceMachineName,
            hostPath: mount,
            guestPath: mount,
            workdir: mount,
            networkDenied: networkDenied,
            memory: memory,
            labels: [configLabel: expectedConfigValue(workspaceRoot: workspaceRoot, networkDenied: networkDenied)]
        )
    }

    /// Builds `container exec` arguments for the machine container. workdir:
    /// Working directory inside the guest.
    public static func execArguments(workdir: String, command: String) -> [String] {
        StrictContainerRunner.containerExecArguments(name: workspaceMachineName, workdir: workdir, command: command)
    }

    /// Arguments inspecting the machine container.
    /// - Returns: Exact argument sequence for the runtime.
    public static func inspectArguments() -> [String] {
        ["inspect", workspaceMachineName]
    }

    /// Whether an `inspect` output proves the machine entry is absent.
    /// - Parameter output: Combined stdout plus stderr from the failed `inspect`.
    /// - Returns: True when the entry is definitively absent.
    public static func inspectIndicatesMissing(output: String) -> Bool {
        let lowered = output.lowercased()
        if lowered.contains("not found") || lowered.contains("no such") {
            return true
        }
        if lowered.contains("not exist") || lowered.contains("does not exist") {
            return true
        }
        return false
    }

    /// Decoded view of one machine `inspect` dump.
    public struct InspectSnapshot: Sendable, Equatable {
        /// Whether the dump reports a live entry.
        public let running: Bool
        /// Image reference reported by the dump.
        public let image: String
        /// Label value under the config key, when present.
        public let configValue: String?

        /// Creates a snapshot.
        public init(running: Bool, image: String, configValue: String?) {
            self.running = running
            self.image = image
            self.configValue = configValue
        }
    }

    /// Machine state for the dashboard control plus CLI status output.
    public struct MachineStatus: Sendable, Equatable {
        /// Whether a machine entry exists.
        public let exists: Bool
        /// Whether the entry is live.
        public let running: Bool
        /// Image reference reported by the probe.
        public let image: String
        /// Whether the live config matches the expected root, nil when unknown.
        public let configMatch: Bool?

        /// Creates a machine status.
        public init(exists: Bool, running: Bool, image: String, configMatch: Bool?) {
            self.exists = exists
            self.running = running
            self.image = image
            self.configMatch = configMatch
        }
    }

    /// Decodes an inspect dump only when it is pure JSON.
    /// - Parameter output: Combined stdout plus stderr from the inspect probe.
    /// - Returns: Decoded array or object, nil when the dump is not pure JSON.
    public static func decodedInspectJSON(from output: String) -> Any? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [])
    }

    /// Recursively collects the first string under one of the given keys. keys:
    /// Logical keys matched case-insensitively.
    public static func firstString(forKeys keys: [String], in value: Any) -> String? {
        let wanted = Set(keys.map { $0.lowercased() })
        if let dict = value as? [String: Any] {
            for (key, entry) in dict where wanted.contains(key.lowercased()) {
                if let text = entry as? String, !text.isEmpty {
                    return text
                }
            }
            for (_, entry) in dict {
                if let found = firstString(forKeys: keys, in: entry) {
                    return found
                }
            }
            return nil
        }
        if let array = value as? [Any] {
            for entry in array {
                if let found = firstString(forKeys: keys, in: entry) {
                    return found
                }
            }
        }
        return nil
    }

    /// Recursively reads the config label value from decoded inspect JSON.
    /// - Parameter value: Decoded inspect array or object.
    /// - Returns: Label value, nil when absent.
    public static func configValueInDecodedJSON(_ value: Any) -> String? {
        if let dict = value as? [String: Any] {
            for (key, entry) in dict where key == configLabel {
                if let text = entry as? String, !text.isEmpty {
                    return text
                }
            }
            for (_, entry) in dict {
                if let found = configValueInDecodedJSON(entry) {
                    return found
                }
            }
            return nil
        }
        if let array = value as? [Any] {
            for entry in array {
                if let found = configValueInDecodedJSON(entry) {
                    return found
                }
                if let text = entry as? String, text.contains(configLabel), let extracted = extractConfigValue(from: text) {
                    return extracted
                }
            }
        }
        if let text = value as? String, text.contains(configLabel) {
            return extractConfigValue(from: text)
        }
        return nil
    }

    /// Extracts the config label value from one raw text fragment.
    /// - Parameter text: Fragment containing the label key.
    /// - Returns: Value after the separator, nil when absent.
    public static func extractConfigValue(from text: String) -> String? {
        guard let keyRange = text.range(of: configLabel) else { return nil }
        var rest = String(text[keyRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = rest.first, first == "=" || first == ":" {
            rest.removeFirst()
            rest = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !rest.isEmpty else { return nil }
        let end = rest.firstIndex(where: { $0 == "\"" || $0 == "'" || $0 == "," || $0 == "}" || $0.isWhitespace || $0.isNewline })
        let token = end.map { String(rest[..<$0]) } ?? rest
        let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Whether a status string reports a live container. - Returns: True only for an affirmative
    /// live marker.
    public static func isRunningStatus(_ status: String) -> Bool {
        StrictContainerRunner.isRunningStatus(status)
    }

    /// Parses one machine `inspect` dump into running plus image plus label.
    /// - Parameter output: Combined stdout plus stderr from the inspect probe.
    /// - Returns: Snapshot with fallback substring extraction when JSON is absent.
    public static func parseInspectOutput(_ output: String) -> InspectSnapshot {
        if let decoded = decodedInspectJSON(from: output) {
            let running: Bool = {
                if let status = firstString(forKeys: ["status", "state"], in: decoded) {
                    // A stopped entry still names the prior run, so only an
                    // explicit live marker counts as running.
                    return StrictContainerRunner.isRunningStatus(status)
                }
                return StrictContainerRunner.isRunningStatus(output)
            }()
            let image = firstString(forKeys: ["image"], in: decoded) ?? ""
            let config = configValueInDecodedJSON(decoded)
            return InspectSnapshot(running: running, image: image, configValue: config)
        }
        let running = StrictContainerRunner.isRunningStatus(output)
        let image: String = {
            if output.contains(StrictContainerRunner.defaultImage) {
                return StrictContainerRunner.defaultImage
            }
            return firstStringFallbackImage(from: output) ?? ""
        }()
        return InspectSnapshot(running: running, image: image, configValue: extractConfigValue(from: output))
    }

    /// Fallback image extraction for non-JSON inspect text.
    /// - Parameter output: Combined stdout plus stderr from the inspect probe.
    /// - Returns: Quoted value after the image key, nil when absent.
    static func firstStringFallbackImage(from output: String) -> String? {
        guard let keyRange = output.range(of: "image", options: .caseInsensitive) else { return nil }
        let rest = String(output[keyRange.upperBound...])
        guard let quote = rest.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return nil }
        let after = String(rest[rest.index(after: quote)...])
        guard let end = after.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return nil }
        let token = String(after[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// Reuses the shared runtime capability probe via the live client.
    public static func probeRuntime() throws {
        try MachineContainerClient.live.probe()
    }

    /// Ensures the long-lived workspace container exists plus runs. Delegates to the live client so
    /// static and injected paths share one ensure implementation differing only by runtime source.
    public static func ensureMachine(workspaceRoot: URL, networkDenied: Bool, memory: String = sharedMemoryCap) async throws {
        try await MachineContainerClient.live.ensureMachine(workspaceRoot: workspaceRoot, networkDenied: networkDenied, memory: memory)
    }

    /// Executes an already resource-limited command in the machine container. - Returns: Bounded
    /// result.
    public static func exec(
        workdir: String,
        command: String,
        timeoutSeconds: TimeInterval = StrictContainerRunner.defaultProcessTimeoutSeconds
    ) async throws -> BoundedProcessResult {
        try await MachineContainerClient.live.exec(workdir: workdir, command: command, timeoutSeconds: timeoutSeconds)
    }

    /// Reports machine state for the dashboard control. Delegates to the live client so static and
    /// injected paths share one status implementation.
    public static func machineStatus() async -> MachineStatus {
        await MachineContainerClient.live.machineStatus(workspaceRoot: WorkspaceStore.resolveRoot())
    }

    /// Reports machine state against one workspace root. Delegates to the live client so static and
    /// injected paths share one status implementation.
    public static func machineStatus(workspaceRoot: URL, networkDenied: Bool? = nil) async -> MachineStatus {
        await MachineContainerClient.live.machineStatus(workspaceRoot: workspaceRoot, networkDenied: networkDenied)
    }

    /// Stops the machine container without removing it via the live client.
    public static func stopMachine() async {
        await MachineContainerClient.live.stopMachine()
    }

    /// Stops plus removes the machine container via the live client.
    public static func recycleMachine() async {
        await MachineContainerClient.live.recycleMachine()
    }
}

/// Injected machine client sharing builders with the live statics.
public struct MachineContainerClient: Sendable {
    private let runtime: any ContainerHostRuntime

    /// Creates a client on an injected runtime, live when nil.
    public init(runtime: any ContainerHostRuntime? = nil) {
        self.runtime = runtime ?? LiveContainerHostRuntime()
    }

    /// Live client used by production paths.
    public static var live: Self {
        Self()
    }

    /// Whether this client stubs the runtime for hermetic tests.
    public var isHermetic: Bool {
        runtime is HermeticContainerRuntime
    }

    /// Requires strict flags through the injected runtime.
    public func probe() throws {
        try runtime.probe()
    }

    /// Ensures the long-lived workspace container exists plus runs.
    public func ensureMachine(workspaceRoot: URL, networkDenied: Bool, memory: String = MachineScopedRunner.sharedMemoryCap) async throws {
        let expected = MachineScopedRunner.expectedConfigValue(workspaceRoot: workspaceRoot, networkDenied: networkDenied)
        let timeout = StrictContainerRunner.defaultProcessTimeoutSeconds
        if let snapshot = await inspectSnapshot(timeout: timeout) {
            if snapshot.configValue != expected {
                try await recreateMismatched(workspaceRoot: workspaceRoot, networkDenied: networkDenied, memory: memory, timeout: timeout)
                return
            }
            if !snapshot.running {
                try await start(timeout: timeout)
            }
            return
        }
        if await reviveListed(timeout: timeout) {
            return
        }
        try await createAndStart(workspaceRoot: workspaceRoot, networkDenied: networkDenied, memory: memory, timeout: timeout)
    }

    /// Executes an already resource-limited command in the machine container.
    public func exec(
        workdir: String,
        command: String,
        timeoutSeconds: TimeInterval = StrictContainerRunner.defaultProcessTimeoutSeconds
    ) async throws -> BoundedProcessResult {
        let args = MachineScopedRunner.execArguments(workdir: workdir, command: command)
        return try await runtime.run(arguments: args, timeoutSeconds: timeoutSeconds)
    }

    public func machineStatus(workspaceRoot: URL, networkDenied: Bool? = nil) async -> MachineScopedRunner.MachineStatus {
        let timeout = StrictContainerRunner.defaultProcessTimeoutSeconds
        let probed: BoundedProcessResult?
        do {
            probed = try await runtime.run(
                arguments: MachineScopedRunner.inspectArguments(),
                timeoutSeconds: timeout
            )
        } catch is CancellationError {
            probed = nil
        } catch {
            RuneWeaverLog.sandbox.debug("MachineScopedRunner: inspect failed: \(error.localizedDescription)")
            probed = nil
        }
        guard let probed, probed.exitCode == 0 else {
            if let fallback = await listedStatus(timeout: timeout) {
                return fallback
            }
            return MachineScopedRunner.MachineStatus(exists: false, running: false, image: "", configMatch: nil)
        }
        let combined = probed.stdoutString + "\n" + probed.stderrString
        let snapshot = MachineScopedRunner.parseInspectOutput(combined)
        guard let networkDenied else {
            return MachineScopedRunner.MachineStatus(exists: true, running: snapshot.running, image: snapshot.image, configMatch: nil)
        }
        let expected = MachineScopedRunner.expectedConfigValue(workspaceRoot: workspaceRoot, networkDenied: networkDenied)
        return MachineScopedRunner.MachineStatus(
            exists: true,
            running: snapshot.running,
            image: snapshot.image,
            configMatch: snapshot.configValue == expected
        )
    }

    /// Stops the machine container without removing it.
    public func stopMachine() async {
        let timeout = StrictContainerRunner.defaultProcessTimeoutSeconds
        do {
            _ = try await runtime.run(
                arguments: StrictContainerRunner.containerStopArguments(name: MachineScopedRunner.workspaceMachineName),
                timeoutSeconds: timeout
            )
        } catch is CancellationError {
            // Teardown continues
        } catch {
            RuneWeaverLog.sandbox.debug("MachineScopedRunner: stopMachine failed: \(error.localizedDescription)")
        }
    }

    /// Stops plus removes the machine container so the next ensure recreates it.
    public func recycleMachine() async {
        await stopAndRemove()
    }

    /// Best-effort stop plus delete, never throwing. Runs even when the calling task is cancelled,
    /// so failure, cancellation, or early return cannot orphan the workspace container.
    public func stopAndRemove(timeoutSeconds: TimeInterval = 5) async {
        do {
            _ = try await runtime.run(
                arguments: StrictContainerRunner.containerStopArguments(name: MachineScopedRunner.workspaceMachineName),
                timeoutSeconds: timeoutSeconds
            )
        } catch is CancellationError {
            // Teardown continues
        } catch {
            RuneWeaverLog.sandbox.debug("MachineScopedRunner: stop failed in stopAndRemove: \(error.localizedDescription)")
        }
        do {
            _ = try await runtime.run(
                arguments: StrictContainerRunner.containerDeleteArguments(name: MachineScopedRunner.workspaceMachineName),
                timeoutSeconds: timeoutSeconds
            )
        } catch is CancellationError {
            // Teardown continues
        } catch {
            RuneWeaverLog.sandbox.debug("MachineScopedRunner: delete failed in stopAndRemove: \(error.localizedDescription)")
        }
    }

    private func start(timeout: TimeInterval) async throws {
        let started = try await runtime.run(
            arguments: StrictContainerRunner.containerStartArguments(name: MachineScopedRunner.workspaceMachineName),
            timeoutSeconds: timeout
        )
        guard started.exitCode == 0 else {
            throw ContainerOperationError.operationFailed(
                "Failed to start workspace container '\(MachineScopedRunner.workspaceMachineName)': \(started.stderrString)"
            )
        }
    }

    private func inspectSnapshot(timeout: TimeInterval) async -> MachineScopedRunner.InspectSnapshot? {
        let probed: BoundedProcessResult?
        do {
            probed = try await runtime.run(
                arguments: MachineScopedRunner.inspectArguments(),
                timeoutSeconds: timeout
            )
        } catch is CancellationError {
            return nil
        } catch {
            RuneWeaverLog.sandbox.debug("MachineScopedRunner: inspectSnapshot failed: \(error.localizedDescription)")
            return nil
        }
        guard let probed, probed.exitCode == 0 else {
            return nil
        }
        return MachineScopedRunner.parseInspectOutput(probed.stdoutString + "\n" + probed.stderrString)
    }

    private func listedStatus(timeout: TimeInterval) async -> MachineScopedRunner.MachineStatus? {
        let listed: BoundedProcessResult?
        do {
            listed = try await runtime.run(
                arguments: StrictContainerRunner.containerListAllArguments(),
                timeoutSeconds: timeout
            )
        } catch is CancellationError {
            return nil
        } catch {
            RuneWeaverLog.sandbox.debug("MachineScopedRunner: listedStatus failed: \(error.localizedDescription)")
            return nil
        }
        guard let listed, listed.exitCode == 0 else {
            return nil
        }
        let rows = StrictContainerRunner.parseContainerListOutput(listed.stdoutString + "\n" + listed.stderrString)
        guard let row = rows.first(where: { $0.name == MachineScopedRunner.workspaceMachineName }) else {
            return nil
        }
        return MachineScopedRunner.MachineStatus(exists: true, running: StrictContainerRunner.isRunningStatus(row.status), image: "", configMatch: nil)
    }

    private func reviveListed(timeout: TimeInterval) async -> Bool {
        let probed: BoundedProcessResult?
        do {
            probed = try await runtime.run(
                arguments: StrictContainerRunner.containerListAllArguments(),
                timeoutSeconds: timeout
            )
        } catch is CancellationError {
            return false
        } catch {
            RuneWeaverLog.sandbox.debug("MachineScopedRunner: reviveListed check failed: \(error.localizedDescription)")
            return false
        }
        guard let probed, probed.exitCode == 0 else {
            return false
        }
        let combined = probed.stdoutString + "\n" + probed.stderrString
        let rows = StrictContainerRunner.parseContainerListOutput(combined)
        guard let row = rows.first(where: { $0.name == MachineScopedRunner.workspaceMachineName }) else {
            return false
        }
        if !StrictContainerRunner.isRunningStatus(row.status) {
            do {
                _ = try await runtime.run(
                    arguments: StrictContainerRunner.containerStartArguments(name: MachineScopedRunner.workspaceMachineName),
                    timeoutSeconds: timeout
                )
            } catch is CancellationError {
                // Cancellation
            } catch {
                RuneWeaverLog.sandbox.debug("MachineScopedRunner: reviveListed start failed: \(error.localizedDescription)")
            }
        }
        return true
    }

    private func createAndStart(workspaceRoot: URL, networkDenied: Bool, memory: String, timeout: TimeInterval) async throws {
        let createArgs = MachineScopedRunner.createArguments(workspaceRoot: workspaceRoot, networkDenied: networkDenied, memory: memory)
        let created = try await runtime.run(arguments: createArgs, timeoutSeconds: timeout)
        if created.exitCode != 0 {
            let detail = created.stdoutString + "\n" + created.stderrString
            if detail.lowercased().contains("already exists") || detail.lowercased().contains("conflict") {
                do {
                    _ = try await runtime.run(
                        arguments: StrictContainerRunner.containerStopArguments(name: MachineScopedRunner.workspaceMachineName),
                        timeoutSeconds: timeout
                    )
                } catch is CancellationError {
                    // Teardown continues
                } catch {
                    RuneWeaverLog.sandbox.debug("MachineScopedRunner: cleanup stop failed: \(error.localizedDescription)")
                }
                do {
                    _ = try await runtime.run(
                        arguments: StrictContainerRunner.containerDeleteArguments(name: MachineScopedRunner.workspaceMachineName),
                        timeoutSeconds: timeout
                    )
                } catch is CancellationError {
                    // Teardown continues
                } catch {
                    RuneWeaverLog.sandbox.debug("MachineScopedRunner: cleanup delete failed: \(error.localizedDescription)")
                }
                let retried = try await runtime.run(arguments: createArgs, timeoutSeconds: timeout)
                guard retried.exitCode == 0 else {
                    throw ContainerOperationError.operationFailed(
                        "Failed to create workspace container '\(MachineScopedRunner.workspaceMachineName)': \(retried.stderrString)"
                    )
                }
            } else {
                throw ContainerOperationError.operationFailed(
                    "Failed to create workspace container '\(MachineScopedRunner.workspaceMachineName)': \(created.stderrString)"
                )
            }
        }
        try await start(timeout: timeout)
    }

    private func recreateMismatched(workspaceRoot: URL, networkDenied: Bool, memory: String, timeout: TimeInterval) async throws {
        await stopAndRemove(timeoutSeconds: timeout)
        try await createAndStart(workspaceRoot: workspaceRoot, networkDenied: networkDenied, memory: memory, timeout: timeout)
    }
}
