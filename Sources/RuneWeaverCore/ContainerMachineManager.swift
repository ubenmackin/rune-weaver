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
/// Shares the bounded runner's result shape so timeouts, output caps, and
/// lossy string decoding stay single-source; the alias keeps the
/// container-scoped name for existing callers.
public typealias ContainerExecutionResult = BoundedProcessResult

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

/// Shared date formatting helpers backing run titles, email dates, and container dates.
///
/// Intent: run-title, email, and container paths share one call site so the
/// POSIX locale and time-zone choices stay single-source and titles plus
/// parsed dates stay stable across callers. Helpers build a fresh formatter
/// per call because `DateFormatter` and `ISO8601DateFormatter` are reference
/// types with shared mutable state that is not safe to share across
/// concurrency domains; per-call instances keep every helper concurrency-safe
/// with no shared mutable state.
///
/// Invariant: no stored formatter instances live here. Each helper configures
/// a local formatter with the same locale, style, and options the cached
/// instances previously used, so formatted output and accepted inputs match
/// the prior behavior without shared state.
public enum SharedDateFormatters: Sendable {
    /// Formats a run-title timestamp with a locale-stable formatter.
    /// - Parameter date: Timestamp to format.
    /// - Returns: Short date plus short time string.
    public static func runTitleString(from date: Date) -> String {
        // Local instance preserves the en_US_POSIX short date plus short time
        // shape without sharing mutable formatter state across threads.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Parses a string with a POSIX formatter for one format.
    /// - Parameters:
    ///   - string: Candidate date string.
    ///   - format: Date format to try.
    ///   - timeZone: Time zone for the attempt (nil keeps the system zone).
    /// - Returns: Parsed date, or nil when the format does not match.
    public static func posixDate(from string: String, format: String, timeZone: TimeZone? = nil) -> Date? {
        // Local instance keeps locale single-source while allowing per-attempt
        // format and time-zone mutations without touching shared state.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.date(from: string)
    }

    /// Parses a timestamp as ISO-8601 with fractional seconds.
    /// - Parameter string: Candidate date string.
    /// - Returns: Parsed date, or nil when the string does not match.
    public static func isoWithFractionalSecondsDate(from string: String) -> Date? {
        // Local instance carries the same internet plus fractional-seconds
        // options so container timestamps with fractions still parse.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }

    /// Formats a timestamp as ISO-8601 with fractional seconds.
    /// - Parameter date: Timestamp to format.
    /// - Returns: ISO-8601 string with fractional seconds.
    public static func isoWithFractionalSecondsString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Parses a timestamp as ISO-8601 internet date-time without fractions.
    /// - Parameter string: Candidate date string.
    /// - Returns: Parsed date, or nil when the string does not match.
    public static func isoInternetTimeDate(from string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    /// Formats a timestamp as ISO-8601 internet date-time without fractions.
    /// - Parameter date: Timestamp to format.
    /// - Returns: ISO-8601 internet date-time string without fractions.
    public static func isoInternetTimeString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Parses a timestamp as ISO-8601 internet date-time pinned to UTC.
    /// - Parameter string: Candidate date string.
    /// - Returns: Parsed date, or nil when the string does not match.
    public static func isoInternetTimeUTCDate(from string: String) -> Date? {
        // UTC pin matches the expiry-envelope shape for zone-less inputs.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: string)
    }

    /// Formats a timestamp as ISO-8601 internet date-time pinned to UTC.
    /// - Parameter date: Timestamp to format.
    /// - Returns: ISO-8601 internet date-time string pinned to UTC.
    public static func isoInternetTimeUTCString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    /// Parses a timestamp with the default ISO-8601 options.
    /// - Parameter string: Candidate date string.
    /// - Returns: Parsed date, or nil when the string does not match.
    public static func isoDefaultDate(from string: String) -> Date? {
        // Fresh default instance preserves the RFC 2822 fallback behavior.
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: string)
    }

    /// Formats a timestamp with the default ISO-8601 options.
    /// - Parameter date: Timestamp to format.
    /// - Returns: Default ISO-8601 string.
    public static func isoDefaultString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
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

    /// Known install locations always probed after PATH entries.
    /// Mirrors the SearXNG resolver so detonation and search share one lookup:
    /// a minimal PATH must never hide a standard Homebrew install.
    public static let fallbackRuntimeDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// Ordered directories probed for the container runtime.
    /// PATH order wins so an operator override shadows the fallback, while the
    /// appended fallbacks keep a Homebrew install visible when PATH is minimal.
    /// Duplicates collapse so a PATH that already carries a fallback probes it
    /// once; blanks are skipped so empty segments never become relative probes.
    /// - Parameter pathValue: Raw `PATH` value, or nil when unset.
    /// - Returns: Deduplicated directories, PATH entries first.
    public static func runtimeSearchDirectories(pathValue: String?) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        func append(_ dir: String) {
            let trimmed = dir.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
            ordered.append(trimmed)
        }
        if let pathValue {
            for part in pathValue.split(separator: ":") {
                append(String(part))
            }
        }
        for fallback in fallbackRuntimeDirectories {
            append(fallback)
        }
        return ordered
    }

    /// Ordered directories probed for the container runtime in this process.
    /// Reads the live `PATH` so production and diagnostics share one ordering.
    /// - Returns: Deduplicated directories, PATH entries first.
    public static func runtimeSearchDirectories() -> [String] {
        runtimeSearchDirectories(pathValue: ProcessInfo.processInfo.environment["PATH"])
    }

    /// Resolves the absolute path for the container CLI.
    /// Absolute runtime values probe directly without PATH expansion; bare
    /// names probe the shared search ordering with no Docker fallback.
    /// - Parameters:
    ///   - runtime: Binary name or absolute path.
    ///   - searchDirectories: Ordered directories to probe for bare names.
    ///   - isExecutable: Filesystem probe, injectable so tests can stub an install.
    /// - Returns: Executable URL, or nil when missing.
    public static func resolveRuntimeURL(
        runtime: String = "container",
        searchDirectories: [String],
        isExecutable: (String) -> Bool
    ) -> URL? {
        if runtime.hasPrefix("/") {
            let url = URL(fileURLWithPath: runtime)
            return isExecutable(url.path) ? url : nil
        }
        for dir in searchDirectories {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(runtime)
            if isExecutable(candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Resolves the runtime against an explicit PATH value for testing.
    /// Routes the same fallback ordering through a stubbed filesystem probe so
    /// minimal-PATH coverage stays verifiable without touching the real PATH.
    /// - Parameters:
    ///   - runtime: Binary name or absolute path.
    ///   - pathValue: Raw `PATH` value driving the search ordering.
    ///   - isExecutable: Filesystem probe, injectable so tests can stub an install.
    /// - Returns: Executable URL, or nil when missing everywhere searched.
    public static func resolveRuntimeURL(
        runtime: String = "container",
        pathValue: String?,
        isExecutable: (String) -> Bool
    ) -> URL? {
        resolveRuntimeURL(
            runtime: runtime,
            searchDirectories: runtimeSearchDirectories(pathValue: pathValue),
            isExecutable: isExecutable
        )
    }

    /// Resolves the absolute path for the container CLI.
    public static func resolveRuntimeURL(runtime: String = "container") -> URL? {
        if runtime.hasPrefix("/") {
            let url = URL(fileURLWithPath: runtime)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        return resolveRuntimeURL(
            runtime: runtime,
            searchDirectories: runtimeSearchDirectories(),
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }
        )
    }

    /// Creates a new container machine with home-mount none enforced and no ssh-agent forwarding.
    ///
    /// Home isolation rides `--home-mount none`; agent isolation rides never
    /// passing `--ssh` plus stripping `SSH_AUTH_SOCK` from the spawn
    /// environment, so untrusted detonation never forwards the agent.
    public static func createMachine(
        name: String,
        image: String = "alpine:latest",
        runtime: String = "container"
    ) async throws {
        guard let runtimeURL = resolveRuntimeURL(runtime: runtime) else {
            throw ContainerMachineError.runtimeNotFound(runtime)
        }
        // Fail closed when the runtime predates home isolation: no fallback
        // without the flag, so an unsupported runtime never spawns a machine.
        let probe = try await runProcess(executableURL: runtimeURL, arguments: ["machine", "create", "--help"])
        let probeOutput = probe.stdoutString + "\n" + probe.stderrString
        guard probeOutput.contains("--home-mount") else {
            throw ContainerMachineError.operationFailed(
                "Container runtime does not support '--home-mount'; refusing to create machine '\(name)' without home isolation."
            )
        }
        let args = ["machine", "create", image, "--name", name, "--home-mount", "none"]
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
    /// Tries ISO-8601 first, then the POSIX helper per known layout,
    /// then epoch seconds, so container list output variations still age correctly.
    private static func parseCreationDate(from tokens: [String]) -> Date? {
        guard !tokens.isEmpty else { return nil }

        let joined = tokens.joined(separator: " ")
        if let date = SharedDateFormatters.isoWithFractionalSecondsDate(from: joined)
            ?? SharedDateFormatters.isoInternetTimeDate(from: joined)
        {
            return date
        }
        for token in tokens {
            if let date = SharedDateFormatters.isoWithFractionalSecondsDate(from: token)
                ?? SharedDateFormatters.isoInternetTimeDate(from: token)
            {
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
        // Each attempt builds a local POSIX formatter so concurrent parses
        // never share mutable formatter state.
        let utc = TimeZone(secondsFromGMT: 0)
        for format in formats {
            if let date = SharedDateFormatters.posixDate(from: joined, format: format, timeZone: utc) {
                return date
            }
            for token in tokens {
                if let date = SharedDateFormatters.posixDate(from: token, format: format, timeZone: utc) {
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
            // The alias makes this the shared result directly, so no
            // field-by-field copy can drift from the runner's shape.
            return try BoundedProcessRunner.runSync(
                executableURL: executableURL,
                arguments: arguments,
                inputData: inputData,
                timeoutSeconds: timeoutSeconds,
                maxOutputBytes: maxOutputBytes,
                maxErrorBytes: maxProcessErrorBytes
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
            // The alias makes this the shared result directly, so no
            // field-by-field copy can drift from the runner's shape.
            return result
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
            // Name the searched directories so the failure alone explains the
            // miss; the ordering mirrors the resolver (PATH first, then the
            // Homebrew fallbacks) instead of a bare "not in PATH".
            let searched = ContainerMachineManager.runtimeSearchDirectories().joined(separator: ", ")
            return "Apple container CLI ('\(runtime)') was not found in PATH. Install via https://github.com/apple/container. Searched: \(searched)."
        case let .operationFailed(reason):
            return reason
        }
    }
}
