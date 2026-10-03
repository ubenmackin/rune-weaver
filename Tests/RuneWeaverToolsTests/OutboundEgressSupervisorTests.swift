// Rune Weaver Tools Tests — Outbound Egress Supervisor and adversarial exfiltration.
//
// Pins the contract that the egress supervisor enforces the full security
// pipeline: domain allowlist, SSRF guard, target-bound credential verification,
// and response sweeping. Includes adversarial prompt-injection simulations.
// Every test binds the canned DNS proof to its own task rather than the
// process-global holder, so parallel suites can neither replace nor observe
// this suite's stub.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

/// Stub transport returning one canned body so a sweep assertion can echo a
/// live secret without dialing the network.
private struct CannedApiTransport: ApiRequestTransport, Sendable {
    /// Body bytes returned with a 200 JSON response.
    let body: String

    /// Answers every request with the canned body.
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let fallback = request.url ?? URL(fileURLWithPath: "/")
        let response = HTTPURLResponse(
            url: fallback,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ) ?? HTTPURLResponse(url: fallback, mimeType: "application/json", expectedContentLength: 0, textEncodingName: nil)
        return (Data(body.utf8), response)
    }
}

@Suite("OutboundEgressSupervisor")
struct OutboundEgressSupervisorTests {
    /// Builds a supervisor over a throwaway verified policy store and runs
    /// `body` with this test's canned DNS proof bound to its task.
    ///
    /// The resolver binds through `ApiSSRFGuard.$taskTestDNSResolver` rather
    /// than the process-global holder: suites run in parallel and share that
    /// holder, so publishing here could redirect another suite's lookups while
    /// a concurrent clear could drop this suite's proof mid-test.
    /// - Parameters:
    ///   - policy: Verified policy the supervisor enforces.
    ///   - secrets: Credential backing for injection tests; an empty in-memory
    ///     manager when nil.
    ///   - dnsProof: Host-to-addresses proof this test binds; the default
    ///     answers every host with one public address, while exemption tests
    ///     answer their homelab host with a private or link-local address.
    ///   - body: Test body receiving the built supervisor.
    private func withTestSupervisor(
        policy: SecurityPolicy,
        secrets: SecretsManager? = nil,
        dnsProof: @escaping @Sendable (String) -> [String] = { _ in ["93.184.216.34"] },
        _ body: (OutboundEgressSupervisor) async throws -> Void
    ) async throws {
        try await ApiSSRFGuard.$taskTestDNSResolver.withValue(dnsProof) {
            let store = PolicyStore(fileURL: URL(fileURLWithPath: "/tmp/test-egress-\(UUID().uuidString).toml"))
            await store.update(policy)
            let supervisor = OutboundEgressSupervisor(
                policyStore: store,
                secrets: secrets ?? SecretsManager(inMemory: true),
                browserConfig: BrowserConfig()
            )
            try await body(supervisor)
        }
    }

    // MARK: - Network Policy Gate

    @Test
    func `Allows request to listed domain`() async throws {
        let policy = SecurityPolicy(
            network: NetworkEgressPolicy(
                mode: .allowlistOnly,
                allowedDomains: ["api.github.com"]
            )
        )
        try await withTestSupervisor(policy: policy) { supervisor in
            let url = try #require(URL(string: "https://api.github.com/repos"))
            let result = await supervisor.validate(url: url, method: "GET", headers: [:])
            switch result {
            case .allowed: break // expected
            case let .denied(reason), let .unlistedDomain(_, reason): Issue.record("Expected success, got: \(reason)")
            }
        }
    }

    @Test
    func `Denies request to unlisted domain`() async throws {
        let policy = SecurityPolicy(
            network: NetworkEgressPolicy(
                mode: .allowlistOnly,
                allowedDomains: ["api.github.com"]
            )
        )
        try await withTestSupervisor(policy: policy) { supervisor in
            let url = try #require(URL(string: "https://evil.com/steal"))
            let result = await supervisor.validate(url: url, method: "GET", headers: [:])
            switch result {
            case .allowed: Issue.record("Expected failure for unlisted domain")
            case let .denied(reason), let .unlistedDomain(_, reason): #expect(reason.contains("not in the allowed domains"))
            }
        }
    }

