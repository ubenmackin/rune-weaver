// Rune Weaver Tools — SearXNG container lifecycle plus readiness watch.
//
// Holds the existence-aware start-or-run cascade and the readiness watch for
// the local SearXNG engine: inspect-first existence probing with a list
// cross-check, stale-entry removal before fresh runs, explicit image
// pull-before-run, reachability probing, and the ticking watch where HTTP
// success wins, terminal states fail fast with the logs tail, persistent 5xx
// with a readable body fails fast with the capped body tail, definitive non-5xx
// resets the streak, and gaps plus empty or unparseable states keep waiting
// until the backstop. This keeps the
// configuration and daemon-healing helpers in
// `SearXNGEnsurer+Helpers.swift` focused while the lifecycle entry points keep
// calling the same `SearXNGEnsurer` namespace.

import Foundation
import RuneWeaverCore

/// Inconclusive list probe: the `list --all` dump could not confirm presence.
/// Thrown by the shared probe so callers map it to patience instead of a
/// confirmed answer.
private struct InconclusiveListProbeError: Error {}

/// Rune Weaver Tools — SearXNG container lifecycle plus reachability.
///
/// Holds the existence-aware start-or-run cascade (`inspect` with a `list
/// --all` cross-check, present tries `start` plus brief settle, refused
/// removes with `rm`-first before fresh `run`, absent goes straight to `run`,
/// residual race wedges still revive), the explicit pull-before-run helper,
/// the fresh-run helper, failure guidance, reachability probing, and bounded
/// process execution so the main `SearXNGEnsurer` actor body stays within the
/// type-length budget. Callers keep using the same `SearXNGEnsurer` namespace.
extension SearXNGEnsurer {
    /// Arguments probing whether the tracked image is already cached locally.
    /// Exits 0 when cached, so the minutes-budget pull below runs only for
    /// first installs instead of on every ensure.
    /// - Parameter image: Tracked image reference, defaulting to the shared constant.
    /// - Returns: Arguments for the image presence probe.
    public static func imageInspectArguments(image: String = containerImage) -> [String] {
        ["image", "inspect", image]
    }

    /// Arguments pulling the tracked image with the long minutes budget.
    /// Split out from `run` so the short run timeout never hides a registry
    /// download; a timed-out pull is safe to retry because layers stay cached.
    /// - Parameter image: Tracked image reference, defaulting to the shared constant.
    /// - Returns: Arguments for the explicit pull step.
    public static func imagePullArguments(image: String = containerImage) -> [String] {
        ["image", "pull", image]
    }

    /// Arguments starting the existing named container.
    /// Shared by the fast-path start and the wedged half-create fallback so
    /// both spell the name identically instead of drifting between call sites.
    /// - Returns: Arguments reviving the existing container.
    public static func containerStartArguments() -> [String] {
        ["start", containerName]
    }

    /// Arguments listing every container including stopped ones for existence checks.
    /// Plain `list` shows only running entries, so a stopped entry would read
    /// as absent and the next `run` would collide on the name; `--all` keeps
    /// the check honest. Shares the daemon probe verb so the engine, the
    /// escape-hatch script, and diagnostics never drift on the list spelling.
    /// - Returns: Arguments for the existence listing.
    public static func containerListAllArguments() -> [String] {
        ["list", "--all"]
    }

    /// Arguments probing the tracked entry directly for existence checks.
    /// Exits 0 when the entry exists in any state, non-zero with a not-found
    /// hint when absent, so an absent entry can skip the doomed `start` and go
    /// straight to a fresh `run` without burning the start budget.
    /// - Returns: Arguments inspecting the tracked container entry.
    public static func containerInspectArguments() -> [String] {
        ["inspect", containerName]
    }

    /// Arguments removing a stale entry before a fresh `run`.
    /// Spells `rm` (the `delete` alias) to match the escape-hatch script, so
    /// script and engine never diverge on the remove verb. Best-effort: a
    /// missing entry ignores the failure, keeping the absent fast path cheap.
    /// - Returns: Arguments removing the tracked container entry.
    public static func containerRemoveArguments() -> [String] {
        ["rm", containerName]
    }

    /// Precompiled token-boundary matcher for the tracked entry.
    /// Shared by every list probe so the watch never recompiles per tick; nil
    /// only when the pattern itself cannot compile, which reads as absent.
    public static let containerExistsRegex: NSRegularExpression? = {
        let escaped = NSRegularExpression.escapedPattern(for: containerName)
        return try? NSRegularExpression(
            pattern: "(?<![A-Za-z0-9_.-])\(escaped)(?![A-Za-z0-9_.-])",
            options: [.caseInsensitive]
        )
    }()

    /// Whether a `list --all` dump names the tracked entry.
    /// Matches the name as a whole token bounded by non-name characters, so
    /// `runeweaver-searxng-extra` or a log echo never poses as present while
    /// table, JSON, and YAML shapes still match without a format flag.
    /// Empty output means absent, never present.
    /// - Parameter output: Combined stdout plus stderr from `list --all`.
    /// - Returns: True when the tracked entry appears as an exact token.
    public static func containerExists(inListOutput output: String) -> Bool {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let regex = containerExistsRegex else {
            return false
        }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return regex.firstMatch(in: trimmed, options: [], range: range) != nil
    }

    /// Whether an `inspect` exit proves the tracked entry exists.
    /// Exit 0 means present in any state; any non-zero exit (not-found hint,
    /// timeout, daemon hiccup) reads as absent so the caller still attempts a
    /// fresh `run` that surfaces the actionable detail instead of stalling on
    /// an unknown. The `run` below stays safe because `rm`-first plus the
    /// wedged fallback cover the misread-present race.
    /// - Parameter exitCode: Inspect exit status.
    /// - Returns: True only on exit 0.
    public static func inspectShowsEntryPresent(exitCode: Int32) -> Bool {
        exitCode == 0
    }

    /// Whether `inspect` output carries the absent-entry hint.
    /// Matches only explicit not-found phrasing, so a daemon outage or a
    /// permissions error never poses as a clean absent that would skip the
    /// `start` attempt without diagnostics.
    /// - Parameter output: Combined stdout plus stderr from the failed `inspect`.
    /// - Returns: True when the entry is definitively absent.
    public static func inspectIndicatesMissing(output: String) -> Bool {
        let lowered = output.lowercased()
        if lowered.contains("not found") || lowered.contains("no such") {
            return true
        }
        if lowered.contains("not exist") || lowered.contains("not be found") {
            return true
        }
        return false
    }

    /// Probes whether the tracked entry exists without changing state.
    /// Prefers `inspect` (precise exit 0 when present); a definitive
    /// not-found hint falls back to the `list --all` dump so a transient
    /// inspect miss cannot send a present entry down the absent fast path.
    /// Any other inspect failure reads as absent so the caller still attempts
    /// a fresh `run` that surfaces the actionable detail. Bounded by the
    /// start timeout so the check never burns the readiness watch budget.
    /// - Parameter runtime: Resolved Apple Container CLI.
    /// - Returns: True when the entry exists in any state.
    public static func containerEntryExists(runtime: URL) async -> Bool {
        if Task.isCancelled {
            return false
        }
        do {
            let (code, _) = try await runProcess(
                executableURL: runtime,
                arguments: containerInspectArguments(),
                timeoutSeconds: containerStartTimeoutSeconds
            )
            if Task.isCancelled {
                return false
            }
            if inspectShowsEntryPresent(exitCode: code) {
                return true
            }
            // Any non-zero inspect (definitive miss or unknown failure) earns
            // one list cross-check: a wedged half-create can flake inspect
            // while the entry blocks `run`, and unknown failures fall through
            // to the dump rather than assuming absent outright.
            return await containerEntryExistsViaList(runtime: runtime)
        } catch is CancellationError {
            return false
        } catch {
            if Task.isCancelled {
                return false
            }
            // Spawn or timeout errors also deserve the list cross-check before
            // the caller commits to the absent fast path.
            return await containerEntryExistsViaList(runtime: runtime)
        }
    }

