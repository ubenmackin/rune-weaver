// Rune Weaver Core — Apple Container Machine Lifecycle Manager.

import Dispatch
import Foundation
import os

/// Metadata for a container machine reported by `container machine list`.
public struct ContainerMachineInfo: Sendable, Equatable {
    public let name: String
    public let status: String
    public let image: String
    public let createdAt: Date?

    public init(name: String, status: String = "unknown", image: String = "", createdAt: Date? = nil) {
        self.name = name
        self.status = status
        self.image = image
        self.createdAt = createdAt
    }
}

/// Result of executing a command inside a container machine.
public struct ContainerExecutionResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public var stdoutString: String {
        String(data: stdout, encoding: .utf8) ?? ""
    }

    public var stderrString: String {
        String(data: stderr, encoding: .utf8) ?? ""
    }

    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Summary result of pruning stale container machines.
public struct ContainerPruneResult: Sendable, Equatable {
    public let stopped: Int
    public let destroyed: Int
    public let errors: [String]

    public init(stopped: Int = 0, destroyed: Int = 0, errors: [String] = []) {
        self.stopped = stopped
        self.destroyed = destroyed
        self.errors = errors
    }
}

/// Manages ephemeral container machines for untrusted payload detonation.
public enum ContainerMachineManager {
    /// Standard prefix used for all RuneWeaver-spawned container machines.
    public static let machinePrefix = "runeweaver-"
    /// Default timeout for container CLI invocations, mirroring the plugin bridge so untrusted detonation cannot hang a turn.
    public static let defaultProcessTimeoutSeconds: TimeInterval = 30
    /// Maximum stdout bytes retained from a container invocation, bounding archive listings and single-entry extractions.
    public static let maxProcessOutputBytes = 11 * 1024 * 1024
    /// Maximum stderr bytes retained for diagnostics.
    public static let maxProcessErrorBytes = 64 * 1024

    /// Local creation-time registry for machines spawned in this process.
    private static let trackedCreations = OSAllocatedUnfairLock(initialState: [String: Date]())

    /// Records a local creation time for a machine.
    public static func noteMachineCreated(name: String, at date: Date = Date()) {
        trackedCreations.withLock { $0[name] = date }
    }

    /// Returns the locally tracked creation time for a machine, if any.
    /// - Parameter name: Machine name to look up.
    /// - Returns: Tracked creation date, or `nil` when untracked.
    public static func trackedCreationDate(for name: String) -> Date? {
        trackedCreations.withLock { $0[name] }
    }

    /// Drops the tracked creation time for a machine.
    public static func forgetTrackedMachine(name: String) {
        trackedCreations.withLock { _ = $0.removeValue(forKey: name) }
    }

    /// Drops all locally tracked creation times.
    public static func clearTrackedCreations() {
        trackedCreations.withLock { $0.removeAll(keepingCapacity: false) }
    }

    /// Resolves the effective creation time, preferring the parsed listing value.
    public static func effectiveCreationDate(for name: String, parsed: Date?) -> Date? {
        parsed ?? trackedCreationDate(for: name)
    }

    /// Checks whether the container CLI binary is available on the system.
    public static func isRuntimeAvailable(runtime: String = "container") -> Bool {
        resolveRuntimeURL(runtime: runtime) != nil
    }