    @Test
    func `Denies request to blocked domain even in unrestricted mode`() async throws {
        let policy = SecurityPolicy(
            network: NetworkEgressPolicy(
                mode: .unrestricted,
                blockedDomains: ["evil.com"]
            )
        )
        try await withTestSupervisor(policy: policy) { supervisor in
            let url = try #require(URL(string: "https://evil.com/steal"))
            let result = await supervisor.validate(url: url, method: "GET", headers: [:])
            switch result {
            case .allowed: Issue.record("Expected failure for blocked domain")
            case let .denied(reason), let .unlistedDomain(_, reason): #expect(reason.contains("blocked"))
            }
        }
    }

    @Test
    func `Trailing-dot blocked host cannot evade the network policy gate`() async throws {
        // Regression: `https://evil.com./collect` used to reach the dial in
        // unrestricted mode because the raw host kept its root dot.
        let policy = SecurityPolicy(
            network: NetworkEgressPolicy(
                mode: .unrestricted,
                blockedDomains: ["evil.com"]
            )
        )
        try await withTestSupervisor(policy: policy) { supervisor in
            let url = try #require(URL(string: "https://evil.com./collect"))
            let result = await supervisor.validate(url: url, method: "GET", headers: [:])
            switch result {
            case .allowed: Issue.record("Expected failure for trailing-dot blocked host")
            case let .denied(reason), let .unlistedDomain(_, reason): #expect(reason.contains("blocked"))
            }
        }
    }

    @Test
    func `Trailing-dot allowed host still passes the network policy gate`() async throws {
        let policy = SecurityPolicy(
            network: NetworkEgressPolicy(
                mode: .allowlistOnly,
                allowedDomains: ["api.github.com"]
            )
        )
        try await withTestSupervisor(policy: policy) { supervisor in
            let url = try #require(URL(string: "https://api.github.com./repos"))
            let result = await supervisor.validate(url: url, method: "GET", headers: [:])
            switch result {
            case .allowed: break // expected
            case let .denied(reason), let .unlistedDomain(_, reason): Issue.record("Expected success, got: \(reason)")
            }
        }
    }

    // MARK: - Credential Target-Binding

    @Test
    func `Credential binding allows authorized destination`() async throws {
        let policy = SecurityPolicy(
            network: NetworkEgressPolicy(
                mode: .allowlistOnly,
                allowedDomains: ["api.github.com"]
            ),
            credentials: [
                "GITHUB_PAT": CredentialBinding(
                    allowedHosts: ["api.github.com"],
                    allowedMethods: ["GET"]
                )
            ]
        )
        try await withTestSupervisor(policy: policy) { supervisor in
            let url = try #require(URL(string: "https://api.github.com/repos"))
            let result = await supervisor.validate(
                url: url,
                method: "GET",
                headers: ["Authorization": "Bearer rwsecret:GITHUB_PAT"]
            )
            switch result {
            case .allowed: break // expected — binding authorized
            case let .denied(reason), let .unlistedDomain(_, reason):
                // May fail due to missing secret in test environment, but NOT due to binding
                #expect(!reason.contains("Security Policy Violation"))
            }
        }
    }

    @Test
    func `Credential wildcard binding authorizes subdomain`() async throws {
        // Regression: `*.` bindings verified but could never match, leaving
        // the credential silently unusable.
        let policy = SecurityPolicy(
            network: NetworkEgressPolicy(mode: .unrestricted),
            credentials: [
                "API_KEY": CredentialBinding(
                    allowedHosts: ["*.example.com"],
                    allowedMethods: ["GET"]
                )
            ]
        )
        try await withTestSupervisor(policy: policy) { supervisor in
            let url = try #require(URL(string: "https://api.example.com/data"))
            let result = await supervisor.validate(
                url: url,
                method: "GET",
                headers: ["Authorization": "Bearer rwsecret:API_KEY"]
            )
            switch result {
            case .allowed: break // expected — binding authorized
            case let .denied(reason), let .unlistedDomain(_, reason):
                // May fail resolving the missing test secret, but never the binding.
                #expect(!reason.contains("Security Policy Violation"))
            }
        }
    }

