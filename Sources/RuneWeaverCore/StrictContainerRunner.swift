// Rune Weaver Core — Strict ephemeral container runner.
//
// Purpose: own isolated per-turn execution in throwaway containers that mount
// only fresh workspace scratch, keeping sessions from sharing state.
// Scope: argument builders for create plus exec, runtime capability probing,
// owner-only scratch leaves, bounded host invocation, and the session-keyed
// turn registry with terminal reap plus park-aware sweep.
// Architectural role: single owner for strict isolated execution beside the
// other Core sandbox helpers; callers wrap commands with resource limits.

import Foundation
import os

/// Single owner for strict isolated execution.
public enum StrictContainerRunner: Sendable {
    /// Guest image for strict containers.
    public static let defaultImage = "debian:stable-slim"
    /// Name prefix isolating strict containers from every other container.
    public static let strictNamePrefix = "runeweaver-strict-"
    /// Guest memory cap; larger sizes stay deferred. Both tiers cap at 1G.
    public static let defaultMemory = "1G"
    /// Long-lived workspace container never touched by the strict sweep.
    public static let workspaceContainerName = "runeweaver-workspace"
    /// Environment key enforcing hermetic tests; when "1" live paths refuse.
    public static let hermeticTestsEnvKey = "RUNEWEAVER_HERMETIC_TESTS"

    /// Derives the per-session container name from the session identifier.
    /// - Parameter sessionID: Owning turn session.
    /// - Returns: Prefix plus the first 8 lowercase hex chars.
    public static func strictContainerName(for sessionID: UUID) -> String {
        let hex = sessionID.uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        return strictNamePrefix + hex
    }

    /// Builds `container create` arguments for one strict container.
    /// - Parameters:
    ///   - name: Container name.
    ///   - hostPath: Fresh scratch leaf on the host.
    ///   - guestPath: Mount point inside the guest.
    ///   - workdir: Working directory inside the guest.
    ///   - networkDenied: When true the container gets no DNS.
    ///   - memory: Guest memory cap.
    /// - Returns: Exact argument sequence for the runtime.
    public static func containerCreateArguments(
        name: String,
        hostPath: String,
        guestPath: String,
        workdir: String,
        networkDenied: Bool,
        memory: String = defaultMemory
    ) -> [String] {
        containerCreateArguments(
            name: name,
            hostPath: hostPath,
            guestPath: guestPath,
            workdir: workdir,
            networkDenied: networkDenied,
            memory: memory,
            labels: [:]
        )
    }

    /// Builds `container create` arguments with labels placed before the image.
    /// - Parameters:
    ///   - name: Container name.
    ///   - hostPath: Fresh scratch leaf on the host.
    ///   - guestPath: Mount point inside the guest.
    ///   - workdir: Working directory inside the guest.
    ///   - networkDenied: When true the container gets no DNS.
    ///   - memory: Guest memory cap.
    ///   - labels: Label pairs stored as `--label key=value` before the image.
    /// - Returns: Exact argument sequence with labels preceding the image.
    public static func containerCreateArguments(
        name: String,
        hostPath: String,
        guestPath: String,
        workdir: String,
        networkDenied: Bool,
        memory: String = defaultMemory,
        labels: [String: String]
    ) -> [String] {
        var args = [
            "create",
            "--name", name,
            "--volume", "\(hostPath):\(guestPath)",
            "--workdir", workdir,
            "--read-only",
            "--tmpfs", "/tmp",
            "--memory", memory
        ]
        if networkDenied {
            args.append("--no-dns")
        }
        for key in labels.keys.sorted() {
            guard let value = labels[key] else { continue }
            args.append("--label")
            args.append("\(key)=\(value)")
        }
        args.append(contentsOf: ["--entrypoint", "/bin/sleep", defaultImage, "infinity"])
        return args
    }

    /// Builds `container exec` arguments for one strict container.
    /// - Parameters:
    ///   - name: Container name.
    ///   - workdir: Working directory inside the guest.
    ///   - command: Already resource-limited shell command.
    /// - Returns: Exact argument sequence for the runtime.
    public static func containerExecArguments(name: String, workdir: String, command: String) -> [String] {
        ["exec", "-w", workdir, name, "/bin/bash", "-c", command]
    }

    /// Arguments starting one strict container.
    public static func containerStartArguments(name: String) -> [String] {
        ["start", name]
    }

    /// Arguments stopping one strict container.
    public static func containerStopArguments(name: String) -> [String] {
        ["stop", name]
    }

