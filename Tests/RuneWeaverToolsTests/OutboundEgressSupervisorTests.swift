// Rune Weaver Tools Tests — Outbound Egress Supervisor and adversarial exfiltration.

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
    /// Builds a supervisor over a throwaway verified policy store and runs `body` with this test's
    /// canned DNS proof bound to its task.
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
        // The destination itself is ambiguous, so the gate refuses it rather than dialing a path
        // whose routed resource depends on the decoder.
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
            // An exemption names the host, never what it resolves to: a rebinding answer in
            // never-dialable space refuses even for the exempted name.
            let exemptedURL = try #require(URL(string: "https://nas.homelab.internal/status"))
            let rebinding = await supervisor.validateReadOnly(url: exemptedURL)
            let refusedRebinding = rebinding.map {
                $0.contains("resolves to blocked address") || $0.contains("could not be verified")
            } ?? false
            #expect(
                refusedRebinding,
                "expected the exempted name to refuse a blocked rebinding answer or fail closed unresolved, got: \(rebinding ?? "nil")"
            )
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
                // The unexempted private-resolving host must refuse either way it is proven
                // blocked: through the canned resolution or through the fail-closed DNS timeout this
                // environment guarantees.
                #expect(
                    reason.contains("resolves to blocked address") || reason.contains("could not be verified"),
                    "expected the unexempted private answer to refuse or fail closed, got: \(reason)"
                )
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

    // MARK: - Active Grant Summary

    @Test
    func `Active grants report session and one-shot allows`() async throws {
        let policy = SecurityPolicy(
            network: NetworkEgressPolicy(
                mode: .allowlistOnly,
                allowedDomains: ["api.github.com"]
            )
        )
        try await withTestSupervisor(policy: policy) { supervisor in
            let sessionID = UUID()
            let otherSession = UUID()
            await supervisor.allowDomainForSession(sessionID: sessionID, domain: "Example.COM")
            await supervisor.allowDomainOnce(domain: "one-shot.example.com", sessionID: sessionID)
            // A grant rides only its own session: another session reads its
            // own grants and never a peer's.
            await supervisor.allowDomainForSession(sessionID: otherSession, domain: "other.example.com")

            let summary = await supervisor.activeGrants(sessionID: sessionID)
            #expect(summary.sessionDomains == ["example.com"])
            #expect(summary.oneShotDomains == ["one-shot.example.com"])

            let otherSummary = await supervisor.activeGrants(sessionID: otherSession)
            #expect(otherSummary.sessionDomains == ["other.example.com"])
            #expect(otherSummary.oneShotDomains == [])
        }
    }

    @Test
    func `Nil session reads report only session-less one-shot grants`() async throws {
        let policy = SecurityPolicy()
        try await withTestSupervisor(policy: policy) { supervisor in
            let sessionID = UUID()
            await supervisor.allowDomainOnce(domain: "open.example.com", sessionID: nil)
            await supervisor.allowDomainOnce(domain: "scoped.example.com", sessionID: sessionID)
            await supervisor.allowDomainForSession(sessionID: sessionID, domain: "session.example.com")

            // A session-less caller can spend only the nil-key grants, and a
            // session grant never rides a session-less read.
            let openSummary = await supervisor.activeGrants(sessionID: nil)
            #expect(openSummary.sessionDomains == [])
            #expect(openSummary.oneShotDomains == ["open.example.com"])

            // Any session spends the session-less grants alongside its own.
            let scopedSummary = await supervisor.activeGrants(sessionID: sessionID)
            #expect(scopedSummary.sessionDomains == ["session.example.com"])
            #expect(scopedSummary.oneShotDomains == ["open.example.com", "scoped.example.com"])
        }
    }

    @Test
    func `Reading the summary does not spend a one-shot grant`() async throws {
        let policy = SecurityPolicy()
        try await withTestSupervisor(policy: policy) { supervisor in
            let sessionID = UUID()
            await supervisor.allowDomainOnce(domain: "repeat.example.com", sessionID: sessionID)
            // The projection is read-only, so repeated reads leave the grant
            // spendable by the real gate.
            #expect(await supervisor.activeGrants(sessionID: sessionID).oneShotDomains == ["repeat.example.com"])
            #expect(await supervisor.activeGrants(sessionID: sessionID).oneShotDomains == ["repeat.example.com"])
        }
    }

    @Test
    func `Consumed one-shot grant drops out of the summary`() async throws {
        // An allowlist-empty policy parks the host, the one-shot grant covers
        // the hop once, and the spent domain no longer reads back.
        let policy = SecurityPolicy(
            network: NetworkEgressPolicy(mode: .allowlistOnly)
        )
        try await withTestSupervisor(policy: policy) { supervisor in
            let sessionID = UUID()
            await supervisor.allowDomainOnce(domain: "consume.example.com", sessionID: sessionID)
            #expect(await supervisor.activeGrants(sessionID: sessionID).oneShotDomains == ["consume.example.com"])
            let url = try #require(URL(string: "https://consume.example.com/data"))
            switch await supervisor.validate(url: url, method: "GET", headers: [:], sessionID: sessionID) {
            case .allowed: break // expected — the one-shot grant covered the hop
            case let .denied(reason), let .unlistedDomain(_, reason):
                Issue.record("Expected the one-shot grant to allow the hop, got: \(reason)")
            }
            #expect(await supervisor.activeGrants(sessionID: sessionID).oneShotDomains == [])
        }
    }

    @Test
    func `Clearing a session evicts its grants from the summary`() async throws {
        let policy = SecurityPolicy()
        try await withTestSupervisor(policy: policy) { supervisor in
            let sessionID = UUID()
            await supervisor.allowDomainForSession(sessionID: sessionID, domain: "session.example.com")
            await supervisor.allowDomainOnce(domain: "one-shot.example.com", sessionID: sessionID)
            await supervisor.clearSession(sessionID: sessionID)
            let summary = await supervisor.activeGrants(sessionID: sessionID)
            #expect(summary.sessionDomains.isEmpty)
            #expect(summary.oneShotDomains.isEmpty)
        }
    }

    @Test
    func `Sibling-tenant wildcard grants cover nothing fail-closed`() {
        // A bare shared-parent wildcard must not cover its tenants, while the
        // tenant wildcard itself still covers the tenant and its subdomains.
        let suffixes = [
            "co.at", "co.id", "co.il", "co.ke", "co.th",
            "ltd.uk", "plc.uk", "sch.uk", "asn.au", "id.au",
            "wordpress.com", "tumblr.com", "myshopify.com",
            "github.dev", "githubusercontent.com", "googleusercontent.com",
            "deno.dev", "repl.co", "duckdns.org", "ngrok.io", "trycloudflare.com"
        ]
        for suffix in suffixes {
            let tenant = "evil.\(suffix)"
            #expect(OutboundEgressSupervisor.grantEntry("*.\(suffix)", covers: tenant) == false)
            #expect(OutboundEgressSupervisor.grantEntry("*.\(tenant)", covers: tenant) == true)
            #expect(OutboundEgressSupervisor.grantEntry("*.\(tenant)", covers: "sub.\(tenant)") == true)
        }
    }
}
