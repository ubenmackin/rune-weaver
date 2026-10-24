// Rune Weaver Tools Tests — Browser egress enforcement through the canonical SSRF guard.

import Dispatch
import Foundation
import os
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

/// Canned bridge doubles and public-literal proofs for the browser egress suite.
private enum BrowserEgressSupport {
    /// Records whether the bridge was entered, proving denied entries never spawn.
    final class CallFlag: Sendable {
        private let box: OSAllocatedUnfairLock<Bool>

        init() {
            box = OSAllocatedUnfairLock(initialState: false)
        }

        func mark() {
            box.withLock { $0 = true }
        }

        var called: Bool {
            box.withLock { $0 }
        }
    }

    /// Records hostnames that reached the SSRF resolver, in call order.
    /// Guarded so the log stays Sendable and safe to read after the
    /// task-scoped DNS binding clears.
    final class ResolverLog: Sendable {
        private let hosts = OSAllocatedUnfairLock<[String]>(initialState: [])

        /// Records one resolver request.
        /// - Parameter host: Hostname the guard asked the resolver about.
        func record(_ host: String) {
            hosts.withLock { $0.append(host) }
        }

        /// Hostnames the resolver was asked about, in call order.
        var recorded: [String] {
            hosts.withLock { $0 }
        }
    }

    /// Stub gateway returning one canned snapshot without touching the network.
    struct CannedNavigateGateway: BrowserPlaywrightGateway, Sendable {
        let snapshot: BrowserSnapshot
        let navigateFlag: CallFlag
        let actFlag: CallFlag

        func navigate(url _: String, includeScreenshot _: Bool) async throws -> BrowserSnapshot {
            navigateFlag.mark()
            return snapshot
        }

        func navigate(url _: String, includeScreenshot _: Bool, dryRun _: Bool) async throws -> BrowserSnapshot {
            navigateFlag.mark()
            return snapshot
        }

        func act(action: BrowserActAction, ref: String, text _: String?, url: String) async throws -> BrowserActResult {
            actFlag.mark()
            return BrowserActResult(url: url, action: action, ref: ref)
        }
    }

    /// Stub gateway returning one canned act result without touching the network.
    struct CannedActGateway: BrowserPlaywrightGateway, Sendable {
        let result: BrowserActResult
        let navigateFlag: CallFlag
        let actFlag: CallFlag

        func navigate(url: String, includeScreenshot _: Bool) async throws -> BrowserSnapshot {
            navigateFlag.mark()
            return BrowserSnapshot(
                url: url,
                title: "",
                text: "",
                refs: [],
                redirectChain: [BrowserRedirectStep(url: url)]
            )
        }

        func navigate(url: String, includeScreenshot _: Bool, dryRun _: Bool) async throws -> BrowserSnapshot {
            navigateFlag.mark()
            return BrowserSnapshot(
                url: url,
                title: "",
                text: "",
                refs: [],
                redirectChain: [BrowserRedirectStep(url: url)]
            )
        }

        func act(action _: BrowserActAction, ref _: String, text _: String?, url _: String) async throws -> BrowserActResult {
            actFlag.mark()
            return result
        }
    }

    /// Public literal host proving dialable paths without resolver use.
    static let publicLiteralHost = "93.184.216.34"

    /// Public literal start URL for entry-plus-redirect proofs.
    static var publicStartURL: String {
        "https://\(publicLiteralHost)/start"
    }

    /// Public literal landing URL for entry-plus-redirect proofs.
    static var publicLandedURL: String {
        "https://\(publicLiteralHost)/landed"
    }

    /// Public literal page URL for act entry proofs.
    static var publicPageURL: String {
        "https://\(publicLiteralHost)/page"
    }

    /// Browser policy with a public search origin so loopback carries no exemption.
    static func publicSearchConfig() -> BrowserConfig {
        BrowserConfig(searxngURL: "https://example.com")
    }

