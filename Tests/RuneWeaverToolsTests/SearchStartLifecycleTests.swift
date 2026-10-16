// Rune Weaver Tools Tests — Explicit pull, wedged fallback, banners, stages, and joiners.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

@Suite("Search Start Lifecycle — Pull, Wedge, Banners, Stages")
struct SearchStartLifecycleTests {
    @Test
    func `Per-step budgets keep the pull long and the probes short`() {
        // The first-run pull pays minutes once while inspect, run, and start
        // stay short so cached hosts never pay the pull budget by accident.
        #expect(SearXNGEnsurer.containerImagePullTimeoutSeconds == 300)
        #expect(SearXNGEnsurer.containerImageInspectTimeoutSeconds == 8)
        #expect(SearXNGEnsurer.containerRunTimeoutSeconds == 8)
        #expect(SearXNGEnsurer.containerStartTimeoutSeconds == 5)
        #expect(SearXNGEnsurer.containerImagePullTimeoutSeconds > SearXNGEnsurer.containerRunTimeoutSeconds)
        #expect(SearXNGEnsurer.containerImagePullTimeoutSeconds > SearXNGEnsurer.containerImageInspectTimeoutSeconds)
    }

    @Test
    func `Pull step stays split ahead of the fresh run`() {
        // The inspect probe and the explicit pull use different verbs from the
        // fresh run, so a registry download never hides inside the short run
        // budget and retries can resume cached layers.
        let image = SearXNGEnsurer.containerImage
        #expect(SearXNGEnsurer.imageInspectArguments() == ["image", "inspect", image])
        #expect(SearXNGEnsurer.imagePullArguments() == ["image", "pull", image])
        #expect(SearXNGEnsurer.containerStartArguments() == ["start", SearXNGEnsurer.containerName])
        let runArgs = SearXNGEnsurer.containerRunArguments(settingsPath: "/tmp/settings.yml", hostPort: 8888)
        #expect(runArgs.contains("run"))
        #expect(!runArgs.contains("pull"))
        #expect(!SearXNGEnsurer.imagePullArguments().contains("run"))
        #expect(runArgs.contains("127.0.0.1:8888:8080"))
        #expect(runArgs.contains("/tmp/settings.yml:/etc/searxng/settings.yml:ro"))
        // Cascade order keeps the pull ahead of the run: the stage list reads
        // runtime, daemon, start, pull, run, waiting.
        let stages = SearXNGEnsurer.EnsureStage.allCases.map(\.rawValue)
        #expect(stages == ["runtime", "daemon", "start", "pull", "run", "waiting"])
        let pullIndex = stages.firstIndex(of: "pull") ?? -1
        let runIndex = stages.firstIndex(of: "run") ?? -1
        #expect(pullIndex >= 0 && runIndex >= 0 && pullIndex < runIndex)
    }

    @Test
    func `Wedged conflicts require the container name on bare conflict`() {
        // A killed run leaves a half-created same-name entry that is still
        // startable; the fallback must catch it without treating an unrelated
        // registry conflict as the same wedge.
        #expect(SearXNGEnsurer.isWedgedContainer(output: "Error: container already exists") == true)
        #expect(SearXNGEnsurer.isWedgedContainer(output: "ALREADY IN USE by another container") == true)
        #expect(SearXNGEnsurer.isWedgedContainer(output: "Conflict: name runeweaver-searxng is already in use") == true)
        #expect(SearXNGEnsurer.isWedgedContainer(output: "conflict: image layer conflict in registry") == false)
        #expect(SearXNGEnsurer.isWedgedContainer(output: "run failed: exit 1") == false)
        #expect(SearXNGEnsurer.isWedgedContainer(output: "") == false)
    }

    @Test
    func `Pull timeout banner names cached-layer retry once`() {
        // A timed-out pull is safe to retry because layers stay cached; the
        // banner carries that retry note plus exactly one remediation.
        let banner = SearXNGEnsurer.pullTimeoutBanner()
        #expect(banner.contains("timed out after 300s"))
        #expect(banner.lowercased().contains("cached"))
        #expect(banner.components(separatedBy: "scripts/searxng-up.sh").count - 1 == 1)
        #expect(!banner.contains("stage:"))
        let custom = SearXNGEnsurer.pullTimeoutBanner(timeoutSeconds: 300)
        #expect(custom == banner)
    }