    /// Single `list --all` probe shared by existence checks.
    /// Runs one listing under the caller budget and reports whether the dump
    /// names the tracked entry, so inspect-first callers never drift on verbs
    /// or match polarity. Throws on cancel, spawn failure, timeout, or non-zero
    /// exit so an inconclusive probe maps to patience instead of posing as a
    /// confirmed answer.
    /// - Parameters:
    ///   - runtime: Resolved Apple Container CLI.
    ///   - timeout: Probe budget for this caller (start vs readiness).
    /// - Returns: True when the dump names the tracked entry.
    /// - Throws: Cancellation or an inconclusive probe; callers map it to patience.
    public static func listContainsEntry(runtime: URL, timeout: Double) async throws -> Bool {
        try Task.checkCancellation()
        let (code, output) = try await runProcess(
            executableURL: runtime,
            arguments: containerListAllArguments(),
            timeoutSeconds: timeout
        )
        try Task.checkCancellation()
        guard code == 0 else {
            throw InconclusiveListProbeError()
        }
        return containerExists(inListOutput: output)
    }

    /// Cross-checks existence via the `list --all` dump.
    /// Keeps the inspect-first probe honest when inspect flakes; a failed
    /// listing reads as absent so the caller still attempts a fresh `run`
    /// instead of stalling. Never throws, never claims present on empty output.
    /// - Parameter runtime: Resolved Apple Container CLI.
    /// - Returns: True when the dump names the tracked entry.
    public static func containerEntryExistsViaList(runtime: URL) async -> Bool {
        if Task.isCancelled {
            return false
        }
        do {
            return try await listContainsEntry(runtime: runtime, timeout: containerStartTimeoutSeconds)
        } catch is CancellationError {
            return false
        } catch {
            return false
        }
    }

    /// Removes a stale entry before a fresh `run`.
    /// Best-effort `rm`-first so the next `run` cannot hit "already exists":
    /// a missing entry, a concurrent remover win, or a permissions miss all
    /// fall through to the fresh `run`, which keeps the residual race fallback
    /// below. Bounded by the start timeout so a hung remove cannot burn the
    /// readiness watch budget.
    /// - Parameter runtime: Resolved Apple Container CLI.
    public static func removeStaleContainer(runtime: URL) async {
        if Task.isCancelled {
            return
        }
        do {
            _ = try await runProcess(
                executableURL: runtime,
                arguments: containerRemoveArguments(),
                timeoutSeconds: containerStartTimeoutSeconds
            )
        } catch is CancellationError {
            return
        } catch {
            // Intentionally ignored: the fresh `run` below plus the wedged
            // fallback decide the outcome, not the remove exit.
            return
        }
    }

    /// Polls briefly for the engine after a `start` before declaring refusal.
    /// Gives a slow start one settle window to answer so a start that needs an
    /// extra second never churns the entry via needless `rm` plus `run`.
    /// Returns on the first 2xx/3xx probe; cancellation aborts as unreachable
    /// so the caller never masks a cancelled turn as started.
    /// - Parameters:
    ///   - baseURL: Configured `searxng_url`.
    ///   - timeoutSeconds: Settle window for the brief poll.
    /// - Returns: True when the engine answered inside the window.
    public static func pollForReachableBriefly(baseURL: String, timeoutSeconds: Double) async -> Bool {
        if Task.isCancelled {
            return false
        }
        if await isReachable(baseURL: baseURL) {
            return true
        }
        // Monotonic budget so an NTP or sleep clock step never shortens or
        // stretches the settle window the way a wall-clock deadline would.
        let budget = Duration.nanoseconds(Int64(max(0, timeoutSeconds) * 1_000_000_000))
        let clock = ContinuousClock()
        let start = clock.now
        while clock.now - start < budget {
            if Task.isCancelled {
                return false
            }
            do {
                try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            } catch is CancellationError {
                return false
            } catch {
                return false
            }
            if Task.isCancelled {
                return false
            }
            if await isReachable(baseURL: baseURL) {
                return true
            }
        }
        return false
    }

    /// Arguments running a fresh container with the per-install settings mount.
    /// Split from the pull step so each carries its own timeout: pull pays
    /// minutes once, run stays short. The publish stays loopback-only because
    /// the engine has no auth. Capped at one CPU and 512M because single-user
    /// search never needs more; verify live usage with
    /// `container stats --no-stream runeweaver-searxng` before raising the ceiling.
    /// - Parameters:
    ///   - settingsPath: Per-install settings file mounted read-only.
    ///   - hostPort: Loopback host port derived from `searxng_url`.
    ///   - image: Tracked image reference, defaulting to the shared constant.
    /// - Returns: Arguments creating the fresh container.
    public static func containerRunArguments(settingsPath: String, hostPort: Int, image: String = containerImage) -> [String] {
        [
            "run", "-d",
            "--cpus", "1",
            "--memory", "512M",
            "--name", containerName,
            "-p", "127.0.0.1:\(hostPort):8080",
            "-v", "\(settingsPath):/etc/searxng/settings.yml:ro",
            image
        ]
    }

    /// Whether `run` output shows a wedged same-name container.
    /// A killed `run` can leave a half-created entry that blocks the next
    /// `run` with a name conflict; that entry is still startable, so the
    /// cascade revives it via `start` instead of surfacing the conflict as a
    /// fresh-run failure. The existence-aware path removes the entry with
    /// `rm`-first before every fresh `run` (mirroring the escape-hatch
    /// script), so this conflict is impossible except for cross-process races
    /// that recreate the name between `rm` and `run` — still revived here
    /// before failing.
    /// - Parameter output: Combined stdout plus stderr from the failed `run`.
    /// - Returns: True when the output names the same-name conflict.
    public static func isWedgedContainer(output: String) -> Bool {
        let lowered = output.lowercased()
        if lowered.contains("already exists") || lowered.contains("already in use") {
            return true
        }
        // Apple Container reports name conflicts with conflict wording tied
        // to the container name; bare "conflict" without the name could be an
        // unrelated registry conflict, so require both.
        if lowered.contains("conflict"), lowered.contains(containerName.lowercased()) {
            return true
        }
        return false
    }