    /// Arguments deleting one strict container.
    public static func containerDeleteArguments(name: String) -> [String] {
        ["delete", name]
    }

    /// Arguments listing every container including stopped ones.
    public static func containerListAllArguments() -> [String] {
        ["list", "--all"]
    }

    /// Parses `container list --all` output into name plus status pairs.
    ///
    /// Rows carry NAME, IMAGE, STATUS left to right, so the image column must
    /// never read as status. The header owns the STATUS index when present;
    /// headerless output falls back to the third column, then to a scan for
    /// status keywords across trailing tokens.
    /// - Parameter output: Combined stdout plus stderr from the listing.
    /// - Returns: Name plus status for each row, header skipped.
    public static func parseContainerListOutput(_ output: String) -> [(name: String, status: String)] {
        var entries: [(name: String, status: String)] = []
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        var statusIndex: Int?
        var sawHeader = false
        for line in lines {
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let name = parts.first else { continue }
            if !sawHeader, name.lowercased() == "name" {
                sawHeader = true
                statusIndex = parts.firstIndex(where: { $0.lowercased() == "status" })
                continue
            }
            guard name.lowercased() != "name", !name.allSatisfy({ $0 == Character("-") }) else { continue }
            let status: String = if let idx = statusIndex, parts.count > idx {
                parts[idx...].joined(separator: " ")
            } else if parts.count >= 3 {
                parts[2...].joined(separator: " ")
            } else if parts.count == 2, isStatusToken(parts[1]) {
                parts[1]
            } else {
                "unknown"
            }
            entries.append((name: name, status: status.isEmpty ? "unknown" : status))
        }
        return entries
    }

    /// Whether a token reads as a container status marker.
    ///
    /// Sweep only reaps stopped shapes, so the fallback must not mistake an
    /// image reference for a status; only explicit status vocabulary counts.
    static func isStatusToken(_ token: String) -> Bool {
        let lowered = token.lowercased()
        return lowered.contains("running")
            || lowered.contains("stopped")
            || lowered.contains("exited")
            || lowered.contains("created")
            || lowered.contains("starting")
            || lowered.contains("stopping")
            || lowered.contains("paused")
            || lowered.contains("unknown")
    }

    /// Whether a status string reports a live container.
    ///
    /// Negated and historical mentions never count as live, so
    /// `not running`, `not-running`, and `stopped (was running)` read as
    /// stopped while a whole-word `running` reads as live.
    /// - Parameter status: Raw status text or full inspect dump.
    /// - Returns: True only for an affirmative live marker.
    public static func isRunningStatus(_ status: String) -> Bool {
        let lowered = status.lowercased()
        if lowered.contains("not running") || lowered.contains("not-running") || lowered.contains("not_running") {
            return false
        }
        if lowered.contains("was running") {
            return false
        }
        let tokens = lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return tokens.contains(where: { $0 == "running" })
    }

    /// Verifies stubbed help text carries every required strict flag.
    /// - Parameters:
    ///   - createHelp: Combined stdout plus stderr from `create --help`.
    ///   - execHelp: Combined stdout plus stderr from `exec --help`.
    public static func probeRuntimeHelp(createHelp: String, execHelp: String) throws {
        let combined = createHelp + "\n" + execHelp
        for flag in ["--volume", "--workdir", "--no-dns", "--read-only", "--tmpfs", "--entrypoint", "--memory"] {
            guard combined.contains(flag) else {
                throw ContainerMachineError.operationFailed(
                    "Container runtime is missing required flag '\(flag)'; refusing strict execution without it."
                )
            }
        }
    }

