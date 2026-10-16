// Rune Weaver Core — Strict ephemeral container runner.

import Foundation
import os

/// Single owner for strict isolated execution.
public enum StrictContainerRunner: Sendable {
    /// Guest image for strict containers.
    public static let defaultImage = "debian:stable-slim"
    /// Name prefix isolating strict containers from every other container.
    public static let strictNamePrefix = "runeweaver-strict-"
    /// Fallback guest memory cap when no containers policy is threaded.
    /// Production bash tiers read the threaded `ContainerSeam` memory instead.
    public static var defaultMemory: String {
        memoryCapString(forMB: ContainersConfig.defaultMemoryMB)
    }

    /// Clamped memory budget from the loaded containers policy.
    public static func clampedMemoryMB(for config: ContainersConfig) -> Int {
        min(max(config.memoryMB, ContainersConfig.minMemoryMB), ContainersConfig.maxMemoryMB)
    }

    /// Clamped concurrency cap from the loaded containers policy.
    public static func clampedMaxConcurrent(for config: ContainersConfig) -> Int {
        min(max(config.maxConcurrent, ContainersConfig.minMaxConcurrent), ContainersConfig.maxMaxConcurrent)
    }

    /// Memory string for the loaded containers policy.
    public static func memoryCap(for config: ContainersConfig) -> String {
        memoryCapString(forMB: clampedMemoryMB(for: config))
    }

    /// Long-lived workspace container never touched by the strict sweep.
    public static let workspaceContainerName = "runeweaver-workspace"
    /// Environment key enforcing hermetic tests; when "1" live paths refuse.
    public static let hermeticTestsEnvKey = "RUNEWEAVER_HERMETIC_TESTS"
    /// Default timeout for container CLI invocations, mirroring the plugin
    /// bridge so an untrusted detonation cannot hang a turn.
    public static let defaultProcessTimeoutSeconds: TimeInterval = 30
    /// Maximum stdout bytes retained from a container invocation, bounding
    /// listings and single-entry extractions.
    public static let maxProcessOutputBytes = 11 * 1024 * 1024
    /// Maximum stderr bytes retained for diagnostics.
    public static let maxProcessErrorBytes = 64 * 1024
    /// Legacy detonation name shapes kept inside the reclamation scope. Longer `runeweaver-` names
    /// (the SearXNG service container, the workspace container) are never derived from this list.
    public static let detonationNamePrefixes = ["runeweaver-session-", "runeweaver-attach-"]

    /// Whether a container name counts as an ephemeral RuneWeaver container. The machine singleton
    /// workspace container and the SearXNG service container are never matched.
    public static func isEphemeralContainerName(_ name: String) -> Bool {
        guard name != workspaceContainerName else { return false }
        if name.hasPrefix(strictNamePrefix) {
            return true
        }
        return detonationNamePrefixes.contains { name.hasPrefix($0) }
    }

    /// Formats one configured MB value as the runtime memory string.
    /// - Parameter megabytes: Configured memory budget in megabytes.
    /// - Returns: Runtime memory string (e.g. "512M").
    public static func memoryCapString(forMB megabytes: Int) -> String {
        "\(megabytes)M"
    }

    /// Known install locations always probed after PATH entries.
    /// Single owner for runtime lookup shared by detonation and search:
    /// a minimal PATH must never hide a standard Homebrew install.
    public static let fallbackRuntimeDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// Ordered directories probed for the container runtime. PATH order wins so an operator
    /// override shadows the fallback, while the appended fallbacks keep a Homebrew install visible
    /// when PATH is minimal.
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

    /// Resolves the absolute path for the container CLI. Absolute runtime values probe directly
    /// without PATH expansion; bare names probe the shared search ordering with no Docker fallback.
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

    /// Resolves the runtime against an explicit PATH value for testing. Routes the same fallback
    /// ordering through a stubbed filesystem probe so minimal-PATH coverage stays verifiable without
    /// touching the real PATH.
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

    /// Verifies stubbed help text carries every required strict flag. createHelp:
    /// Combined stdout plus stderr from `create --help`.
    public static func probeRuntimeHelp(createHelp: String, execHelp: String) throws {
        let combined = createHelp + "\n" + execHelp
        for flag in ["--volume", "--workdir", "--no-dns", "--read-only", "--tmpfs", "--entrypoint", "--memory"] {
            guard combined.contains(flag) else {
                throw ContainerOperationError.operationFailed(
                    "Container runtime is missing required flag '\(flag)'; refusing strict execution without it."
                )
            }
        }
    }