    /// Ensures the tracked image is cached, pulling explicitly when absent.
    /// Probes with `image inspect` first so cached hosts skip the minutes
    /// budget entirely; only an absent image pays the long pull, and a retry
    /// resumes already-downloaded layers. A pull failure returns its stage
    /// fragment so the caller can fail closed without also attempting a `run`
    /// that could not succeed without the image. Reports the user-visible
    /// pulling stage only while actually downloading, so cached hosts never
    /// flash a pull step they skipped.
    /// - Parameters:
    ///   - runtime: Resolved Apple Container CLI.
    ///   - onStage: Optional live progress callback for the dashboard and CLI.
    /// - Returns: Failure fragment when the pull failed, nil when cached or pulled.
    public static func ensureImageAvailable(runtime: URL, onStage: StartStageReporter? = nil) async -> String? {
        if Task.isCancelled {
            return nil
        }
        do {
            let (code, _) = try await runProcess(
                executableURL: runtime,
                arguments: imageInspectArguments(),
                timeoutSeconds: containerImageInspectTimeoutSeconds
            )
            if Task.isCancelled {
                return nil
            }
            if code == 0 {
                return nil
            }
        } catch is CancellationError {
            return nil
        } catch {
            // Any inspect error (missing image, timeout, daemon hiccup) falls
            // through to the explicit pull, which surfaces the actionable
            // timeout versus Hub-reachability detail.
            if Task.isCancelled {
                return nil
            }
        }
        if Task.isCancelled {
            return nil
        }
        await onStage?(.pulling)
        do {
            let (code, output) = try await runProcess(
                executableURL: runtime,
                arguments: imagePullArguments(),
                timeoutSeconds: containerImagePullTimeoutSeconds
            )
            if Task.isCancelled {
                return nil
            }
            if code == 0 {
                return nil
            }
            return failureMessage(
                stage: EnsureStage.pull.rawValue,
                exitCode: code,
                output: output,
                timedOut: false
            )
        } catch is CancellationError {
            return nil
        } catch let error as BoundedProcessError {
            return runFailureMessage(
                error: error,
                stage: EnsureStage.pull.rawValue,
                timeout: containerImagePullTimeoutSeconds
            )
        } catch {
            return failureMessage(
                stage: EnsureStage.pull.rawValue,
                exitCode: nil,
                output: error.localizedDescription,
                timedOut: false
            )
        }
    }

    /// Starts or recreates the SearXNG container with failure detail.
    /// Existence-aware retry mirroring the escape-hatch script: probes for the
    /// tracked entry via `inspect` (with a `list --all` cross-check) before
    /// paying a `start` or `run`. A present entry tries `start`, polls briefly
    /// for the settle, and returns on reachable; an exit-0 start that stays
    /// dark returns to the watch path instead of churning via `rm` plus `run`,
    /// while only a refused start removes the wedged entry with `rm`-first
    /// then falls through to a fresh `run` with the per-install settings mount
    /// and the cached image. An absent entry goes straight to the fresh `run`
    /// without a doomed `start`. Only an exit-0 spawn claims a start so
    /// cross-process races never double-claim; failures carry stage, exit,
    /// capped tail, and timeout for the message.
    /// - Parameters:
    ///   - browser: `[browser]` policy carrying the base URL.
    ///   - runtime: Resolved Apple Container CLI.
    ///   - onStage: Optional live progress callback for the dashboard and CLI.
    /// - Returns: Whether this call started a container plus failure detail.
    public static func startExistingOrRun(browser: BrowserConfig, runtime: URL, onStage: StartStageReporter? = nil) async -> ContainerOutcome {
        if Task.isCancelled {
            return ContainerOutcome(didStart: false, failure: nil)
        }
        // Existence decides the branch: present entries earn a `start`
        // attempt, while absent entries skip it entirely so the logs never
        // carry a misleading not-found start failure for a first install.
        let entryExists = await containerEntryExists(runtime: runtime)
        if Task.isCancelled {
            return ContainerOutcome(didStart: false, failure: nil)
        }
        if !entryExists {
            // Absent fast path: no entry to revive, so go straight to the
            // fresh `run` below. A concurrent creator may have answered the
            // probe between the check and now, so confirm reachability first;
            // reachable now means another process won and no start is claimed.
            if await isReachable(baseURL: browser.searxngURL) {
                return ContainerOutcome(didStart: false, failure: nil)
            }
            return await runFreshContainer(browser: browser, runtime: runtime, lastFailure: nil, onStage: onStage)
        }
        // Present entry: try `start`, poll briefly for the settle, and return
        // on reachable. Only an exit-0 start claims the outcome, so a
        // container revived by another process reports false instead of
        // double-claiming.
        var lastFailure: String?
        do {
            let (code, output) = try await runProcess(
                executableURL: runtime,
                arguments: containerStartArguments(),
                timeoutSeconds: containerStartTimeoutSeconds
            )
            if Task.isCancelled {
                return ContainerOutcome(didStart: false, failure: nil)
            }
            // Brief settle poll keeps a slow start from looking wedged: a
            // start that needs an extra second proves itself here instead of
            // churning the entry via needless `rm` plus `run`.
            if await pollForReachableBriefly(baseURL: browser.searxngURL, timeoutSeconds: containerStartSettleSeconds) {
                return ContainerOutcome(didStart: code == 0, failure: nil)
            }
            // Exit 0 yet still dark after the settle: the spawn claimed the
            // entry and the container may need more than the brief settle to
            // answer, so return to the watch path instead of deleting a
            // healthy starting container via `rm` plus `run`.
            if code == 0 {
                return ContainerOutcome(didStart: true, failure: nil)
            }
            lastFailure = failureMessage(
                stage: EnsureStage.start.rawValue,
                exitCode: code,
                output: output,
                timedOut: false
            )
        } catch is CancellationError {
            return ContainerOutcome(didStart: false, failure: nil)
        } catch let error as BoundedProcessError {
            lastFailure = runFailureMessage(error: error, stage: EnsureStage.start.rawValue, timeout: containerStartTimeoutSeconds)
        } catch {
            lastFailure = failureMessage(
                stage: EnsureStage.start.rawValue,
                exitCode: nil,
                output: error.localizedDescription,
                timedOut: false
            )
        }
        if Task.isCancelled {
            return ContainerOutcome(didStart: false, failure: nil)
        }
        if await isReachable(baseURL: browser.searxngURL) {
            // Reachable now supersedes the earlier start failure, so clear it
            // instead of carrying a stale stage detail into a success.
            return ContainerOutcome(didStart: false, failure: nil)
        }
        // Start refusal: remove the wedged entry with `rm`-first before the
        // fresh `run`, mirroring the escape-hatch script so the next `run`
        // cannot hit "already exists". Best-effort: a concurrent remover win
        // still leaves `run` safe. Re-probe after the remove in case another
        // starter answered mid-remove.
        await removeStaleContainer(runtime: runtime)
        if Task.isCancelled {
            return ContainerOutcome(didStart: false, failure: nil)
        }
        if await isReachable(baseURL: browser.searxngURL) {
            return ContainerOutcome(didStart: false, failure: nil)
        }
        return await runFreshContainer(browser: browser, runtime: runtime, lastFailure: lastFailure, onStage: onStage)
    }

