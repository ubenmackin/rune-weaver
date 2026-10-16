// Rune Weaver Tools — SearXNG container lifecycle plus readiness watch.

import Foundation
import RuneWeaverCore

/// Inconclusive list probe: the `list --all` dump could not confirm presence.
/// Thrown by the shared probe so callers map it to patience instead of a
/// confirmed answer.
private struct InconclusiveListProbeError: Error {}

/// Rune Weaver Tools — SearXNG container lifecycle plus reachability.
extension SearXNGEnsurer {
    /// Arguments probing whether the tracked image is already cached locally. Exits 0 when cached,
    /// so the minutes-budget pull below runs only for first installs instead of on every ensure.
    public static func imageInspectArguments(image: String = containerImage) -> [String] {
        ["image", "inspect", image]
    }

    /// Arguments pulling the tracked image with the long minutes budget. Split out from `run` so
    /// the short run timeout never hides a registry download; a timed-out pull is safe to retry
    /// because layers stay cached.
    public static func imagePullArguments(image: String = containerImage) -> [String] {
        ["image", "pull", image]
    }

    /// Arguments starting the existing named container. Shared by the fast-path start and the
    /// wedged half-create fallback so both spell the name identically instead of drifting between
    /// call sites.
    public static func containerStartArguments() -> [String] {
        ["start", containerName]
    }

    /// Arguments listing every container including stopped ones for existence checks.
    public static func containerListAllArguments() -> [String] {
        ["list", "--all"]
    }

    /// Arguments probing the tracked entry directly for existence checks.
    public static func containerInspectArguments() -> [String] {
        ["inspect", containerName]
    }

    /// Arguments removing a stale entry before a fresh `run`. Spells `rm` (the `delete` alias) to
    /// match the escape-hatch script, so script and engine never diverge on the remove verb.
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
    public static func inspectShowsEntryPresent(exitCode: Int32) -> Bool {
        exitCode == 0
    }

    /// Whether `inspect` output carries the absent-entry hint.
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
            // Any non-zero inspect (definitive miss or unknown failure) earns one list cross-check:
            // a wedged half-create can flake inspect while the entry blocks `run`, and unknown
            // failures fall through to the dump rather than assuming absent outright.
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

    /// Single `list --all` probe shared by existence checks. Runs one listing under the caller
    /// budget and reports whether the dump names the tracked entry, so inspect-first callers never
    /// drift on verbs or match polarity.
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

    /// Cross-checks existence via the `list --all` dump. Keeps the inspect-first probe honest when
    /// inspect flakes; a failed listing reads as absent so the caller still attempts a fresh `run`
    /// instead of stalling.
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

    /// Polls briefly for the engine after a `start` before declaring refusal. Gives a slow start
    /// one settle window to answer so a start that needs an extra second never churns the entry via
    /// needless `rm` plus `run`.
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

    /// Arguments running a fresh container with the per-install settings mount. Split from the pull
    /// step so each carries its own timeout: pull pays minutes once, run stays short.
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
            // Absent fast path: no entry to revive, so go straight to the fresh `run` below.
            if await isReachable(baseURL: browser.searxngURL) {
                return ContainerOutcome(didStart: false, failure: nil)
            }
            return await runFreshContainer(browser: browser, runtime: runtime, lastFailure: nil, onStage: onStage)
        }
        // Present entry: try `start`, poll briefly for the settle, and return on reachable. Only an
        // exit-0 start claims the outcome, so a container revived by another process reports false
        // instead of double-claiming.
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
            // Exit 0 yet still dark after the settle: the spawn claimed the entry and the container
            // may need more than the brief settle to answer, so return to the watch path instead of
            // deleting a healthy starting container via `rm` plus `run`.
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
        // Start refusal: remove the wedged entry with `rm`-first before the fresh `run`, mirroring
        // the escape-hatch script so the next `run` cannot hit "already exists".
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
    public static func runFreshContainer(
        browser: BrowserConfig,
        runtime: URL,
        lastFailure: String?,
        onStage: StartStageReporter? = nil
    ) async -> ContainerOutcome {
        // Ensure the per-install override exists with a random secret before resolving the mount,
        // so the shipped placeholder is never mounted.
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
        // Explicit pull ahead of run, only when the image is absent. A pull failure fails closed
        // here without also attempting a `run` that could not succeed without the image, keeping one
        // cause per banner.
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
            // `rm`-first before this `run` makes the conflict impossible except for cross-process
            // races recreating the name mid-flight; that residual entry is still startable, so
            // revive it before reporting the conflict as a run failure.
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

    /// Builds the run-stage failure fragment for a bounded-process error. Shared by the start and
    /// run phases so timeout mapping stays single sourced between the container heal steps.
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
extension SearXNGEnsurer {
    /// Lines of container logs captured when the watch fails.
    /// Small enough to stay readable in diagnostics, large enough to carry the
    /// crash line that explains an exit.
    public static let containerLogsTailLines = 50
    /// Budget for each state or logs probe inside the watch.
    /// Short so one hung inspect never stalls the tick past the next sleep.
    public static let readinessProbeTimeoutSeconds: Double = 5

    /// Arguments fetching the tail of container logs without following. Uses the Apple Container
    /// `-n` tail flag so the probe stays bounded even when the container has logged verbosely since
    /// start.
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

    /// Outcome of one readiness watch. Success means HTTP answered; failure carries the chained
    /// detail plus the last state and logs tail separately so banners and diagnostics stay honest.
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

    /// Classifies one inspect dump into a readiness state. Missing is checked first so a not-found
    /// hint never poses as a crash; a non-zero exit degrades to patience since daemon or spawn prose
    /// is not container state.
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

    /// Whether raw text contains a whole-token match for the precompiled shape. Case-insensitive so
    /// JSON and prose casings share one gate; a missing pattern never matches so a compile failure
    /// degrades to patience.
    public static func matchesWord(_ regex: NSRegularExpression?, in text: String) -> Bool {
        guard let regex else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    // Decoded-inspect JSON helpers live in `SearXNGEnsurer+Helpers.swift` so
    // this file stays within the length budget; the watch below keeps the
    // same HTTP-wins plus terminal-fails-fast plus backstop semantics.

    /// Strict quoted error assignment required in raw-text output.
    public static let nonEmptyErrorShapeRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "[\"']error[\"']\\s*:\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s,\\}\\]]+))",
        options: [.caseInsensitive]
    )

    /// Whether inspect output carries a non-empty error value.
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

    /// Whether a classified state fails the watch immediately. Kept beside the classifier so the
    /// tick and the unit tests share one gate instead of duplicating the terminal set.
    public static func isTerminalReadinessState(_ state: ContainerReadinessState) -> Bool {
        state.isTerminal
    }

    /// Whether raw inspect text already proves a terminal crash. Missing is terminal too, but
    /// callers needing the distinction use the classifier directly so a vanished entry never renders
    /// as a crash.
    public static func isTerminalReadinessOutput(_ output: String) -> Bool {
        let state = classifyContainerReadiness(output: output, exitCode: nil)
        return state == .exited || state == .errored
    }

    /// Probes the tracked entry without changing state. Prefers inspect for precision, then
    /// cross-checks the list dump so a flaked inspect never promotes a present entry to missing or
    /// demotes a vanished entry to unknown.
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

    /// Confirms absence via the list dump when inspect is inconclusive. A failed listing never
    /// claims present, so the caller still attempts patience instead of stalling on an unknown
    /// probe.
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

    /// Fetches the capped logs tail for failure detail. Best-effort: a failed fetch yields an empty
    /// tail so the state still fails with its name instead of masking the crash behind a logs error.
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