    @Test
    func `Credential wildcard binding denies lookalike host`() async throws {
        let policy = SecurityPolicy(
            network: NetworkEgressPolicy(mode: .unrestricted),
            credentials: [
                "API_KEY": CredentialBinding(
                    allowedHosts: ["*.example.com"],
                    allowedMethods: ["GET"]
                )
            ]
        )
        try await withTestSupervisor(policy: policy) { supervisor in
            let url = try #require(URL(string: "https://evil-example.com/steal"))
            let result = await supervisor.validate(
                url: url,
                method: "GET",
                headers: ["Authorization": "Bearer rwsecret:API_KEY"]
            )
            switch result {
            case .allowed: Issue.record("Expected failure — lookalike host not authorized")
            case let .denied(reason), let .unlistedDomain(_, reason):
                #expect(reason.contains("Security Policy Violation"))
                #expect(reason.contains("not authorized for host"))
            }
        }
    }

    @Test
    func `Credential binding denies unauthorized host`() async throws {
        let policy = SecurityPolicy(
            network: NetworkEgressPolicy(
                mode: .unrestricted
            ),
            credentials: [
                "OPENAI_KEY": CredentialBinding(
                    allowedHosts: ["api.openai.com"],
                    allowedMethods: ["POST"]
                )
            ]
        )
        try await withTestSupervisor(policy: policy) { supervisor in
            let url = try #require(URL(string: "https://evil-collector.io/steal"))
            let result = await supervisor.validate(
                url: url,
                method: "POST",
                headers: ["Authorization": "Bearer rwsecret:OPENAI_KEY"]
            )
            switch result {
            case .allowed: Issue.record("Expected failure — credential sent to unauthorized host")
            case let .denied(reason), let .unlistedDomain(_, reason):
                #expect(reason.contains("Security Policy Violation"))
                #expect(reason.contains("not authorized for host"))
            }
        }
    }

    @Test
    func `Credential with no binding in policy is rejected`() async throws {
        let policy = SecurityPolicy(
            network: NetworkEgressPolicy(mode: .unrestricted),
            credentials: [:] // no bindings at all
        )
        try await withTestSupervisor(policy: policy) { supervisor in
            let url = try #require(URL(string: "https://api.github.com/repos"))
            let result = await supervisor.validate(
                url: url,
                method: "GET",
                headers: ["Authorization": "Bearer rwsecret:UNKNOWN_KEY"]
            )
            switch result {
            case .allowed: Issue.record("Expected failure — no binding for UNKNOWN_KEY")
            case let .denied(reason), let .unlistedDomain(_, reason):
                #expect(reason.contains("Security Policy Violation"))
                #expect(reason.contains("no binding"))
            }
        }
    }

    // MARK: - Path Prefix Traversal (Adversarial Regression)

    @Test
    func `Credential binding denies dot-segment traversal out of the authorized prefix`() async throws {
        let policy = SecurityPolicy(
            network: NetworkEgressPolicy(mode: .unrestricted),
            credentials: [
                "PATH_KEY": CredentialBinding(
                    allowedHosts: ["api.example.com"],
                    allowedMethods: ["GET"],
                    allowedPathPrefixes: ["/v1/"]
                )
            ]
        )
        try await withTestSupervisor(policy: policy) { supervisor in
            let url = try #require(URL(string: "https://api.example.com/v1/../admin/steal"))
            let result = await supervisor.validate(
                url: url,
                method: "GET",
                headers: ["Authorization": "Bearer rwsecret:PATH_KEY"]
            )
            switch result {
            case .allowed:
                Issue.record("CRITICAL: a dot-segment traversal satisfied the credential path-prefix binding")
            case let .denied(reason), let .unlistedDomain(_, reason):
                #expect(reason.contains("Security Policy Violation"))
                #expect(reason.contains("not authorized for path"))
            }
        }
    }

    @Test
    func `Credential binding denies encoded traversal spellings`() async throws {
        let policy = SecurityPolicy(
            network: NetworkEgressPolicy(mode: .unrestricted),
            credentials: [
                "PATH_KEY": CredentialBinding(
                    allowedHosts: ["api.example.com"],
                    allowedMethods: ["GET"],
                    allowedPathPrefixes: ["/v1/"]
                )
            ]
        )
        try await withTestSupervisor(policy: policy) { supervisor in
            let spellings = ["/v1/%2e%2e/admin/steal", "/v1%2f..%2fadmin/steal", "/v1%5c..%5cadmin/steal"]
            for spelling in spellings {
                let url = try #require(URL(string: "https://api.example.com\(spelling)"))
                let result = await supervisor.validate(
                    url: url,
                    method: "GET",
                    headers: ["Authorization": "Bearer rwsecret:PATH_KEY"]
                )
                switch result {
                case .allowed:
                    Issue.record("CRITICAL: '\(spelling)' satisfied the credential path-prefix binding")
                case let .denied(reason), let .unlistedDomain(_, reason):
                    #expect(reason.contains("Security Policy Violation"), "unexpected reason for '\(spelling)': \(reason)")
                }
            }
        }
    }