    /// Runs a fresh SearXNG container with the per-install settings mount.
    /// Pulls the tracked image explicitly ahead of `run` when absent (long
    /// minutes budget, skipped when cached so retries resume layers), then
    /// runs with a short timeout. Callers remove the stale entry with
    /// `rm`-first before arriving here (mirroring the escape-hatch script),
    /// so a `run` name conflict is impossible except for cross-process races
    /// that recreate the name between `rm` and `run`; that residual wedge
    /// still revives via `start` before surfacing a failure.
    /// - Parameters:
    ///   - browser: `[browser]` policy carrying the base URL.
    ///   - runtime: Resolved Apple Container CLI.
    ///   - lastFailure: Failure detail from the start attempt, if any.
    ///   - onStage: Optional live progress callback for the dashboard and CLI.
    /// - Returns: Whether this call started a container plus failure detail.
    public static func runFreshContainer(
        browser: BrowserConfig,
        runtime: URL,
        lastFailure: String?,
        onStage: StartStageReporter? = nil
    ) async -> ContainerOutcome {
        // Ensure the per-install override exists with a random secret before
        // resolving the mount, so the shipped placeholder is never mounted.
        // Fail closed when secret permissions cannot be enforced: a hardening
        // failure must never fall through to mounting a world-readable file.
        guard ensureOverrideSettingsFile() != nil else {
            let secretFailure = failureMessage(
                stage: EnsureStage.run.rawValue,
                exitCode: nil,
                output: "secret permissions",
                timedOut: false
            )
            return ContainerOutcome(
                didStart: false,
                failure: lastFailure.map { "\($0); \(secretFailure)" } ?? secretFailure
            )
        }
        guard let settings = bundledSettingsPath() else {
            // Fail closed: never start with image defaults, which lack the
            // guaranteed formats:[html,json]. The caller falls through to
            // polling and then to the guidance error naming the manual hatch.
            let missing = failureMessage(
                stage: EnsureStage.run.rawValue,
                exitCode: nil,
                output: "no SearXNG settings found for mount",
                timedOut: false
            )
            return ContainerOutcome(didStart: false, failure: lastFailure.map { "\($0); \(missing)" } ?? missing)
        }
        if Task.isCancelled {
            return ContainerOutcome(didStart: false, failure: nil)
        }
        // Explicit pull ahead of run, only when the image is absent. A pull
        // failure fails closed here without also attempting a `run` that
        // could not succeed without the image, keeping one cause per banner.
        // The pull reports its own user-visible stage from inside the helper,
        // so re-assert `starting` before the run spawn covers the pull-to-run
        // move on hosts that actually downloaded.
        var chainedFailure = lastFailure
        if let pullFailure = await ensureImageAvailable(runtime: runtime, onStage: onStage) {
            if Task.isCancelled {
                return ContainerOutcome(didStart: false, failure: nil)
            }
            chainedFailure = chainedFailure.map { "\($0); \(pullFailure)" } ?? pullFailure
            return ContainerOutcome(didStart: false, failure: chainedFailure)
        }
        if Task.isCancelled {
            return ContainerOutcome(didStart: false, failure: nil)
        }
        await onStage?(.starting)
        let port = hostPort(from: browser.searxngURL)
        let runArgs = containerRunArguments(settingsPath: settings, hostPort: port)
        do {
            let (code, output) = try await runProcess(executableURL: runtime, arguments: runArgs, timeoutSeconds: containerRunTimeoutSeconds)
            if Task.isCancelled {
                return ContainerOutcome(didStart: false, failure: nil)
            }
            if code == 0 {
                // Exit 0 supersedes the earlier start failure, so success
                // clears the stale stage detail instead of carrying it forward.
                return ContainerOutcome(didStart: true, failure: nil)
            }
            // `rm`-first before this `run` makes the conflict impossible except
            // for cross-process races recreating the name mid-flight; that
            // residual entry is still startable, so revive it before reporting
            // the conflict as a run failure.
            if isWedgedContainer(output: output) {
                if let revived = await startWedgedContainer(browser: browser, runtime: runtime) {
                    return revived
                }
                if Task.isCancelled {
                    return ContainerOutcome(didStart: false, failure: nil)
                }
            }
            let runFailure = failureMessage(
                stage: EnsureStage.run.rawValue,
                exitCode: code,
                output: output,
                timedOut: false
            )
            return ContainerOutcome(
                didStart: false,
                failure: chainedFailure.map { "\($0); \(runFailure)" } ?? runFailure
            )
        } catch is CancellationError {
            return ContainerOutcome(didStart: false, failure: nil)
        } catch let error as BoundedProcessError {
            let runFailure = runFailureMessage(
                error: error,
                stage: EnsureStage.run.rawValue,
                timeout: containerRunTimeoutSeconds
            )
            return ContainerOutcome(
                didStart: false,
                failure: chainedFailure.map { "\($0); \(runFailure)" } ?? runFailure
            )
        } catch {
            let runFailure = failureMessage(
                stage: EnsureStage.run.rawValue,
                exitCode: nil,
                output: error.localizedDescription,
                timedOut: false
            )
            return ContainerOutcome(
                didStart: false,
                failure: chainedFailure.map { "\($0); \(runFailure)" } ?? runFailure
            )
        }
    }

    /// Revives a wedged same-name container left by a killed fresh run.
    /// Runs `start` with the short start budget and gates the claim on a
    /// reachability probe, so a start that exits 0 without the engine
    /// answering never reports a start. Returns nil when the wedge did not
    /// revive, letting the caller surface the original `run` conflict.
    /// - Parameters:
    ///   - browser: `[browser]` policy carrying the base URL.
    ///   - runtime: Resolved Apple Container CLI.
    /// - Returns: Start outcome when the wedge revived, nil otherwise.
    public static func startWedgedContainer(browser: BrowserConfig, runtime: URL) async -> ContainerOutcome? {
        if Task.isCancelled {
            return nil
        }
        do {
            let (code, _) = try await runProcess(
                executableURL: runtime,
                arguments: containerStartArguments(),
                timeoutSeconds: containerStartTimeoutSeconds
            )
            if Task.isCancelled {
                return nil
            }
            // Only a true revive claims a start: a nonzero exit leaves the
            // original run conflict plus chained detail for the caller to
            // surface, and an unanswered probe does the same.
            guard code == 0 else {
                return nil
            }
            guard await isReachable(baseURL: browser.searxngURL) else {
                return nil
            }
            return ContainerOutcome(didStart: true, failure: nil)
        } catch {
            return nil
        }
    }

    /// Builds the run-stage failure fragment for a bounded-process error.
    /// Shared by the start and run phases so timeout mapping stays single
    /// sourced between the container heal steps.
    /// - Parameters:
    ///   - error: Bounded-process failure from the container spawn.
    ///   - stage: Cascade stage name for the failure message.
    ///   - timeout: Budget for the timeout note when the spawn timed out.
    /// - Returns: Single-line failure fragment.
    public static func runFailureMessage(error: BoundedProcessError, stage: String, timeout: Double) -> String {
        let timedOut = if case .timedOut = error {
            true
        } else {
            false
        }
        return failureMessage(
            stage: stage,
            exitCode: nil,
            output: error.localizedDescription,
            timedOut: timedOut,
            timeoutSeconds: timedOut ? timeout : nil
        )
    }

    /// Best-effort container stop shared by the server stop route.
    /// A missing runtime or absent container still reports stopped so the
    /// settings toggle never sticks on a 500; later searches re-ensure.
    public static func bestEffortStop() async {
        guard let runtime = resolveRuntimeURL() else { return }
        do {
            _ = try await runProcess(
                executableURL: runtime,
                arguments: ["stop", containerName],
                timeoutSeconds: 8
            )
        } catch {
            RuneWeaverLog.tools.debug("SearXNG bestEffortStop completed with: \(error.localizedDescription)")
        }
    }

    /// Probes the SearXNG base URL with a short timeout.
    /// Surfaces 3xx instead of auto-following so the probe shares the no-follow
    /// session policy with `web.fetch` (`NoRedirectDelegate` plus per-hop
    /// re-validation there); a safe start can never launder an
    /// unsafe redirect through the session follower.
    /// - Parameter baseURL: Configured `searxng_url`.
    /// - Returns: True when the engine answers with 2xx/3xx.
    public static func isReachable(baseURL: String) async -> Bool {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        var request = URLRequest(url: url, timeoutInterval: probeTimeoutSeconds)
        request.httpMethod = "GET"
        request.setValue(WebFetchTool.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let delegate = NoRedirectDelegate()
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return isReadinessSuccessStatusCode(http.statusCode)
        } catch {
            return false
        }
    }