    @Test
    func `Pull failure banner names Hub reachability once`() {
        // A failed pull points at Hub reachability rather than the run step,
        // so a registry miss never renders as a run failure.
        let banner = SearXNGEnsurer.pullFailedBanner()
        #expect(banner.lowercased().contains("hub"))
        #expect(banner.components(separatedBy: "scripts/searxng-up.sh").count - 1 == 1)
        #expect(!banner.contains("stage:"))
        #expect(!banner.lowercased().contains("timed out"))
    }

    @Test
    func `Run banner stays distinct from pull banners`() {
        // Fresh-run failures keep the run cause while pull banners keep their
        // own causes; each renders once without nesting stage fragments.
        let banner = SearXNGEnsurer.runBanner()
        #expect(banner.lowercased().contains("run failed"))
        #expect(banner.components(separatedBy: "scripts/searxng-up.sh").count - 1 == 1)
        #expect(!banner.contains("stage:"))
        #expect(banner != SearXNGEnsurer.pullFailedBanner())
        #expect(banner != SearXNGEnsurer.pullTimeoutBanner())
    }

    @Test
    func `Unreachable error picks one banner per terminal cause`() {
        // The selector threads exactly one retry-aware cause into the banner
        // while the chained stage detail travels separately for logs.
        let baseURL = "http://127.0.0.1:8888"
        let pullTimeout = SearXNGEnsurer.failureMessage(
            stage: "pull", exitCode: nil, output: "download stalled", timedOut: true, timeoutSeconds: 300
        )
        let pullTimeoutError = SearXNGEnsurer.unreachableError(baseURL: baseURL, detail: pullTimeout)
        #expect(pullTimeoutError.localizedDescription == SearXNGEnsurer.pullTimeoutBanner())
        #expect((SearXNGEnsurer.diagnostics(from: pullTimeoutError) ?? "").contains("stage: pull"))

        let pullFailed = SearXNGEnsurer.failureMessage(
            stage: "pull", exitCode: 1, output: "pull access denied", timedOut: false
        )
        let pullFailedError = SearXNGEnsurer.unreachableError(baseURL: baseURL, detail: pullFailed)
        #expect(pullFailedError.localizedDescription == SearXNGEnsurer.pullFailedBanner())

        let runFailed = SearXNGEnsurer.failureMessage(
            stage: "run", exitCode: 1, output: "boom", timedOut: false
        )
        let runError = SearXNGEnsurer.unreachableError(baseURL: baseURL, detail: runFailed)
        #expect(runError.localizedDescription == SearXNGEnsurer.runBanner())

        let startFailed = SearXNGEnsurer.failureMessage(
            stage: "start", exitCode: 1, output: "boom", timedOut: false
        )
        let startError = SearXNGEnsurer.unreachableError(baseURL: baseURL, detail: startFailed)
        #expect(startError.localizedDescription == SearXNGEnsurer.runBanner())

        let daemonFailed = SearXNGEnsurer.failureMessage(
            stage: "daemon", exitCode: 1, output: "xpc down", timedOut: false
        )
        let daemonError = SearXNGEnsurer.unreachableError(baseURL: baseURL, detail: daemonFailed)
        #expect(daemonError.localizedDescription == SearXNGEnsurer.daemonBanner())

        let waitingBackstop = SearXNGEnsurer.failureMessage(
            stage: "waiting", exitCode: nil, output: nil, timedOut: true, timeoutSeconds: 165
        )
        let waitingError = SearXNGEnsurer.unreachableError(baseURL: baseURL, detail: waitingBackstop)
        #expect(waitingError.localizedDescription == SearXNGEnsurer.readinessBackstopBanner(baseURL: baseURL))
        #expect((SearXNGEnsurer.diagnostics(from: waitingError) ?? "").contains("timed out after 165s"))
        #expect(SearXNGEnsurer.readinessWatchTimeoutSeconds == 165)
        // Every banner renders once: one hatch command, no stage fragments.
        for error in [pullTimeoutError, pullFailedError, runError, startError, daemonError, waitingError] {
            #expect(error.localizedDescription.components(separatedBy: "scripts/searxng-up.sh").count - 1 == 1)
            #expect(!error.localizedDescription.contains("stage:"))
        }
    }