    @Test
    func `Credential binding still allows traversal-free prefix paths and injects`() async throws {
        let secrets = SecretsManager(inMemory: true)
        try await secrets.store(key: "PATH_KEY", secret: "live-path-secret")
        let policy = SecurityPolicy(
            network: NetworkEgressPolicy(mode: .unrestricted),
            credentials: [
                "PATH_KEY": CredentialBinding(
                    allowedHosts: ["api.example.com"],
                    allowedMethods: ["GET"],
                    allowedPathPrefixes: ["/v1/"]
                )
            ]
        )
        try await withTestSupervisor(policy: policy, secrets: secrets) { supervisor in
            // Ordinary percent-encoding (a space here) is not a traversal
            // spelling, so the authorized prefix still injects.
            for spelling in ["/v1/models", "/v1/a%20b"] {
                let url = try #require(URL(string: "https://api.example.com\(spelling)"))
                let result = await supervisor.validate(
                    url: url,
                    method: "GET",
                    headers: ["Authorization": "Bearer rwsecret:PATH_KEY"]
                )
                switch result {
                case let .allowed(outcome):
                    #expect(outcome.resolvedHeaders["Authorization"] == "Bearer live-path-secret")
                case let .denied(reason), let .unlistedDomain(_, reason):
                    Issue.record("Expected an authorized prefix path for '\(spelling)', got: \(reason)")
                }
            }
        }
    }

    @Test
    func `Ambiguous traversal spellings refuse even without a credential claim`() async throws {
        // The destination itself is ambiguous, so the gate refuses it rather
        // than dialing a path whose routed resource depends on the decoder.
        // The double-encoded spelling stays refused even when URL parsing
        // decodes one layer, because the resolver checks every layer.
        let policy = SecurityPolicy(network: NetworkEgressPolicy(mode: .unrestricted))
        try await withTestSupervisor(policy: policy) { supervisor in
            let url = try #require(URL(string: "https://api.example.com/v1/%252e%252e/admin"))
            let result = await supervisor.validate(url: url, method: "GET", headers: [:])
            switch result {
            case .allowed:
                Issue.record("CRITICAL: an ambiguous traversal path reached the transport")
            case let .denied(reason), let .unlistedDomain(_, reason):
                #expect(reason.contains("Security Policy Violation"))
            }
        }
    }

    // MARK: - Adversarial Prompt Injection Simulation

    @Test
    func `Prompt injection exfiltration attempt is blocked`() async throws {
        // Scenario: A malicious webpage instructs the agent to send the
        // OpenAI API key to an attacker's endpoint.
        let policy = SecurityPolicy(
            network: NetworkEgressPolicy(
                mode: .allowlistOnly,
                allowedDomains: ["api.openai.com"]
            ),
            credentials: [
                "OPENAI_API_KEY": CredentialBinding(
                    allowedHosts: ["api.openai.com"],
                    allowedMethods: ["POST"],
                    allowedPathPrefixes: ["/v1/"]
                )
            ]
        )
        try await withTestSupervisor(policy: policy) { supervisor in
            // The injected instruction tries to send the key to attacker.com
            let attackerURL = try #require(URL(string: "https://attacker.com/collect"))
            let result = await supervisor.validate(
                url: attackerURL,
                method: "POST",
                headers: ["Authorization": "Bearer rwsecret:OPENAI_API_KEY"]
            )
            switch result {
            case .allowed: Issue.record("CRITICAL: Prompt injection exfiltration was NOT blocked!")
            case let .denied(reason), let .unlistedDomain(_, reason):
                // Must fail on domain allowlist BEFORE reaching credential binding
                #expect(reason.contains("not in the allowed domains") || reason.contains("Security Policy Violation"))
            }
        }
    }