    /// Resolves the absolute path for the container CLI.
    public static func resolveRuntimeURL(runtime: String = "container") -> URL? {
        if runtime.starts(with: "/") {
            let url = URL(fileURLWithPath: runtime)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"
        for dir in envPath.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(runtime)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Creates a new container machine with an internal virtual disk.
    public static func createMachine(
        name: String,
        image: String = "alpine:latest",
        runtime: String = "container"
    ) async throws {
        guard let runtimeURL = resolveRuntimeURL(runtime: runtime) else {
            throw ContainerMachineError.runtimeNotFound(runtime)
        }
        let args = ["machine", "create", image, "--name", name]
        let result = try await runProcess(executableURL: runtimeURL, arguments: args)
        guard result.exitCode == 0 else {
            throw ContainerMachineError.operationFailed(
                "Failed to create container machine '\(name)': \(result.stderrString)"
            )
        }
        // Record only on success so failed spawns never gain a proven youth
        // that would later shield a same-named retry from reclamation.
        noteMachineCreated(name: name, at: Date())
    }

    /// Runs a command inside the specified container machine.
    public static func run(
        machineName: String,
        command: [String],
        runtime: String = "container",
        inputData: Data? = nil
    ) async throws -> ContainerExecutionResult {
        guard let runtimeURL = resolveRuntimeURL(runtime: runtime) else {
            throw ContainerMachineError.runtimeNotFound(runtime)
        }
        var args = ["machine", "run", "-n", machineName]
        args.append(contentsOf: command)
        return try await runProcess(executableURL: runtimeURL, arguments: args, inputData: inputData)
    }

    /// Stops a running container machine synchronously.
    public static func stopMachineSync(
        name: String,
        runtime: String = "container"
    ) throws {
        guard let runtimeURL = resolveRuntimeURL(runtime: runtime) else {
            throw ContainerMachineError.runtimeNotFound(runtime)
        }
        let args = ["machine", "stop", name]
        let result = try runProcessSync(executableURL: runtimeURL, arguments: args)
        guard result.exitCode == 0 else {
            let detail = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ContainerMachineError.operationFailed(
                "Failed to stop container machine '\(name)'\(detail.isEmpty ? "" : ": \(detail)")"
            )
        }
    }

    /// Stops a running container machine.
    public static func stopMachine(
        name: String,
        runtime: String = "container"
    ) async throws {
        try stopMachineSync(name: name, runtime: runtime)
    }

    /// Deletes a container machine synchronously.
    public static func deleteMachineSync(
        name: String,
        runtime: String = "container"
    ) throws {
        guard let runtimeURL = resolveRuntimeURL(runtime: runtime) else {
            throw ContainerMachineError.runtimeNotFound(runtime)
        }
        let args = ["machine", "delete", name]
        let result = try runProcessSync(executableURL: runtimeURL, arguments: args)
        guard result.exitCode == 0 else {
            let detail = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ContainerMachineError.operationFailed(
                "Failed to delete container machine '\(name)'\(detail.isEmpty ? "" : ": \(detail)")"
            )
        }
        forgetTrackedMachine(name: name)
    }

    /// Deletes a container machine, reclaiming its virtual disk and resources.
    public static func deleteMachine(
        name: String,
        runtime: String = "container"
    ) async throws {
        try deleteMachineSync(name: name, runtime: runtime)
    }

    /// Lists container machines matching the given prefix synchronously.
    public static func listMachinesSync(
        prefix: String = machinePrefix,
        runtime: String = "container"
    ) throws -> [ContainerMachineInfo] {
        guard let runtimeURL = resolveRuntimeURL(runtime: runtime) else {
            throw ContainerMachineError.runtimeNotFound(runtime)
        }
        let args = ["machine", "list"]
        let result = try runProcessSync(executableURL: runtimeURL, arguments: args)
        guard result.exitCode == 0 else {
            let detail = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ContainerMachineError.operationFailed(
                "Failed to list container machines\(detail.isEmpty ? "" : ": \(detail)")"
            )
        }

        return parseMachineListOutput(result.stdoutString, prefix: prefix)
    }

    /// Lists container machines matching the given prefix.
    public static func listMachines(
        prefix: String = machinePrefix,
        runtime: String = "container"
    ) async throws -> [ContainerMachineInfo] {
        try listMachinesSync(prefix: prefix, runtime: runtime)
    }

    // MARK: - Internal Helpers

    /// Parses tabular or line-based stdout from `container machine list`.
    public static func parseMachineListOutput(_ output: String, prefix: String) -> [ContainerMachineInfo] {
        var machines: [ContainerMachineInfo] = []
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines {
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let name = parts.first else { continue }
            // Skip the header row and any separator line, neither of which is a machine.
            guard name.lowercased() != "name", !name.allSatisfy({ $0 == Character("-") }) else { continue }
            guard name.hasPrefix(prefix) else { continue }
            let status = parts.count > 1 ? parts[1] : "unknown"
            let image = parts.count > 2 ? parts[2] : ""
            let remaining = parts.count > 3 ? Array(parts[3...]) : []
            let parsed = parseCreationDate(from: remaining)
            let effective = effectiveCreationDate(for: name, parsed: parsed)
            machines.append(ContainerMachineInfo(name: name, status: status, image: image, createdAt: effective))
        }
        return machines
    }

    /// Probes trailing listing columns for a creation timestamp.
    private static func parseCreationDate(from tokens: [String]) -> Date? {
        guard !tokens.isEmpty else { return nil }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]

        let joined = tokens.joined(separator: " ")
        if let date = iso.date(from: joined) ?? isoPlain.date(from: joined) {
            return date
        }
        for token in tokens {
            if let date = iso.date(from: token) ?? isoPlain.date(from: token) {
                return date
            }
        }

        let formats = [
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss Z",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd",
            "MM/dd/yyyy HH:mm:ss",
            "MM/dd/yyyy"
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: joined) {
                return date
            }
            for token in tokens {
                if let date = formatter.date(from: token) {
                    return date
                }
            }
        }

        // Epoch fallback: seconds since 1970, with millis tolerated so both
        // `1699999999` and `1699999999000` age correctly. Values below the
        // 2001 threshold are ignored so stray counters never pose as dates.
        for token in tokens {
            guard let value = Double(token) else { continue }
            if value >= 1_000_000_000_000 {
                return Date(timeIntervalSince1970: value / 1000)
            }
            if value >= 1_000_000_000, value < 10_000_000_000 {
                return Date(timeIntervalSince1970: value)
            }
        }
        return nil
    }

