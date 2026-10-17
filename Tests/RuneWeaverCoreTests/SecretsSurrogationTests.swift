// Rune Weaver Core Tests — Secret surrogation keeping live credentials out of agent context.

import Foundation
import os
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

/// Process-wide gate serializing test credential environment mutation.
private actor SurrogateEnvGate {
    /// Whether a scoped body currently holds the gate.
    private var locked = false
    /// FIFO waiters queued while the gate is held.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Acquires the gate, suspending until the current holder releases it.
    private func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Releases the gate, resuming the next waiter when present.
    private func release() {
        if waiters.isEmpty {
            locked = false
        } else {
            let next = waiters.removeFirst()
            next.resume()
        }
    }

    /// Runs `body` with the stub credential installed.
    func withCredential(envVar: String, value: String?, _ body: () async throws -> Void) async rethrows {
        await acquire()
        defer { release() }
        let saved: String? = envVar.withCString { keyPtr in
            getenv(keyPtr).map { String(cString: $0) }
        }
        if let value {
            setenv(envVar, value, 1)
        } else {
            unsetenv(envVar)
        }
        defer {
            if let saved {
                setenv(envVar, saved, 1)
            } else {
                unsetenv(envVar)
            }
        }
        try await body()
    }
}

/// Shared gate serializing surrogate credential setup.
private let surrogateEnvGate = SurrogateEnvGate()

/// Box capturing the wire request seen by the stub transport.
private final class CapturedRequestBox: Sendable {
    /// Guard for the captured request.
    private let stored = OSAllocatedUnfairLock<URLRequest?>(initialState: nil)

    /// Records the wire request.
    func set(_ request: URLRequest) {
        stored.withLock { $0 = request }
    }

    /// Returns the last recorded request.
    var value: URLRequest? {
        stored.withLock { $0 }
    }
}

/// Stub transport returning canned JSON while capturing the wire request.
private struct CapturingApiTransport: ApiRequestTransport, Sendable {
    let box: CapturedRequestBox
    let body: Data

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        box.set(request)
        let fallback = request.url ?? URL(fileURLWithPath: "/")
        let response = HTTPURLResponse(
            url: fallback,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ) ?? HTTPURLResponse(url: fallback, mimeType: "application/json", expectedContentLength: 0, textEncodingName: nil)
        return (body, response)
    }
}

/// Publishes canned public DNS proof so stubbed HTTPS dials stay hermetic.
private func stubPublicDNS() {
    ApiSSRFGuard.testDNSResolver = { _ in ["93.184.216.34"] }
}

/// Restores system resolution after a stubbed test.
private func clearDNS() {
    ApiSSRFGuard.testDNSResolver = nil
}

/// Decoded preview envelope for dry-run assertions.
private struct SurrogatePreviewEnvelope: Decodable {
    let status: String
    let dryRun: Bool?
    let requestHeaders: [String: String]?
}

@Suite("Surrogate Issuance")
struct SurrogateIssuanceTests {
    @Test
    func `Surrogate carries the key as a reference without reading secrets`() throws {
        let secrets = SecretsManager()
        let reference = try secrets.surrogate(for: "MY_API_KEY")
        #expect(reference == "rwsecret:MY_API_KEY")
        #expect(SecretsManager.containsSurrogate(reference))
        #expect(SecretsManager.surrogateKey(from: reference) == "MY_API_KEY")
    }

    @Test
    func `Embedded scheme keeps the reference discoverable`() {
        #expect(SecretsManager.containsSurrogate("Bearer rwsecret:MY_API_KEY"))
        #expect(SecretsManager.surrogates(in: "Bearer rwsecret:MY_API_KEY") == ["MY_API_KEY"])
        #expect(SecretsManager.surrogateKey(from: "Bearer rwsecret:MY_API_KEY") == nil)
    }

    @Test
    func `Surrogate reflects live rotation instead of storing a copy`() async throws {
        let key = "RW_TEST_ROTATING_KEY"
        let secrets = SecretsManager()
        let reference = try secrets.surrogate(for: key)
        try await surrogateEnvGate.withCredential(envVar: key, value: "first-value") {
            let first = try await secrets.resolveSurrogate(reference)
            #expect(first == "first-value")
        }
        try await surrogateEnvGate.withCredential(envVar: key, value: "second-value") {
            let second = try await secrets.resolveSurrogate(reference)
            #expect(second == "second-value")
        }
    }
}

@Suite("Surrogate Resolution", .serialized)
struct SurrogateResolutionTests {
    @Test
    func `Exact surrogate resolves through the live environment`() async throws {
        let key = "RW_TEST_SURROGATE_ROUNDTRIP"
        let secrets = SecretsManager()
        try await surrogateEnvGate.withCredential(envVar: key, value: "live-secret-abc-123") {
            let reference = try secrets.surrogate(for: key)
            let resolvedSurrogate = try await secrets.resolveSurrogate(reference)
            #expect(resolvedSurrogate == "live-secret-abc-123")
            let resolved = try await secrets.resolve(reference)
            #expect(resolved == "live-secret-abc-123")
        }
    }

