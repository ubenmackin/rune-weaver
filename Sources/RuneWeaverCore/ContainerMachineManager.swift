// Rune Weaver Core — Apple Container Machine Lifecycle Manager.
//
// Manages microVM container machine instances via the `apple/container` CLI
// (`container machine` subcommands). Provides ephemeral detonation chambers for
// untrusted external payloads (email attachments, archives, unvetted scripts)
// with zero host filesystem mounts and automatic lifecycle cleanup.

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
    ///
    /// The container CLI's tabular listing carries no reliable creation
    /// timestamp, so ages would otherwise stay unknown and TTL checks could
    /// never fire. Recording the wall-clock time at successful creation gives
    /// every locally spawned machine a proven youth; listings that do carry
    /// timestamps take precedence, and machines with neither source are
    /// treated as stale so untracked VMs cannot accumulate silently across
    /// restarts. Entries are dropped on successful delete, keeping the table
    /// bounded by live machines.
    private static let trackedCreations = OSAllocatedUnfairLock(initialState: [String: Date]())

    /// Records a local creation time for a machine.
    ///
    /// Called after a successful `createMachine`; exposed so listings without
    /// timestamps can still be aged and so tests can pin deterministic ages.
    /// - Parameters:
    ///   - name: Machine name as passed to the runtime.
    ///   - date: Creation time. Defaults to now.
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
    ///
    /// Called after a successful delete so the registry stays bounded by live
    /// machines rather than growing with every spawn.
    /// - Parameter name: Machine name to forget.
    public static func forgetTrackedMachine(name: String) {
        trackedCreations.withLock { _ = $0.removeValue(forKey: name) }
    }

    /// Drops all locally tracked creation times.
    ///
    /// Housekeeping for process reuse and test isolation: without it a
    /// long-lived process would retain ages for machines deleted out of band.
    public static func clearTrackedCreations() {
        trackedCreations.withLock { $0.removeAll(keepingCapacity: false) }
    }

    /// Resolves the effective creation time, preferring the parsed listing value.
    ///
    /// List output wins when present because it reflects the runtime's ground
    /// truth (including machines spawned by other processes); the local
    /// registry is only a fallback for timestamp-less listings.
    /// - Parameters:
    ///   - name: Machine name for the registry fallback.
    ///   - parsed: Timestamp parsed from the listing, if any.
    /// - Returns: Effective creation date, or `nil` when neither source knows it.
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
    ///
    /// Throws instead of swallowing failures so prune passes can record the
    /// outcome per machine rather than reporting success while VMs persist.
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
    ///
    /// Throws instead of swallowing failures so prune passes can record the
    /// outcome per machine rather than reporting success while VMs persist.
    /// Successful deletes also drop the local creation-time entry.
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
    ///
    /// Throws when the runtime is missing or the listing fails so callers can
    /// distinguish "no machines" from "could not inspect", instead of silently
    /// treating an unlisted fleet as already reclaimed.
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
    ///
    /// Expects `NAME STATUS [IMAGE] [CREATED ...]` rows; the trailing columns
    /// are probed for a creation timestamp (ISO-8601, common date shapes, or
    /// epoch seconds) because the CLI offers no stable machine-inspect flag.
    /// Rows without a parsable timestamp fall back to the local creation
    /// registry so freshly spawned machines still age correctly.
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
    ///
    /// Tries the joined remainder first so two-column dates (`2026-09-15
    /// 10:00:00`) parse as one value, then falls back to single tokens for
    /// ISO-8601 and epoch forms. Fresh `DateFormatter`s are built per call so
    /// no shared formatter state is touched from concurrent prune paths.
    /// Timezone-less shapes are read as UTC to keep TTL math deterministic.
    /// - Parameter tokens: Columns after `NAME STATUS [IMAGE]`.
    /// - Returns: Parsed date, or `nil` when no token looks like a timestamp.
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
    ///
    /// Untrusted archive detonation streams arbitrary bytes through stdin, so the
    /// child must never hang a turn: the timeout terminates a stuck runtime, the
    /// throwing stdin write surfaces broken pipes instead of silently dropping
    /// bytes, and stdout/stderr drain concurrently in bounded chunks so a large
    /// stderr cannot fill its pipe and deadlock a stdout wait.
    /// - Parameters:
    ///   - executableURL: Container CLI binary.
    ///   - arguments: CLI arguments.
    ///   - inputData: Bytes piped to stdin (archive payload), if any.
    ///   - timeoutSeconds: Seconds before the child is terminated. Defaults to the shared 30s bridge budget.
    ///   - maxOutputBytes: Maximum stdout bytes retained. Defaults to the shared detonation bound.
    /// - Returns: Exit status plus bounded stdout/stderr.
    /// - Throws: `ContainerMachineError/operationFailed` on timeout or output overrun.
    public static func runProcessSync(
        executableURL: URL,
        arguments: [String],
        inputData: Data? = nil,
        timeoutSeconds: TimeInterval = defaultProcessTimeoutSeconds,
        maxOutputBytes: Int = maxProcessOutputBytes
    ) throws -> ContainerExecutionResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdinPipe = Pipe()
        process.standardInput = stdinPipe

        try process.run()
        if let inputData, !inputData.isEmpty {
            do {
                try stdinPipe.fileHandleForWriting.write(contentsOf: inputData)
            } catch {
                // Child closed stdin early; drain still reports the exit status.
            }
        }
        try? stdinPipe.fileHandleForWriting.close()

        let group = DispatchGroup()
        let stdoutStore = OSAllocatedUnfairLock(initialState: BoundedRead())
        let stderrStore = OSAllocatedUnfairLock(initialState: BoundedRead())
        let outHandle = stdoutPipe.fileHandleForReading
        let errHandle = stderrPipe.fileHandleForReading
        let stdoutLimit = maxOutputBytes
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = boundedRead(handle: outHandle, limit: stdoutLimit, process: process)
            stdoutStore.withLock { $0 = result }
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = boundedRead(handle: errHandle, limit: maxProcessErrorBytes, process: process)
            stderrStore.withLock { $0 = result }
            group.leave()
        }

        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let timeoutWork = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.withLock { $0 = true }
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutWork)
        process.waitUntilExit()
        group.wait()
        timeoutWork.cancel()

        if timedOut.withLock({ $0 }) {
            throw ContainerMachineError.operationFailed(
                "Container command timed out after \(Int(timeoutSeconds))s."
            )
        }
        let outResult = stdoutStore.withLock { $0 }
        let errResult = stderrStore.withLock { $0 }
        if outResult.didExceed {
            throw ContainerMachineError.operationFailed(
                "Container output exceeded the \(stdoutLimit)-byte limit and was terminated."
            )
        }

        return ContainerExecutionResult(
            exitCode: process.terminationStatus,
            stdout: outResult.data,
            stderr: errResult.data
        )
    }

    /// Incremental capped pipe read shared by the concurrent stdout/stderr drains.
    private struct BoundedRead: Sendable {
        /// Bytes accumulated so far.
        var data = Data()
        /// Whether the cap was passed (caller terminates the child).
        var didExceed = false
    }

    /// Reads one pipe in small chunks, terminating the child as soon as the cap passes.
    private static func boundedRead(handle: FileHandle, limit: Int, process: Process) -> BoundedRead {
        var result = BoundedRead()
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 16384)
            } catch {
                break
            }
            guard let chunk, !chunk.isEmpty else { break }
            result.data.append(chunk)
            if result.data.count > limit {
                if process.isRunning {
                    process.terminate()
                }
                result.didExceed = true
                break
            }
        }
        return result
    }

    private static func runProcess(
        executableURL: URL,
        arguments: [String],
        inputData: Data? = nil,
        timeoutSeconds: TimeInterval = defaultProcessTimeoutSeconds
    ) async throws -> ContainerExecutionResult {
        try runProcessSync(
            executableURL: executableURL,
            arguments: arguments,
            inputData: inputData,
            timeoutSeconds: timeoutSeconds
        )
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