    /// Runs a container CLI invocation with a timeout and bounded concurrent output drain.
    /// Delegates to the shared `BoundedProcessRunner` so timeout, capped
    /// drains, and terminate-on-cap stay single-source with every other
    /// subprocess caller; no local runner lives here.
    public static func runProcessSync(
        executableURL: URL,
        arguments: [String],
        inputData: Data? = nil,
        timeoutSeconds: TimeInterval = defaultProcessTimeoutSeconds,
        maxOutputBytes: Int = maxProcessOutputBytes
    ) throws -> ContainerExecutionResult {
        do {
            let result = try BoundedProcessRunner.runSync(
                executableURL: executableURL,
                arguments: arguments,
                inputData: inputData,
                timeoutSeconds: timeoutSeconds,
                maxOutputBytes: maxOutputBytes,
                maxErrorBytes: maxProcessErrorBytes
            )
            return ContainerExecutionResult(
                exitCode: result.exitCode,
                stdout: result.stdout,
                stderr: result.stderr
            )
        } catch let error as BoundedProcessError {
            throw ContainerMachineError.operationFailed(error.localizedDescription)
        }
    }

    /// Runs a container CLI invocation off the cooperative pool.
    /// Delegates to the shared `BoundedProcessRunner` async entry point.
    private static func runProcess(
        executableURL: URL,
        arguments: [String],
        inputData: Data? = nil,
        timeoutSeconds: TimeInterval = defaultProcessTimeoutSeconds
    ) async throws -> ContainerExecutionResult {
        try Task.checkCancellation()
        do {
            let result = try await BoundedProcessRunner.runAsync(
                executableURL: executableURL,
                arguments: arguments,
                inputData: inputData,
                timeoutSeconds: timeoutSeconds,
                maxOutputBytes: maxProcessOutputBytes,
                maxErrorBytes: maxProcessErrorBytes
            )
            try Task.checkCancellation()
            return ContainerExecutionResult(
                exitCode: result.exitCode,
                stdout: result.stdout,
                stderr: result.stderr
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BoundedProcessError {
            throw ContainerMachineError.operationFailed(error.localizedDescription)
        }
    }
}

/// Errors relating to container machine operations.
public enum ContainerMachineError: LocalizedError, Sendable {
    case runtimeNotFound(String)
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .runtimeNotFound(runtime):
            "Apple container CLI ('\(runtime)') was not found in PATH. Install via https://github.com/apple/container."
        case let .operationFailed(reason):
            reason
        }
    }
}