    @Test
    func `Credential redirect exfiltration to unauthorized host is blocked`() async throws {
        // Scenario: Agent calls a legitimate API that redirects to a malicious host.
        // The supervisor should prevent credentials from being sent to the redirect target.
        let policy = SecurityPolicy(
            network: NetworkEgressPolicy(
                mode: .allowlistOnly,
                allowedDomains: ["api.github.com", "evil-redirect.com"]
            ),
            credentials: [
                "GITHUB_PAT": CredentialBinding(
                    allowedHosts: ["api.github.com"],
                    allowedMethods: ["GET"]
                )
            ]
        )
        try await withTestSupervisor(policy: policy) { supervisor in
            // The redirect target is allowed by network policy but NOT by credential binding
            let redirectURL = try #require(URL(string: "https://evil-redirect.com/collect"))
            let result = await supervisor.validate(
                url: redirectURL,
                method: "GET",
                headers: ["Authorization": "Bearer rwsecret:GITHUB_PAT"]
            )
            switch result {
            case .allowed: Issue.record("CRITICAL: Credential reached unauthorized redirect target!")
            case let .denied(reason), let .unlistedDomain(_, reason):
                #expect(reason.contains("Security Policy Violation"))
                #expect(reason.contains("not authorized for host"))
            }
        }
    }

    @Test
    func `Multiple surrogates in headers all validated`() async throws {
        let policy = SecurityPolicy(
            network: NetworkEgressPolicy(mode: .unrestricted),
            credentials: [
                "KEY_A": CredentialBinding(allowedHosts: ["api.example.com"]),
                "KEY_B": CredentialBinding(allowedHosts: ["other.example.com"])
            ]
        )
        try await withTestSupervisor(policy: policy) { supervisor in
            // KEY_A is authorized for api.example.com, but KEY_B is not
            let url = try #require(URL(string: "https://api.example.com/data"))
            let result = await supervisor.validate(
                url: url,
                method: "GET",
                headers: [
                    "Authorization": "Bearer rwsecret:KEY_A",
                    "X-Custom-Auth": "rwsecret:KEY_B"
                ]
            )
            switch result {
            case .allowed: Issue.record("Expected failure — KEY_B not authorized for api.example.com")
            case let .denied(reason), let .unlistedDomain(_, reason):
                #expect(reason.contains("KEY_B"))
                #expect(reason.contains("not authorized"))
            }
        }
    }

    // MARK: - Read-Only Validation

    @Test
    func `Read-only validation allows listed domain`() async throws {
        let policy = SecurityPolicy(
            network: NetworkEgressPolicy(
                mode: .allowlistOnly,
                allowedDomains: ["example.com"]
            )
        )
        try await withTestSupervisor(policy: policy) { supervisor in
            let url = try #require(URL(string: "https://example.com/page"))
            let result = await supervisor.validateReadOnly(url: url)
            #expect(result == nil)
        }
    }

    @Test
    func `Read-only validation denies unlisted domain`() async throws {
        let policy = SecurityPolicy(
            network: NetworkEgressPolicy(
                mode: .allowlistOnly,
                allowedDomains: ["example.com"]
            )
        )
        try await withTestSupervisor(policy: policy) { supervisor in
            let url = try #require(URL(string: "https://evil.com/page"))
            let result = await supervisor.validateReadOnly(url: url)
            #expect(result != nil)
        }
    }

    // MARK: - Effective SSRF Exemptions (Policy Local Exemptions)

    @Test
    func `Private-resolving host is denied without a local exemption`() async throws {
        let policy = SecurityPolicy(
            network: NetworkEgressPolicy(mode: .unrestricted, blockedDomains: [])
        )
        try await withTestSupervisor(policy: policy, dnsProof: { _ in ["192.168.1.50"] }) { supervisor in
            let url = try #require(URL(string: "https://nas.homelab.internal/status"))
            let result = await supervisor.validate(url: url, method: "GET", headers: [:])
            switch result {
            case .allowed: Issue.record("Expected SSRF denial for a private-resolving host without an exemption")
            case let .denied(reason), let .unlistedDomain(_, reason):
                #expect(reason.contains("resolves to blocked address"))
            }
            let readOnly = await supervisor.validateReadOnly(url: url)
            #expect(readOnly?.contains("resolves to blocked address") == true)
        }
    }

