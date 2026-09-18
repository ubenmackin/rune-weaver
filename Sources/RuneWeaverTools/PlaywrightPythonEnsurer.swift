// Rune Weaver Tools — Playwright Python virtual environment ensurer.

import Foundation
import RuneWeaverCore

/// Ensures a usable Python virtual environment with Playwright and Chromium installed.
/// Managed at `~/.runeweaver/python` so server instances never collide with Homebrew
/// system pythons or externally-managed-environment restrictions.
/// `RUNEWEAVER_PYTHON_BIN` or gateway-level overrides skip provisioning entirely;
/// pipx install is left alone because it never satisfies the import.
/// Offline pip or browser downloads fail closed with the venv path plus a
/// manual fallback instead of the old generic pip hint. Concurrent callers
/// collapse onto one in-flight provision following the resolving, creating,
/// installing, browsers cascade, publishing a live stage plus Start time so
/// health polls render one line plus elapsed instead of hanging silently.
/// Seatbelt and Apple Container boundaries stay untouched: provisioning only
/// touches the managed venv directory and spawns local python processes.
public actor PlaywrightPythonEnsurer {
    /// Shared process-wide ensurer backing first navigate and serve warmup.
    public static let shared = PlaywrightPythonEnsurer()

    /// User-visible provision stage while one flight runs.
    /// Coarser than pip output: one flight moves resolving, creating,
    /// installing, browsers so health polls and single-flight joiners watch
    /// one step plus elapsed instead of one static label.
    public enum Stage: String, Sendable, CaseIterable, Codable {
        case resolving
        case creating
        case installing
        case browsers

        /// Short operator-facing copy naming the in-flight step.
        /// This wording is a cross-boundary contract: the dashboard mirrors it
        /// for the Preparing line, so renames must land on both sides together
        /// and stay pinned by the stage-copy contract tests.
        public var userCopy: String {
            Self.userCopies[self] ?? "Preparing"
        }

        /// Single source for stage copy inside the engine.
        /// Keeping the table beside the cases prevents per-call-site drift and
        /// gives contract tests one accessor to pin against the dashboard mirror.
        private static var userCopies: [Stage: String] {
            [
                .resolving: "Finding system Python",
                .creating: "Creating managed browser environment",
                .installing: "Installing Playwright package",
                .browsers: "Installing Chromium browser"
            ]
        }

        /// Canonical stage-to-copy table for contract tests.
        /// Keyed by raw value so dashboard and engine suites compare the same shape.
        public static var userCopiesByRawValue: [String: String] {
            Dictionary(uniqueKeysWithValues: Stage.allCases.map { ($0.rawValue, $0.userCopy) })
        }
    }

    /// One in-flight provision snapshot: the current stage plus when it began.
    /// `startedAt` is pinned at flight creation and preserved across stage
    /// moves so elapsed time counts the whole provision, not the current step.
    public struct Progress: Sendable, Equatable {
        public let stage: Stage
        public let startedAt: Date

        public init(stage: Stage, startedAt: Date = Date()) {
            self.stage = stage
            self.startedAt = startedAt
        }
    }

    /// Non-throwing provision outcome for health routes sharing the flight.
    /// `started` is true only when this caller owned a flight that actually
    /// provisioned; joiners collapsing onto an existing flight never claim a
    /// start. Failures carry a trimmed banner in `message` plus chained
    /// detail in `diagnostics` so inline slots and collapsed UI each render once.
    public struct Report: Sendable, Equatable {
        public let ready: Bool
        public let started: Bool
        public let pythonPath: String
        public let venvPath: String
        public let message: String?
        public let diagnostics: String?

        public init(
            ready: Bool,
            started: Bool,
            pythonPath: String,
            venvPath: String,
            message: String? = nil,
            diagnostics: String? = nil
        ) {
            self.ready = ready
            self.started = started
            self.pythonPath = pythonPath
            self.venvPath = venvPath
            self.message = NormalizedText.value(message)
            self.diagnostics = NormalizedText.value(diagnostics)
        }
    }

    /// Stage callback threaded through provisioning so each phase can report
    /// without owning actor state; the owning flight maps it onto progress.
    public typealias StageReporter = @Sendable (Stage) async -> Void

    /// Budget for `python3 -m venv` so a slow disk still converges without
    /// hanging a turn behind the bridge timeout.
    public static let venvCreateTimeoutSeconds: TimeInterval = 120
    /// Budget for `pip install playwright` inside the managed venv.
    /// First installs download wheels, so the run pays minutes once instead
    /// of failing fast like the 30s bridge budget.
    public static let pipInstallTimeoutSeconds: TimeInterval = 300
    /// Budget for `playwright install chromium` inside the managed venv.
    /// Browser downloads are hundreds of megabytes on first run.
    public static let browserInstallTimeoutSeconds: TimeInterval = 300
    /// Budget for the `import playwright` readiness probe.
    public static let importProbeTimeoutSeconds: TimeInterval = 15
    /// Budget for the `python3 --version` system probe.
    public static let systemProbeTimeoutSeconds: TimeInterval = 10
    /// Cap for pip and browser stderr tails kept in diagnostics.
    public static let maxDiagnosticsChars = 2000
    /// Pinned Playwright pip release installed into the managed venv.
    /// Pinned exact so fresh provisions converge instead of floating across
    /// breaking helper APIs. To bump: verify the helper in
    /// `BrowserPlaywrightScript` against the new release, update this
    /// constant, and keep the manual fallback copy below installing the same
    /// requirement.
    public static let pinnedPlaywrightVersion = "1.49.1"
    /// Pinned pip requirement derived from the version above.
    /// Single-sourced so provisioning and the manual fallback copy install
    /// the same release.
    public static var pinnedPlaywrightRequirement: String {
        "playwright==\(pinnedPlaywrightVersion)"
    }

    /// Single in-flight provision task so concurrent navigates collapse onto
    /// one venv creation instead of racing `venv` plus `pip install`.
    private var inFlight: Task<String, Error>?
    /// Live provision snapshot, cleared on settle or cancel so no terminal
    /// flight leaves a stale Starting display behind.
    private var liveProgress: Progress?
    /// Last provisioned interpreter, re-probed on every hit so a deleted venv
    /// or a broken upgrade never returns a stale warm path.
    private var cachedPythonPath: String?

    /// Creates an ensurer (shared in production, fresh in tests).
    public init() {}

    /// Managed venv directory, single-sourced through `BrowserConfig` so the
    /// gateway, health copy, and manual fallback never drift.
    /// - Returns: `~/.runeweaver/python` expanded for the current user.
    public static func managedVenvDirURL() -> URL {
        BrowserConfig.managedPythonVenvDirURL()
    }

    /// Interpreter inside the managed venv.
    /// - Returns: `~/.runeweaver/python/bin/python` expanded.
    public static func managedPythonURL() -> URL {
        BrowserConfig.managedPythonExecutableURL()
    }

    /// Display path for the managed venv directory (unexpanded, for copy).
    public static var managedVenvDisplayPath: String {
        BrowserConfig.managedPythonVenvDisplayPath()
    }

    /// Display path for the managed interpreter (unexpanded, for copy).
    public static var managedPythonDisplayPath: String {
        BrowserConfig.managedPythonDisplayPath()
    }

    /// Explicit override from `RUNEWEAVER_PYTHON_BIN`, trimmed.
    /// - Returns: Override path, or nil when unset or blank so the managed
    ///   venv plus PATH fallback decide instead.
    public static func envOverridePythonBin() -> String? {
        NormalizedText.value(ProcessInfo.processInfo.environment[BrowserConfig.pythonBinEnvVar])
    }

    /// Manual fallback naming the managed interpreter.
    /// Names the venv python explicitly because `pipx` and `brew
    /// install playwright-cli` never satisfy `import playwright` for the
    /// server python; the Linux `install-deps` note stays advisory because it
    /// typically needs sudo outside the harness. Installs the pinned
    /// requirement so manual recovery converges with managed provisioning.
    /// - Parameter pythonPath: Interpreter to name, defaulting to the managed one.
    /// - Returns: Copy-paste recovery commands.
    public static func manualFallbackHint(pythonPath: String? = nil) -> String {
        let python = NormalizedText.value(pythonPath, fallback: managedPythonURL().path)
        let effective = python.isEmpty ? managedPythonURL().path : python
        return "\(effective) -m pip install \(pinnedPlaywrightRequirement) && \(effective) -m playwright install chromium"
            + " (on Linux also run `\(effective) -m playwright install-deps` or install system browser dependencies manually)"
    }

    /// Actionable missing-dependency message naming the venv path.
    /// Replaces the old generic pip hint so offline or half-provisioned
    /// states point at the managed entry plus the manual fallback instead of
    /// a system-wide `python3 -m pip` that Homebrew now refuses.
    /// - Parameters:
    ///   - stage: Provision step that failed, if known.
    ///   - detail: Underlying cause (pip tail, launch text, or import text).
    ///   - pythonPath: Interpreter that failed, defaulting to the managed one.
    /// - Returns: `playwrightMissing` copy carrying venv plus fallback.
    public static func missingMessage(stage: Stage?, detail: String, pythonPath: String? = nil) -> String {
        let venvPath = managedVenvDisplayPath
        let effective = NormalizedText.value(pythonPath, fallback: managedPythonURL().path)
        let cause = NormalizedText.value(detail) ?? "Playwright is not ready"
        let step = stage.map { " (stage \($0.rawValue): \($0.userCopy))" } ?? ""
        return "\(cause)\(step). Managed browser Python: \(venvPath) (\(effective))."
            + " Manual fallback: \(manualFallbackHint(pythonPath: effective))."
            + " `pipx` and `brew install playwright-cli` do not provide `import playwright` for the server python."
            + " Check network connectivity — offline installs fail closed without changing the existing venv."
    }

    /// Whether the managed interpreter file exists (without probing import).
    /// - Returns: True when `~/.runeweaver/python/bin/python` is present.
    public static func isManagedPythonPresent() -> Bool {
        FileManager.default.fileExists(atPath: managedPythonURL().path)
    }

    /// Fast-path resolution preferring override, then managed, then PATH.
    /// Returns nil for the PATH fallback so the bridge keeps its
    /// `/usr/bin/env python3` spelling instead of a resolved absolute path
    /// that could drift across Homebrew updates.
    /// - Parameter explicit: Gateway-level explicit path, if any.
    /// - Returns: Effective python path, or nil to use PATH `python3`.
    public static func fastEffectivePythonBin(explicit: String?) -> String? {
        if let trimmed = NormalizedText.value(explicit) {
            return trimmed
        }
        if let override = envOverridePythonBin() {
            return override
        }
        if isManagedPythonPresent() {
            return managedPythonURL().path
        }
        return nil
    }

    /// Resolves the interpreter for dry-run previews without provisioning.
    /// Dry runs validate without mutating, so they never pay the venv, pip,
    /// or browser budgets and never publish staged progress; the caller keeps
    /// the `/usr/bin/env python3` spelling when nothing is already present.
    /// - Parameter explicit: Gateway-level explicit path, if any.
    /// - Returns: Effective python path, or nil to use PATH `python3`.
    public static func resolveDryRunPythonBin(explicit: String?) -> String? {
        fastEffectivePythonBin(explicit: explicit)
    }

    /// Returns the live provision snapshot, if a flight is running.
    /// - Returns: Current stage plus Start time, or nil when idle.
    public func currentProgress() -> Progress? {
        liveProgress
    }

    /// Lightweight readiness probe for health routes.
    /// Resolves the effective interpreter through the fast path without
    /// provisioning, then checks only `import playwright`, so dashboard
    /// health polls stay cheap and side-effect free while a provision flight
    /// publishes its stage separately through `currentProgress`. Opening
    /// Settings must never kick off the venv, pip, or browser budgets.
    /// - Parameter explicitPythonBin: Gateway-level explicit path, if any.
    /// - Returns: Readiness plus the effective interpreter path probed.
    public static func probeReadiness(explicitPythonBin: String? = nil) async -> (ready: Bool, pythonPath: String) {
        if Task.isCancelled {
            return (false, managedPythonURL().path)
        }
        guard let effective = fastEffectivePythonBin(explicit: explicitPythonBin) else {
            // PATH fallback keeps the bridge's `/usr/bin/env python3` spelling
            // instead of a resolved absolute path that could drift across
            // installs, so the probe dials through env identically.
            let ready = await canImportPlaywrightViaEnv()
            return (ready, "python3")
        }
        let ready = await canImportPlaywright(pythonPath: effective)
        return (ready, effective)
    }

    /// Pins the initial snapshot when an owner flight starts.
    /// Idempotent: a repeated begin keeps the original `startedAt` so elapsed
    /// never rewinds when stages re-enter.
    private func beginProgress() {
        if liveProgress == nil {
            liveProgress = Progress(stage: .resolving, startedAt: Date())
        }
    }

    /// Moves the snapshot to a new stage, preserving the original Start time.
    private func noteStage(_ stage: Stage) {
        if let existing = liveProgress {
            liveProgress = Progress(stage: stage, startedAt: existing.startedAt)
        } else {
            liveProgress = Progress(stage: stage, startedAt: Date())
        }
    }

    /// Clears the snapshot when its flight settles or cancels.
    private func clearProgress() {
        liveProgress = nil
    }

    /// Ensures a usable interpreter, provisioning the managed venv on demand.
    /// Explicit and `RUNEWEAVER_PYTHON_BIN` paths return immediately without
    /// provisioning so operator overrides never pay the pip budget; otherwise
    /// a present managed interpreter that already imports playwright returns
    /// immediately, and only a missing entry or a failed import collapses onto
    /// one provisioning flight. Serve boot calls this best-effort via
    /// `warmup()` while first navigate awaits it inline.
    /// - Parameter explicitPythonBin: Gateway-level explicit path, if any.
    /// - Returns: Effective interpreter path to spawn.
    public func ensure(explicitPythonBin: String? = nil) async throws -> String {
        let outcome = try await ensureWithOwnership(explicitPythonBin: explicitPythonBin)
        return outcome.path
    }

    /// Ensures like `ensure` while reporting whether this caller provisioned.
    /// Shared by the throwing path and the health report so both agree on the
    /// single-flight outcome without duplicating the fast-path checks.
    /// - Parameter explicitPythonBin: Gateway-level explicit path, if any.
    /// - Returns: Effective path plus whether this caller owned the provision.
    private func ensureWithOwnership(explicitPythonBin: String? = nil) async throws -> (path: String, didProvision: Bool) {
        try Task.checkCancellation()
        if let trimmedExplicit = NormalizedText.value(explicitPythonBin) {
            return (trimmedExplicit, false)
        }
        if let override = Self.envOverridePythonBin() {
            return (override, false)
        }
        // Fast path keeps warm navigates to one import probe instead of a
        // full provision; the probe itself stays short so a down interpreter
        // fails fast into the single flight below. Every hit re-probes so a
        // deleted venv or a broken upgrade never returns a stale warm path.
        if Self.isManagedPythonPresent() {
            let managedPath = Self.managedPythonURL().path
            if await Self.canImportPlaywright(pythonPath: managedPath) {
                cachedPythonPath = managedPath
                try Task.checkCancellation()
                return (managedPath, false)
            }
            // Probe failed: drop a stale warm entry so the next caller does
            // not trust a broken interpreter without paying one more probe.
            if cachedPythonPath == managedPath {
                cachedPythonPath = nil
            }
        } else if cachedPythonPath != nil {
            // Managed entry deleted: drop the warm entry instead of returning
            // a path whose file no longer exists.
            cachedPythonPath = nil
        }
        let flight = acquireFlight()
        if !flight.isOwner {
            do {
                let path = try await flight.task.value
                return (path, false)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                throw error
            }
        }
        do {
            let path = try await awaitOwnedFlight(task: flight.task)
            cachedPythonPath = path
            return (path, true)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw error
        }
    }

    /// Non-throwing ensure for health routes sharing the single-flight path.
    /// Joiners collapsing onto an existing flight never claim a start, and a
    /// cancelled turn reports not-ready without claiming.
    /// - Parameter explicitPythonBin: Gateway-level explicit path, if any.
    /// - Returns: Readiness plus whether this caller provisioned plus banner.
    public func ensureReport(explicitPythonBin: String? = nil) async -> Report {
        if Task.isCancelled {
            return Report(
                ready: false,
                started: false,
                pythonPath: Self.managedPythonURL().path,
                venvPath: Self.managedVenvDisplayPath,
                message: nil
            )
        }
        do {
            let outcome = try await ensureWithOwnership(explicitPythonBin: explicitPythonBin)
            if Task.isCancelled {
                return Report(
                    ready: false,
                    started: false,
                    pythonPath: outcome.path,
                    venvPath: Self.managedVenvDisplayPath,
                    message: nil
                )
            }
            return Report(
                ready: true,
                started: outcome.didProvision,
                pythonPath: outcome.path,
                venvPath: Self.managedVenvDisplayPath,
                message: nil
            )
        } catch is CancellationError {
            return Report(
                ready: false,
                started: false,
                pythonPath: Self.managedPythonURL().path,
                venvPath: Self.managedVenvDisplayPath,
                message: nil
            )
        } catch {
            if Task.isCancelled {
                return Report(
                    ready: false,
                    started: false,
                    pythonPath: Self.managedPythonURL().path,
                    venvPath: Self.managedVenvDisplayPath,
                    message: nil
                )
            }
            let detail = error.localizedDescription
            return Report(
                ready: false,
                started: false,
                pythonPath: Self.managedPythonURL().path,
                venvPath: Self.managedVenvDisplayPath,
                message: detail,
                diagnostics: Self.diagnostics(from: error)
            )
        }
    }

    /// Best-effort warmup for serve boot: provisions in the background without
    /// ever failing boot. Failures stay in the server log so a down network
    /// never flips a healthy boot into a failure, while the live stage plus
    /// health payload carries state to the dashboard.
    public func warmup() async {
        if Task.isCancelled {
            return
        }
        do {
            _ = try await ensure()
        } catch is CancellationError {
            return
        } catch {
            RuneWeaverLog.tools.debug("PlaywrightPythonEnsurer: managed venv unavailable: \(error.localizedDescription)")
        }
    }

    /// Single-flight handle collapsing concurrent callers onto one task.
    /// Only the owner clears the entry, so joiners never reap a flight they
    /// did not start.
    private struct ProvisionFlight {
        let task: Task<String, Error>
        let isOwner: Bool
    }

    /// Collapses concurrent callers onto a single provision task.
    private func acquireFlight() -> ProvisionFlight {
        if let existing = inFlight {
            return ProvisionFlight(task: existing, isOwner: false)
        }
        // Pin the snapshot before the Task starts so joiners and health polls
        // see `resolving` from the first instant instead of a gap reading idle.
        beginProgress()
        let task = Task<String, Error> {
            try await Self.provisionImpl(onStage: { stage in
                await self.noteStage(stage)
            })
        }
        inFlight = task
        return ProvisionFlight(task: task, isOwner: true)
    }

    /// Awaits an owned flight, cancelling it when the waiter cancels.
    /// Completion, failure, and cancellation all clear the stage snapshot so
    /// no terminal flight leaves a stale Starting display behind.
    private func awaitOwnedFlight(task: Task<String, Error>) async throws -> String {
        defer {
            inFlight = nil
            clearProgress()
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

// MARK: - Provisioning implementation

/// Encapsulates the ordered subprocess commands needed to provision and probe the managed venv.
extension PlaywrightPythonEnsurer {
    /// Runs one managed provision through the ordered cascade.
    /// Follows resolving, creating, installing, browsers: each step records
    /// its own failure detail while the thrown banner holds only the
    /// actionable cause plus the venv path and manual fallback. An existing
    /// managed entry is reused; only a missing directory runs `venv`, and a
    /// present directory missing `bin/python` fails closed without deleting
    /// anything so a user-owned non-venv directory is never clobbered.
    /// - Parameter onStage: Live stage reporter, nil keeps it silent.
    /// - Returns: Managed interpreter path.
    private static func provisionImpl(onStage: StageReporter? = nil) async throws -> String {
        try Task.checkCancellation()
        await onStage?(.resolving)
        guard await systemPython3Available() else {
            throw BrowserError.playwrightMissing(missingMessage(
                stage: .resolving,
                detail: "Could not find python3 for browser automation. Install Python 3 via Xcode Command Line Tools or Homebrew"
            ))
        }
        try Task.checkCancellation()
        await onStage?(.creating)
        try await ensureVenvDir()
        try Task.checkCancellation()
        await onStage?(.installing)
        try await pipInstallPlaywright()
        try Task.checkCancellation()
        await onStage?(.browsers)
        try await installChromium()
        try Task.checkCancellation()
        let managedPath = managedPythonURL().path
        guard await canImportPlaywright(pythonPath: managedPath) else {
            throw BrowserError.playwrightMissing(missingMessage(
                stage: .browsers,
                detail: "Managed Python is present but `import playwright` still fails after provisioning"
            ))
        }
        return managedPath
    }

    /// Ensures the managed venv directory exists without clobbering.
    /// A missing directory runs `python3 -m venv` once; a present directory
    /// holding `bin/python` reuses it; a present directory missing the
    /// interpreter fails closed without deleting so user content survives.
    private static func ensureVenvDir() async throws {
        let manager = FileManager.default
        let dirPath = managedVenvDirURL().path
        var isDir: ObjCBool = false
        if manager.fileExists(atPath: dirPath, isDirectory: &isDir) {
            if isDir.boolValue, manager.fileExists(atPath: managedPythonURL().path) {
                return
            }
            let detail = "Managed path \(managedVenvDisplayPath) exists but is not a virtual environment "
                + "(missing bin/python). Move it aside or remove it, then retry"
            throw BrowserError.playwrightMissing(missingMessage(
                stage: .creating,
                detail: detail
            ))
        }
        // Create the parent (`~/.runeweaver`) before `venv` so a fresh home
        // never fails on a missing directory instead of the real cause.
        try? manager.createDirectory(
            at: managedVenvDirURL().deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            _ = try await BoundedProcessRunner.runAsync(
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["python3", "-m", "venv", dirPath],
                timeoutSeconds: venvCreateTimeoutSeconds,
                maxOutputBytes: 64 * 1024,
                maxErrorBytes: 64 * 1024
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BoundedProcessError {
            throw BrowserError.playwrightMissing(missingMessage(
                stage: .creating,
                detail: "Could not create managed venv at \(managedVenvDisplayPath): \(describeBoundedError(error))"
            ))
        } catch {
            throw BrowserError.playwrightMissing(missingMessage(
                stage: .creating,
                detail: "Could not create managed venv at \(managedVenvDisplayPath): \(error.localizedDescription)"
            ))
        }
        guard manager.fileExists(atPath: managedPythonURL().path) else {
            throw BrowserError.playwrightMissing(missingMessage(
                stage: .creating,
                detail: "Managed venv creation reported success but \(managedPythonDisplayPath) is still missing"
            ))
        }
    }

    /// Installs the Playwright package inside the managed venv.
    /// Uses the venv interpreter (`-m pip`) so Homebrew's
    /// externally-managed guard never trips; a system-wide `pip install`
    /// outside the venv is never attempted. Installs the pinned requirement
    /// so fresh provisions converge on one tested release.
    private static func pipInstallPlaywright() async throws {
        let pythonPath = managedPythonURL().path
        do {
            let result = try await BoundedProcessRunner.runAsync(
                executableURL: URL(fileURLWithPath: pythonPath),
                arguments: ["-m", "pip", "install", pinnedPlaywrightRequirement],
                timeoutSeconds: pipInstallTimeoutSeconds,
                maxOutputBytes: 64 * 1024,
                maxErrorBytes: 64 * 1024
            )
            guard result.exitCode == 0 else {
                let tail = cappedTail(stdout: result.stdout, stderr: result.stderr)
                throw BrowserError.playwrightMissing(missingMessage(
                    stage: .installing,
                    detail: "`pip install \(pinnedPlaywrightRequirement)` failed (exit \(result.exitCode))\(tail.isEmpty ? "" : ": \(tail)")"
                ))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BrowserError {
            throw error
        } catch let error as BoundedProcessError {
            throw BrowserError.playwrightMissing(missingMessage(
                stage: .installing,
                detail: "`pip install \(pinnedPlaywrightRequirement)` did not complete: \(describeBoundedError(error))"
            ))
        } catch {
            throw BrowserError.playwrightMissing(missingMessage(
                stage: .installing,
                detail: "`pip install \(pinnedPlaywrightRequirement)` failed: \(error.localizedDescription)"
            ))
        }
    }

    /// Installs the Chromium browser into the managed venv.
    /// System dependency installation (`install-deps`) stays a manual note
    /// because it typically needs sudo outside the harness; macOS bundles the
    /// needed libraries while Linux hosts may need the extra step.
    private static func installChromium() async throws {
        let pythonPath = managedPythonURL().path
        do {
            let result = try await BoundedProcessRunner.runAsync(
                executableURL: URL(fileURLWithPath: pythonPath),
                arguments: ["-m", "playwright", "install", "chromium"],
                timeoutSeconds: browserInstallTimeoutSeconds,
                maxOutputBytes: 64 * 1024,
                maxErrorBytes: 64 * 1024
            )
            guard result.exitCode == 0 else {
                let tail = cappedTail(stdout: result.stdout, stderr: result.stderr)
                throw BrowserError.playwrightMissing(missingMessage(
                    stage: .browsers,
                    detail: "`playwright install chromium` failed (exit \(result.exitCode))\(tail.isEmpty ? "" : ": \(tail)")"
                ))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BrowserError {
            throw error
        } catch let error as BoundedProcessError {
            throw BrowserError.playwrightMissing(missingMessage(
                stage: .browsers,
                detail: "`playwright install chromium` did not complete: \(describeBoundedError(error))"
            ))
        } catch {
            throw BrowserError.playwrightMissing(missingMessage(
                stage: .browsers,
                detail: "`playwright install chromium` failed: \(error.localizedDescription)"
            ))
        }
    }

    /// Probes whether `python3` exists on PATH.
    /// - Returns: True when `python3 --version` exits zero before the budget.
    private static func systemPython3Available() async -> Bool {
        if Task.isCancelled {
            return false
        }
        do {
            let result = try await BoundedProcessRunner.runAsync(
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["python3", "--version"],
                timeoutSeconds: systemProbeTimeoutSeconds,
                maxOutputBytes: 4 * 1024,
                maxErrorBytes: 4 * 1024
            )
            return result.exitCode == 0
        } catch {
            return false
        }
    }

    /// Probes whether an interpreter can import playwright.
    /// - Parameter pythonPath: Interpreter to probe.
    /// - Returns: True only when `import playwright` exits zero.
    private static func canImportPlaywright(pythonPath: String) async -> Bool {
        if Task.isCancelled {
            return false
        }
        guard let trimmed = NormalizedText.value(pythonPath) else {
            return false
        }
        do {
            let result = try await BoundedProcessRunner.runAsync(
                executableURL: URL(fileURLWithPath: trimmed),
                arguments: ["-c", "import playwright"],
                timeoutSeconds: importProbeTimeoutSeconds,
                maxOutputBytes: 4 * 1024,
                maxErrorBytes: 4 * 1024
            )
            return result.exitCode == 0
        } catch {
            return false
        }
    }

    /// Probes whether PATH `python3` can import playwright.
    /// Covers the fallback where no absolute interpreter resolves, so health
    /// reports the same spelling the bridge would spawn through env.
    /// - Returns: True only when `import playwright` exits zero.
    private static func canImportPlaywrightViaEnv() async -> Bool {
        if Task.isCancelled {
            return false
        }
        do {
            let result = try await BoundedProcessRunner.runAsync(
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["python3", "-c", "import playwright"],
                timeoutSeconds: importProbeTimeoutSeconds,
                maxOutputBytes: 4 * 1024,
                maxErrorBytes: 4 * 1024
            )
            return result.exitCode == 0
        } catch {
            return false
        }
    }

    /// Human copy for a bounded-runner failure without child bytes.
    private static func describeBoundedError(_ error: BoundedProcessError) -> String {
        switch error {
        case .timedOut:
            "timed out (offline downloads fail closed; retry with connectivity)"
        case .outputLimitExceeded:
            "produced too much output and was terminated"
        case let .launchFailed(detail):
            "could not launch (\(detail))"
        }
    }

    /// Capped stdout plus stderr tail for diagnostics without unbounded bytes.
    private static func cappedTail(stdout: Data, stderr: Data) -> String {
        let combined = [stderr, stdout]
            .compactMap { String(data: $0, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !combined.isEmpty else {
            return ""
        }
        guard combined.count > maxDiagnosticsChars else {
            return combined
        }
        return String(combined.suffix(maxDiagnosticsChars))
    }

    /// Chained diagnostics for health payloads without duplicating the banner.
    private static func diagnostics(from error: Error) -> String? {
        let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty else {
            return nil
        }
        guard detail.count > maxDiagnosticsChars else {
            return detail
        }
        return String(detail.suffix(maxDiagnosticsChars))
    }
}