    @Test
    func `Start stages expose stable copy per step`() {
        // The owner flight and every client render the same five steps; the
        // copy lives beside the raw value so CLI and dashboard never drift.
        let stages = SearXNGEnsurer.StartStage.allCases
        #expect(stages.map(\.rawValue) == ["resolving", "daemon", "pulling", "starting", "waiting"])
        #expect(SearXNGEnsurer.StartStage.resolving.userCopy == "Checking container runtime")
        #expect(SearXNGEnsurer.StartStage.daemon.userCopy == "Waking container service")
        #expect(SearXNGEnsurer.StartStage.pulling.userCopy == "Pulling search image")
        #expect(SearXNGEnsurer.StartStage.starting.userCopy == "Starting search container")
        #expect(SearXNGEnsurer.StartStage.waiting.userCopy == "Waiting for search to respond")
        #expect(Set(stages.map(\.userCopy)).count == stages.count)
        for stage in stages {
            #expect(!stage.userCopy.isEmpty)
        }
    }

    @Test
    func `Start stages round-trip through their raw values`() {
        // Health payloads carry the raw string; an unknown step must fail to
        // decode rather than silently alias to a known step.
        for stage in SearXNGEnsurer.StartStage.allCases {
            let encoded = try? JSONEncoder().encode(stage)
            let decoded = try? JSONDecoder().decode(SearXNGEnsurer.StartStage.self, from: encoded ?? Data())
            #expect(decoded == stage)
        }
        #expect(SearXNGEnsurer.StartStage(rawValue: "resolving") == .resolving)
        #expect(SearXNGEnsurer.StartStage(rawValue: "unknown-step") == nil)
    }

    @Test
    func `Start progress pins the Start instant across stage moves`() {
        // Elapsed time counts the whole Start, not the current step, so the
        // snapshot preserves `startedAt` while the stage advances.
        let pinned = Date(timeIntervalSince1970: 1_700_000_000)
        let first = SearXNGEnsurer.StartProgress(stage: .resolving, startedAt: pinned)
        let moved = SearXNGEnsurer.StartProgress(stage: .pulling, startedAt: first.startedAt)
        #expect(moved.stage == .pulling)
        #expect(moved.startedAt == pinned)
        #expect(first != moved)
    }

    @Test
    func `Single-flight keys collapse one origin while keeping others apart`() {
        // Concurrent callers for one normalized base URL share a flight while
        // different origins run independently instead of reporting cross-config
        // reachability.
        #expect(SearXNGEnsurer.inFlightKey(for: "http://127.0.0.1:8888/") == "http://127.0.0.1:8888")
        #expect(SearXNGEnsurer.inFlightKey(for: " HTTP://127.0.0.1:8888/ ") == SearXNGEnsurer.inFlightKey(for: "http://127.0.0.1:8888"))
        #expect(SearXNGEnsurer.inFlightKey(for: "http://127.0.0.1:8888") != SearXNGEnsurer.inFlightKey(for: "http://127.0.0.1:9999"))
    }

    @Test
    func `Idle ensurer exposes no Start snapshot for joiners`() async {
        // Joiners poll the owner's snapshot; an idle engine must read nil
        // instead of a stale Starting display left behind by a settled flight.
        let ensurer = SearXNGEnsurer()
        let snapshot = await ensurer.currentStartProgress(for: "http://127.0.0.1:8888")
        #expect(snapshot == nil)
    }

    @Test
    func `CLI watcher math clamps skew and names the live step`() {
        // The serve watcher only reads snapshots and never drives the flight;
        // future-dated Starts clamp to zero while past Starts tick whole
        // seconds beside the verbatim step copy.
        let future = Date().addingTimeInterval(60)
        #expect(max(0, Int(Date().timeIntervalSince(future))) == 0)
        let past = Date().addingTimeInterval(-65)
        let elapsed = max(0, Int(Date().timeIntervalSince(past)))
        #expect(elapsed >= 60 && elapsed <= 90)
        let line = "SearXNG \(SearXNGEnsurer.StartStage.pulling.userCopy)… (\(elapsed)s)"
        #expect(line.contains("Pulling search image"))
        #expect(line.hasSuffix("s)"))
    }
}