    /// Probes the base URL once for the sick fast path, capturing status plus body.
    /// Shares the no-follow policy and the short probe budget with `isReachable`
    /// so both probes agree on success; only a 5xx with a readable capped tail
    /// counts toward sickness, while success carries no tail, definitive non-5xx
    /// such as 4xx breaks the streak, and gaps plus empty or undecodable 5xx
    /// bodies arrive empty so the watch keeps waiting instead of tripping on noise.
    /// The body is bounded by the shared fetch cap: an advertised `Content-Length`
    /// beyond the cap short-circuits without decoding, and larger-than-cap payloads
    /// decode only their shared-cap prefix, so a wedged loopback 5xx with a large
    /// body cannot allocate unbounded per tick before the capped tail.
    /// - Parameter baseURL: Configured `searxng_url`.
    /// - Returns: Status plus capped body tail, or no-response when nothing parsed.
    public static func fetchHTTPProbe(baseURL: String) async -> HTTPProbeSnapshot {
        if Task.isCancelled {
            return .noResponse
        }
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else {
            return .noResponse
        }
        var request = URLRequest(url: url, timeoutInterval: probeTimeoutSeconds)
        request.httpMethod = "GET"
        request.setValue(WebFetchTool.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let delegate = NoRedirectDelegate()
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)
            if Task.isCancelled {
                return .noResponse
            }
            guard let http = response as? HTTPURLResponse else {
                return .noResponse
            }
            let code = http.statusCode
            if isReadinessSuccessStatusCode(code) {
                return HTTPProbeSnapshot(statusCode: code, bodyTail: "")
            }
            guard isReadinessServerErrorStatusCode(code) else {
                return HTTPProbeSnapshot(statusCode: code, bodyTail: "")
            }
            // Bound before decode under the shared fetch cap so per-tick
            // allocation stays capped even when loopback answers instantly.
            if let lengthValue = http.value(forHTTPHeaderField: "Content-Length")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                let advertised = Int(lengthValue),
                advertised > WebFetchTool.maxFetchBytes
            {
                return HTTPProbeSnapshot(statusCode: code, bodyTail: "")
            }
            let bounded = data.count > WebFetchTool.maxFetchBytes ? Data(data.prefix(WebFetchTool.maxFetchBytes)) : data
            guard let tail = countableServerErrorBodyTail(from: bounded) else {
                return HTTPProbeSnapshot(statusCode: code, bodyTail: "")
            }
            return HTTPProbeSnapshot(statusCode: code, bodyTail: tail)
        } catch {
            return .noResponse
        }
    }

    /// Fail-closed banner naming the terminal cause plus one hatch command.
    /// The banner holds only one retry-aware terminal cause (daemon, pull
    /// timeout with cached-layer retry, pull failure with Hub reachability,
    /// run/start, watch crash or missing with logs, watch sick 5xx with body,
    /// watch backstop with last state, or not-reachable) plus a single
    /// `scripts/searxng-up.sh` remediation so each of install, daemon, pull
    /// timeout, pull failure, run, watch crash, watch sick, watch stuck, and poll
    /// renders once without nesting the unreachable text around install text or
    /// chaining every stage into the banner. The full per-stage detail (stage,
    /// exit, capped tail, timeout) travels in `diagnosticsUserInfoKey` for server
    /// warn logs plus the collapsed Settings diagnostics element.
    /// - Parameters:
    ///   - baseURL: Configured `searxng_url`.
    ///   - detail: Chained per-stage fragments from the cascade, if any.
    /// - Returns: Error carrying the trimmed banner plus chained diagnostics.
    public static func unreachableError(baseURL: String, detail: String?) -> Error {
        let trimmed = (detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let pullStage = EnsureStage.pull.rawValue
        // Match crash, missing, and sickness only on the waiting state hint before
        // the logs tail, so backstop log or body prose containing error, missing,
        // or http wording never misrenders as a terminal banner.
        let waitingHint = waitingStateHint(in: trimmed).lowercased()
        let sickCode = serverErrorStatusCode(in: trimmed)
        let banner: String = if trimmed.contains("stage: \(pullStage)"), trimmed.contains("timed out") {
            pullTimeoutBanner()
        } else if trimmed.contains("stage: \(pullStage)") {
            pullFailedBanner()
        } else if trimmed.contains("stage: waiting"), waitingHint.contains("missing") {
            readinessMissingBanner()
        } else if trimmed.contains("stage: waiting"),
                  waitingHint.contains("exited") || waitingHint.contains("error") || waitingHint.contains("crash")
        {
            readinessCrashBanner()
        } else if trimmed.contains("stage: waiting"), sickCode != nil {
            readinessServerErrorBanner(statusCode: sickCode)
        } else if trimmed.contains("stage: waiting") {
            readinessBackstopBanner(baseURL: baseURL)
        } else if trimmed.contains("stage: run") || trimmed.contains("stage: start") {
            runBanner()
        } else if trimmed.contains("stage: daemon") {
            daemonBanner()
        } else {
            timeoutBanner(baseURL: baseURL)
        }
        var userInfo: [String: Any] = [NSLocalizedDescriptionKey: banner]
        if !trimmed.isEmpty {
            userInfo[diagnosticsUserInfoKey] = trimmed
        }
        return NSError(domain: "RuneWeaverSearXNG", code: 1, userInfo: userInfo)
    }

    /// State hint inside waiting fragments without the logs tail.
    /// Splits the chained detail on `;`, keeps waiting fragments, and cuts
    /// each at `logs:` so log prose containing error or missing never poses
    /// as a crash or missing state.
    /// - Parameter detail: Chained per-stage fragments from the cascade.
    /// - Returns: Joined state hints before the logs tail.
    public static func waitingStateHint(in detail: String) -> String {
        let segments = detail.components(separatedBy: ";")
        var hints: [String] = []
        for segment in segments {
            guard segment.contains("stage: waiting") else { continue }
            let afterDetail: String = if let range = segment.range(of: "detail:") {
                String(segment[range.upperBound...])
            } else {
                segment
            }
            if let logsRange = afterDetail.range(of: "logs:", options: .caseInsensitive) {
                hints.append(String(afterDetail[..<logsRange.lowerBound]))
            } else {
                hints.append(afterDetail)
            }
        }
        return hints.joined(separator: " ")
    }

    /// Fail-closed guidance naming the manual escape hatch.
    /// - Parameter baseURL: Configured `searxng_url`.
    /// - Returns: Error carrying remediation steps.
    public static func unreachableError(baseURL: String) -> Error {
        unreachableError(baseURL: baseURL, detail: nil)
    }

    /// Runs one container process without blocking the cooperative pool.
    public static func runProcess(executableURL: URL, arguments: [String], timeoutSeconds: Double) async throws -> (Int32, String) {
        try Task.checkCancellation()
        do {
            let result = try await BoundedProcessRunner.runAsync(
                executableURL: executableURL,
                arguments: arguments,
                timeoutSeconds: timeoutSeconds,
                maxOutputBytes: 64 * 1024,
                maxErrorBytes: 64 * 1024
            )
            try Task.checkCancellation()
            return (result.exitCode, result.stdoutString + result.stderrString)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw error
        }
    }
}