    /// Canned public snapshot with an honest two-hop chain over literals.
    static func publicSnapshot() -> BrowserSnapshot {
        BrowserSnapshot(
            url: publicLandedURL,
            title: "Example",
            text: "hello",
            refs: [],
            redirectChain: [
                BrowserRedirectStep(url: publicStartURL),
                BrowserRedirectStep(url: publicLandedURL)
            ]
        )
    }

    /// Builds a verified policy store over a throwaway file path.
    static func policyStore(_ policy: SecurityPolicy) async -> PolicyStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rw-browser-policy-\(UUID().uuidString).toml")
        let store = PolicyStore(fileURL: url)
        await store.update(policy)
        return store
    }
}

/// Runs `body` with the debug DNS resolver bound to `resolver` for this test's task and its
/// children.
private func withTaskScopedDNS(
    _ resolver: @escaping @Sendable (String) -> [String],
    _ body: () async throws -> Void
) async throws {
    try await ApiSSRFGuard.$taskTestDNSResolver.withValue(resolver) {
        try await body()
    }
}

/// Blocks until `semaphore` signals without parking the cooperative pool.
private func waitForSignal(_ semaphore: DispatchSemaphore) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            semaphore.wait()
            continuation.resume()
        }
    }
}

@Suite("Browser Egress Enforcement", .serialized)
struct BrowserEgressTests {
    @Test
    func `Navigate denies loopback with the shared refusal shape`() async throws {
        let navigateFlag = BrowserEgressSupport.CallFlag()
        let actFlag = BrowserEgressSupport.CallFlag()
        let gateway = BrowserEgressSupport.CannedNavigateGateway(
            snapshot: BrowserEgressSupport.publicSnapshot(),
            navigateFlag: navigateFlag,
            actFlag: actFlag
        )
        // A public search origin leaves loopback without an exemption, so the
        // entry must fail before the bridge spawns.
        let tool = BrowserNavigateTool(gateway: gateway, browserConfig: BrowserEgressSupport.publicSearchConfig())
        let output = try await tool.execute(
            input: ToolInput(toolName: "browser.navigate", argumentsJSON: #"{"url":"http://localhost/"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError)
        #expect(output.content.contains("Invalid URL:"))
        #expect(output.content.contains("SSRF denied"))
        #expect(navigateFlag.called == false)
    }

    @Test
    func `Navigate denies metadata hosts`() async throws {
        let navigateFlag = BrowserEgressSupport.CallFlag()
        let actFlag = BrowserEgressSupport.CallFlag()
        let gateway = BrowserEgressSupport.CannedNavigateGateway(
            snapshot: BrowserEgressSupport.publicSnapshot(),
            navigateFlag: navigateFlag,
            actFlag: actFlag
        )
        // Metadata denials are literal-only, so they need no resolver.
        let tool = BrowserNavigateTool(gateway: gateway, browserConfig: BrowserEgressSupport.publicSearchConfig())
        let output = try await tool.execute(
            input: ToolInput(toolName: "browser.navigate", argumentsJSON: #"{"url":"http://metadata.google.internal/latest"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError)
        #expect(output.content.contains("Invalid URL:"))
        #expect(output.content.contains("SSRF denied"))
        #expect(navigateFlag.called == false)
    }

    @Test
    func `Navigate denies link-local targets`() async throws {
        let navigateFlag = BrowserEgressSupport.CallFlag()
        let actFlag = BrowserEgressSupport.CallFlag()
        let gateway = BrowserEgressSupport.CannedNavigateGateway(
            snapshot: BrowserEgressSupport.publicSnapshot(),
            navigateFlag: navigateFlag,
            actFlag: actFlag
        )
        // Link-local stays never-allowlisted, so even an explicit homelab
        // pattern cannot launder it through the entry check.
        let tool = BrowserNavigateTool(gateway: gateway, browserConfig: BrowserEgressSupport.publicSearchConfig())
        let output = try await tool.execute(
            input: ToolInput(toolName: "browser.navigate", argumentsJSON: #"{"url":"http://169.254.169.254/latest/meta-data"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError)
        #expect(output.content.contains("Invalid URL:"))
        #expect(output.content.contains("SSRF denied"))
        #expect(navigateFlag.called == false)
    }

    @Test
    func `Configured model origin stays dialable while other loopback denies`() async throws {
        let browser = BrowserEgressSupport.publicSearchConfig()
        let modelURL = "http://127.0.0.1:11434/v1/models"
        let exemptSnapshot = BrowserSnapshot(
            url: modelURL,
            title: "",
            text: "models",
            refs: [],
            redirectChain: [BrowserRedirectStep(url: modelURL)]
        )
        let allowedFlag = BrowserEgressSupport.CallFlag()
        let allowedTool = BrowserNavigateTool(
            gateway: BrowserEgressSupport.CannedNavigateGateway(
                snapshot: exemptSnapshot,
                navigateFlag: allowedFlag,
                actFlag: BrowserEgressSupport.CallFlag()
            ),
            browserConfig: browser,
            llmServerURLs: ["http://127.0.0.1:11434"]
        )
        let allowed = try await allowedTool.execute(
            input: ToolInput(toolName: "browser.navigate", argumentsJSON: #"{"url":"\#(modelURL)"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(!allowed.isError)
        #expect(allowedFlag.called == true)
        // The same literal without the model exemption fails closed, proving
        // the allowance came from the configured origin rather than a broad
        // loopback pass.
        let deniedFlag = BrowserEgressSupport.CallFlag()
        let deniedTool = BrowserNavigateTool(
            gateway: BrowserEgressSupport.CannedNavigateGateway(
                snapshot: exemptSnapshot,
                navigateFlag: deniedFlag,
                actFlag: BrowserEgressSupport.CallFlag()
            ),
            browserConfig: browser
        )
        let denied = try await deniedTool.execute(
            input: ToolInput(toolName: "browser.navigate", argumentsJSON: #"{"url":"http://127.0.0.1:9999/admin"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(denied.isError)
        #expect(denied.content.contains("SSRF denied"))
        #expect(deniedFlag.called == false)
    }

    @Test
    func `Bridge-reported redirect into sensitive range denies`() async throws {
        // The entry is a public literal, but the helper reports a hop into
        // link-local space; the tool must re-vet the chain before encoding.
        let poisoned = BrowserSnapshot(
            url: "http://169.254.169.254/",
            title: "",
            text: "",
            refs: [],
            redirectChain: [
                BrowserRedirectStep(url: BrowserEgressSupport.publicStartURL),
                BrowserRedirectStep(url: "http://169.254.169.254/")
            ]
        )
        let navigateFlag = BrowserEgressSupport.CallFlag()
        let tool = BrowserNavigateTool(
            gateway: BrowserEgressSupport.CannedNavigateGateway(
                snapshot: poisoned,
                navigateFlag: navigateFlag,
                actFlag: BrowserEgressSupport.CallFlag()
            ),
            browserConfig: BrowserEgressSupport.publicSearchConfig()
        )
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "browser.navigate",
                argumentsJSON: #"{"url":"\#(BrowserEgressSupport.publicStartURL)"}"#
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError)
        #expect(output.content.contains("Invalid URL:"))
        #expect(navigateFlag.called == true)
    }

    @Test
    func `Bridge-reported final URL into loopback denies`() async throws {
        // A single-step chain with a loopback landing must fail even though
        // the only chain entry besides the landing is the public literal start.
        let loopbackLanding = BrowserSnapshot(
            url: "http://localhost/",
            title: "",
            text: "",
            refs: [],
            redirectChain: [BrowserRedirectStep(url: BrowserEgressSupport.publicStartURL)]
        )
        let tool = BrowserNavigateTool(
            gateway: BrowserEgressSupport.CannedNavigateGateway(
                snapshot: loopbackLanding,
                navigateFlag: BrowserEgressSupport.CallFlag(),
                actFlag: BrowserEgressSupport.CallFlag()
            ),
            browserConfig: BrowserEgressSupport.publicSearchConfig()
        )
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "browser.navigate",
                argumentsJSON: #"{"url":"\#(BrowserEgressSupport.publicStartURL)"}"#
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError)
        #expect(output.content.contains("SSRF denied"))
    }

    @Test
    func `Unverified hosts fail closed without entering the bridge`() async throws {
        // Empty DNS proof fails closed at the guard without network or global
        // stub; verified public proof dials, so absence never becomes permission.
        let origins = ApiSSRFGuard.allowlistedOrigins(browserConfig: BrowserEgressSupport.publicSearchConfig())
        #expect(
            ApiSSRFGuard.vettedIPListDenial(host: "example.com", addresses: [], origins: origins)
                == ApiSSRFGuard.unverifiedDenial(for: "example.com")
        )
        #expect(
            ApiSSRFGuard.vettedIPListDenial(host: "example.com", addresses: ["93.184.216.34"], origins: origins)
                == nil
        )
        // The tool still delegates denials to the guard before spawning: a
        // literal sensitive entry never enters the bridge.
        let navigateFlag = BrowserEgressSupport.CallFlag()
        let tool = BrowserNavigateTool(
            gateway: BrowserEgressSupport.CannedNavigateGateway(
                snapshot: BrowserEgressSupport.publicSnapshot(),
                navigateFlag: navigateFlag,
                actFlag: BrowserEgressSupport.CallFlag()
            ),
            browserConfig: BrowserEgressSupport.publicSearchConfig()
        )
        let output = try await tool.execute(
            input: ToolInput(toolName: "browser.navigate", argumentsJSON: #"{"url":"http://localhost/"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError)
        #expect(output.content.contains("SSRF denied"))
        #expect(navigateFlag.called == false)
    }

    @Test
    func `Act denies sensitive snapshot URLs before dispatch`() async throws {
        let actFlag = BrowserEgressSupport.CallFlag()
        let tool = BrowserActTool(
            gateway: BrowserEgressSupport.CannedActGateway(
                result: BrowserActResult(url: BrowserEgressSupport.publicLandedURL, action: .click, ref: "e1"),
                navigateFlag: BrowserEgressSupport.CallFlag(),
                actFlag: actFlag
            ),
            browserConfig: BrowserEgressSupport.publicSearchConfig()
        )
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "browser.act",
                argumentsJSON: #"{"action":"click","ref":"e1","url":"http://169.254.169.254/"}"#
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError)
        #expect(output.content.contains("Invalid URL:"))
        #expect(output.content.contains("SSRF denied"))
        #expect(actFlag.called == false)
    }

    @Test
    func `Act denies sensitive post-action landings`() async throws {
        // The snapshot URL is a public literal, but the action lands in metadata space.
        let actFlag = BrowserEgressSupport.CallFlag()
        let tool = BrowserActTool(
            gateway: BrowserEgressSupport.CannedActGateway(
                result: BrowserActResult(url: "http://metadata.google.internal/", action: .click, ref: "e1"),
                navigateFlag: BrowserEgressSupport.CallFlag(),
                actFlag: actFlag
            ),
            browserConfig: BrowserEgressSupport.publicSearchConfig()
        )
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "browser.act",
                argumentsJSON: #"{"action":"click","ref":"e1","url":"\#(BrowserEgressSupport.publicPageURL)"}"#
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError)
        #expect(output.content.contains("SSRF denied"))
        #expect(actFlag.called == true)
    }

    @Test
    func `Public navigation and actions still succeed`() async throws {
        // Public literals settle without resolver use, so entry, redirect
        // re-validation, and act landing all succeed hermetically while prod
        // still fails closed on unverified hostnames.
        let navigateFlag = BrowserEgressSupport.CallFlag()
        let navigateTool = BrowserNavigateTool(
            gateway: BrowserEgressSupport.CannedNavigateGateway(
                snapshot: BrowserEgressSupport.publicSnapshot(),
                navigateFlag: navigateFlag,
                actFlag: BrowserEgressSupport.CallFlag()
            ),
            browserConfig: BrowserEgressSupport.publicSearchConfig()
        )
        let navigateOutput = try await navigateTool.execute(
            input: ToolInput(
                toolName: "browser.navigate",
                argumentsJSON: #"{"url":"\#(BrowserEgressSupport.publicStartURL)"}"#
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(!navigateOutput.isError)
        #expect(navigateFlag.called == true)
        let envelope = try JSONDecoder().decode(
            BrowserNavigateEnvelope.self, from: Data(navigateOutput.content.utf8)
        )
        #expect(envelope.finalUrl == BrowserEgressSupport.publicLandedURL)
        #expect(envelope.redirectCount == 1)

        let actFlag = BrowserEgressSupport.CallFlag()
        let actTool = BrowserActTool(
            gateway: BrowserEgressSupport.CannedActGateway(
                result: BrowserActResult(url: BrowserEgressSupport.publicLandedURL, action: .click, ref: "e1"),
                navigateFlag: BrowserEgressSupport.CallFlag(),
                actFlag: actFlag
            ),
            browserConfig: BrowserEgressSupport.publicSearchConfig()
        )
        let actOutput = try await actTool.execute(
            input: ToolInput(
                toolName: "browser.act",
                argumentsJSON: #"{"action":"click","ref":"e1","url":"\#(BrowserEgressSupport.publicPageURL)"}"#
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(!actOutput.isError)
        #expect(actFlag.called == true)

        // Dry-run previews stay local: validation passes, but no browser
        // context opens and the preview envelope reports the would-act shape.
        let previewFlag = BrowserEgressSupport.CallFlag()
        let previewTool = BrowserActTool(
            gateway: BrowserEgressSupport.CannedActGateway(
                result: BrowserActResult(url: BrowserEgressSupport.publicLandedURL, action: .click, ref: "e1"),
                navigateFlag: BrowserEgressSupport.CallFlag(),
                actFlag: previewFlag
            ),
            browserConfig: BrowserEgressSupport.publicSearchConfig()
        )
        let preview = try await previewTool.execute(
            input: ToolInput(
                toolName: "browser.act",
                argumentsJSON: #"{"action":"click","ref":"e1","url":"\#(BrowserEgressSupport.publicPageURL)"}"#
            ),
            context: ToolContext(conversationID: UUID(), dryRun: true)
        )
        #expect(!preview.isError)
        #expect(previewFlag.called == false)
        let previewEnvelope = try JSONDecoder().decode(
            BrowserActEnvelope.self, from: Data(preview.content.utf8)
        )
        #expect(previewEnvelope.dryRun == true)
    }

    @Test
    func `Gateway denies sensitive entries before spawning`() async throws {
        // Validation precedes any subprocess use, so the dry-run fast path
        // still refuses without provisioning the managed environment.
        let gateway = SubprocessPlaywrightGateway(browserConfig: BrowserEgressSupport.publicSearchConfig())
        do {
            _ = try await gateway.navigate(url: "http://localhost/", includeScreenshot: false, dryRun: true)
            Issue.record("Expected a loopback denial before the bridge spawns")
        } catch let error as BrowserError {
            #expect(error.localizedDescription.contains("SSRF denied"))
        } catch {
            Issue.record("Expected BrowserError, got \(error)")
        }
    }

    @Test
    func `Policy-denied host never reaches the resolver`() async throws {
        // A destination denied by policy.toml must refuse before the SSRF
        // stage resolves any hostname: the supervised path enters the network
        // policy gate first, so a denied host causes no DNS side effect.
        let resolverLog = BrowserEgressSupport.ResolverLog()
        try await withTaskScopedDNS({ host in
            resolverLog.record(host)
            return ["93.184.216.34"]
        }) {
            let store = await BrowserEgressSupport.policyStore(
                SecurityPolicy(
                    network: NetworkEgressPolicy(
                        mode: .allowlistOnly,
                        allowedDomains: ["allowed.example.com"],
                        blockedDomains: ["blocked.example.com"]
                    )
                )
            )
            let supervisor = try await OutboundEgressSupervisor.make(policyStore: store)
            do {
                _ = try await BrowserValidation.validateURLAsync(
                    "https://blocked.example.com/page",
                    browserConfig: BrowserEgressSupport.publicSearchConfig(),
                    egressSupervisor: supervisor
                )
                Issue.record("Expected the policy-denied host to be refused")
            } catch let error as BrowserError {
                #expect(error.localizedDescription.contains("Egress blocked"))
            } catch {
                Issue.record("Expected BrowserError, got \(error)")
            }
            #expect(resolverLog.recorded.isEmpty)
        }
    }

    @Test
    func `Supervised destinations still vet resolved addresses`() async throws {
        // A policy-allowed host still needs resolved-address vetting on the supervised path: the
        // supervisor's SSRF stage judges its own exemption set, so the canonical guard must re-vet
        // the surviving destination and refuse a loopback resolution.
        let store = await BrowserEgressSupport.policyStore(
            SecurityPolicy(network: NetworkEgressPolicy(mode: .unrestricted))
        )
        let supervisor = try await OutboundEgressSupervisor.make(policyStore: store)
        try await withTaskScopedDNS({ _ in ["127.0.0.1"] }) {
            do {
                _ = try await BrowserValidation.validateURLAsync(
                    "https://loopback.example.com/page",
                    browserConfig: BrowserEgressSupport.publicSearchConfig(),
                    egressSupervisor: supervisor
                )
                Issue.record("Expected the loopback resolution to be refused")
            } catch let error as BrowserError {
                #expect(error.localizedDescription.contains("SSRF denied"))
            } catch {
                Issue.record("Expected BrowserError, got \(error)")
            }
        }
    }

    @Test
    func `Tool descriptions disclose the SSRF guard`() {
        let navigate = BrowserNavigateTool(browserConfig: BrowserEgressSupport.publicSearchConfig())
        #expect(navigate.description.contains("SSRF-guarded"))
        #expect(navigate.description.contains("loopback"))
        #expect(navigate.description.contains("link-local"))
        #expect(navigate.description.contains("metadata"))
        let act = BrowserActTool(browserConfig: BrowserEgressSupport.publicSearchConfig())
        #expect(act.description.contains("SSRF-guarded"))
    }

    @Test
    func `Helper re-gates post-action landings`() {
        // The embedded program keeps a single range table and applies it to
        // the entry URL, the navigate landing, and the post-action landing.
        #expect(BrowserPlaywrightScript.source.contains("_ssrf_deny_reason"))
        #expect(BrowserPlaywrightScript.source.contains("landed_after"))
    }

    @Test
    func `BrowserNavigateArgs decodes headed and interactive flags`() throws {
        // Defaults to false when omitted.
        let defaultData = try JSONDecoder().decode(
            BrowserNavigateArgs.self,
            from: Data(#"{"url":"https://example.com"}"#.utf8)
        )
        #expect(defaultData.headed == false)

        // Decodes explicit headed flag.
        let headedData = try JSONDecoder().decode(
            BrowserNavigateArgs.self,
            from: Data(#"{"url":"https://example.com","headed":true}"#.utf8)
        )
        #expect(headedData.headed == true)

        // Decodes interactive alias.
        let interactiveData = try JSONDecoder().decode(
            BrowserNavigateArgs.self,
            from: Data(#"{"url":"https://example.com","interactive":true}"#.utf8)
        )
        #expect(interactiveData.headed == true)

        // Decodes false explicitly.
        let falseData = try JSONDecoder().decode(
            BrowserNavigateArgs.self,
            from: Data(#"{"url":"https://example.com","headed":false}"#.utf8)
        )
        #expect(falseData.headed == false)
    }

    @Test
    func `Embedded helper uses persistent context and headed support`() {
        #expect(BrowserPlaywrightScript.source.contains("launch_persistent_context"))
        #expect(BrowserPlaywrightScript.source.contains("browser_profiles"))
        #expect(BrowserPlaywrightScript.source.contains("is_headed"))
        #expect(SubprocessPlaywrightGateway.headedProcessTimeoutSeconds == 180.0)
        // The headed wait cap stays strictly below the kill budget so the timeout path still reaches
        // `finally: context.close()`; the kill budget covers the navigation budget plus the wait cap
        // plus headroom so a slow `goto` is never killed mid-navigation before cleanup.
        let headedKill = SubprocessPlaywrightGateway.headedProcessTimeoutSeconds
        let headedWait = SubprocessPlaywrightGateway.headedWaitSeconds
        let headroom = SubprocessPlaywrightGateway.headedCleanupHeadroomSeconds
        #expect(headedWait < headedKill)
        #expect(headedWait == headedKill - headroom)
        let waitBudget = "max_wait = \(headedWait)"
        #expect(BrowserPlaywrightScript.source.contains(waitBudget))
        #expect(!BrowserPlaywrightScript.source.contains("max_wait = \(headedKill)"))
        #expect(SubprocessPlaywrightGateway.headedEffectiveTimeout(for: 30) > 30 + headedWait)
        // The `finally` close releases Chromium's SingletonLock, so the next
        // serialized run can reopen the persistent profile; losing this line
        // would leave the profile locked after an early return or failure.
        #expect(BrowserPlaywrightScript.source.contains("finally:"))
        #expect(BrowserPlaywrightScript.source.contains("context.close()"))
        #expect(BrowserPlaywrightScript.source.contains("storage_state.json"))
        #expect(BrowserPlaywrightScript.source.contains("save_storage_state"))
        #expect(BrowserPlaywrightScript.source.contains("restore_storage_state"))
        #expect(BrowserPlaywrightScript.source.contains("ctx.add_cookies(cookies)"))
        #expect(BrowserPlaywrightScript.source.contains("--disable-blink-features=AutomationControlled"))
        #expect(BrowserPlaywrightScript.source.contains("host_and_path = ((parsed_url.hostname or \"\") + (parsed_url.path or \"\")).lower()"))
        #expect(BrowserPlaywrightScript.source.contains("/errors/validateCaptcha"))
    }

    @Test
    func `Configured timeout reaches navigation and action payloads`() {
        // `browser.timeout_seconds` must govern in-page timeouts, not only the
        // subprocess kill budget, or the Settings copy lies to the operator.
        let navigate = BrowserSubprocessIO.navigatePayload(
            url: BrowserEgressSupport.publicStartURL,
            includeScreenshot: false,
            headed: false,
            timeoutSeconds: 120
        )
        #expect(navigate["op"] as? String == "navigate")
        #expect(navigate["timeoutMs"] as? Int == 120_000)
        let headed = BrowserSubprocessIO.navigatePayload(
            url: BrowserEgressSupport.publicStartURL,
            includeScreenshot: true,
            headed: true,
            timeoutSeconds: 45
        )
        #expect(headed["includeScreenshot"] as? Bool == true)
        #expect(headed["headed"] as? Bool == true)
        #expect(headed["timeoutMs"] as? Int == 45000)
        let act = BrowserSubprocessIO.actPayload(
            url: BrowserEgressSupport.publicPageURL,
            action: "click",
            ref: "e1",
            text: nil,
            timeoutSeconds: 90
        )
        #expect(act["op"] as? String == "act")
        #expect(act["ref"] as? String == "e1")
        #expect(act["timeoutMs"] as? Int == 90000)
        // The helper consumes the plumbed budget and keeps its legacy literals
        // only as the fallback for callers that reach the bridge directly.
        #expect(BrowserPlaywrightScript.source.contains("_request_timeout_ms"))
        #expect(BrowserPlaywrightScript.source.contains("timeout=timeout_ms"))
        #expect(BrowserPlaywrightScript.source.contains("timeout=action_timeout_ms"))
        #expect(!BrowserPlaywrightScript.source.contains("timeout=30000"))
        #expect(!BrowserPlaywrightScript.source.contains("timeout=10000"))
    }

    @Test
    func `Concurrent bridge runs serialize on the profile queue`() async throws {
        // A persistent profile admits one Chromium process at a time, so overlapping helpers would
        // collide on its SingletonLock and fail a legitimate call; the serial queue must keep runs
        // from overlapping even when two callers fire together.
        let events = OSAllocatedUnfairLock<[String]>(initialState: [])
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        async let first: Void = BrowserSubprocessIO.runSerialized {
            events.withLock { $0.append("first-start") }
            entered.signal()
            release.wait()
            events.withLock { $0.append("first-end") }
        }
        await waitForSignal(entered)
        async let second: Void = BrowserSubprocessIO.runSerialized {
            events.withLock { $0.append("second-start") }
            events.withLock { $0.append("second-end") }
        }
        release.signal()
        try await first
        try await second
        let recorded = events.withLock { $0 }
        #expect(recorded == ["first-start", "first-end", "second-start", "second-end"])
    }

    @Test
    func `validateActText accepts scroll directions and distances`() throws {
        #expect(try BrowserValidation.validateActText(action: .scroll, text: nil) == nil)
        #expect(try BrowserValidation.validateActText(action: .scroll, text: "   ") == nil)
        #expect(try BrowserValidation.validateActText(action: .scroll, text: "down") == "down")
        #expect(try BrowserValidation.validateActText(action: .scroll, text: "up") == "up")
        #expect(try BrowserValidation.validateActText(action: .scroll, text: "top") == "top")
        #expect(try BrowserValidation.validateActText(action: .scroll, text: "bottom") == "bottom")
        #expect(try BrowserValidation.validateActText(action: .scroll, text: "500") == "500")
        #expect(try BrowserValidation.validateActText(action: .scroll, text: "-250") == "-250")
        #expect(throws: BrowserError.self) {
            try BrowserValidation.validateActText(action: .scroll, text: "down\0line")
        }
        #expect(throws: BrowserError.self) {
            try BrowserValidation.validateActText(action: .click, text: "unexpected")
        }
    }

    @Test
    func `parseActPayload decodes post-action title, bounded text, and refs`() throws {
        let json = """
        {
            "ok": true,
            "url": "https://www.amazon.com/cart",
            "action": "click",
            "ref": "e12",
            "title": "Amazon.com Shopping Cart",
            "text": "Added to Cart. 1 item in cart.",
            "refs": [
                {"ref": "e1", "role": "button", "name": "Proceed to checkout"},
                {"ref": "invalid_ref", "role": "link", "name": "bad"}
            ],
            "downloads": []
        }
        """
        let data = Data(json.utf8)
        let result = try BrowserBridgeParsing.parseActPayload(
            data,
            action: .click,
            ref: "e12",
            fallbackURL: "https://www.amazon.com/cart"
        )
        #expect(result.url == "https://www.amazon.com/cart")
        #expect(result.action == .click)
        #expect(result.ref == "e12")
        #expect(result.title == "Amazon.com Shopping Cart")
        #expect(result.text == "Added to Cart. 1 item in cart.")
        #expect(result.refs?.count == 1)
        #expect(result.refs?.first?.ref == "e1")
        #expect(result.refs?.first?.name == "Proceed to checkout")
    }

    @Test
    func `BrowserPlaywrightScript includes key mapping and interactive selector excluding hidden inputs`() {
        #expect(BrowserPlaywrightScript.source.contains("input:not([type=\"hidden\"])"))
        #expect(BrowserPlaywrightScript.source.contains("\"return\": \"Enter\""))
        #expect(BrowserPlaywrightScript.source.contains("scroll_into_view_if_needed"))
        #expect(BrowserPlaywrightScript.source.contains("force=True"))
    }
}
