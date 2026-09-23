// Rune Weaver Tools — Static web search over self-hosted SearXNG plus its lifecycle.
//
// `web.search` keeps queries on operator infrastructure: a bounded static read
// over the self-hosted SearXNG JSON endpoint (`GET <searxng_url>/search` with
// `format=json`), capped by the smaller of the caller limit and `[browser]`
// `max_results` so the model cannot fan out unbounded context. The envelope
// carries titles, URLs, and snippets tolerating SearXNG key drift (`q`/`count`
// aliases, `content` vs `snippet`, `url` vs `link`).
//
// `SearXNGEnsurer` keeps the local engine warm for both serve boot and first
// search. Concurrent callers for one normalized base URL collapse onto a single
// in-flight attempt following the runtime, daemon, start, pull, run, watch
// cascade (cached-image heals plus a readiness watch with a minutes-scale
// backstop ticking on short sleeps; a first-run image pull adds its own
// minutes budget on top) while racing processes serialize on the shared
// container name. The owner flight
// publishes a live user-visible stage plus Start time on the actor, so health
// polls and single-flight joiners watch resolving, daemon, pulling, starting,
// waiting instead of one static label; the snapshot clears on settle or cancel.
// A missing runtime
// fails with install guidance (Apple Container link, Docker unsupported); a
// down system service heals via a fast probe plus bounded `system start`
// before any container start. Overrides carry a template-version marker
// comment; an existing file missing the marker or holding an older value is
// regenerated with a fresh secret at `0600` and the container is recreated
// with `rm`-first plus a fresh `run` so the new settings and sizing actually
// boot instead of lingering behind a `start` of the old entry. The container
// step is existence-aware, mirroring
// the escape-hatch script `rm`-first: a present entry tries `start`, polls
// briefly, and returns on reachable, while a refused start removes the wedged
// entry with `rm` before a fresh `run`; an absent entry goes straight to the
// fresh `run`. The fresh path then pulls the tracked `:latest` image once
// (skipped when already cached so retries resume downloaded layers) before a
// short-timeout run with a loopback-only publish plus a per-install secret
// (`0600` file, `0700` directory; the bundled placeholder is never mounted).
// `rm`-first makes a `run` name conflict impossible except for cross-process
// races recreating the name mid-flight; that residual wedge still revives via
// `start` instead of failing the fresh `run`.
// Fresh runs track `:latest` by design so new installs follow upstream without
// a version bump; pin via `SEARXNG_IMAGE` when reproducibility matters. After
// the heal the readiness watch ticks on short sleeps: HTTP reachable (2xx/3xx)
// wins, terminal container states (exited, errored, missing) fail fast with
// the capped logs tail, persistent HTTP 5xx with a readable body fails fast
// with the capped body tail once the consecutive threshold trips, definitive
// non-5xx such as 4xx resets the streak while gaps plus empty-bodied or
// unparseable states keep waiting until the backstop, which
// fails with the last state plus logs tail (timeout-only when nothing ever
// answered). Banners name the failing stage (start refusal, crash logs, sick
// body, stuck wait) instead of a timeout note.
// Failures report a trimmed banner (terminal cause plus one `scripts/searxng-up.sh`
// remediation, retry-aware: pull timeout names cached-layer retry, pull
// failure names Hub reachability, run failure names the exit plus tail, watch
// crash or missing names the exit plus logs) while per-stage detail (stage,
// exit, capped tail, timeout) moves to server warn logs plus collapsed
// diagnostics. The container stays running after quit by design.

import Foundation
import RuneWeaverCore

/// Lifecycle contract for the SearXNG dependency, injectable for tests.
public protocol SearXNGEnsuring: Sendable {
    /// Ensures SearXNG answers at the configured URL, starting it when down.
    /// - Parameter browser: `[browser]` policy carrying the base URL.
    /// - Throws: Guidance error when the engine stays unreachable.
    func ensure(browser: BrowserConfig) async throws
}