/// Rune Weaver Tools — Readiness watch with fail-fast terminal states.
///
/// Replaces the fixed short poll after the container heal with a watch that
/// ticks on short sleeps until a minutes-scale backstop. Reachability (2xx/3xx)
/// wins on every tick and resets the sick streak, terminal container states fail
/// fast with the capped logs tail, persistent 5xx with a readable body fails fast
/// with the capped body tail once the consecutive threshold trips, definitive
/// non-5xx resets the streak, and gaps plus empty-bodied or unparseable states
/// keep waiting so a slow boot past the old
/// budget still converges. The backstop fails with the last observed state plus
/// logs tail (timeout-only when nothing ever answered), and banners name the
/// failing stage (crash, sick, stuck) instead of a timeout note.
extension SearXNGEnsurer {
    /// Lines of container logs captured when the watch fails.
    /// Small enough to stay readable in diagnostics, large enough to carry the
    /// crash line that explains an exit.
    public static let containerLogsTailLines = 50
    /// Budget for each state or logs probe inside the watch.
    /// Short so one hung inspect never stalls the tick past the next sleep.
    public static let readinessProbeTimeoutSeconds: Double = 5

    /// Arguments fetching the tail of container logs without following.
    /// Uses the Apple Container `-n` tail flag so the probe stays bounded even
    /// when the container has logged verbosely since start.
    /// - Parameter tailLines: Lines from the end of the logs, clamped positive.
    /// - Returns: Arguments for the logs probe.
    public static func containerLogsArguments(tailLines: Int = containerLogsTailLines) -> [String] {
        ["logs", "-n", "\(max(1, tailLines))", containerName]
    }

    /// Readiness states observed while waiting for the engine to answer.
    /// Only the crash family is terminal; everything else keeps waiting so an
    /// unparseable inspect degrades to patience instead of a false failure.
    public enum ContainerReadinessState: String, Sendable, Equatable, CaseIterable {
        case running
        case waiting
        case exited
        case errored
        case missing
        case unknown

        /// Whether this state fails the watch immediately with logs.
        /// Exited, errored, and missing all mean the container will never answer
        /// without operator action, while running, waiting, and unknown may still converge.
        var isTerminal: Bool {
            switch self {
            case .exited, .errored, .missing:
                true
            case .running, .waiting, .unknown:
                false
            }
        }
    }

    /// Snapshot of one container state probe inside the watch.
    /// Carries the classified state plus the raw hint and exit so failure detail
    /// can name what the watch last saw without re-running the probe.
    public struct ContainerReadinessSnapshot: Sendable, Equatable {
        public let state: ContainerReadinessState
        public let rawState: String
        public let exitCode: Int32?

        public init(state: ContainerReadinessState, rawState: String, exitCode: Int32? = nil) {
            self.state = state
            self.rawState = rawState
            self.exitCode = exitCode
        }

        /// Idle snapshot for external bases with no local container to watch.
        /// Unknown keeps the loop on HTTP alone until the backstop.
        static var unknownNoContainer: Self {
            Self(state: .unknown, rawState: ContainerReadinessState.unknown.rawValue, exitCode: nil)
        }
    }

    /// Outcome of one readiness watch.
    /// Success means HTTP answered; failure carries the chained detail plus the
    /// last state and logs tail separately so banners and diagnostics stay honest.
    /// Cancellation is explicit so callers never mistake a cancelled turn for a crash.
    public struct ReadinessWatchOutcome: Sendable, Equatable {
        public let succeeded: Bool
        public let failureDetail: String?
        public let lastState: String
        public let logsTail: String
        public let cancelled: Bool

        public init(succeeded: Bool, failureDetail: String? = nil, lastState: String = "unknown", logsTail: String = "", cancelled: Bool = false) {
            self.succeeded = succeeded
            self.failureDetail = failureDetail
            self.lastState = lastState
            self.logsTail = logsTail
            self.cancelled = cancelled
        }

        /// Cancelled outcome that callers map to `CancellationError`.
        /// Carries no detail so a cancelled turn never renders as a crash banner.
        static var cancelledOutcome: Self {
            Self(succeeded: false, failureDetail: nil, lastState: "unknown", logsTail: "", cancelled: true)
        }
    }

    /// Classifies one inspect dump into a readiness state.
    /// Missing is checked first so a not-found hint never poses as a crash;
    /// a non-zero exit degrades to patience since daemon or spawn prose is not
    /// container state. An exit-0 JSON dump classifies from exact `State`
    /// fields (`Status`, `Error`, `Dead`, `OOMKilled`) so health-adjacent
    /// wording such as deadlines, `ErrorLogPath`, or image references keeps
    /// waiting instead of failing fast; only non-JSON prose falls back to
    /// word-boundary shapes, and anything unparseable stays unknown.
    /// - Parameters:
    ///   - output: Combined stdout plus stderr from the inspect probe.
    ///   - exitCode: Inspect exit status, when a process ran; nil keeps classification for raw-text callers.
    /// - Returns: Classified state, unknown when the output proves nothing.
    public static func classifyContainerReadiness(output: String, exitCode: Int32?) -> ContainerReadinessState {
        if inspectIndicatesMissing(output: output) {
            return .missing
        }
        if let exitCode, exitCode != 0 {
            return .unknown
        }
        // Exact state wins when the dump parses: a healthy entry carrying a
        // deadline, an error-adjacent path, or a failed-looking image tag still
        // reports its live `Status`, so only that status can fail the watch.
        if let json = decodedInspectJSON(from: output) {
            if let state = stateClassificationFromDecodedJSON(json) {
                return state
            }
            if nonEmptyErrorInDecodedJSON(json) {
                return .errored
            }
            return .unknown
        }
        // Raw-text fallback stays strict: word boundaries keep `deadline` from
        // posing as dead and image tags from posing as failed, while the error
        // shape requires a quoted non-empty value so log paths keep waiting.
        if matchesWord(exitedWordRegex, in: output) {
            return .exited
        }
        if hasNonEmptyErrorValue(in: output) || matchesWord(deadWordRegex, in: output)
            || matchesWord(oomKilledWordRegex, in: output)
        {
            return .errored
        }
        if matchesWord(failedWordRegex, in: output) {
            return .errored
        }
        if matchesWord(runningWordRegex, in: output) || output.lowercased().contains(" up ") {
            return .running
        }
        if matchesWord(waitingWordRegex, in: output) {
            return .waiting
        }
        return .unknown
    }