    /// Requires strict flags across live `create --help` plus `exec --help`.
    public static func probeRuntimeHelp() throws {
        guard ProcessInfo.processInfo.environment["RUNEWEAVER_HERMETIC_TESTS"] != "1" else {
            throw ContainerOperationError.operationFailed(
                "Refusing live container probe by RUNEWEAVER_HERMETIC_TESTS hermetic guard; full suite creates zero containers."
            )
        }
        guard let runtimeURL = resolveRuntimeURL() else {
            throw ContainerOperationError.runtimeNotFound("container")
        }
        let createHelp: String
        do {
            let result = try BoundedProcessRunner.runSync(
                executableURL: runtimeURL,
                arguments: ["create", "--help"],
                timeoutSeconds: defaultProcessTimeoutSeconds,
                maxOutputBytes: maxProcessOutputBytes,
                maxErrorBytes: maxProcessErrorBytes
            )
            createHelp = result.stdoutString + "\n" + result.stderrString
        } catch {
            throw ContainerOperationError.operationFailed(
                "Unable to probe 'container create --help': \(error.localizedDescription)"
            )
        }
        let execHelp: String
        do {
            let result = try BoundedProcessRunner.runSync(
                executableURL: runtimeURL,
                arguments: ["exec", "--help"],
                timeoutSeconds: defaultProcessTimeoutSeconds,
                maxOutputBytes: maxProcessOutputBytes,
                maxErrorBytes: maxProcessErrorBytes
            )
            execHelp = result.stdoutString + "\n" + result.stderrString
        } catch {
            throw ContainerOperationError.operationFailed(
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

    /// Runs one host `container` invocation with bounded output. arguments:
    /// Arguments after the runtime binary.
    public static func runHostCommand(arguments: [String], timeoutSeconds: TimeInterval) async throws -> BoundedProcessResult {
        guard ProcessInfo.processInfo.environment["RUNEWEAVER_HERMETIC_TESTS"] != "1" else {
            throw ContainerOperationError.operationFailed(
                "Refusing live container run by RUNEWEAVER_HERMETIC_TESTS hermetic guard; full suite creates zero containers."
            )
        }
        return try await LiveContainerHostRuntime().run(arguments: arguments, timeoutSeconds: timeoutSeconds)
    }

    static func bestEffortRemoveContainer(name: String, timeoutSeconds: TimeInterval) async {
        do {
            _ = try await runHostCommand(arguments: containerStopArguments(name: name), timeoutSeconds: timeoutSeconds)
        } catch is CancellationError {
            // Teardown continues
        } catch {
            RuneWeaverLog.sandbox.debug("StrictContainerRunner: stop container failed: \(error.localizedDescription)")
        }
        do {
            _ = try await runHostCommand(arguments: containerDeleteArguments(name: name), timeoutSeconds: timeoutSeconds)
        } catch is CancellationError {
            // Teardown continues
        } catch {
            RuneWeaverLog.sandbox.debug("StrictContainerRunner: delete container failed: \(error.localizedDescription)")
        }
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
        guard ProcessInfo.processInfo.environment[hermeticTestsEnvKey] != "1" else { return }
        guard let runtimeURL = resolveRuntimeURL() else { return }
        _ = try? BoundedProcessRunner.runSync(
            executableURL: runtimeURL,
            arguments: containerStopArguments(name: name),
            timeoutSeconds: timeoutSeconds
        )
        _ = try? BoundedProcessRunner.runSync(
            executableURL: runtimeURL,
            arguments: containerDeleteArguments(name: name),
            timeoutSeconds: timeoutSeconds
        )
    }

    /// Synchronously reaps one test session container plus its scratch. Only live creations are
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
    /// Runs one host `container` invocation with bounded output and optional stdin bytes.
    func run(arguments: [String], inputData: Data?, timeoutSeconds: TimeInterval) async throws -> BoundedProcessResult
    /// Requires strict flags across live `create --help` plus `exec --help`.
    func probe() throws
}

extension ContainerHostRuntime {
    /// Convenience forwarding a stdin-less invocation.
    public func run(arguments: [String], timeoutSeconds: TimeInterval) async throws -> BoundedProcessResult {
        try await run(arguments: arguments, inputData: nil, timeoutSeconds: timeoutSeconds)
    }
}

/// Live host runtime spawning the real container CLI.
public struct LiveContainerHostRuntime: ContainerHostRuntime, Sendable {
    /// Creates the live runtime.
    public init() {}
    /// Resolves the real container CLI from the shared strict runner resolver.
    public func resolveRuntimeURL() -> URL? {
        StrictContainerRunner.resolveRuntimeURL()
    }

    /// Runs one host invocation with bounded output and optional stdin bytes.
    public func run(arguments: [String], inputData: Data? = nil, timeoutSeconds: TimeInterval) async throws -> BoundedProcessResult {
        guard ProcessInfo.processInfo.environment["RUNEWEAVER_HERMETIC_TESTS"] != "1" else {
            throw ContainerOperationError.operationFailed(
                "Refusing live container run by RUNEWEAVER_HERMETIC_TESTS hermetic guard; full suite creates zero containers."
            )
        }
        guard let runtimeURL = StrictContainerRunner.resolveRuntimeURL() else {
            throw ContainerOperationError.runtimeNotFound("container")
        }
        return try await BoundedProcessRunner.runAsync(
            executableURL: runtimeURL,
            arguments: arguments,
            inputData: inputData,
            timeoutSeconds: timeoutSeconds,
            maxOutputBytes: StrictContainerRunner.maxProcessOutputBytes,
            maxErrorBytes: StrictContainerRunner.maxProcessErrorBytes
        )
    }

    /// Probes the live runtime for strict flags.
    public func probe() throws {
        guard ProcessInfo.processInfo.environment["RUNEWEAVER_HERMETIC_TESTS"] != "1" else {
            throw ContainerOperationError.operationFailed(
                "Refusing live container probe by RUNEWEAVER_HERMETIC_TESTS hermetic guard; full suite creates zero containers."
            )
        }
        try StrictContainerRunner.probeRuntimeHelp()
    }
}

/// Stubbed host runtime for hermetic tests, never spawning.
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
    public func run(arguments: [String], inputData _: Data? = nil, timeoutSeconds _: TimeInterval) async throws -> BoundedProcessResult {
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

    /// Deletes tracked scratch plus clears tracking, never throwing. Scratch removal is synchronous
    /// file work, so it runs even when the calling task is cancelled; container entries are
    /// stub-only and need no spawn to reap.
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
    private var entries: [UUID: Entry] = [:]
    private let runtime: any ContainerHostRuntime
    /// Shared ephemeral admission ledger checked before every create.
    public let ephemeralLedger: EphemeralContainerLedger

    /// Creates an empty registry on the live runtime.
    public init() {
        self.runtime = LiveContainerHostRuntime()
        self.ephemeralLedger = EphemeralContainerLedger()
    }

    /// Creates an empty registry on an injected runtime, sharing an injected
    /// ledger or creating one on the same runtime.
    public init(runtime: any ContainerHostRuntime, ephemeralLedger: EphemeralContainerLedger? = nil) {
        self.runtime = runtime
        self.ephemeralLedger = ephemeralLedger ?? EphemeralContainerLedger(runtime: runtime)
    }

    /// Applies the loaded containers cap to the shared ledger in place.
    public func applyContainersConfig(_ config: ContainersConfig) async {
        await ephemeralLedger.updateMaxConcurrent(StrictContainerRunner.clampedMaxConcurrent(for: config))
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
        do {
            _ = try await runtime.run(
                arguments: StrictContainerRunner.containerStopArguments(name: name),
                timeoutSeconds: timeoutSeconds
            )
        } catch is CancellationError {
            // Teardown continues
        } catch {
            RuneWeaverLog.sandbox.debug("StrictContainerRunner: bestEffortRemove stop failed: \(error.localizedDescription)")
        }
        do {
            _ = try await runtime.run(
                arguments: StrictContainerRunner.containerDeleteArguments(name: name),
                timeoutSeconds: timeoutSeconds
            )
        } catch is CancellationError {
            // Teardown continues
        } catch {
            RuneWeaverLog.sandbox.debug("StrictContainerRunner: bestEffortRemove delete failed: \(error.localizedDescription)")
        }
    }

    private func noteScratchIfHermetic(_ url: URL) {
        (runtime as? HermeticContainerRuntime)?.noteScratch(url)
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

    /// Ensures one isolated container plus one scratch leaf for the session.
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
        // Admission rides the shared ledger before any create so the cap
        // denies fail-closed and census failure never spawns; the machine
        // singleton stays exempt from counts.
        try await ephemeralLedger.admit(timeoutSeconds: timeoutSeconds)
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
            await ephemeralLedger.register(name: name)
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
            throw ContainerOperationError.operationFailed("No strict container for session \(sessionID.uuidString).")
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
            throw ContainerOperationError.operationFailed("No strict container for session \(sessionID.uuidString).")
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
        await ephemeralLedger.unregister(name: entry.containerName)
        StrictContainerRunner.reapTmpDir(entry.scratchURL)
    }

    /// Reaps every tracked session, for teardown after failure, cancellation, or early return.
    public func reapAll(timeoutSeconds: TimeInterval = 30) async {
        let snapshot = Array(entries.values)
        entries.removeAll()
        for entry in snapshot {
            StrictContainerRunner.forgetTestContainer(sessionID: entry.sessionID)
            await bestEffortRemove(name: entry.containerName, timeoutSeconds: timeoutSeconds)
            await ephemeralLedger.unregister(name: entry.containerName)
            StrictContainerRunner.reapTmpDir(entry.scratchURL)
        }
        await (runtime as? HermeticContainerRuntime)?.reapAll()
    }

    /// Reaps only after terminal outcomes, never on park.
    public func reapAfterOutcome(sessionID: UUID, isParked: Bool, timeoutSeconds: TimeInterval = 30) async {
        guard Self.shouldReapAfterOutcome(isParked: isParked) else { return }
        await reap(sessionID: sessionID, timeoutSeconds: timeoutSeconds)
    }

    /// Park-aware sweep removing stopped ephemeral containers plus expired orphan scratch.
    public func sweep(
        workspaceTmp: URL,
        parkedSessionIDs: Set<UUID>,
        now: Date = Date(),
        ttlSeconds: TimeInterval = StrictTurnRegistry.sweepTTLSeconds,
        timeoutSeconds: TimeInterval = 30
    ) async -> SweepResult {
        var containersRemoved = 0
        var scratchRemoved = 0
        let parkedNames = Set(parkedSessionIDs.map { StrictContainerRunner.strictContainerName(for: $0) })
        let expiredIDs = expiredEntryIDs(parkedSessionIDs: parkedSessionIDs, now: now, ttlSeconds: ttlSeconds)
        let reaped = await reapExpiredEntries(expiredIDs, timeoutSeconds: timeoutSeconds)
        containersRemoved += reaped.containersRemoved
        scratchRemoved += reaped.scratchRemoved
        if let combined = await listedContainersForSweep(timeoutSeconds: timeoutSeconds) {
            let liveNames = Set(entries.values.map(\.containerName))
            containersRemoved += await reclaimListedOrphans(
                combined: combined,
                excludedNames: parkedNames.union(liveNames),
                now: now,
                ttlSeconds: ttlSeconds,
                timeoutSeconds: timeoutSeconds
            )
        }
        let liveScratch = Set(entries.values.map(\.scratchURL.standardizedFileURL.path))
        scratchRemoved += reclaimOrphanScratch(
            workspaceTmp: workspaceTmp,
            liveScratch: liveScratch,
            now: now,
            ttlSeconds: ttlSeconds
        )
        return SweepResult(containersRemoved: containersRemoved, scratchRemoved: scratchRemoved)
    }

    /// Whether one running orphan is old enough to reclaim.
    private func isExpiredRunningOrphan(
        name: String,
        now: Date,
        ttlSeconds: TimeInterval,
        timeoutSeconds: TimeInterval
    ) async -> Bool {
        if let admitted = await ephemeralLedger.registrationDate(for: name) {
            return now.timeIntervalSince(admitted) > ttlSeconds
        }
        guard let created = await inspectCreatedDate(name: name, timeoutSeconds: timeoutSeconds) else {
            return false
        }
        return now.timeIntervalSince(created) > ttlSeconds
    }

    /// Reads one orphan creation stamp without ever throwing.
    private func inspectCreatedDate(name: String, timeoutSeconds: TimeInterval) async -> Date? {
        do {
            let probed = try await runHost(
                arguments: StrictContainerRunner.containerInspectArguments(name: name),
                timeoutSeconds: timeoutSeconds
            )
            guard probed.exitCode == 0 else { return nil }
            return StrictContainerRunner.inspectCreatedDate(from: probed.stdoutString + "\n" + probed.stderrString)
        } catch {
            return nil
        }
    }

    /// Sweep deriving parked sessions from the live approvals queue.
    public func sweep(
        workspaceTmp: URL,
        approvals: ApprovalQueue,
        now: Date = Date(),
        ttlSeconds: TimeInterval = StrictTurnRegistry.sweepTTLSeconds,
        timeoutSeconds: TimeInterval = 30
    ) async -> SweepResult {
        let listed = await approvals.list()
        let parked = Self.parkedSessionIDs(from: listed)
        return await sweep(
            workspaceTmp: workspaceTmp,
            parkedSessionIDs: parked,
            now: now,
            ttlSeconds: ttlSeconds,
            timeoutSeconds: timeoutSeconds
        )
    }
}

// MARK: - StrictTurnRegistry Sweep Steps

extension StrictTurnRegistry {
    private func expiredEntryIDs(parkedSessionIDs: Set<UUID>, now: Date, ttlSeconds: TimeInterval) -> [UUID] {
        var expiredIDs: [UUID] = []
        for (sessionID, entry) in entries where !parkedSessionIDs.contains(sessionID) {
            if now.timeIntervalSince(entry.createdAt) > ttlSeconds {
                expiredIDs.append(sessionID)
            }
        }
        return expiredIDs
    }

    private func reapExpiredEntries(_ expiredIDs: [UUID], timeoutSeconds: TimeInterval) async -> SweepResult {
        var containersRemoved = 0
        var scratchRemoved = 0
        for sessionID in expiredIDs {
            guard let entry = entries.removeValue(forKey: sessionID) else { continue }
            await bestEffortRemove(name: entry.containerName, timeoutSeconds: timeoutSeconds)
            await ephemeralLedger.unregister(name: entry.containerName)
            StrictContainerRunner.reapTmpDir(entry.scratchURL)
            containersRemoved += 1
            scratchRemoved += 1
        }
        return SweepResult(containersRemoved: containersRemoved, scratchRemoved: scratchRemoved)
    }

    private func listedContainersForSweep(timeoutSeconds: TimeInterval) async -> String? {
        guard runtime.resolveRuntimeURL() != nil else { return nil }
        do {
            let listed = try await runHost(
                arguments: StrictContainerRunner.containerListAllArguments(),
                timeoutSeconds: timeoutSeconds
            )
            return listed.stdoutString + "\n" + listed.stderrString
        } catch is CancellationError {
            return nil
        } catch {
            RuneWeaverLog.sandbox.debug("StrictContainerRunner: failed to list containers during sweep: \(error.localizedDescription)")
            return nil
        }
    }

    private func reclaimListedOrphans(
        combined: String,
        excludedNames: Set<String>,
        now: Date,
        ttlSeconds: TimeInterval,
        timeoutSeconds: TimeInterval
    ) async -> Int {
        var removed = 0
        for row in StrictContainerRunner.parseContainerListOutput(combined) {
            guard row.name != StrictContainerRunner.workspaceContainerName else { continue }
            guard StrictContainerRunner.isEphemeralContainerName(row.name) else { continue }
            guard !excludedNames.contains(row.name) else { continue }
            if !isStoppedStatus(row.status) {
                guard StrictContainerRunner.isRunningStatus(row.status) else { continue }
                guard !Task.isCancelled else { break }
                guard await isExpiredRunningOrphan(
                    name: row.name,
                    now: now,
                    ttlSeconds: ttlSeconds,
                    timeoutSeconds: timeoutSeconds
                ) else { continue }
            }
            await bestEffortRemove(name: row.name, timeoutSeconds: timeoutSeconds)
            await ephemeralLedger.unregister(name: row.name)
            removed += 1
        }
        return removed
    }

    private func isStoppedStatus(_ status: String) -> Bool {
        let lowered = status.lowercased()
        return lowered.contains("stopped") || lowered.contains("exited") || lowered.contains("created")
    }

    private func reclaimOrphanScratch(
        workspaceTmp: URL,
        liveScratch: Set<String>,
        now: Date,
        ttlSeconds: TimeInterval
    ) -> Int {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: workspaceTmp,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        ) else { return 0 }
        var removed = 0
        for child in children {
            guard !liveScratch.contains(child.standardizedFileURL.path) else { continue }
            let values = try? child.resourceValues(forKeys: [.contentModificationDateKey])
            // A leaf without a readable mtime reads as expired so an
            // unreadable orphan cannot pin scratch past the TTL.
            let mtime = values?.contentModificationDate ?? Date.distantPast
            guard now.timeIntervalSince(mtime) > ttlSeconds else { continue }
            StrictContainerRunner.reapTmpDir(child)
            removed += 1
        }
        return removed
    }
}

/// Shared container seam carrying one runtime plus its registries. Hermetic tests pass a stubbed
/// seam so strict plus machine creations never spawn and teardown reaps every tracked name plus
/// scratch leaf.
public struct ContainerSeam: Sendable {
    /// Host runtime behind both tiers.
    public let runtime: any ContainerHostRuntime
    /// Isolated strict registry sharing the runtime.
    public let strictRegistry: StrictTurnRegistry
    /// Machine client sharing the runtime.
    public let machineClient: MachineContainerClient
    /// Shared ephemeral admission ledger owning the concurrency cap.
    public let ephemeralLedger: EphemeralContainerLedger
    /// Guest memory cap applied at creation.
    public let memory: String

    /// Creates a seam sharing one runtime across both tiers.
    public init(runtime: (any ContainerHostRuntime)? = nil, memory: String = StrictContainerRunner.defaultMemory) {
        let resolved: any ContainerHostRuntime = runtime ?? LiveContainerHostRuntime()
        let ledger = EphemeralContainerLedger(runtime: resolved)
        self.runtime = resolved
        self.strictRegistry = StrictTurnRegistry(runtime: resolved, ephemeralLedger: ledger)
        self.machineClient = MachineContainerClient(runtime: resolved)
        self.ephemeralLedger = ledger
        self.memory = memory
    }

    /// Creates a seam from the loaded containers policy with a fresh ledger.
    public init(containersConfig: ContainersConfig, runtime: (any ContainerHostRuntime)? = nil) {
        let resolved: any ContainerHostRuntime = runtime ?? LiveContainerHostRuntime()
        let ledger = EphemeralContainerLedger(
            runtime: resolved,
            maxConcurrent: StrictContainerRunner.clampedMaxConcurrent(for: containersConfig)
        )
        self.runtime = resolved
        self.strictRegistry = StrictTurnRegistry(runtime: resolved, ephemeralLedger: ledger)
        self.machineClient = MachineContainerClient(runtime: resolved)
        self.ephemeralLedger = ledger
        self.memory = StrictContainerRunner.memoryCap(for: containersConfig)
    }

    /// Creates a seam from the loaded policy sharing one registry plus ledger.
    public init(
        containersConfig: ContainersConfig,
        strictRegistry: StrictTurnRegistry,
        ephemeralLedger: EphemeralContainerLedger,
        runtime: (any ContainerHostRuntime)? = nil
    ) {
        let resolved: any ContainerHostRuntime = runtime ?? LiveContainerHostRuntime()
        self.runtime = resolved
        self.strictRegistry = strictRegistry
        self.machineClient = MachineContainerClient(runtime: resolved)
        self.ephemeralLedger = ephemeralLedger
        self.memory = StrictContainerRunner.memoryCap(for: containersConfig)
    }

    /// Live seam for production paths.
    public static var live: Self {
        Self()
    }

    /// Hermetic seam plus its stub, sharing one stubbed runtime.
    public static func hermetic() -> (seam: Self, runtime: HermeticContainerRuntime) {
        let stub = HermeticContainerRuntime()
        return (Self(runtime: stub), stub)
    }
}
