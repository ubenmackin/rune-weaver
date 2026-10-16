// Rune Weaver Tools Tests — Existence-aware retry with remove fallback.

import Foundation
@testable import RuneWeaverTools
import Testing

@Suite("Search Existence Retry — Present, Absent, Remove, Wedge")
struct SearchExistenceRetryTests {
    @Test
    func `Existence verbs stay single-sourced with the script`() {
        // The engine and the hatch must spell list, inspect, start, and remove
        // identically; a drift would send one side down the absent fast path
        // while the other still tries a doomed start.
        #expect(SearXNGEnsurer.containerListAllArguments() == ["list", "--all"])
        #expect(SearXNGEnsurer.containerInspectArguments() == ["inspect", SearXNGEnsurer.containerName])
        #expect(SearXNGEnsurer.containerStartArguments() == ["start", SearXNGEnsurer.containerName])
        #expect(SearXNGEnsurer.containerRemoveArguments() == ["rm", SearXNGEnsurer.containerName])
        #expect(SearXNGEnsurer.containerRemoveArguments() != SearXNGEnsurer.containerStartArguments())
    }

    @Test
    func `List dump names the entry in any format`() {
        // Table, JSON, and YAML shapes all carry the tracked name somewhere;
        // the substring keeps every shape readable without a format flag, while
        // an empty dump or a header alone never poses as present.
        let name = SearXNGEnsurer.containerName
        #expect(SearXNGEnsurer.containerExists(inListOutput: "ID IMAGE STATE\n\(name) searxng/searxng:latest stopped") == true)
        #expect(SearXNGEnsurer.containerExists(inListOutput: "{\"configuration\":{\"id\":\"\(name)\"}}") == true)
        #expect(SearXNGEnsurer.containerExists(inListOutput: "id: \(name)\nstatus: stopped") == true)
        #expect(SearXNGEnsurer.containerExists(inListOutput: "") == false)
        #expect(SearXNGEnsurer.containerExists(inListOutput: "   \n  ") == false)
        #expect(SearXNGEnsurer.containerExists(inListOutput: "ID IMAGE OS ARCH STATE IP") == false)
        #expect(SearXNGEnsurer.containerExists(inListOutput: "buildkit ghcr.io/apple/container-builder-shim/builder:0.0.3 linux arm64 running 192.168.64.2") == false)
    }

    @Test
    func `Inspect exit decides presence while missing wording stays explicit`() {
        // Exit 0 is the only present proof; any other exit reads as absent so the caller still
        // attempts a fresh run that surfaces detail.
        #expect(SearXNGEnsurer.inspectShowsEntryPresent(exitCode: 0) == true)
        #expect(SearXNGEnsurer.inspectShowsEntryPresent(exitCode: 1) == false)
        #expect(SearXNGEnsurer.inspectShowsEntryPresent(exitCode: 2) == false)
        #expect(SearXNGEnsurer.inspectIndicatesMissing(output: "Error: container not found") == true)
        #expect(SearXNGEnsurer.inspectIndicatesMissing(output: "no such container: runeweaver-searxng") == true)
        #expect(SearXNGEnsurer.inspectIndicatesMissing(output: "container does not exist") == true)
        #expect(SearXNGEnsurer.inspectIndicatesMissing(output: "") == false)
        #expect(SearXNGEnsurer.inspectIndicatesMissing(output: "XPC connection invalid") == false)
        #expect(SearXNGEnsurer.inspectIndicatesMissing(output: "permission denied") == false)
    }

    @Test
    func `Settle window stays brief beside the start budget`() {
        // A present entry earns one short settle poll to prove itself before paying `rm` plus pull
        // plus `run`; the window must stay positive yet shorter than the start spawn so the
        // cached-image cascade stays responsive instead of doubling the start phase.
        #expect(SearXNGEnsurer.containerStartSettleSeconds > 0)
        #expect(SearXNGEnsurer.containerStartSettleSeconds < SearXNGEnsurer.containerStartTimeoutSeconds)
        #expect(SearXNGEnsurer.containerStartSettleSeconds <= SearXNGEnsurer.readinessWatchTimeoutSeconds)
    }

