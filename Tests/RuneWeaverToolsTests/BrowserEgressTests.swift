// Rune Weaver Tools Tests — Browser egress enforcement through the canonical SSRF guard.
//
// Approval-free browsing must not dial loopback, link-local, metadata, or
// private ranges from prompt-injected content. This suite pins that the
// interactive tools vet every entry URL through the single-source guard with
// the configured search, media, and model exemptions before the bridge spawns,
// and that every bridge-reported redirect and landing URL re-vets the same way
// so a public start cannot bounce into sensitive ranges. Public-host proofs use
// public IP literals (no resolver use) so they stay hermetic without touching
// the process-global DNS stub; hostname DNS vetting pins through the pure
// resolved-list verdict instead, keeping parallel suites from publishing and
// clearing canned proof under each other mid-chain.

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
    /// A dotted public address settles in the literal stage, so success proofs
    /// never read the process-global DNS stub and stay immune to parallel
    /// suites publishing and clearing canned proof mid-chain.
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
}
