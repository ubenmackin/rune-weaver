// Rune Weaver Tools Tests — Readiness sick fail-fast on persistent HTTP 5xx.
//
// Purpose: pins the consecutive-5xx threshold trip, the success reset, and the
// distinct crash, sick, and stuck message shapes so a wedged engine fails fast
// with its body tail instead of burning the minutes-scale backstop.
// Scope: pure `SearXNGEnsurer` counting plus banner helpers and hermetic
// `watchReadiness` loops with stubbed probes; no processes are spawned and no
// network is touched.
// Architectural role: guards the waiting-stage contract shared by the engine
// cascade, the CLI watcher, the dashboard watch, and the escape-hatch script.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

@Suite("Search Readiness — Sick Fail-Fast on Persistent 5xx")
struct SearchReadinessServerErrorTests {
    @Test
    func `Sick threshold trips after consecutive countable 5xx`() {
        // Three readable 500s in a row prove sickness; one transient never trips
        // alone, so the streak must reach the threshold before failing fast.
        #expect(SearXNGEnsurer.consecutiveServerErrorThreshold == 3)
        var streak = 0
        streak = SearXNGEnsurer.nextConsecutiveServerErrorCount(current: streak, statusCode: 500, bodyTail: "boom one")
        #expect(streak == 1)
        #expect(SearXNGEnsurer.shouldFailFastOnConsecutiveServerErrors(streak) == false)
        streak = SearXNGEnsurer.nextConsecutiveServerErrorCount(current: streak, statusCode: 503, bodyTail: "boom two")
        #expect(streak == 2)
        #expect(SearXNGEnsurer.shouldFailFastOnConsecutiveServerErrors(streak) == false)
        streak = SearXNGEnsurer.nextConsecutiveServerErrorCount(current: streak, statusCode: 500, bodyTail: "boom three")
        #expect(streak == 3)
        #expect(SearXNGEnsurer.shouldFailFastOnConsecutiveServerErrors(streak) == true)
    }

    @Test
    func `Success on 2xx or 3xx resets the streak`() {
        // Proven health clears the streak so an old pair of 500s plus a later
        // isolated 500 never poses as three consecutive.
        #expect(SearXNGEnsurer.nextConsecutiveServerErrorCount(current: 2, statusCode: 200, bodyTail: "") == 0)
        #expect(SearXNGEnsurer.nextConsecutiveServerErrorCount(current: 2, statusCode: 302, bodyTail: "") == 0)
        #expect(SearXNGEnsurer.nextConsecutiveServerErrorCount(current: 2, statusCode: 399, bodyTail: "") == 0)
        #expect(SearXNGEnsurer.isReadinessSuccessStatusCode(200) == true)
        #expect(SearXNGEnsurer.isReadinessSuccessStatusCode(302) == true)
        #expect(SearXNGEnsurer.isReadinessSuccessStatusCode(500) == false)
        #expect(SearXNGEnsurer.isReadinessSuccessStatusCode(404) == false)
    }

    @Test
    func `Empty unparseable and non-5xx bodies keep waiting without tripping`() {
        // Gaps (bare, blank, undecodable, or empty 5xx) preserve the streak while
        // a definitive non-5xx answer such as 404 breaks consecutiveness and
        // clears it; neither trips the threshold alone, so the watch keeps
        // waiting instead of failing fast on noise or on an interleaved 404.
        #expect(SearXNGEnsurer.isCountableServerErrorBody("") == false)
        #expect(SearXNGEnsurer.isCountableServerErrorBody("   \n  ") == false)
        #expect(SearXNGEnsurer.isCountableServerErrorBody("boom") == true)
        #expect(SearXNGEnsurer.shouldCountServerError(statusCode: 500, bodyTail: "") == false)
        #expect(SearXNGEnsurer.shouldCountServerError(statusCode: 500, bodyTail: "  ") == false)
        #expect(SearXNGEnsurer.shouldCountServerError(statusCode: 500, bodyTail: "boom") == true)
        #expect(SearXNGEnsurer.shouldCountServerError(statusCode: 404, bodyTail: "boom") == false)
        #expect(SearXNGEnsurer.shouldCountServerError(statusCode: nil, bodyTail: "boom") == false)
        #expect(SearXNGEnsurer.shouldCountServerError(statusCode: 200, bodyTail: "boom") == false)
        #expect(SearXNGEnsurer.nextConsecutiveServerErrorCount(current: 2, statusCode: 500, bodyTail: "") == 2)
        #expect(SearXNGEnsurer.nextConsecutiveServerErrorCount(current: 2, statusCode: 404, bodyTail: "boom") == 0)
        #expect(SearXNGEnsurer.nextConsecutiveServerErrorCount(current: 2, statusCode: nil, bodyTail: "") == 2)
        #expect(SearXNGEnsurer.countableServerErrorBodyTail(from: Data()) == nil)
        #expect(SearXNGEnsurer.countableServerErrorBodyTail(from: Data("   ".utf8)) == nil)
        #expect(SearXNGEnsurer.countableServerErrorBodyTail(from: Data("boom".utf8)) == "boom")
        #expect(SearXNGEnsurer.countableServerErrorBodyTail(from: Data([0xFF, 0xFE, 0x00])) == nil)
    }