    @Test
    func `Private-resolving host dials under a policy local exemption`() async throws {
        let policy = SecurityPolicy(
            network: NetworkEgressPolicy(
                mode: .unrestricted,
                localExemptions: ["nas.homelab.internal"]
            )
        )
        try await withTestSupervisor(policy: policy, dnsProof: { _ in ["192.168.1.50"] }) { supervisor in
            let url = try #require(URL(string: "https://nas.homelab.internal/status"))
            let result = await supervisor.validate(url: url, method: "GET", headers: [:])
            switch result {
            case let .allowed(outcome):
                #expect(outcome.dialPin.host == "nas.homelab.internal")
                #expect(outcome.dialPin.addresses == ["192.168.1.50"])
                #expect(outcome.dialPin.isSecure)
            case let .denied(reason), let .unlistedDomain(_, reason):
                Issue.record("Expected the local exemption to allow the private-resolving host, got: \(reason)")
            }
            let readOnly = await supervisor.validateReadOnly(url: url)
            #expect(readOnly == nil)
        }
    }

    @Test
    func `Metadata and link-local stay denied even under a policy local exemption`() async throws {
        let policy = SecurityPolicy(
            network: NetworkEgressPolicy(
                mode: .unrestricted,
                blockedDomains: [],
                localExemptions: ["nas.homelab.internal"]
            )
        )
        try await withTestSupervisor(policy: policy, dnsProof: { _ in ["169.254.10.9"] }) { supervisor in
            let metadataURL = try #require(URL(string: "http://169.254.169.254/latest/meta-data/"))
            let metadataResult = await supervisor.validate(url: metadataURL, method: "GET", headers: [:])
            switch metadataResult {
            case .allowed: Issue.record("CRITICAL: metadata literal dialed under a local exemption")
            case let .denied(reason), let .unlistedDomain(_, reason): #expect(reason.contains("metadata"))
            }
            let linkLocalURL = try #require(URL(string: "http://169.254.10.9/metadata"))
            let linkLocalResult = await supervisor.validateReadOnly(url: linkLocalURL)
            #expect(linkLocalResult?.contains("link-local") == true)
            // An exemption names the host, never what it resolves to: a
            // rebinding answer in never-dialable space refuses even for the
            // exempted name.
            let exemptedURL = try #require(URL(string: "https://nas.homelab.internal/status"))
            let rebinding = await supervisor.validateReadOnly(url: exemptedURL)
            #expect(rebinding?.contains("resolves to blocked address") == true)
        }
    }

    @Test
    func `Policy exemption write after supervisor construction applies live`() async throws {
        let resolver: @Sendable (String) -> [String] = { _ in ["192.168.1.50"] }
        try await ApiSSRFGuard.$taskTestDNSResolver.withValue(resolver) {
            let store = PolicyStore(fileURL: URL(fileURLWithPath: "/tmp/test-egress-\(UUID().uuidString).toml"))
            await store.update(SecurityPolicy(network: NetworkEgressPolicy(mode: .unrestricted, blockedDomains: [])))
            let supervisor = OutboundEgressSupervisor(
                policyStore: store,
                secrets: SecretsManager(inMemory: true),
                browserConfig: BrowserConfig()
            )
            let url = try #require(URL(string: "https://nas.homelab.internal/status"))
            let before = await supervisor.validate(url: url, method: "GET", headers: [:])
            switch before {
            case .allowed: Issue.record("Expected denial before the policy carried the exemption")
            case let .denied(reason), let .unlistedDomain(_, reason):
                #expect(reason.contains("resolves to blocked address"))
            }
            // A policy write lands through the shared store with no restart;
            // the supervisor reads the snapshot per call, so the next verdict
            // carries the new exemption.
            let violations = await store.update(
                SecurityPolicy(
                    network: NetworkEgressPolicy(
                        mode: .unrestricted,
                        localExemptions: ["nas.homelab.internal"]
                    )
                )
            )
            #expect(violations.isEmpty)
            let after = await supervisor.validate(url: url, method: "GET", headers: [:])
            switch after {
            case let .allowed(outcome):
                #expect(outcome.dialPin.host == "nas.homelab.internal")
                #expect(outcome.dialPin.addresses == ["192.168.1.50"])
            case let .denied(reason), let .unlistedDomain(_, reason):
                Issue.record("Expected the live policy write to exempt the homelab host, got: \(reason)")
            }
            let readOnly = await supervisor.validateReadOnly(url: url)
            #expect(readOnly == nil)
        }
    }