    @Test
    func `Embedded surrogate resolves inside a header value`() async throws {
        let key = "RW_TEST_SURROGATE_EMBEDDED"
        let secrets = SecretsManager()
        try await surrogateEnvGate.withCredential(envVar: key, value: "live-secret-abc-123") {
            let outcome = try await secrets.resolveValueContainingSurrogates("Bearer rwsecret:\(key)")
            #expect(outcome.resolved == "Bearer live-secret-abc-123")
            #expect(outcome.secrets == ["live-secret-abc-123"])
        }
    }

    @Test
    func `Unknown surrogate throws a typed error naming the key`() async {
        let secrets = SecretsManager()
        let missing = "RW_TEST_DEFINITELY_MISSING_SURROGATE_KEY"
        unsetenv(missing)
        do {
            _ = try await secrets.resolveSurrogate("rwsecret:\(missing)")
            Issue.record("Expected unknownSurrogate for a missing key")
        } catch let error as SecretsError {
            guard case let .unknownSurrogate(key) = error else {
                Issue.record("Expected unknownSurrogate, got \(error)")
                return
            }
            #expect(key == missing)
        } catch {
            Issue.record("Expected SecretsError, got \(error)")
        }
    }

    @Test
    func `Reserved sovereign accounts refuse every surrogate resolution point`() async throws {
        let secrets = SecretsManager(
            service: "com.runeweaver.test.sovereign.reserve.\(UUID().uuidString)",
            inMemory: true
        )
        let reserved = EnclaveHMACSigner.signingKeyAccount
        // Stored exactly as the ledger stores it, bypassing route validation,
        // so the refusal below can only come from the resolution surface.
        try await secrets.storeKeychain(key: reserved, secret: "attestation-key-material")
        for value in ["rwsecret:\(reserved)", "Bearer rwsecret:\(reserved)"] {
            do {
                _ = try await secrets.resolveValueContainingSurrogates(value)
                Issue.record("Expected the reserved account to refuse embedded resolution")
            } catch let error as SecretsError {
                guard case let .unknownSurrogate(key) = error else {
                    Issue.record("Expected unknownSurrogate, got \(error)")
                    return
                }
                #expect(key == reserved)
            } catch {
                Issue.record("Expected SecretsError, got \(error)")
            }
        }
        do {
            _ = try await secrets.resolveSurrogate("rwsecret:\(reserved)")
            Issue.record("Expected the reserved account to refuse exact resolution")
        } catch let error as SecretsError {
            guard case .unknownSurrogate = error else {
                Issue.record("Expected unknownSurrogate, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected SecretsError, got \(error)")
        }
    }

    @Test
    func `Plain env names keep the historical nil-when-absent shape`() async throws {
        let secrets = SecretsManager()
        let missing = "RW_TEST_DEFINITELY_ABSENT_PLAIN_KEY"
        unsetenv(missing)
        #expect(try await secrets.resolve(missing) == nil)
    }
}

@Suite("API Transport Surrogation", .serialized)
struct ApiSurrogateTransportTests {
    /// Builds the mandatory supervisor over a verified policy that allows one
    /// host and binds one surrogate key, mirroring the production factory's
    /// requirement so the transport tests exercise the supervised path.
    private func makeSupervisor(host: String, key: String?) async -> OutboundEgressSupervisor {
        let store = PolicyStore(fileURL: URL(fileURLWithPath: "/tmp/rw-api-supervision-\(UUID().uuidString).toml"))
        var credentials: [String: CredentialBinding] = [:]
        if let key {
            credentials[key] = CredentialBinding(allowedHosts: [host])
        }
        await store.update(
            SecurityPolicy(
                network: NetworkEgressPolicy(mode: .allowlistOnly, allowedDomains: [host]),
                credentials: credentials
            )
        )
        return OutboundEgressSupervisor(policyStore: store, secrets: SecretsManager(), browserConfig: BrowserConfig())
    }