    @Test
    func `Sick detail carries the capped body tail without a timeout note`() {
        // The sick headline names the HTTP status plus the body tail so the
        // banner router can tell it from a timeout-only backstop; the timeout
        // note stays exclusive to the stuck path.
        let detail = SearXNGEnsurer.readinessServerErrorDetail(statusCode: 500, bodyTail: "boom failure tail")
        #expect(detail.contains("stage: waiting"))
        #expect(detail.contains("http 500"))
        #expect(detail.contains("boom failure tail"))
        #expect(!detail.lowercased().contains("timed out"))
        #expect(SearXNGEnsurer.serverErrorStatusCode(in: detail) == 500)
    }

    @Test
    func `Crash sick and stuck render distinct banners with one remediation`() {
        // Each cause keeps its own headline: exited names a crash, http 5xx names
        // sickness, and the timeout-only wait names a stuck boot. Raw tails stay
        // in diagnostics while banners carry exactly one hatch command.
        let baseURL = "http://127.0.0.1:8888"
        let crashDetail = SearXNGEnsurer.readinessFailureDetail(
            stateText: "exited",
            logsTail: "exit logs tail",
            timedOut: false,
            exitCode: 1
        )
        let sickDetail = SearXNGEnsurer.readinessServerErrorDetail(statusCode: 503, bodyTail: "sick body tail")
        let stuckDetail = SearXNGEnsurer.readinessFailureDetail(
            stateText: "last state unknown",
            logsTail: "",
            timedOut: true,
            timeoutSeconds: SearXNGEnsurer.readinessWatchTimeoutSeconds
        )
        let crashError = SearXNGEnsurer.unreachableError(baseURL: baseURL, detail: crashDetail)
        let sickError = SearXNGEnsurer.unreachableError(baseURL: baseURL, detail: sickDetail)
        let stuckError = SearXNGEnsurer.unreachableError(baseURL: baseURL, detail: stuckDetail)
        #expect(crashError.localizedDescription == SearXNGEnsurer.readinessCrashBanner())
        #expect(sickError.localizedDescription == SearXNGEnsurer.readinessServerErrorBanner(statusCode: 503))
        #expect(stuckError.localizedDescription == SearXNGEnsurer.readinessBackstopBanner(baseURL: baseURL))
        #expect(crashError.localizedDescription != sickError.localizedDescription)
        #expect(sickError.localizedDescription != stuckError.localizedDescription)
        #expect(crashError.localizedDescription != stuckError.localizedDescription)
        for error in [crashError, sickError, stuckError] {
            #expect(error.localizedDescription.components(separatedBy: "scripts/searxng-up.sh").count - 1 == 1)
            #expect(!error.localizedDescription.contains("stage:"))
        }
        #expect((SearXNGEnsurer.diagnostics(from: sickError) ?? "").contains("sick body tail"))
        #expect((SearXNGEnsurer.diagnostics(from: stuckError) ?? "").contains("timed out after"))
        #expect(!sickError.localizedDescription.lowercased().contains("timed out"))
    }

    @Test
    func `Watch trips sick fast instead of burning to the backstop`() async {
        // A stubbed probe that always answers countable 500s must fail with the
        // sick headline on the threshold trip, carrying the body tail as the
        // last state plus logs instead of a timeout note.
        let outcome = await SearXNGEnsurer.watchReadiness(
            timeoutSeconds: 5,
            pollInterval: 1_000_000,
            isReachable: { false },
            containerState: { SearXNGEnsurer.ContainerReadinessSnapshot(state: .unknown, rawState: "unknown") },
            containerLogs: { "" },
            httpProbe: { SearXNGEnsurer.HTTPProbeSnapshot(statusCode: 500, bodyTail: "sick body tail") }
        )
        #expect(outcome.succeeded == false)
        #expect(outcome.cancelled == false)
        #expect((outcome.failureDetail ?? "").contains("http 500"))
        #expect((outcome.failureDetail ?? "").contains("sick body tail"))
        #expect(!(outcome.failureDetail ?? "").lowercased().contains("timed out"))
        #expect(outcome.lastState == "http 500")
        #expect(outcome.logsTail == "sick body tail")
    }

    @Test
    func `Watch succeeds on healthy probes`() async {
        // An answering engine never pays the sick path: success returns at once
        // with a running hint and no failure detail.
        let outcome = await SearXNGEnsurer.watchReadiness(
            timeoutSeconds: 5,
            pollInterval: 1_000_000,
            isReachable: { false },
            containerState: { SearXNGEnsurer.ContainerReadinessSnapshot(state: .unknown, rawState: "unknown") },
            containerLogs: { "" },
            httpProbe: { SearXNGEnsurer.HTTPProbeSnapshot(statusCode: 200, bodyTail: "") }
        )
        #expect(outcome.succeeded == true)
        #expect(outcome.cancelled == false)
        #expect(outcome.failureDetail == nil)
    }
}