/// Single-flight lifecycle for the local SearXNG engine.
public actor SearXNGEnsurer: SearXNGEnsuring {
    /// Shared process-wide ensurer backing serve and search.
    public static let shared = SearXNGEnsurer()

    /// Container name shared by boot, search, and the escape-hatch script.
    public static let containerName = "runeweaver-searxng"
    /// Tracked OCI image for fresh runs when no container exists yet.
    /// Deliberately tracks `:latest` so fresh installs follow upstream without a
    /// version bump; pin via `SEARXNG_IMAGE` (script) or this constant when
    /// reproducibility matters. Keep in sync with `scripts/searxng-up.sh`.
    public static let containerImage = "searxng/searxng:latest"
    /// Backstop for the readiness watch after the heal.
    /// The server settles first at 165s while the dashboard client cap holds longer at 360s
    /// (suspending while the stage reports pulling), so a slow boot reports its terminal state
    /// before the client stops the stage line.
    /// The watch ticks on short sleeps: reachable (2xx/3xx) wins, terminal container states
    /// fail fast with logs, persistent 5xx with a readable body fails fast with the capped
    /// body tail once the consecutive threshold trips, definitive non-5xx resets the
    /// streak while gaps plus empty-bodied or unparseable states keep waiting until
    /// this backstop, which fails with the last state plus logs
    /// tail (timeout-only when nothing ever answered). Heals above it carry their own
    /// timeouts; a first-run pull adds its minutes budget on top. Single source for the
    /// minutes-scale backstop.
    public static let readinessWatchTimeoutSeconds: Double = 165

    /// Delay between readiness watch ticks while waiting for boot.
    /// Short so a crash fails fast on the next tick instead of sleeping through the backstop.
    public static let pollIntervalNanoseconds: UInt64 = 500_000_000
    /// Fast reachability probe timeout so a down engine fails fast.
    public static let probeTimeoutSeconds: Double = 2
    /// Long budget for the explicit image pull when the local image is absent.
    /// First pulls download ~150 MB, so the run stays short by paying the
    /// download here once; retries resume already-cached layers instead of
    /// restarting from zero.
    public static let containerImagePullTimeoutSeconds: Double = 300
    /// Short probe for image presence so a cached image never pays the pull budget.
    public static let containerImageInspectTimeoutSeconds: Double = 8
    /// Short budget for the fresh container run.
    /// Kept small because the image pull is split out ahead of it, so `run`
    /// only creates plus starts and never hides a registry download.
    public static let containerRunTimeoutSeconds: Double = 8
    /// Short budget for starting (or reviving a wedged) existing container.
    public static let containerStartTimeoutSeconds: Double = 5
    /// Brief settle window after `start` before declaring refusal.
    /// Lets a slow start answer one extra probe so a present entry that needs
    /// an extra second never churns via needless `rm` plus fresh `run`; short
    /// enough that the cached-image cascade stays responsive.
    public static let containerStartSettleSeconds: Double = 2
    /// Consecutive countable HTTP 5xx probe responses that trip the sick fail-fast.
    /// Small enough that a wedged engine fails in seconds instead of burning the
    /// minutes-scale backstop, large enough that one transient 500 never poses as
    /// persistent sickness. Only 5xx with a readable non-empty body counts; 2xx/3xx
    /// and definitive non-5xx such as 4xx reset the streak while gaps plus empty
    /// or unparseable 5xx preserve it and keep waiting. Single source for the sick threshold.
    public static let consecutiveServerErrorThreshold: Int = 3

    /// In-flight ensure tasks keyed by normalized base URL so concurrent
    /// callers for the same origin collapse while different origins run
    /// independently instead of reporting cross-config reachability. The
    /// Boolean carries whether the flight actually started a local container,
    /// so `ensureReport` can return the real start outcome instead of a
    /// precomputed guess.
    private var inFlight: [String: Task<Bool, Error>] = [:]

    /// User-visible Start stage reported while one ensure flight runs.
    /// Coarser than the diagnostics cascade (`EnsureStage` keeps the per-stage
    /// failure detail): one flight moves resolving, daemon, pulling, starting,
    /// waiting so the dashboard can render a single live line plus elapsed time
    /// instead of one static Starting label across the minutes-scale watch.
    public enum StartStage: String, Sendable, CaseIterable, Codable {
        case resolving
        case daemon
        case pulling
        case starting
        case waiting

        /// Short operator-facing copy naming the in-flight step.
        /// Kept beside the raw value (instead of in the dashboard) so the CLI
        /// boot lines and every client render the same wording without drifting.
        public var userCopy: String {
            switch self {
            case .resolving:
                "Checking container runtime"
            case .daemon:
                "Waking container service"
            case .pulling:
                "Pulling search image"
            case .starting:
                "Starting search container"
            case .waiting:
                "Waiting for search to respond"
            }
        }
    }

    /// One in-flight Start snapshot: the current stage plus when the Start began.
    /// `startedAt` is pinned at flight creation and preserved across stage moves
    /// so elapsed time counts the whole Start, not the current step.
    public struct StartProgress: Sendable, Equatable {
        public let stage: StartStage
        public let startedAt: Date

        public init(stage: StartStage, startedAt: Date = Date()) {
            self.stage = stage
            self.startedAt = startedAt
        }
    }

    /// Stage callback threaded through the static cascade so each phase can
    /// report without owning actor state; the owning flight maps it onto the
    /// per-URL progress below.
    public typealias StartStageReporter = @Sendable (StartStage) async -> Void

    /// Live Start snapshots keyed by normalized base URL, mirroring `inFlight`.
    /// Stored on the actor (not in the Task) so single-flight joiners polling
    /// health see the owner's stage while the flight runs, and so completion,
    /// failure, or cancellation clears it instead of sticking the UI on Starting.
    private var startProgressByKey: [String: StartProgress] = [:]

    /// Returns the live Start snapshot for a base URL, if a flight is running.
    /// - Parameter baseURL: Configured `searxng_url`.
    /// - Returns: Current stage plus Start time, or nil when idle.
    public func currentStartProgress(for baseURL: String) -> StartProgress? {
        startProgressByKey[Self.inFlightKey(for: baseURL)]
    }

    /// Pins the initial snapshot when an owner flight starts.
    /// Idempotent: a repeated begin keeps the original `startedAt` so elapsed
    /// time never rewinds when stages are re-entered.
    private func beginStartProgress(forKey key: String) {
        if startProgressByKey[key] == nil {
            startProgressByKey[key] = StartProgress(stage: .resolving, startedAt: Date())
        }
    }

    /// Moves the snapshot to a new stage, preserving the original `startedAt`.
    /// A report for an unknown key starts a snapshot rather than dropping the
    /// stage, so late cascade reports still surface instead of vanishing.
    private func noteStartStage(_ stage: StartStage, forKey key: String) {
        if let existing = startProgressByKey[key] {
            startProgressByKey[key] = StartProgress(stage: stage, startedAt: existing.startedAt)
        } else {
            startProgressByKey[key] = StartProgress(stage: stage, startedAt: Date())
        }
    }

    /// Clears the snapshot when its flight settles or cancels.
    private func clearStartProgress(forKey key: String) {
        startProgressByKey[key] = nil
    }

    /// Single-flight handle collapsing concurrent ensure callers onto one task.
    /// Carries the normalized key plus whether this caller owns the flight;
    /// only the owner clears the entry, so joiners never reap a flight they
    /// did not start.
    private struct EnsureFlight {
        let key: String
        let task: Task<Bool, Error>
        let isOwner: Bool
    }

    /// Creates an ensurer (shared in production, fresh in tests).
    public init() {}

    /// Normalizes a base URL into a single-flight key.
    /// - Parameter baseURL: Configured `searxng_url`.
    /// - Returns: Lowercased trimmed URL without trailing slashes.
    public static func inFlightKey(for baseURL: String) -> String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Collapses concurrent callers for one base URL onto a single flight.
    /// Returns the in-flight task plus whether this caller owns it; only the
    /// owner clears the entry via `awaitOwnedFlight`, so joiners never reap
    /// a flight they did not start.
    private func acquireFlight(browser: BrowserConfig) -> EnsureFlight {
        let key = Self.inFlightKey(for: browser.searxngURL)
        if let existing = inFlight[key] {
            return EnsureFlight(key: key, task: existing, isOwner: false)
        }
        let captured = browser
        // Pin the snapshot before the Task starts so joiners and health polls
        // see `resolving` from the first instant instead of a gap that reads idle.
        beginStartProgress(forKey: key)
        let task = Task<Bool, Error> {
            try await Self.ensureImpl(browser: captured, onStage: { stage in
                await self.noteStartStage(stage, forKey: key)
            })
        }
        inFlight[key] = task
        return EnsureFlight(key: key, task: task, isOwner: true)
    }

    /// Awaits an owned flight, cancelling it when the waiter cancels.
    /// Cancelling the waiter cancels the owned flight so the container start
    /// plus watch does not keep running detached after the turn.
    /// Completion, failure, and cancellation all clear the stage snapshot, so
    /// no terminal or cancelled flight leaves a stale Starting display behind.
    private func awaitOwnedFlight(key: String, task: Task<Bool, Error>) async throws -> Bool {
        defer {
            inFlight[key] = nil
            clearStartProgress(forKey: key)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Ensures SearXNG answers, starting it when down.
    public func ensure(browser: BrowserConfig) async throws {
        try Task.checkCancellation()
        if await Self.isReachable(baseURL: browser.searxngURL) {
            try Task.checkCancellation()
            return
        }
        let flight = acquireFlight(browser: browser)
        if !flight.isOwner {
            do {
                _ = try await flight.task.value
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                if await Self.isReachable(baseURL: browser.searxngURL) {
                    return
                }
                // The owner error already carries full guidance plus the last
                // cascade detail, so propagate it directly instead of wrapping
                // it in a second guidance message.
                throw error
            }
            try Task.checkCancellation()
            if await Self.isReachable(baseURL: browser.searxngURL) {
                return
            }
            // Owner succeeded but this joiner still probes dark (a flap
            // between flights): fail closed with a waiting-stage detail instead
            // of a bare guidance string, so the banner stays the shared backstop.
            let flapFailure = Self.failureMessage(
                stage: EnsureStage.waiting.rawValue,
                exitCode: nil,
                output: "owner flight succeeded but engine still unreachable",
                timedOut: false
            )
            throw Self.unreachableError(baseURL: browser.searxngURL, detail: flapFailure)
        }
        do {
            _ = try await awaitOwnedFlight(key: flight.key, task: flight.task)
        } catch is CancellationError {
            // Cooperative cancellation must propagate even when another
            // process brought the engine up mid-cancel; reachability never
            // masks a cancelled turn.
            throw CancellationError()
        } catch {
            if await Self.isReachable(baseURL: browser.searxngURL) {
                return
            }
            throw error
        }
    }

    /// Non-throwing ensure for HTTP lifecycle routes sharing the single-flight path.
    /// Fresh callers own one `ensureImpl` flight and report its real start
    /// outcome; joiners collapsing onto an existing flight never claim a
    /// start. A cancelled turn reports unreachable without claiming, so the
    /// route never marks a cancelled turn reachable. Failures carry a trimmed
    /// banner in `message` (terminal cause plus one hatch command) with the
    /// full per-stage detail (stage, exit, capped tail, timeout) in
    /// `diagnostics` for warn logs plus collapsed UI, so the banner renders
    /// once instead of chaining every stage.
    /// - Parameter browser: `[browser]` policy carrying the base URL.
    /// - Returns: Reachability plus whether this caller actually started a container plus banner and diagnostics.
    public func ensureReport(browser: BrowserConfig) async -> EnsureReport {
        if Task.isCancelled {
            return EnsureReport(reachable: false, started: false, message: nil)
        }
        if await Self.isReachable(baseURL: browser.searxngURL) {
            // Never report reachable for a cancelled turn, even when the
            // probe succeeded before cancellation landed.
            if Task.isCancelled {
                return EnsureReport(reachable: false, started: false, message: nil)
            }
            return EnsureReport(reachable: true, started: false, message: nil)
        }
        if Task.isCancelled {
            return EnsureReport(reachable: false, started: false, message: nil)
        }
        let key = Self.inFlightKey(for: browser.searxngURL)
        if inFlight[key] != nil {
            // Joiner: collapse onto the owner's flight without claiming.
            var joinMessage: String?
            var joinDiagnostics: String?
            do {
                try await ensure(browser: browser)
            } catch is CancellationError {
                return EnsureReport(reachable: false, started: false, message: nil)
            } catch {
                if Task.isCancelled {
                    return EnsureReport(reachable: false, started: false, message: nil)
                }
                joinMessage = error.localizedDescription
                joinDiagnostics = Self.diagnostics(from: error)
                // Fall through to the honest probe below.
            }
            if Task.isCancelled {
                return EnsureReport(reachable: false, started: false, message: nil)
            }
            let reachable = await Self.isReachable(baseURL: browser.searxngURL)
            if Task.isCancelled {
                return EnsureReport(reachable: false, started: false, message: nil)
            }
            if reachable {
                return EnsureReport(reachable: true, started: false, message: nil)
            }
            return EnsureReport(reachable: false, started: false, message: joinMessage, diagnostics: joinDiagnostics)
        }
        // Owner: run one flight and return its actual start outcome, not a
        // precomputed guess, so an engine already started by another process
        // or revived without a local start reports started:false.
        let flight = acquireFlight(browser: browser)
        do {
            let didStart = try await awaitOwnedFlight(key: flight.key, task: flight.task)
            if Task.isCancelled {
                return EnsureReport(reachable: false, started: false, message: nil)
            }
            return EnsureReport(reachable: true, started: didStart, message: nil)
        } catch is CancellationError {
            return EnsureReport(reachable: false, started: false, message: nil)
        } catch {
            if Task.isCancelled {
                return EnsureReport(reachable: false, started: false, message: nil)
            }
            // Failed flight: probe honestly without claiming a start the
            // flight could not prove, so cross-process races never double-claim.
            // The trimmed banner threads through for the inline slot while the
            // chained diagnostics thread through for warn logs plus collapsed UI.
            let detail = error.localizedDescription
            let diagnostics = Self.diagnostics(from: error)
            let reachable = await Self.isReachable(baseURL: browser.searxngURL)
            if Task.isCancelled {
                return EnsureReport(reachable: false, started: false, message: nil)
            }
            if reachable {
                return EnsureReport(reachable: true, started: false, message: nil)
            }
            return EnsureReport(reachable: false, started: false, message: detail, diagnostics: diagnostics)
        }
    }

    /// Runs one self-healing attempt through the ordered cascade.
    /// Follows runtime, daemon, start, pull, run, watch (heals plus a readiness
    /// watch with a minutes-scale backstop ticking on short sleeps, while a
    /// first-run pull adds its minutes budget once and retries resume cached layers):
    /// each stage records its own fragment for diagnostics, while the thrown
    /// banner holds only the retry-aware terminal cause plus one hatch command
    /// so install, daemon, pull timeout, pull failure, run, and watch crash or
    /// missing each render once. An existing override missing the current
    /// template marker (or holding an older value) is regenerated with a fresh
    /// secret before the container step, then recreated with `rm`-first plus a
    /// fresh `run` so the new settings and sizing boot. The start step itself
    /// is existence-aware (`inspect` with a
    /// `list --all` cross-check, then `start` plus brief settle on present,
    /// `rm`-first then fresh `run` on refusal, straight to `run` on absent,
    /// with the residual race wedge still revived). User-visible progress
    /// reports through `onStage` at each phase boundary (the pull step itself
    /// reports from inside the container heal only when it actually
    /// downloads); nil keeps the attempt silent for callers with no display.
    /// - Returns: Whether this attempt actually started a local container or the system service.
    private static func ensureImpl(browser: BrowserConfig, onStage: StartStageReporter? = nil) async throws -> Bool {
        try Task.checkCancellation()
        if await isReachable(baseURL: browser.searxngURL) {
            try Task.checkCancellation()
            return false
        }
        // Stage order matters: a missing runtime short-circuits before any
        // daemon probe, and a down daemon heals before container start/run so
        // later stages never misreport a service outage as a container miss.
        // A missing runtime fails with the install guidance alone: wrapping
        // the unreachable-engine text around it would bury the one actionable
        // cause under a second message, so the single error propagates as-is
        // through the web.search failure path.
        await onStage?(.resolving)
        guard let runtime = resolveRuntimeURL() else {
            throw runtimeNotFoundError()
        }
        try Task.checkCancellation()
        // External bases need no local heal: hold HTTP alone through the shared
        // watch until the backstop, so a slow remote boot still converges
        // without ever triggering a container launch for an unrelated origin.
        guard isManagedBaseURL(browser.searxngURL) else {
            await onStage?(.waiting)
            let externalOutcome = await watchExternalReadiness(baseURL: browser.searxngURL)
            if externalOutcome.cancelled {
                throw CancellationError()
            }
            try Task.checkCancellation()
            if externalOutcome.succeeded {
                return false
            }
            let externalFailure = externalOutcome.failureDetail ?? readinessFailureDetail(
                stateText: "last state unknown",
                logsTail: "",
                timedOut: true,
                timeoutSeconds: readinessWatchTimeoutSeconds
            )
            throw unreachableError(baseURL: browser.searxngURL, detail: externalFailure)
        }
        var lastFailure: String?
        await onStage?(.daemon)
        let daemonOutcome = await ensureDaemonStarted(runtime: runtime)
        var daemonStarted = daemonOutcome.daemonStarted
        if let daemonFailure = daemonOutcome.failure {
            lastFailure = daemonFailure
        }
        try Task.checkCancellation()
        // Best-effort container heal: the existence-aware start checks for the
        // entry first (present tries `start` plus brief settle, refused
        // removes with `rm`-first before fresh `run`, absent goes straight to
        // `run`, residual race wedges still revive), then falls through to
        // the watch and the guidance error, so a container-less host fails
        // closed instead of crashing boot. A stale override (existing file
        // missing the current template marker or holding an older value)
        // skips the `start` fast path entirely: it is regenerated with a
        // fresh secret first, the entry is dropped with `rm`-first, and a
        // fresh `run` boots the new document plus current sizing, so the
        // remove always precedes the run. The real start outcome flows
        // back to `ensureReport` so it never reports a precomputed guess.
        // The heal reports `pulling` itself only while actually downloading;
        // every other container step reads as `starting` here.
        await onStage?(.starting)
        let containerOutcome: SearXNGEnsurer.ContainerOutcome
        if isStaleOverridePresent() {
            // Fail closed before any remove: a permission failure returns nil,
            // and deleting the working entry first would leave no container
            // when the fresh run below also fails closed on the same secret.
            guard ensureOverrideSettingsFile() != nil else {
                let secretFailure = failureMessage(
                    stage: EnsureStage.run.rawValue,
                    exitCode: nil,
                    output: "secret permissions",
                    timedOut: false
                )
                lastFailure = lastFailure.map { "\($0); \(secretFailure)" } ?? secretFailure
                throw unreachableError(baseURL: browser.searxngURL, detail: lastFailure)
            }
            try Task.checkCancellation()
            // Remove-first before the fresh run mirrors the escape-hatch
            // script, making the recreate conflict-impossible except for a
            // cross-process race that the fresh run still revives via `start`.
            await removeStaleContainer(runtime: runtime)
            try Task.checkCancellation()
            if await isReachable(baseURL: browser.searxngURL) {
                containerOutcome = SearXNGEnsurer.ContainerOutcome(didStart: false, failure: nil)
            } else {
                let recreated = await runFreshContainer(
                    browser: browser,
                    runtime: runtime,
                    lastFailure: lastFailure,
                    onStage: onStage
                )
                // The fresh run already chains the daemon detail, so adopt its
                // failure directly instead of chaining a second time.
                if let recreatedFailure = recreated.failure {
                    lastFailure = recreatedFailure
                }
                if recreated.didStart {
                    daemonStarted = daemonStarted || recreated.didStart
                }
                containerOutcome = recreated
            }
        } else {
            let healed = await startExistingOrRun(browser: browser, runtime: runtime, onStage: onStage)
            if healed.didStart {
                daemonStarted = daemonStarted || healed.didStart
            }
            if let healedFailure = healed.failure {
                lastFailure = lastFailure.map { "\($0); \(healedFailure)" } ?? healedFailure
            }
            containerOutcome = healed
        }
        try Task.checkCancellation()
        await onStage?(.waiting)
        // Readiness watch replaces the fixed short poll: reachable (2xx/3xx) wins,
        // terminal container states fail fast with the capped logs tail, persistent
        // 5xx with a readable body fails fast with the capped body tail, definitive
        // non-5xx resets the streak while gaps plus empty-bodied or unparseable
        // states keep waiting until the backstop, which
        // fails with the last state plus logs tail. Cancellation stays cooperative so
        // the single-flight joiner contract never mistakes a cancel for a crash.
        let watchOutcome = await watchEngineReadiness(baseURL: browser.searxngURL, runtime: runtime)
        if watchOutcome.cancelled {
            throw CancellationError()
        }
        try Task.checkCancellation()
        if watchOutcome.succeeded {
            return daemonStarted || containerOutcome.didStart
        }
        let watchFailure = watchOutcome.failureDetail ?? readinessFailureDetail(
            stateText: "last state \(watchOutcome.lastState)",
            logsTail: watchOutcome.logsTail,
            timedOut: true,
            timeoutSeconds: readinessWatchTimeoutSeconds
        )
        throw unreachableError(baseURL: browser.searxngURL, detail: lastFailure.map { "\($0); \(watchFailure)" } ?? watchFailure)
    }
}

/// Best-effort container start plus cascade stage names for `SearXNGEnsurer`.
///
/// Holds the non-throwing start helpers and the ordered cascade stage names
/// outside the actor body so the single-flight lifecycle stays within the
/// type-length budget. Behavior is unchanged: the start path still heals the
/// daemon first, then the existence-aware container step, then the shared
/// readiness watch, claiming a start only when this call started the daemon
/// or container and the engine answers before the backstop.
public extension SearXNGEnsurer {
    /// Ordered cascade stages for one ensure attempt.
    /// Kept explicit so the heal order stays reviewable: runtime must resolve
    /// before any daemon probe, the daemon must answer before container
    /// start, the image pull sits ahead of the fresh run only (skipped when
    /// cached), and the readiness watch always comes last under its waiting detail.
    enum EnsureStage: String, CaseIterable, Sendable {
        case runtime
        case daemon
        case start
        case pull
        case run
        case waiting
    }

    /// Starts or runs the container without throwing.
    /// Shared by the tool path and the server lifecycle routes so boot logic
    /// cannot drift between loopback bind and settings-mount handling.
    /// Heals the system daemon first, then the existence-aware container step
    /// (present tries `start` plus brief settle, refused removes with
    /// `rm`-first before fresh `run`, absent goes straight to `run`), then holds
    /// the shared readiness watch so a slow boot still counts as started once HTTP
    /// answers instead of reporting false on the first dark probe.
    /// Returns true only when this call actually started a local container
    /// or the system service (exit 0) and the engine answers before the backstop: a
    /// missing runtime, a cancelled task, an external (non-loopback) base
    /// URL, a missing settings document, a failed spawn, or an engine that
    /// stays unreachable through the watch reports false instead of claiming a start, so
    /// cross-process races never double-claim.
    @discardableResult
    static func bestEffortStart(browser: BrowserConfig) async -> Bool {
        guard isManagedBaseURL(browser.searxngURL) else { return false }
        guard let runtime = resolveRuntimeURL() else { return false }
        if Task.isCancelled {
            return false
        }
        // Daemon first: a down service makes every container call fail with
        // XPC text, so heal it before judging start/run outcomes.
        let daemon = await ensureDaemonStarted(runtime: runtime)
        if Task.isCancelled {
            return false
        }
        if await isReachable(baseURL: browser.searxngURL) {
            return daemon.daemonStarted
        }
        let container = await startExistingOrRun(browser: browser, runtime: runtime)
        if Task.isCancelled {
            return false
        }
        // Never claim a start while the engine stays unreachable: hold the shared
        // readiness watch so a fresh run needing more than one probe interval still
        // converges instead of reporting false on the first dark check.
        let watchOutcome = await watchEngineReadiness(baseURL: browser.searxngURL, runtime: runtime)
        if Task.isCancelled || watchOutcome.cancelled {
            return false
        }
        guard watchOutcome.succeeded else {
            return false
        }
        return daemon.daemonStarted || container.didStart
    }

    /// Best-effort start for callers holding only the base URL string.
    /// - Parameter baseURL: Configured `searxng_url` for port and settings.
    /// - Returns: True only when this call actually started a container or the daemon (exit 0).
    @discardableResult
    static func bestEffortStart(baseURL: String) async -> Bool {
        guard isManagedBaseURL(baseURL), resolveRuntimeURL() != nil else { return false }
        return await bestEffortStart(browser: BrowserConfig(searxngURL: baseURL))
    }
}

/// Arguments for the `web.search` tool.
public struct WebSearchArgs: Sendable, Equatable, Decodable {
    /// Free-text query sent to SearXNG.
    public let query: String
    /// Maximum results to return, bounded by config and the hard cap.
    public let limit: Int

    /// Default result count when the caller omits `limit`.
    public static let defaultLimit = 10
    /// Hard upper bound so a crafted limit cannot flood context.
    public static let maxLimit = 50

    /// Memberwise initializer with limit clamping.
    public init(query: String, limit: Int = defaultLimit) {
        self.query = query
        self.limit = min(max(limit, 1), Self.maxLimit)
    }

    private enum CodingKeys: String, CodingKey {
        case query
        // Single-letter wire alias keeps a descriptive case name.
        case queryShort = "q"
        case limit
        case count
    }

    /// Decodes arguments, accepting `q`/`count` aliases for model drift.
    /// - Parameter decoder: Decoder for the arguments document.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let query = try container.decodeIfPresent(String.self, forKey: .query)
            ?? container.decodeIfPresent(String.self, forKey: .queryShort)
            ?? ""
        let rawLimit = try container.decodeIfPresent(Int.self, forKey: .limit)
            ?? container.decodeIfPresent(Int.self, forKey: .count)
            ?? Self.defaultLimit
        self.init(query: query, limit: rawLimit)
    }

    /// Trimmed query.
    public var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One search hit returned to the model.
public struct WebSearchResult: Sendable, Equatable, Codable {
    /// Result title (falls back to the URL when SearXNG omits it).
    public let title: String
    /// Absolute result URL.
    public let url: String
    /// Snippet (`content` when SearXNG uses that key).
    public let snippet: String

    /// Creates a hit.
    public init(title: String, url: String, snippet: String) {
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

/// Envelope wrapping `web.search` success output.
public struct WebSearchEnvelope: Sendable, Equatable, Codable {
    /// Echoed query that was run.
    public let query: String
    /// Number of hits in `results`.
    public let count: Int
    /// Hits, best first, bounded by config.
    public let results: [WebSearchResult]

    /// Creates an envelope.
    public init(query: String, results: [WebSearchResult]) {
        self.query = query
        self.results = results
        self.count = results.count
    }
}

/// Transport for SearXNG HTTP round trips, injectable for hermetic tests.
public protocol WebSearchTransport: Sendable {
    /// Performs one SearXNG round trip.
    /// - Parameter request: Request to send.
    /// - Returns: Body bytes plus the URL response.
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// Live SearXNG transport that never follows redirects automatically.
public struct URLSessionWebSearchTransport: WebSearchTransport, Sendable {
    /// Creates a live transport.
    public init() {}

    /// Sends one request, surfacing 3xx instead of following.
    /// Shares the single-source no-follow policy with the fetch and API
    /// transports so a safe search start cannot launder an unsafe hop
    /// through the session follower.
    /// - Parameter request: Request to send.
    /// - Returns: Body plus response.
    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let delegate = NoRedirectDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await session.data(for: request)
    }
}

/// SearXNG wire DTOs tolerating key drift across releases.
private struct SearXNGResultDTO: Decodable {
    let title: String?
    let url: String?
    let link: String?
    let content: String?
    let snippet: String?

    private enum CodingKeys: String, CodingKey {
        case title
        case url
        case link
        case content
        case snippet
    }
}

private struct SearXNGResponseDTO: Decodable {
    let results: [SearXNGResultDTO]?

    private enum CodingKeys: String, CodingKey {
        case results
    }
}

/// Read-only `web.search` tool over self-hosted SearXNG.
public struct WebSearchTool: Tool, Sendable {
    /// Stable tool name referenced by the LLM and memory.
    public let name = "web.search"
    /// When the LLM should use this tool.
    public let description =
        "Searches the web via local SearXNG. "
            + "Use when the user asks for current, external, or factual information beyond memory. "
            + "Returns bounded titles, URLs, and snippets."
    /// Function-calling contract for `query` and optional `limit`.
    /// Every decoder alias (`q`, `count`) is advertised so a compliant
    /// validator accepts exactly what the decoder handles.
    public let inputSchema =
        JSONSchema(
            rawValue: #"{"type":"object","properties":{"query":{"type":"string","description":"Free-text search query"},"#
                + #""q":{"type":"string","description":"Alias for query"},"limit":{"type":"integer","description":"Maximum results "#
                + #"(1-50, default 10, capped by browser.max_results)","minimum":1,"maximum":50},"count":{"type":"integer","#
                + #""description":"Alias for limit (1-50)","minimum":1,"maximum":50}},"anyOf":[{"required":["query"]},"#
                + #"{"required":["q"]}],"additionalProperties":false}"#
        )
    /// Always allowed: search never changes engine or remote state.
    public let permissionLevel = PermissionLevel.readOnly
    /// Network-derived bytes may carry injected directives, so results enter as labeled data.
    public var contentTrustLevel: ContentTrustLevel {
        .untrustedExternal
    }

    /// Browser policy supplying the base URL, timeout, and cap.
    private let browserConfig: BrowserConfig
    /// HTTP transport (live session by default, stub in tests).
    private let transport: any WebSearchTransport
    /// Lifecycle ensurer (shared actor by default, stub in tests).
    private let ensurer: any SearXNGEnsuring

    /// Creates a search tool.
    public init(
        browserConfig: BrowserConfig = BrowserConfig(),
        transport: (any WebSearchTransport)? = nil,
        ensurer: (any SearXNGEnsuring)? = nil
    ) {
        self.browserConfig = browserConfig
        self.transport = transport ?? URLSessionWebSearchTransport()
        self.ensurer = ensurer ?? SearXNGEnsurer.shared
    }

    /// Runs the search, ensuring the engine first.
    public func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        let args: WebSearchArgs
        do {
            args = try JSONDecoder().decode(WebSearchArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            return .failure(
                "Invalid web.search arguments: expected {\"query\": \"<text>\", \"limit\": <1-50>}.",
                callID: input.callID,
                errorKind: .invalidSyntax
            )
        }
        let query = args.trimmedQuery
        guard !query.isEmpty else {
            return .failure(
                "Invalid web.search arguments: 'query' must not be empty.",
                callID: input.callID,
                errorKind: .invalidSyntax
            )
        }
        // Bound N up front so every path below (live or stubbed) honors the
        // same ceiling: caller limit, config cap, and the hard 50 cap.
        let effectiveLimit = Self.effectiveLimit(requested: args.limit, browserConfig: browserConfig)
        // Fail fast on a misconfigured base URL before burning the ensure
        // budget or attempting a container start for a request that can never
        // build. This is an environment failure, not a caller argument-shape
        // failure, so it carries an explicit execution kind: the wording is
        // deliberately not "Invalid ...", which the bus's legacy content sniff
        // would otherwise mask as invalid_syntax.
        guard let request = Self.searchRequest(baseURL: browserConfig.searxngURL, query: query, timeout: browserConfig.searchTimeoutSeconds) else {
            return .failure(
                "web.search configuration error: browser.searxng_url '\(browserConfig.searxngURL)' must be an absolute URL.",
                callID: input.callID,
                errorKind: .executionError
            )
        }
        do {
            try await ensurer.ensure(browser: browserConfig)
        } catch {
            // Single guidance: the ensurer error already carries the one
            // actionable cause (install guidance for a missing runtime, or the
            // last cascade detail otherwise), so surface it verbatim instead
            // of nesting it inside a second unreachable message. The engine
            // being down is a runtime failure, never an argument-shape one.
            return .failure(error.localizedDescription, callID: input.callID, errorKind: .executionError)
        }
        do {
            let (data, response) = try await transport.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure("SearXNG returned no HTTP response.", callID: input.callID, errorKind: .executionError)
            }
            guard (200 ..< 300).contains(http.statusCode) else {
                let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let suffix = detail.isEmpty ? "" : ": \(String(detail.prefix(300)))"
                return .failure("SearXNG search failed (HTTP \(http.statusCode))\(suffix).", callID: input.callID, errorKind: .executionError)
            }
            let parsed = try Self.parseSearchPayload(data)
            let capped = Array(parsed.prefix(effectiveLimit))
            let envelope = WebSearchEnvelope(query: query, results: capped)
            let content = try ToolEnvelopeEncoding.encode(envelope)
            return .success(content, callID: input.callID)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DecodingError {
            return .failure("Could not decode SearXNG response: \(error.localizedDescription)", callID: input.callID, errorKind: .executionError)
        } catch {
            return .failure("web.search failed: \(error.localizedDescription)", callID: input.callID, errorKind: .executionError)
        }
    }

    // MARK: - Pure helpers (covered by unit tests)

    /// Bounds the result count by caller limit, config cap, and the hard cap.
    public static func effectiveLimit(requested: Int, browserConfig: BrowserConfig) -> Int {
        let clampedRequest = min(max(requested, 1), WebSearchArgs.maxLimit)
        let clampedConfig = min(max(browserConfig.maxResults, 1), BrowserConfig.maxAllowedResults)
        return min(clampedRequest, clampedConfig)
    }

    /// Builds the SearXNG JSON request, percent-encoding the query.
    /// Strips a trailing `/search` (case-insensitive, with or without slash)
    /// from the configured base URL before appending, so a base already
    /// ending in `/search` never becomes `/search/search` and fails closed.
    public static func searchRequest(baseURL: String, query: String, timeout: Int) -> URLRequest? {
        var normalized = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // Strip trailing `/search` segments when the operator configured
        // the full endpoint instead of the base URL.
        while normalized.count >= "/search".count,
              normalized.lowercased().hasSuffix("/search")
        {
            normalized = String(normalized.dropLast("/search".count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        // Fail closed on non-web schemes: a misconfigured `searxng_url` with a
        // file:/ftp:/javascript:-adjacent shape must never build a request,
        // mirroring the per-hop allowlist in `web.fetch`/`api.request`.
        guard WebURLSafety.isSafeUrl(normalized) else { return nil }
        guard !normalized.isEmpty, let base = URL(string: normalized) else { return nil }
        // Fail closed on embedded query or fragment: appending `/search` to
        // `http://127.0.0.1:8888/?x=1` would mangle the endpoint instead of
        // dialing the JSON API, so such bases never build a request.
        if base.query != nil || base.fragment != nil {
            return nil
        }
        var components = URLComponents(url: base.appendingPathComponent("search"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: Double(max(timeout, 1)))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(WebFetchTool.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Parses SearXNG JSON into hits, tolerating key drift.
    public static func parseSearchPayload(_ data: Data) throws -> [WebSearchResult] {
        let decoded = try JSONDecoder().decode(SearXNGResponseDTO.self, from: data)
        let rows = decoded.results ?? []
        var hits: [WebSearchResult] = []
        hits.reserveCapacity(rows.count)
        for row in rows {
            let rawURL = (row.url ?? row.link ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawURL.isEmpty else { continue }
            let title = (row.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = (row.content ?? row.snippet ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            hits.append(WebSearchResult(
                title: title.isEmpty ? rawURL : title,
                url: rawURL,
                snippet: snippet
            ))
        }
        return hits
    }
}

/// Factory registering the search tool on a `ToolBus`.
public enum WebSearchTools {
    /// Tool names in registration order.
    public static let toolNames = ["web.search"]

    /// Builds the search tool for a browser config.
    public static func makeTools(
        browserConfig: BrowserConfig = BrowserConfig(),
        transport: (any WebSearchTransport)? = nil,
        ensurer: (any SearXNGEnsuring)? = nil
    ) -> [any Tool] {
        [WebSearchTool(browserConfig: browserConfig, transport: transport, ensurer: ensurer)]
    }

    /// Registers the search tool, replacing same-named entries.
    public static func register(
        on bus: ToolBus,
        browserConfig: BrowserConfig = BrowserConfig(),
        transport: (any WebSearchTransport)? = nil,
        ensurer: (any SearXNGEnsuring)? = nil
    ) async {
        for tool in makeTools(browserConfig: browserConfig, transport: transport, ensurer: ensurer) {
            await bus.register(tool: tool)
        }
    }
}

/// Combined web tool family (`web.search` plus `web.fetch`).
public enum WebTools {
    /// Tool names in registration order.
    public static let toolNames = ["web.search", "web.fetch"]

    /// Builds both web tools for a browser config and optional media config.
    public static func makeTools(
        browserConfig: BrowserConfig = BrowserConfig(),
        mediaConfig: MediaConfig? = nil,
        searchTransport: (any WebSearchTransport)? = nil,
        fetchTransport: (any WebFetchTransport)? = nil,
        ensurer: (any SearXNGEnsuring)? = nil
    ) -> [any Tool] {
        WebSearchTools.makeTools(browserConfig: browserConfig, transport: searchTransport, ensurer: ensurer)
            + WebFetchTools.makeTools(browserConfig: browserConfig, mediaConfig: mediaConfig, transport: fetchTransport)
    }

    /// Registers both web tools, replacing same-named entries.
    public static func register(
        on bus: ToolBus,
        browserConfig: BrowserConfig = BrowserConfig(),
        mediaConfig: MediaConfig? = nil,
        searchTransport: (any WebSearchTransport)? = nil,
        fetchTransport: (any WebFetchTransport)? = nil,
        ensurer: (any SearXNGEnsuring)? = nil
    ) async {
        for tool in makeTools(
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            searchTransport: searchTransport,
            fetchTransport: fetchTransport,
            ensurer: ensurer
        ) {
            await bus.register(tool: tool)
        }
    }
}