    @Test
    func `Args carry the surrogate while the wire request carries the real value`() async throws {
        let key = "RW_TEST_API_TRANSPORT_TOKEN"
        try await surrogateEnvGate.withCredential(envVar: key, value: "live-secret-abc-123") {
            stubPublicDNS()
            defer { clearDNS() }
            let box = CapturedRequestBox()
            let transport = CapturingApiTransport(box: box, body: Data(#"{"hello":"world"}"#.utf8))
            let supervisor = await makeSupervisor(host: "example.com", key: key)
            let tool = ApiRequestTool(transport: transport, egressSupervisor: supervisor)
            let arguments = #"{"method":"GET","url":"https://example.com/ping","headers":{"Authorization":"Bearer rwsecret:\#(key)"}}"#
            #expect(arguments.contains("rwsecret:"))
            #expect(!arguments.contains("live-secret-abc-123"))
            let output = try await tool.execute(
                input: ToolInput(toolName: "api.request", argumentsJSON: arguments),
                context: ToolContext(conversationID: UUID())
            )
            #expect(!output.isError)
            let wire = try #require(box.value)
            let wireAuth = wire.value(forHTTPHeaderField: "Authorization") ?? ""
            #expect(wireAuth == "Bearer live-secret-abc-123")
            #expect(!output.content.contains("live-secret-abc-123"))
        }
    }

    @Test
    func `Unknown surrogate fails closed as a typed failure`() async throws {
        let missing = "RW_TEST_API_MISSING_TRANSPORT_KEY"
        unsetenv(missing)
        stubPublicDNS()
        defer { clearDNS() }
        let box = CapturedRequestBox()
        let supervisor = await makeSupervisor(host: "example.com", key: missing)
        let tool = ApiRequestTool(
            transport: CapturingApiTransport(box: box, body: Data(#"{}"#.utf8)),
            egressSupervisor: supervisor
        )
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "api.request",
                argumentsJSON: #"{"method":"GET","url":"https://example.com/ping","headers":{"Authorization":"Bearer rwsecret:\#(missing)"}}"#
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError)
        #expect(output.content.contains(missing))
        #expect(box.value == nil)
    }

    @Test
    func `Dry-run previews keep the surrogate and never touch the real value`() async throws {
        let key = "RW_TEST_API_DRYRUN_TOKEN"
        try await surrogateEnvGate.withCredential(envVar: key, value: "live-secret-abc-123") {
            stubPublicDNS()
            defer { clearDNS() }
            let box = CapturedRequestBox()
            let supervisor = await makeSupervisor(host: "example.com", key: key)
            let tool = ApiRequestTool(
                transport: CapturingApiTransport(box: box, body: Data(#"{}"#.utf8)),
                egressSupervisor: supervisor
            )
            let output = try await tool.execute(
                input: ToolInput(
                    toolName: "api.request",
                    argumentsJSON: #"{"method":"GET","url":"https://example.com/ping","headers":{"Authorization":"Bearer rwsecret:\#(key)"}}"#
                ),
                context: ToolContext(conversationID: UUID(), dryRun: true)
            )
            #expect(!output.isError)
            #expect(box.value == nil)
            let envelope = try JSONDecoder().decode(SurrogatePreviewEnvelope.self, from: Data(output.content.utf8))
            #expect(envelope.status == "preview")
            #expect(envelope.dryRun == true)
            let previewAuth = envelope.requestHeaders?["Authorization"] ?? ""
            #expect(previewAuth.contains("rwsecret:\(key)"))
            #expect(!output.content.contains("live-secret-abc-123"))
        }
    }
}

@Suite("Redaction Parity")
struct SurrogateRedactionTests {
    @Test
    func `Resolved values sweep out of echoed output`() {
        let secrets = SecretsManager()
        let swept = secrets.redactResolved(
            "server echoed live-secret-abc-123 back",
            secrets: ["live-secret-abc-123"]
        )
        #expect(!swept.contains("live-secret-abc-123"))
        #expect(swept.contains(SecretsManager.redactedPlaceholder))
    }

    @Test
    func `Longest secret sweeps first so overlaps leave nothing behind`() {
        let secrets = SecretsManager()
        let swept = secrets.redactResolved(
            "token live-secret-abc-123",
            secrets: ["live-secret-abc-123", "live-secret"]
        )
        #expect(!swept.contains("live-secret-abc-123"))
        #expect(!swept.contains("live-secret"))
    }

    @Test
    func `Header redaction preserves surrogates while sweeping resolved echoes`() {
        let preview = ApiHeaderPolicy.redacted(["Authorization": "Bearer rwsecret:MY_KEY"])
        #expect(preview["Authorization"] == "Bearer rwsecret:MY_KEY")
        let live = ApiHeaderPolicy.redacted(
            ["Authorization": "Bearer live-secret-abc-123", "Accept": "live-secret-abc-123"],
            resolvedSecrets: ["live-secret-abc-123"]
        )
        #expect(live["Authorization"] == ApiHeaderPolicy.redactedPlaceholder)
        #expect(live["Accept"] == ApiHeaderPolicy.redactedPlaceholder)
    }
}

@Suite("Header Allowlist Stability")
struct SurrogateAllowlistTests {
    @Test
    func `Allowlist still admits only the three documented headers`() {
        #expect(ApiHeaderPolicy.allowedHeaders == ["accept", "content-type", "authorization"])
        #expect(ApiHeaderPolicy.isAllowed("Accept"))
        #expect(ApiHeaderPolicy.isAllowed("Content-Type"))
        #expect(ApiHeaderPolicy.isAllowed("Authorization"))
        #expect(!ApiHeaderPolicy.isAllowed("X-Api-Key"))
        #expect(!ApiHeaderPolicy.isAllowed("Cookie"))
    }

    @Test
    func `Surrogate values pass validation without widening the allowlist`() throws {
        let checked = try ApiHeaderPolicy.validated(["Authorization": "Bearer rwsecret:MY_KEY"])
        #expect(checked["Authorization"] == "Bearer rwsecret:MY_KEY")
        do {
            _ = try ApiHeaderPolicy.validated(["X-Api-Key": "live-secret-abc-123"])
            Issue.record("Expected allowlist rejection for X-Api-Key")
        } catch let error as ApiRequestError {
            guard case .invalidHeaders = error else {
                Issue.record("Expected invalidHeaders, got \(error)")
                return
            }
        }
    }
}