    /// Requires strict flags across live `create --help` plus `exec --help`.
    public static func probeRuntimeHelp() throws {
        guard ProcessInfo.processInfo.environment["RUNEWEAVER_HERMETIC_TESTS"] != "1" else {
            throw ContainerMachineError.operationFailed(
                "Refusing live container probe by RUNEWEAVER_HERMETIC_TESTS hermetic guard; full suite creates zero containers."
            )
        }
        guard let runtimeURL = ContainerMachineManager.resolveRuntimeURL() else {
            throw ContainerMachineError.runtimeNotFound("container")
        }
        let createHelp: String
        do {
            let result = try BoundedProcessRunner.runSync(
                executableURL: runtimeURL,
                arguments: ["create", "--help"],
                timeoutSeconds: ContainerMachineManager.defaultProcessTimeoutSeconds,
                maxOutputBytes: ContainerMachineManager.maxProcessOutputBytes,
                maxErrorBytes: ContainerMachineManager.maxProcessErrorBytes
            )
            createHelp = result.stdoutString + "\n" + result.stderrString
        } catch {
            throw ContainerMachineError.operationFailed(
                "Unable to probe 'container create --help': \(error.localizedDescription)"
            )
        }
        let execHelp: String
        do {
            let result = try BoundedProcessRunner.runSync(
                executableURL: runtimeURL,
                arguments: ["exec", "--help"],
                timeoutSeconds: ContainerMachineManager.defaultProcessTimeoutSeconds,
                maxOutputBytes: ContainerMachineManager.maxProcessOutputBytes,
                maxErrorBytes: ContainerMachineManager.maxProcessErrorBytes
            )
            execHelp = result.stdoutString + "\n" + result.stderrString
        } catch {
            throw ContainerMachineError.operationFailed(
                "Unable to probe 'container exec --help': \(error.localizedDescription)"
            )
        }
        try probeRuntimeHelp(createHelp: createHelp, execHelp: execHelp)
    }

    /// Creates one UUID scratch leaf under the workspace temp root.
    /// - Parameter workspaceTmp: Workspace `tmp/` directory.
    /// - Returns: Fresh leaf URL.
    public static func makeFreshTmpDir(in workspaceTmp: URL) throws -> URL {
        let leaf = workspaceTmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: leaf,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Creation leaves existing permissions untouched on collision, so
        // re-secure the leaf even though UUID collision is not expected.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: leaf.path)
        return leaf
    }

    /// Best-effort scratch removal that never throws.
    /// - Parameter url: Leaf to delete.
    public static func reapTmpDir(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Runs one host `container` invocation with bounded output.
    /// - Parameters:
    ///   - arguments: Arguments after the runtime binary.
    ///   - timeoutSeconds: Wall-clock budget.
    /// - Returns: Bounded result.
    public static func runHostCommand(arguments: [String], timeoutSeconds: TimeInterval) async throws -> BoundedProcessResult {
        guard ProcessInfo.processInfo.environment["RUNEWEAVER_HERMETIC_TESTS"] != "1" else {
            throw ContainerMachineError.operationFailed(
                "Refusing live container run by RUNEWEAVER_HERMETIC_TESTS hermetic guard; full suite creates zero containers."
            )
        }
        return try await LiveContainerHostRuntime().run(arguments: arguments, timeoutSeconds: timeoutSeconds)
    }

    /// Best-effort stop plus delete for crash idempotence.
    static func bestEffortRemoveContainer(name: String, timeoutSeconds: TimeInterval) async {
        _ = try? await runHostCommand(arguments: containerStopArguments(name: name), timeoutSeconds: timeoutSeconds)
        _ = try? await runHostCommand(arguments: containerDeleteArguments(name: name), timeoutSeconds: timeoutSeconds)
    }

    private struct TestContainerTrack: Sendable {
        let name: String
        let scratch: URL
    }

    private static let testContainerTracks = OSAllocatedUnfairLock(initialState: [UUID: TestContainerTrack]())

    static func noteTestContainer(sessionID: UUID, name: String, scratch: URL) {
        testContainerTracks.withLock { $0[sessionID] = TestContainerTrack(name: name, scratch: scratch) }
    }

    static func forgetTestContainer(sessionID: UUID) {
        testContainerTracks.withLock { _ = $0.removeValue(forKey: sessionID) }
    }

    private static func stopAndDeleteSync(name: String, timeoutSeconds: TimeInterval) {
        guard ProcessInfo.processInfo.environment["RUNEWEAVER_HERMETIC_TESTS"] != "1" else { return }
        guard let runtimeURL = ContainerMachineManager.resolveRuntimeURL() else { return }
        _ = try? ContainerMachineManager.runProcessSync(
            executableURL: runtimeURL,
            arguments: containerStopArguments(name: name),
            timeoutSeconds: timeoutSeconds
        )
        _ = try? ContainerMachineManager.runProcessSync(
            executableURL: runtimeURL,
            arguments: containerDeleteArguments(name: name),
            timeoutSeconds: timeoutSeconds
        )
    }

    /// Synchronously reaps one test session container plus its scratch.
    ///
    /// Synchronous so test `defer` blocks reap even on early return or
    /// cancellation, where `await` is unavailable. Only live creations are
    /// tracked, so stubbed hermetic runs never spawn here.
    public static func reapTestSessionSync(_ sessionID: UUID, timeoutSeconds: TimeInterval = 10) {
        guard let track = testContainerTracks.withLock({ $0.removeValue(forKey: sessionID) }) else { return }
        stopAndDeleteSync(name: track.name, timeoutSeconds: timeoutSeconds)
        reapTmpDir(track.scratch)
    }
}

/// Host runtime behind strict plus machine execution, injectable for hermetic tests.
public protocol ContainerHostRuntime: Sendable {
    /// Resolves the container CLI, nil when absent.
    func resolveRuntimeURL() -> URL?
    /// Runs one host `container` invocation with bounded output.
    func run(arguments: [String], timeoutSeconds: TimeInterval) async throws -> BoundedProcessResult
    /// Requires strict flags across live `create --help` plus `exec --help`.
    func probe() throws
}

/// Live host runtime spawning the real container CLI.
public struct LiveContainerHostRuntime: ContainerHostRuntime, Sendable {
    /// Creates the live runtime.
    public init() {}
    /// Resolves the real container CLI.
    public func resolveRuntimeURL() -> URL? {
        ContainerMachineManager.resolveRuntimeURL()
    }

