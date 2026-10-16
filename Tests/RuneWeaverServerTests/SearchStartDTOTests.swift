// Rune Weaver Server Tests — Search Start DTOs for staged health polling.

import Foundation
@testable import RuneWeaverServer
import Testing

@Suite("Search Start DTOs — Stage plus Start Time")
struct SearchStartDTOTests {
    @Test
    func `Health response stays pill-only with idle stage cleared`() {
        // Idle engines carry no stage so the dashboard renders the tri-state
        // pill (Reachable, Stopped, Unknown) without a stale Starting line.
        let idle = SearchHealthResponse(reachable: true, baseURL: "http://127.0.0.1:8888", containerName: "runeweaver-searxng")
        #expect(idle.stage == nil)
        #expect(idle.startedAt == nil)
        #expect(idle.status == "running")
        #expect(idle.url == "http://127.0.0.1:8888")
        let stopped = SearchHealthResponse(reachable: false, baseURL: "http://127.0.0.1:8888", containerName: "runeweaver-searxng")
        #expect(stopped.status == "stopped")
    }

    @Test
    func `Health response carries the live stage for joiners`() {
        // While a Start runs, every poller sees the same step plus Start time
        // so profile and Settings panes stay in lockstep on one contract.
        let startedAt = 1_700_000_000.0
        let inflight = SearchHealthResponse(
            reachable: false,
            baseURL: "http://127.0.0.1:8888",
            containerName: "runeweaver-searxng",
            stage: "pulling",
            startedAt: startedAt
        )
        #expect(inflight.stage == "pulling")
        #expect(inflight.startedAt == startedAt)
        #expect(inflight.status == "stopped")
    }

    @Test
    func `Health response normalizes blank stage and bad Start times`() {
        // Blank or whitespace stages degrade to idle, and non-positive plus
        // non-finite Start times degrade to unknown so elapsed math falls back
        // to the client-side Start instant instead of a garbage epoch.
        let blank = SearchHealthResponse(
            reachable: false, baseURL: "http://127.0.0.1:8888", containerName: "c", stage: "  ", startedAt: 1_700_000_000
        )
        #expect(blank.stage == nil)
        #expect(blank.startedAt == 1_700_000_000)
        for bad in [0.0, -5.0, Double.nan, Double.infinity] {
            let response = SearchHealthResponse(
                reachable: false, baseURL: "http://127.0.0.1:8888", containerName: "c", stage: "waiting", startedAt: bad
            )
            #expect(response.stage == "waiting")
            #expect(response.startedAt == nil)
        }
    }

    @Test
    func `Health response tolerates url and baseURL shapes`() throws {
        // Dual-contract reads keep custom ports regardless of which key the
        // engine encoded; older payloads without stage keys decode to idle.
        let payload = #"{"reachable":false,"url":"http://127.0.0.1:9999"}"#.data(using: .utf8) ?? Data()
        let decoded = try JSONDecoder().decode(SearchHealthResponse.self, from: payload)
        #expect(decoded.baseURL == "http://127.0.0.1:9999")
        #expect(decoded.url == "http://127.0.0.1:9999")
        #expect(decoded.stage == nil)
        #expect(decoded.startedAt == nil)
        #expect(decoded.status == "stopped")

        // Split stays on the comma boundary so each raw-string half keeps
        // balanced quotes; the continuation opens with its own quote.
        let stagedJSON = #"{"reachable":false,"baseURL":"http://127.0.0.1:8888","containerName":"c","#
            + #""url":"http://127.0.0.1:8888","status":"stopped","stage":"starting","startedAt":1700000000}"#
        let staged = stagedJSON.data(using: .utf8) ?? Data()
        let stagedDecoded = try JSONDecoder().decode(SearchHealthResponse.self, from: staged)
        #expect(stagedDecoded.stage == "starting")
        #expect(stagedDecoded.startedAt == 1_700_000_000)
    }

    @Test
    func `Health response round-trips the staged contract`() throws {
        // Encode carries both URL keys plus status so either dashboard reader
        // keeps the custom port; idle omits the staged keys entirely.
        let inflight = SearchHealthResponse(
            reachable: false, baseURL: "http://127.0.0.1:8888", containerName: "c", stage: "daemon", startedAt: 1_700_000_001
        )
        let body = try JSONEncoder().encode(inflight)
        let roundTripped = try JSONDecoder().decode(SearchHealthResponse.self, from: body)
        #expect(roundTripped == inflight)
        let idle = SearchHealthResponse(reachable: true, baseURL: "http://127.0.0.1:8888", containerName: "c")
        let idleBody = try JSONEncoder().encode(idle)
        let idleJSON = try JSONSerialization.jsonObject(with: idleBody) as? [String: Any]
        #expect(idleJSON?["baseURL"] as? String == "http://127.0.0.1:8888")
        #expect(idleJSON?["url"] as? String == "http://127.0.0.1:8888")
        #expect(idleJSON?["status"] as? String == "running")
    }

    @Test
    func `Global health nests the same stage for the profile dot`() throws {
        // `GET /health` nests the snapshot under `searchStage` plus
        // `searchStartedAt` while `/search/health` uses `stage` plus
        // `startedAt`; both clear on settle so no path sticks on Starting.
        let inflight = HealthResponse(searchStage: "pulling", searchStartedAt: 1_700_000_000)
        #expect(inflight.searchStage == "pulling")
        #expect(inflight.searchStartedAt == 1_700_000_000)
        let idle = HealthResponse()
        #expect(idle.searchStage == nil)
        #expect(idle.searchStartedAt == nil)
        let body = try JSONEncoder().encode(inflight)
        let roundTripped = try JSONDecoder().decode(HealthResponse.self, from: body)
        #expect(roundTripped.searchStage == "pulling")
        #expect(roundTripped.searchStartedAt == 1_700_000_000)
    }

    @Test
    func `Global health trims drifted stage strings`() {
        // Blank or whitespace stages degrade to idle so a new engine step
        // never blanks the in-flight line and old engines stay parseable.
        #expect(HealthResponse(searchStage: "  ").searchStage == nil)
        #expect(HealthResponse(searchStage: "starting").searchStage == "starting")
        #expect(HealthResponse(searchStage: "starting", searchStartedAt: 0).searchStartedAt == nil)
        #expect(HealthResponse(searchStage: "starting", searchStartedAt: -1).searchStartedAt == nil)
    }

    @Test
    func `Ensure response keeps the banner apart from diagnostics`() {
        // Inline slots render the trimmed banner once while collapsed UI plus
        // warn logs keep the chained per-stage detail; blanks normalize to nil
        // so callers never render whitespace as detail.
        let report = SearchEnsureResponse(
            reachable: false, baseURL: "http://127.0.0.1:8888", started: false,
            message: "SearXNG image pull failed. Check Docker Hub reachability, then run `scripts/searxng-up.sh` to retry.",
            diagnostics: "stage: pull, exit: 1, detail: denied"
        )
        #expect((report.message ?? "").contains("scripts/searxng-up.sh"))
        #expect((report.diagnostics ?? "").contains("stage: pull"))
        #expect(!((report.message ?? "").contains("stage:")))
        let blanked = SearchEnsureResponse(reachable: false, baseURL: "http://127.0.0.1:8888", started: false, message: "  ", diagnostics: "  ")
        #expect(blanked.message == nil)
        #expect(blanked.diagnostics == nil)
    }
}