    @Test
    func `Wedged entry refusing start still reaches a fresh run then revives`() {
        // A wedged half-create reads as present, refuses the start, is cleared with `rm`-first,
        // then recreates via a fresh `run` with the settings mount and the cached image; a residual
        // race conflict on that `run` still revives via `start` before failing.
        let name = SearXNGEnsurer.containerName
        // Present branch: the listing names the wedged entry, so the caller
        // earns the `start` attempt instead of skipping straight to `run`.
        #expect(SearXNGEnsurer.containerExists(inListOutput: "\(name) searxng/searxng:latest stopped") == true)
        #expect(SearXNGEnsurer.inspectShowsEntryPresent(exitCode: 0) == true)
        // Refusal branch: `rm`-first precedes the fresh `run`, spelling the
        // same verbs the hatch script uses so neither side drifts.
        #expect(SearXNGEnsurer.containerRemoveArguments() == ["rm", name])
        let runArgs = SearXNGEnsurer.containerRunArguments(settingsPath: "/tmp/settings.yml", hostPort: 8888)
        #expect(runArgs.first == "run")
        #expect(runArgs.contains(name))
        #expect(runArgs.contains("127.0.0.1:8888:8080"))
        #expect(runArgs.contains("/tmp/settings.yml:/etc/searxng/settings.yml:ro"))
        // Residual race: the fresh `run` reports the same-name conflict, which
        // stays startable and revives via the existing `start` verb.
        #expect(SearXNGEnsurer.isWedgedContainer(output: "Error: container already exists") == true)
        #expect(SearXNGEnsurer.containerStartArguments() == ["start", name])
    }

    @Test
    func `Absent entry goes straight to run without a start`() {
        // A first install lists nothing and inspects non-zero, so the caller
        // skips the doomed `start` and its misleading not-found detail and
        // pays only the fresh `run` with the mounted settings.
        #expect(SearXNGEnsurer.containerExists(inListOutput: "ID IMAGE OS ARCH STATE IP") == false)
        #expect(SearXNGEnsurer.inspectShowsEntryPresent(exitCode: 1) == false)
        #expect(SearXNGEnsurer.inspectIndicatesMissing(output: "Error: container not found: runeweaver-searxng") == true)
        let runArgs = SearXNGEnsurer.containerRunArguments(settingsPath: "/tmp/settings.yml", hostPort: 8888)
        #expect(runArgs.contains("run"))
        #expect(!runArgs.contains("pull"))
        #expect(runArgs.contains("/tmp/settings.yml:/etc/searxng/settings.yml:ro"))
    }

    @Test
    func `Fresh run after rm-first is conflict-impossible except races`() {
        // `rm`-first before every fresh `run` makes the name conflict impossible in the
        // single-flight path; only a cross-process race recreating the name between `rm` and `run`
        // can still wedge, and that residual still revives via `start`.
        let runArgs = SearXNGEnsurer.containerRunArguments(settingsPath: "/tmp/settings.yml", hostPort: 8888)
        // The run verb never spells the remove verb, proving remove precedes
        // run instead of hiding inside it.
        #expect(runArgs.first == "run")
        #expect(!runArgs.contains("rm"))
        #expect(SearXNGEnsurer.isWedgedContainer(output: "") == false)
        #expect(SearXNGEnsurer.isWedgedContainer(output: "run ok: created runeweaver-searxng") == false)
        #expect(SearXNGEnsurer.isWedgedContainer(output: "run failed: exit 1") == false)
        // The residual race still counts as startable, so the fallback below
        // stays reachable even though the ordered path cannot hit it alone.
        #expect(SearXNGEnsurer.isWedgedContainer(output: "Conflict: name runeweaver-searxng is already in use") == true)
        #expect(SearXNGEnsurer.isWedgedContainer(output: "conflict: image layer conflict in registry") == false)
    }
}
