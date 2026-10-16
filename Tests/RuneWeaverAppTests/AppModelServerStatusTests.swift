// Rune Weaver App Tests — AppModel server status shape for the menu bar.

import Foundation
@testable import RuneWeaverApp
import Testing

@Suite("AppModel server status")
@MainActor
struct AppModelServerStatusTests {
    @Test
    func `failed set raises flag with fixed title and preserved short detail`() {
        let model = AppModel()
        // Short refusal hint fits the one-line budget, so the stored detail
        // must round-trip unchanged instead of gaining an ellipsis.
        let detail = "Bind 127.0.0.1 refused — no owner token"
        model.setServerFailed(detail: detail)

        // The flag alone selects the Failed affordance; the title stays fixed
        // so width never depends on the underlying error text.
        #expect(model.isServerFailed == true)
        #expect(model.serverStatus == "Server failed")
        #expect(model.serverStatusDetail == detail)
        #expect(model.serverStatus.count <= 40)
        #expect((model.serverStatusDetail?.count ?? 0) <= 140)
    }

    @Test
    func `overlong detail truncates to 140 with ellipsis prefix`() {
        let model = AppModel()
        // Filler plus an actionable tail: truncation must keep the tail where
        // the recovery hint sits and mark the cut with a leading ellipsis.
        let tail = "check Keychain plus file permissions"
        let long = String(repeating: "x", count: 200) + tail
        model.setServerFailed(detail: long)

        #expect(model.isServerFailed == true)
        #expect(model.serverStatus == "Server failed")
        #expect(model.serverStatusDetail?.count == 140)
        #expect(model.serverStatusDetail?.hasPrefix("…") == true)
        // Trailing hint survives because the helper keeps the suffix, which
        // is what the owner needs to act without opening the log.
        #expect(model.serverStatusDetail?.hasSuffix(tail) == true)
        #expect(model.serverStatus.count <= 40)
        #expect((model.serverStatusDetail?.count ?? 0) <= 140)
    }

    @Test
    func `starting clears a prior failure`() {
        let model = AppModel()
        // Seed a stale refusal first so the test proves a retry never renders
        // the previous failure beside fresh progress.
        model.setServerFailed(detail: "Bind 127.0.0.1 refused — no owner token")
        model.setServerStarting()

        // Healthy transitions always drop both the flag and the summary, so
        // no failure text can linger past recovery.
        #expect(model.isServerFailed == false)
        #expect(model.serverStatusDetail == nil)
        #expect(model.serverStatus == "Starting…")
        #expect(model.serverStatus.count <= 40)
        #expect((model.serverStatusDetail?.count ?? 0) <= 140)
    }

    @Test
    func `running with auth maps to plain Running title`() {
        let model = AppModel()
        model.setServerRunning(host: "127.0.0.1", port: 8080, authConfigured: true)

        // A provisioned bind names the endpoint with no local-only cue, so
        // the owner never mistakes it for a limited boot.
        #expect(model.isServerFailed == false)
        #expect(model.serverStatusDetail == nil)
        #expect(model.serverStatus == "Running on 127.0.0.1:8080")
        #expect(model.serverStatus.hasPrefix("Running") == true)
        #expect(model.serverStatus.contains("local only") == false)
        #expect(model.serverStatus.count <= 40)
        #expect((model.serverStatusDetail?.count ?? 0) <= 140)
    }

    @Test
    func `running without auth maps to local-only title`() {
        let model = AppModel()
        model.setServerRunning(host: "127.0.0.1", port: 8080, authConfigured: false)

        // A healthy loopback boot without a token stays usable for local work
        // but must name the posture, so LAN refusal is never a surprise.
        #expect(model.isServerFailed == false)
        #expect(model.serverStatusDetail == nil)
        #expect(model.serverStatus == "Running on 127.0.0.1:8080 — local only")
        #expect(model.serverStatus.contains("local only") == true)
        #expect(model.serverStatus.count <= 40)
        #expect((model.serverStatusDetail?.count ?? 0) <= 140)
    }
}