    /// Terminal tokens matched only on word boundaries in raw-text output.
    /// Shared so each watch tick avoids recompiling; boundaries keep substrings
    /// such as deadlines from failing a healthy container while JSON dumps
    /// never reach this path because exact state already decided above.
    public static let exitedWordRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "\\bexited\\b",
        options: [.caseInsensitive]
    )
    public static let deadWordRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "\\bdead\\b",
        options: [.caseInsensitive]
    )
    public static let oomKilledWordRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "\\boom[\\s_\\-]*killed\\b",
        options: [.caseInsensitive]
    )
    public static let failedWordRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "\\bfailed\\b",
        options: [.caseInsensitive]
    )
    public static let runningWordRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "\\brunning\\b",
        options: [.caseInsensitive]
    )
    public static let waitingWordRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "\\b(created|starting|restarting|paused|removing|waiting)\\b",
        options: [.caseInsensitive]
    )

    /// Whether raw text contains a whole-token match for the precompiled shape.
    /// Case-insensitive so JSON and prose casings share one gate; a missing
    /// pattern never matches so a compile failure degrades to patience.
    /// - Parameters:
    ///   - regex: Precompiled word-boundary shape, nil reads as no match.
    ///   - text: Raw inspect text for the fallback path.
    /// - Returns: True when the token appears on word boundaries.
    public static func matchesWord(_ regex: NSRegularExpression?, in text: String) -> Bool {
        guard let regex else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    // Decoded-inspect JSON helpers live in `SearXNGEnsurer+Helpers.swift` so
    // this file stays within the length budget; the watch below keeps the
    // same HTTP-wins plus terminal-fails-fast plus backstop semantics.

    /// Strict quoted error assignment required in raw-text output.
    /// Only `"error": <non-empty>` counts, so `ErrorLogPath`, log values
    /// containing error, and differently-named keys keep waiting; shared so
    /// each tick avoids recompiling.
    public static let nonEmptyErrorShapeRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "[\"']error[\"']\\s*:\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s,\\}\\]]+))",
        options: [.caseInsensitive]
    )

    /// Whether inspect output carries a non-empty error value.
    /// Decoded JSON checks exact `Error` keys so adjacent key names never
    /// count; raw text requires the quoted non-empty shape for the same
    /// reason, and bare prose without that shape keeps waiting.
    /// - Parameter output: Combined stdout plus stderr from the inspect probe.
    /// - Returns: True when a non-empty error signal remains.
    public static func hasNonEmptyErrorValue(in output: String) -> Bool {
        if let json = decodedInspectJSON(from: output) {
            return nonEmptyErrorInDecodedJSON(json)
        }
        guard output.lowercased().contains("error") else { return false }
        guard let regex = nonEmptyErrorShapeRegex else { return false }
        let range = NSRange(output.startIndex..., in: output)
        let matches = regex.matches(in: output, options: [], range: range)
        for match in matches {
            // Quoted captures prove a value only when non-blank and not the
            // literal null; an empty assignment is the healthy inspect shape.
            for index in 1 ... 2 {
                let capture = match.range(at: index)
                guard capture.location != NSNotFound, let swiftRange = Range(capture, in: output) else { continue }
                let raw = String(output[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty, raw.lowercased() != "null" else { continue }
                return true
            }
            // Unquoted captures cover numeric or boolean encodings; null and
            // falsy placeholders still read as healthy rather than failures.
            let unquoted = match.range(at: 3)
            guard unquoted.location != NSNotFound, let swiftRange = Range(unquoted, in: output) else { continue }
            let raw = String(output[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }
            let lowered = raw.lowercased()
            if ["null", "nil", "none", "false", "0", "0.0"].contains(lowered) {
                continue
            }
            return true
        }
        return false
    }

    /// Whether a classified state fails the watch immediately.
    /// Kept beside the classifier so the tick and the unit tests share one gate
    /// instead of duplicating the terminal set.
    /// - Parameter state: Classified readiness state.
    /// - Returns: True for exited, errored, or missing.
    public static func isTerminalReadinessState(_ state: ContainerReadinessState) -> Bool {
        state.isTerminal
    }

    /// Whether raw inspect text already proves a terminal crash.
    /// Missing is terminal too, but callers needing the distinction use the
    /// classifier directly so a vanished entry never renders as a crash.
    /// - Parameter output: Combined stdout plus stderr from the inspect probe.
    /// - Returns: True when the text names an exited or errored state.
    public static func isTerminalReadinessOutput(_ output: String) -> Bool {
        let state = classifyContainerReadiness(output: output, exitCode: nil)
        return state == .exited || state == .errored
    }

    /// Probes the tracked entry without changing state.
    /// Prefers inspect for precision, then cross-checks the list dump so a flaked
    /// inspect never promotes a present entry to missing or demotes a vanished
    /// entry to unknown. Unparseable output degrades to unknown so the watch
    /// keeps waiting instead of failing on garbage.
    /// - Parameter runtime: Resolved Apple Container CLI.
    /// - Returns: Snapshot naming the current state plus the raw hint.
    public static func fetchContainerReadiness(runtime: URL) async -> ContainerReadinessSnapshot {
        if Task.isCancelled {
            return ContainerReadinessSnapshot(state: .unknown, rawState: "unknown", exitCode: nil)
        }
        do {
            let (code, output) = try await runProcess(
                executableURL: runtime,
                arguments: containerInspectArguments(),
                timeoutSeconds: readinessProbeTimeoutSeconds
            )
            if Task.isCancelled {
                return ContainerReadinessSnapshot(state: .unknown, rawState: "unknown", exitCode: code)
            }
            if code == 0 {
                let state = classifyContainerReadiness(output: output, exitCode: code)
                // An exit-0 inspect that classifies unknown stays unknown: the
                // entry exists but the shape drifted, so patience is correct.
                return ContainerReadinessSnapshot(state: state, rawState: state.rawValue, exitCode: code)
            }
            if inspectIndicatesMissing(output: output) {
                let confirmedAbsent = await confirmedContainerAbsent(runtime: runtime)
                if confirmedAbsent {
                    return ContainerReadinessSnapshot(state: .missing, rawState: "missing", exitCode: code)
                }
                return ContainerReadinessSnapshot(state: .unknown, rawState: "unknown", exitCode: code)
            }
            // Unknown inspect failure (timeout, daemon hiccup): consult the list
            // before deciding, so a transient miss never reads as a vanishing entry.
            let absent = await confirmedContainerAbsent(runtime: runtime)
            if absent {
                return ContainerReadinessSnapshot(state: .missing, rawState: "missing", exitCode: code)
            }
            let state = classifyContainerReadiness(output: output, exitCode: code)
            if state.isTerminal {
                return ContainerReadinessSnapshot(state: state, rawState: state.rawValue, exitCode: code)
            }
            return ContainerReadinessSnapshot(state: .unknown, rawState: "unknown", exitCode: code)
        } catch is CancellationError {
            return ContainerReadinessSnapshot(state: .unknown, rawState: "unknown", exitCode: nil)
        } catch {
            if Task.isCancelled {
                return ContainerReadinessSnapshot(state: .unknown, rawState: "unknown", exitCode: nil)
            }
            let absent = await confirmedContainerAbsent(runtime: runtime)
            if absent {
                return ContainerReadinessSnapshot(state: .missing, rawState: "missing", exitCode: nil)
            }
            return ContainerReadinessSnapshot(state: .unknown, rawState: "unknown", exitCode: nil)
        }
    }

    /// Confirms absence via the list dump when inspect is inconclusive.
    /// A failed listing never claims present, so the caller still attempts patience
    /// instead of stalling on an unknown probe.
    /// - Parameter runtime: Resolved Apple Container CLI.
    /// - Returns: True only when the dump proves the entry is gone.
    public static func confirmedContainerAbsent(runtime: URL) async -> Bool {
        if Task.isCancelled {
            return false
        }
        do {
            return try await !listContainsEntry(runtime: runtime, timeout: readinessProbeTimeoutSeconds)
        } catch {
            return false
        }
    }

    /// Fetches the capped logs tail for failure detail.
    /// Best-effort: a failed fetch yields an empty tail so the state still fails
    /// with its name instead of masking the crash behind a logs error.
    /// - Parameters:
    ///   - runtime: Resolved Apple Container CLI.
    ///   - tailLines: Lines from the end of the logs.
    /// - Returns: Single-line capped tail, or empty when unavailable.
    public static func fetchContainerLogsTail(runtime: URL, tailLines: Int = containerLogsTailLines) async -> String {
        if Task.isCancelled {
            return ""
        }
        do {
            let (_, output) = try await runProcess(
                executableURL: runtime,
                arguments: containerLogsArguments(tailLines: tailLines),
                timeoutSeconds: readinessProbeTimeoutSeconds
            )
            if Task.isCancelled {
                return ""
            }
            return cappedTail(output)
        } catch {
            return ""
        }
    }

    /// Builds one watch failure fragment naming the state plus logs tail.
    /// Terminal crashes carry the exit wording plus logs without a timeout note;
    /// the backstop carries the last state plus logs with its budget so the
    /// headline can name what the watch last saw.
    /// - Parameters:
    ///   - stateText: Last or terminal state hint (exited, missing, running, unknown).
    ///   - logsTail: Capped logs tail, possibly empty.
    ///   - timedOut: Whether the backstop fired.
    ///   - timeoutSeconds: Backstop budget for the timeout note when timed out.
    ///   - exitCode: Inspect exit when the terminal probe ran.
    /// - Returns: Single-line failure fragment for the diagnostics chain.
    public static func readinessFailureDetail(
        stateText: String,
        logsTail: String,
        timedOut: Bool,
        timeoutSeconds: Double? = nil,
        exitCode: Int32? = nil
    ) -> String {
        let trimmedState = stateText.trimmingCharacters(in: .whitespacesAndNewlines)
        let stateHint = trimmedState.isEmpty ? "unknown" : trimmedState
        let combined = if logsTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            "container \(stateHint)"
        } else {
            "container \(stateHint) logs: \(logsTail)"
        }
        return failureMessage(
            stage: "waiting",
            exitCode: exitCode,
            output: combined,
            timedOut: timedOut,
            timeoutSeconds: timeoutSeconds
        )
    }

    /// Core watch loop shared by production and hermetic tests.
    /// Ticks on short sleeps: reachable (2xx/3xx) returns success and resets the
    /// sick streak, terminal states return failure with the logs tail, persistent
    /// countable 5xx returns failure with the capped body tail once the consecutive
    /// threshold trips, definitive non-5xx resets the streak, and gaps plus
    /// empty-bodied or unparseable states keep waiting
    /// until the backstop, which fails with the last state plus logs tail
    /// (timeout-only when nothing ever answered). Cancellation returns the cancelled
    /// outcome so callers map it to `CancellationError` instead of a crash banner.
    /// - Parameters:
    ///   - timeoutSeconds: Backstop budget, defaulting to the server readiness watch (165s, settling before the longer client cap which suspends while pulling).
    ///   - pollInterval: Sleep between ticks, defaulting to the short watch interval.
    ///   - isReachable: Probe answering true once HTTP responds 2xx/3xx. Skipped on ticks
    ///     where `httpProbe` is provided, so a single fetch per tick drives both success and sickness.
    ///   - containerState: Probe classifying the tracked entry each tick.
    ///   - containerLogs: Probe fetching the capped logs tail on terminal or backstop.
    ///   - httpProbe: Rich HTTP probe carrying status plus capped body tail for the sick
    ///     fast path. Nil preserves the legacy boolean-only watch; provided, it drives success
    ///     (2xx/3xx resets) and countable 5xx streak tracking per tick.
    /// - Returns: Success plus failure detail with last state and logs tail.
    public static func watchReadiness(
        timeoutSeconds: Double = readinessWatchTimeoutSeconds,
        pollInterval: UInt64 = pollIntervalNanoseconds,
        isReachable: @Sendable @escaping () async -> Bool,
        containerState: @Sendable @escaping () async -> ContainerReadinessSnapshot,
        containerLogs: @Sendable @escaping () async -> String,
        httpProbe: (@Sendable () async -> HTTPProbeSnapshot)? = nil
    ) async -> ReadinessWatchOutcome {
        if Task.isCancelled {
            return .cancelledOutcome
        }
        let probes = ReadinessWatchProbes(
            isReachable: isReachable,
            containerState: containerState,
            containerLogs: containerLogs,
            httpProbe: httpProbe
        )
        let initial = await initialWatchOutcome(probes: probes)
        if let outcome = initial.outcome {
            return outcome
        }
        if Task.isCancelled {
            return .cancelledOutcome
        }
        let backstop = max(1.0, timeoutSeconds)
        let looped = await pollWatchLoop(
            pollInterval: pollInterval,
            backstop: backstop,
            state: ReadinessLoopState(lastState: ContainerReadinessState.unknown.rawValue, sick: initial.sick),
            probes: probes
        )
        if let outcome = looped.outcome {
            return outcome
        }
        if Task.isCancelled {
            return .cancelledOutcome
        }
        let final = await tickHTTPOutcome(probes: probes, lastState: looped.state.lastState, sick: looped.state.sick)
        if let outcome = final.outcome {
            return outcome
        }
        if Task.isCancelled {
            return .cancelledOutcome
        }
        let tail = await probes.containerLogs()
        if Task.isCancelled {
            return .cancelledOutcome
        }
        return backstopWatchOutcome(lastState: looped.state.lastState, tail: tail, backstop: backstop)
    }

    /// Production watch for a managed base with a live container.
    /// Threads the real HTTP probe (boolean plus rich status/body for the sick fast
    /// path) plus the inspect and logs probes through the shared core, so boot and
    /// tests never drift on tick, threshold, or backstop.
    /// - Parameters:
    ///   - baseURL: Configured `searxng_url` for the reachability probe.
    ///   - runtime: Resolved Apple Container CLI for state and logs probes.
    ///   - timeoutSeconds: Backstop budget, defaulting to the server readiness watch (165s, settling before the longer client cap which suspends while pulling).
    /// - Returns: Success plus failure detail with last state and logs tail.
    public static func watchEngineReadiness(
        baseURL: String,
        runtime: URL,
        timeoutSeconds: Double = readinessWatchTimeoutSeconds
    ) async -> ReadinessWatchOutcome {
        let capturedBase = baseURL
        let capturedRuntime = runtime
        return await watchReadiness(
            timeoutSeconds: timeoutSeconds,
            isReachable: { await isReachable(baseURL: capturedBase) },
            containerState: { await fetchContainerReadiness(runtime: capturedRuntime) },
            containerLogs: { await fetchContainerLogsTail(runtime: capturedRuntime) },
            httpProbe: { await fetchHTTPProbe(baseURL: capturedBase) }
        )
    }

    /// Production wait for an external base with no local container.
    /// Holds HTTP alone until the shared backstop since there is no entry whose
    /// exit could fail fast; persistent 5xx still fails fast with the body tail
    /// while the snapshot stays unknown so the loop never mistakes the absence of
    /// a container for a vanished one.
    /// - Parameters:
    ///   - baseURL: Configured `searxng_url` for the reachability probe.
    ///   - timeoutSeconds: Backstop budget, defaulting to the server readiness watch (165s, settling before the longer client cap which suspends while pulling).
    /// - Returns: Success plus poll detail on backstop, never a crash banner.
    public static func watchExternalReadiness(
        baseURL: String,
        timeoutSeconds: Double = readinessWatchTimeoutSeconds
    ) async -> ReadinessWatchOutcome {
        let capturedBase = baseURL
        return await watchReadiness(
            timeoutSeconds: timeoutSeconds,
            isReachable: { await isReachable(baseURL: capturedBase) },
            containerState: { ContainerReadinessSnapshot.unknownNoContainer },
            containerLogs: { "" },
            httpProbe: { await fetchHTTPProbe(baseURL: capturedBase) }
        )
    }
}