    /// Runs one host invocation with bounded output.
    public func run(arguments: [String], timeoutSeconds: TimeInterval) async throws -> BoundedProcessResult {
        guard ProcessInfo.processInfo.environment["RUNEWEAVER_HERMETIC_TESTS"] != "1" else {
            throw ContainerMachineError.operationFailed(
                "Refusing live container run by RUNEWEAVER_HERMETIC_TESTS hermetic guard; full suite creates zero containers."
            )
        }
        guard let runtimeURL = ContainerMachineManager.resolveRuntimeURL() else {
            throw ContainerMachineError.runtimeNotFound("container")
        }
        return try await BoundedProcessRunner.runAsync(
            executableURL: runtimeURL,
            arguments: arguments,
            timeoutSeconds: timeoutSeconds,
            maxOutputBytes: 11 * 1024 * 1024,
            maxErrorBytes: 64 * 1024
        )
    }

    /// Probes the live runtime for strict flags.
    public func probe() throws {
        guard ProcessInfo.processInfo.environment["RUNEWEAVER_HERMETIC_TESTS"] != "1" else {
            throw ContainerMachineError.operationFailed(
                "Refusing live container probe by RUNEWEAVER_HERMETIC_TESTS hermetic guard; full suite creates zero containers."
            )
        }
        try StrictContainerRunner.probeRuntimeHelp()
    }
}

/// Stubbed host runtime for hermetic tests, never spawning.
///
/// Tracks every `create --name` plus every scratch leaf noted by the registry,
/// so teardown can assert creation and reap scratch even after failure,
/// cancellation, or early return. The stub never checks cancellation, so a
/// cancelled test still reaps.
public final class HermeticContainerRuntime: ContainerHostRuntime, Sendable {
    private struct State: Sendable {
        var names: [String] = []
        var scratch: [URL] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Canned help carrying every required strict flag.
    public static var cannedHelp: String {
        "--volume --workdir --no-dns --read-only --tmpfs --entrypoint --memory"
    }

    /// Creates the stubbed runtime.
    public init() {}
    /// Non-nil dummy so hermetic guards pass without a real install.
    public func resolveRuntimeURL() -> URL? {
        URL(fileURLWithPath: "/dev/null")
    }

    /// Validates canned help through the shared fail-closed probe.
    public func probe() throws {
        try StrictContainerRunner.probeRuntimeHelp(createHelp: Self.cannedHelp, execHelp: Self.cannedHelp)
    }

    /// Stubs one host invocation, recording `create --name` entries.
    public func run(arguments: [String], timeoutSeconds _: TimeInterval) async throws -> BoundedProcessResult {
        if let first = arguments.first, first == "create",
           let flag = arguments.firstIndex(of: "--name"), flag + 1 < arguments.count
        {
            noteCreated(arguments[flag + 1])
        }
        if arguments.first == "list" {
            return BoundedProcessResult(exitCode: 0, stdout: Data("NAME STATUS\n".utf8), stderr: Data())
        }
        if arguments.first == "inspect" {
            return BoundedProcessResult(exitCode: 1, stdout: Data(), stderr: Data("not found".utf8))
        }
        return BoundedProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
    }

    private func noteCreated(_ name: String) {
        state.withLock { current in
            if !current.names.contains(name) {
                current.names.append(name)
            }
        }
    }