    @Test
    func `Retired browser allowed origins grant no dialing at the supervisor`() async throws {
        // `browser.allowed_origins` is retired migration input: naming a
        // private host there must not exempt it at the dial decision, even
        // though the same browser config object rides every boot path
        // (`BuiltinToolPlugins`, `ServerContext`, `ServeCommand`,
        // `AppModelBoot`). Only the snapshot's `local_exemptions` (plus auto
        // service origins) may exempt.
        let resolver: @Sendable (String) -> [String] = { _ in ["192.168.1.50"] }
        try await ApiSSRFGuard.$taskTestDNSResolver.withValue(resolver) {
            let store = PolicyStore(fileURL: URL(fileURLWithPath: "/tmp/test-egress-\(UUID().uuidString).toml"))
            await store.update(SecurityPolicy(network: NetworkEgressPolicy(mode: .unrestricted, blockedDomains: [])))
            let supervisor = OutboundEgressSupervisor(
                policyStore: store,
                secrets: SecretsManager(inMemory: true),
                browserConfig: BrowserConfig(allowedOrigins: ["nas.homelab.internal", "192.168.1.*"])
            )
            let url = try #require(URL(string: "https://nas.homelab.internal/status"))
            let result = await supervisor.validate(url: url, method: "GET", headers: [:])
            switch result {
            case .allowed: Issue.record("Retired browser.allowed_origins must not exempt private dialing")
            case let .denied(reason), let .unlistedDomain(_, reason):
                #expect(reason.contains("resolves to blocked address"))
            }
            let readOnly = await supervisor.validateReadOnly(url: url)
            #expect(readOnly?.contains("resolves to blocked address") == true)
            // The guard-level set carries the same verdict: the retired list
            // contributes nothing, so the private literal refuses there too.
            #expect(ApiSSRFGuard.denyReason(for: "http://192.168.1.50/status", browserConfig: BrowserConfig(allowedOrigins: ["192.168.1.*"])) != nil)
        }
    }

    // MARK: - Response Sweeping

    @Test
    func `Response sweeping redacts echoed secrets`() async throws {
        let policy = SecurityPolicy()
        try await withTestSupervisor(policy: policy) { supervisor in
            let content = "Response body contains sk-1234567890abcdef in the text"
            let swept = supervisor.sweepResponse(content, secrets: ["sk-1234567890abcdef"])
            #expect(!swept.contains("sk-1234567890abcdef"))
            #expect(swept.contains("[redacted]"))
        }
    }

    @Test
    func `Tool output sweeps echoed credentials through the supervisor`() async throws {
        // Production reachability: the tool's output boundary must route
        // through `sweepResponse` rather than sweeping on its own, so the
        // choke-point that injected the credential also removes an echo.
        let secrets = SecretsManager(inMemory: true)
        try await secrets.store(key: "RW_TEST_SWEEP_KEY", secret: "live-sweep-secret")
        let policy = SecurityPolicy(
            network: NetworkEgressPolicy(
                mode: .allowlistOnly,
                allowedDomains: ["api.example.com"]
            ),
            credentials: [
                "RW_TEST_SWEEP_KEY": CredentialBinding(
                    allowedHosts: ["api.example.com"],
                    allowedMethods: ["GET"]
                )
            ]
        )
        try await withTestSupervisor(policy: policy, secrets: secrets) { supervisor in
            let tool = ApiRequestTool(
                transport: CannedApiTransport(body: #"{"echo":"live-sweep-secret"}"#),
                egressSupervisor: supervisor
            )
            let output = try await tool.execute(
                input: ToolInput(
                    toolName: "api.request",
                    argumentsJSON: #"{"method":"GET","url":"https://api.example.com/data","headers":{"Authorization":"Bearer rwsecret:RW_TEST_SWEEP_KEY"}}"#
                ),
                context: ToolContext(conversationID: UUID())
            )
            #expect(!output.isError)
            #expect(!output.content.contains("live-sweep-secret"))
            #expect(output.content.contains("[redacted]"))
        }
    }
}