    /// Records one scratch leaf for teardown cleanup.
    public func noteScratch(_ url: URL) {
        let path = url.standardizedFileURL.path
        state.withLock { current in
            if !current.scratch.contains(where: { $0.standardizedFileURL.path == path }) {
                current.scratch.append(url)
            }
        }
    }

    /// Names ever created through the stub, in first-seen order.
    public func createdContainerNames() -> [String] {
        state.withLock { $0.names }
    }

    /// Scratch leaves noted through the stub.
    public func trackedScratchDirs() -> [URL] {
        state.withLock { $0.scratch }
    }

    /// Deletes tracked scratch plus clears tracking, never throwing.
    ///
    /// Scratch removal is synchronous file work, so it runs even when the
    /// calling task is cancelled; container entries are stub-only and need no
    /// spawn to reap.
    public func reapAll() async {
        let snapshot = state.withLock { current -> State in
            let copy = current
            current = State()
            return copy
        }
        for url in snapshot.scratch {
            StrictContainerRunner.reapTmpDir(url)
        }
    }

    /// Synchronous scratch reap for `defer` teardowns that cannot await.
    public func reapAllSync() {
        let snapshot = state.withLock { current -> State in
            let copy = current
            current = State()
            return copy
        }
        for url in snapshot.scratch {
            StrictContainerRunner.reapTmpDir(url)
        }
    }
}

/// Session-keyed owner of one strict container plus one scratch leaf per session.
public actor StrictTurnRegistry {
    /// Live strict turn entry.
    public struct Entry: Sendable, Equatable {
        /// Owning session.
        public let sessionID: UUID
        /// Isolated container name.
        public let containerName: String
        /// Fresh scratch leaf mounted into the container.
        public let scratchURL: URL
        /// Creation instant driving the sweep age.
        public let createdAt: Date
        /// Mount point inside the guest.
        public let guestPath: String
        /// Working directory inside the guest.
        public let workdir: String
        /// Whether the container runs without DNS.
        public let networkDenied: Bool

        /// Creates an entry.
        public init(
            sessionID: UUID,
            containerName: String,
            scratchURL: URL,
            createdAt: Date = Date(),
            guestPath: String = "/workspace",
            workdir: String = "/workspace",
            networkDenied: Bool = true
        ) {
            self.sessionID = sessionID
            self.containerName = containerName
            self.scratchURL = scratchURL
            self.createdAt = createdAt
            self.guestPath = guestPath
            self.workdir = workdir
            self.networkDenied = networkDenied
        }
    }

    /// Outcome of one park-aware sweep.
    public struct SweepResult: Sendable, Equatable {
        /// Strict containers stopped plus deleted.
        public let containersRemoved: Int
        /// Scratch leaves deleted.
        public let scratchRemoved: Int

        /// Creates a sweep result.
        public init(containersRemoved: Int = 0, scratchRemoved: Int = 0) {
            self.containersRemoved = containersRemoved
            self.scratchRemoved = scratchRemoved
        }
    }

    /// Time-to-live for registry entries plus orphan scratch.
    public static let sweepTTLSeconds: TimeInterval = 24 * 60 * 60
    /// Alias keeping scratch aging single-sourced with the sweep TTL.
    public static let scratchTTLSeconds: TimeInterval = sweepTTLSeconds
    /// Shared registry used by live turns.
    public static let shared = StrictTurnRegistry()

    private var entries: [UUID: Entry] = [:]
    private let runtime: any ContainerHostRuntime

    /// Creates an empty registry on the live runtime.
    public init() {
        self.runtime = LiveContainerHostRuntime()
    }

    /// Creates an empty registry on an injected runtime.
    public init(runtime: any ContainerHostRuntime) {
        self.runtime = runtime
    }

    /// Whether this registry stubs the runtime for hermetic tests.
    public var isHermetic: Bool {
        runtime is HermeticContainerRuntime
    }

    /// Container names currently tracked, for teardown assertions.
    public func trackedContainerNames() -> [String] {
        entries.values.map(\.containerName)
    }

    /// Scratch leaves currently tracked, for teardown assertions.
    public func trackedScratchURLs() -> [URL] {
        entries.values.map(\.scratchURL)
    }

    private func runHost(arguments: [String], timeoutSeconds: TimeInterval) async throws -> BoundedProcessResult {
        try await runtime.run(arguments: arguments, timeoutSeconds: timeoutSeconds)
    }

    private func bestEffortRemove(name: String, timeoutSeconds: TimeInterval) async {
        _ = try? await runtime.run(
            arguments: StrictContainerRunner.containerStopArguments(name: name),
            timeoutSeconds: timeoutSeconds
        )
        _ = try? await runtime.run(
            arguments: StrictContainerRunner.containerDeleteArguments(name: name),
            timeoutSeconds: timeoutSeconds
        )
    }

    private func noteScratchIfHermetic(_ url: URL) {
        (runtime as? HermeticContainerRuntime)?.noteScratch(url)
    }

    /// Pure reap verdict: parked turns keep their container, terminal turns reap it.
    /// - Parameter isParked: Whether the turn parked awaiting approval.
    /// - Returns: True when the caller must reap.
    public static func shouldReapAfterOutcome(isParked: Bool) -> Bool {
        !isParked
    }

    /// Returns the live entry for one session, if any.
    /// - Parameter sessionID: Owning session.
    /// - Returns: Entry, or nil when absent.
    public func entry(for sessionID: UUID) -> Entry? {
        entries[sessionID]
    }

    /// Returns the container name for one session, if tracked.
    public func containerName(for sessionID: UUID) -> String? {
        entries[sessionID]?.containerName
    }

    /// Returns the scratch leaf for one session, if tracked.
    public func scratchURL(for sessionID: UUID) -> URL? {
        entries[sessionID]?.scratchURL
    }

    /// Number of tracked sessions.
    public var count: Int {
        entries.count
    }

    /// Derives parked session IDs from the live approvals list.
    public static func parkedSessionIDs(from requests: [PermissionRequest]) -> Set<UUID> {
        Set(requests.compactMap(\.sessionID))
    }

    /// Ensures one isolated container plus one scratch leaf for the session.
    ///
    /// Reuses the live entry within the session when the network mode matches;
    /// a network change recreates the container on the existing scratch so a
    /// parked-then-approved turn cannot reuse the wrong DNS mode. Otherwise
    /// pre-deletes any same-name leftover before creating, so a crashed turn
    /// cannot collide.
    public func ensure(
        sessionID: UUID,
        workspaceTmp: URL,
        guestPath: String = "/workspace",
        workdir: String = "/workspace",
        networkDenied: Bool = true,
        memory: String = StrictContainerRunner.defaultMemory,
        timeoutSeconds: TimeInterval = 30
    ) async throws -> Entry {
        if let existing = entries[sessionID], existing.networkDenied == networkDenied {
            return existing
        }
        if let mismatched = entries[sessionID] {
            let recreated = try await recreateForNetworkChange(
                existing: mismatched,
                guestPath: guestPath,
                workdir: workdir,
                networkDenied: networkDenied,
                memory: memory,
                timeoutSeconds: timeoutSeconds
            )
            entries[sessionID] = recreated
            if !(runtime is HermeticContainerRuntime) {
                StrictContainerRunner.noteTestContainer(sessionID: sessionID, name: recreated.containerName, scratch: recreated.scratchURL)
            }
            return recreated
        }
        let name = StrictContainerRunner.strictContainerName(for: sessionID)
        let scratch = try StrictContainerRunner.makeFreshTmpDir(in: workspaceTmp)
        noteScratchIfHermetic(scratch)
        do {
            await bestEffortRemove(name: name, timeoutSeconds: timeoutSeconds)
            let createArgs = StrictContainerRunner.containerCreateArguments(
                name: name,
                hostPath: scratch.path,
                guestPath: guestPath,
                workdir: workdir,
                networkDenied: networkDenied,
                memory: memory
            )
            _ = try await runHost(arguments: createArgs, timeoutSeconds: timeoutSeconds)
            _ = try await runHost(
                arguments: StrictContainerRunner.containerStartArguments(name: name),
                timeoutSeconds: timeoutSeconds
            )
            let entry = Entry(
                sessionID: sessionID,
                containerName: name,
                scratchURL: scratch,
                createdAt: Date(),
                guestPath: guestPath,
                workdir: workdir,
                networkDenied: networkDenied
            )
            entries[sessionID] = entry
            if !(runtime is HermeticContainerRuntime) {
                StrictContainerRunner.noteTestContainer(sessionID: sessionID, name: name, scratch: scratch)
            }
            return entry
        } catch {
            StrictContainerRunner.reapTmpDir(scratch)
            throw error
        }
    }

    /// Recreates the session container on its existing scratch after a network change.
    private func recreateForNetworkChange(
        existing: Entry,
        guestPath: String,
        workdir: String,
        networkDenied: Bool,
        memory: String,
        timeoutSeconds: TimeInterval
    ) async throws -> Entry {
        await bestEffortRemove(name: existing.containerName, timeoutSeconds: timeoutSeconds)
        let createArgs = StrictContainerRunner.containerCreateArguments(
            name: existing.containerName,
            hostPath: existing.scratchURL.path,
            guestPath: guestPath,
            workdir: workdir,
            networkDenied: networkDenied,
            memory: memory
        )
        _ = try await runHost(arguments: createArgs, timeoutSeconds: timeoutSeconds)
        _ = try await runHost(
            arguments: StrictContainerRunner.containerStartArguments(name: existing.containerName),
            timeoutSeconds: timeoutSeconds
        )
        return Entry(
            sessionID: existing.sessionID,
            containerName: existing.containerName,
            scratchURL: existing.scratchURL,
            createdAt: Date(),
            guestPath: guestPath,
            workdir: workdir,
            networkDenied: networkDenied
        )
    }

    /// Executes an already resource-limited command in the session container.
    public func exec(
        sessionID: UUID,
        command: String,
        timeoutSeconds: TimeInterval = 30
    ) async throws -> BoundedProcessResult {
        guard let entry = entries[sessionID] else {
            throw ContainerMachineError.operationFailed("No strict container for session \(sessionID.uuidString).")
        }
        let args = StrictContainerRunner.containerExecArguments(
            name: entry.containerName,
            workdir: entry.workdir,
            command: command
        )
        return try await runHost(arguments: args, timeoutSeconds: timeoutSeconds)
    }

    /// Executes with an explicit workdir override.
    public func exec(
        sessionID: UUID,
        workdir: String,
        command: String,
        timeoutSeconds: TimeInterval = 30
    ) async throws -> BoundedProcessResult {
        guard let entry = entries[sessionID] else {
            throw ContainerMachineError.operationFailed("No strict container for session \(sessionID.uuidString).")
        }
        let args = StrictContainerRunner.containerExecArguments(
            name: entry.containerName,
            workdir: workdir.isEmpty ? entry.workdir : workdir,
            command: command
        )
        return try await runHost(arguments: args, timeoutSeconds: timeoutSeconds)
    }

    /// Stops plus deletes the container and deletes scratch for one session.
    public func reap(sessionID: UUID, timeoutSeconds: TimeInterval = 30) async {
        guard let entry = entries.removeValue(forKey: sessionID) else { return }
        StrictContainerRunner.forgetTestContainer(sessionID: sessionID)
        await bestEffortRemove(name: entry.containerName, timeoutSeconds: timeoutSeconds)
        StrictContainerRunner.reapTmpDir(entry.scratchURL)
    }

    /// Reaps every tracked session, for teardown after failure, cancellation, or early return.
    public func reapAll(timeoutSeconds: TimeInterval = 30) async {
        let snapshot = Array(entries.values)
        entries.removeAll()
        for entry in snapshot {
            StrictContainerRunner.forgetTestContainer(sessionID: entry.sessionID)
            await bestEffortRemove(name: entry.containerName, timeoutSeconds: timeoutSeconds)
            StrictContainerRunner.reapTmpDir(entry.scratchURL)
        }
        await (runtime as? HermeticContainerRuntime)?.reapAll()
    }

    /// Reaps only after terminal outcomes, never on park.
    public func reapAfterOutcome(sessionID: UUID, isParked: Bool, timeoutSeconds: TimeInterval = 30) async {
        guard Self.shouldReapAfterOutcome(isParked: isParked) else { return }
        await reap(sessionID: sessionID, timeoutSeconds: timeoutSeconds)
    }

    /// Park-aware sweep removing stopped strict containers plus day-old scratch.
    ///
    /// Sessions holding undecided approvals are skipped regardless of age;
    /// the workspace container is skipped by name while other names filter by prefix.
    public func sweep(
        workspaceTmp: URL,
        parkedSessionIDs: Set<UUID>,
        now: Date = Date(),
        timeoutSeconds: TimeInterval = 30
    ) async -> SweepResult {
        var containersRemoved = 0
        var scratchRemoved = 0
        let parkedNames = Set(parkedSessionIDs.map { StrictContainerRunner.strictContainerName(for: $0) })

        var expiredIDs: [UUID] = []
        for (sessionID, entry) in entries where !parkedSessionIDs.contains(sessionID) {
            if now.timeIntervalSince(entry.createdAt) > Self.sweepTTLSeconds {
                expiredIDs.append(sessionID)
            }
        }
        for sessionID in expiredIDs {
            guard let entry = entries.removeValue(forKey: sessionID) else { continue }
            await bestEffortRemove(name: entry.containerName, timeoutSeconds: timeoutSeconds)
            StrictContainerRunner.reapTmpDir(entry.scratchURL)
            containersRemoved += 1
            scratchRemoved += 1
        }

        if runtime.resolveRuntimeURL() != nil {
            if let listed = try? await runHost(
                arguments: StrictContainerRunner.containerListAllArguments(),
                timeoutSeconds: timeoutSeconds
            ) {
                let combined = listed.stdoutString + "\n" + listed.stderrString
                let liveNames = Set(entries.values.map(\.containerName))
                for row in StrictContainerRunner.parseContainerListOutput(combined) {
                    guard row.name != StrictContainerRunner.workspaceContainerName else { continue }
                    guard row.name.hasPrefix(StrictContainerRunner.strictNamePrefix) else { continue }
                    guard !parkedNames.contains(row.name) else { continue }
                    guard !liveNames.contains(row.name) else { continue }
                    let lowered = row.status.lowercased()
                    let isStopped = lowered.contains("stopped") || lowered.contains("exited") || lowered.contains("created")
                    guard isStopped else { continue }
                    await bestEffortRemove(name: row.name, timeoutSeconds: timeoutSeconds)
                    containersRemoved += 1
                }
            }
        }

        let liveScratch = Set(entries.values.map(\.scratchURL.standardizedFileURL.path))
        if let children = try? FileManager.default.contentsOfDirectory(
            at: workspaceTmp,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        ) {
            for child in children {
                guard !liveScratch.contains(child.standardizedFileURL.path) else { continue }
                let values = try? child.resourceValues(forKeys: [.contentModificationDateKey])
                // A leaf without a readable mtime reads as expired so an
                // unreadable orphan cannot pin scratch past the TTL.
                let mtime = values?.contentModificationDate ?? Date.distantPast
                guard now.timeIntervalSince(mtime) > Self.scratchTTLSeconds else { continue }
                StrictContainerRunner.reapTmpDir(child)
                scratchRemoved += 1
            }
        }
        return SweepResult(containersRemoved: containersRemoved, scratchRemoved: scratchRemoved)
    }

    /// Sweep deriving parked sessions from the live approvals queue.
    public func sweep(
        workspaceTmp: URL,
        approvals: ApprovalQueue,
        now: Date = Date(),
        timeoutSeconds: TimeInterval = 30
    ) async -> SweepResult {
        let listed = await approvals.list()
        let parked = Self.parkedSessionIDs(from: listed)
        return await sweep(workspaceTmp: workspaceTmp, parkedSessionIDs: parked, now: now, timeoutSeconds: timeoutSeconds)
    }
}

/// Shared container seam carrying one runtime plus its registries.
///
/// Production passes nil and uses the shared live registry plus the live
/// machine client, preserving per-turn strict plus long-lived workspace reuse.
/// Hermetic tests pass a stubbed seam so strict plus machine creations never
/// spawn and teardown reaps every tracked name plus scratch leaf.
public struct ContainerSeam: Sendable {
    /// Host runtime behind both tiers.
    public let runtime: any ContainerHostRuntime
    /// Isolated strict registry sharing the runtime.
    public let strictRegistry: StrictTurnRegistry
    /// Machine client sharing the runtime.
    public let machineClient: MachineContainerClient
    /// Guest memory cap applied at creation.
    public let memory: String

    /// Creates a seam sharing one runtime across both tiers.
    public init(runtime: (any ContainerHostRuntime)? = nil, memory: String = StrictContainerRunner.defaultMemory) {
        let resolved: any ContainerHostRuntime = runtime ?? LiveContainerHostRuntime()
        self.runtime = resolved
        self.strictRegistry = StrictTurnRegistry(runtime: resolved)
        self.machineClient = MachineContainerClient(runtime: resolved)
        self.memory = memory
    }

    /// Live seam for production paths.
    public static var live: Self {
        Self()
    }

    /// Hermetic seam plus its stub, sharing one stubbed runtime.
    ///
    /// The stubbed seam carries the production memory cap so hermetic turns
    /// verify the same 1G limit production enforces.
    public static func hermetic() -> (seam: Self, runtime: HermeticContainerRuntime) {
        let stub = HermeticContainerRuntime()
        return (Self(runtime: stub), stub)
    }
}
