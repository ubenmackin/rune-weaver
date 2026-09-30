// Rune Weaver Tools Tests — Dial-time pinning for api.request egress.
//
// Purpose: pins the SSRF contract's dial-time half — an allowed vetting
// returns the numeric addresses it proved, the tool carries that pin through
// every redirect hop, and the transport dials the pin instead of resolving the
// hostname again, so a rebinding name cannot reach a destination the gate
// refused.
// Scope: supervisor/tool pin plumbing with hermetic scripted transports,
// resolver-call counting that proves the dial never re-resolves, live
// transport fail-closed behavior without a pin, and the pure HTTP/1.1
// request/response helpers the pinned dialer relies on.
// Architectural role: the regression suite for the check-then-dial race,
// asserting the vetted address is what reaches the transport on the initial
// URL and on every redirect hop.

import Foundation
import os
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

/// One recorded dial with the pin the transport was asked to use.
private struct RecordedPinnedDial: Sendable, Equatable {
    /// Destination URL carried by the request.
    let url: String
    /// Original host identity preserved by the pin.
    let host: String
    /// Numeric addresses the SSRF gate proved.
    let addresses: [String]
    /// Effective destination port.
    let port: Int
    /// Whether the hop dials TLS.
    let isSecure: Bool
}

/// Locked dial log so a test can prove which pins reached the transport.
private final class PinnedDialRecorder: Sendable {
    /// Guarded dials in call order.
    private let dials = OSAllocatedUnfairLock<[RecordedPinnedDial]>(initialState: [])

    /// Dials the transport observed, in call order.
    var recorded: [RecordedPinnedDial] {
        dials.withLock { $0 }
    }

    /// Records one dial.
    func record(_ dial: RecordedPinnedDial) {
        dials.withLock { $0.append(dial) }
    }
}

/// Locked resolver log so a test can prove how many lookups a hop caused.
private final class ResolverCallRecorder: Sendable {
    /// Guarded hostnames in call order.
    private let hosts = OSAllocatedUnfairLock<[String]>(initialState: [])

    /// Hostnames the resolver was asked about, in call order.
    var recorded: [String] {
        hosts.withLock { $0 }
    }

    /// Records one resolver request and returns its 0-based sequence number.
    func record(_ host: String) -> Int {
        hosts.withLock { state in
            state.append(host)
            return state.count - 1
        }
    }
}

/// Scripted response for one destination.
private struct PinnedScriptedResponse: Sendable {
    /// HTTP status to return.
    let statusCode: Int
    /// `Location` header value for redirects, nil otherwise.
    let location: String?
}

/// Stub transport that records each dial's pin and answers from a script.
///
/// The unpinned entry throws so a tool that regressed to dialing by name (or
/// that failed to dispatch the pinned requirement through the existential)
/// fails loudly instead of succeeding silently.
private struct PinnedScriptedTransport: ApiRequestTransport, Sendable {
    /// Shared dial log.
    let recorder: PinnedDialRecorder
    /// Scripted responses keyed by absolute URL; unlisted URLs answer 200 JSON.
    let script: [String: PinnedScriptedResponse]

    /// Refuses the unpinned entry: every production dial must carry a pin.
    func data(for _: URLRequest) async throws -> (Data, URLResponse) {
        throw PinnedDialError.unpinnedDialRefused
    }

    /// Records the pin and answers from the script without following redirects.
    func data(for request: URLRequest, pin: SSRFDialPin) async throws -> (Data, URLResponse) {
        recorder.record(
            RecordedPinnedDial(
                url: request.url?.absoluteString ?? "",
                host: pin.host,
                addresses: pin.addresses,
                port: pin.port,
                isSecure: pin.isSecure
            )
        )
        let destination = request.url?.absoluteString ?? ""
        let scripted = script[destination] ?? PinnedScriptedResponse(statusCode: 200, location: nil)
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

/// Builds a verified policy store over a throwaway file path.
private func makePinnedPolicyStore(_ policy: SecurityPolicy) async -> PolicyStore {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("rw-pinned-\(UUID().uuidString).toml")
    let store = PolicyStore(fileURL: url)
    await store.update(policy)
    return store
}

/// Runs `body` with the debug DNS resolver bound to this test's task.
///
/// The process-global holder is shared by parallel suites, so counting
/// resolver traffic requires a task-scoped binding.
private func withPinnedDNS(
    _ resolver: @escaping @Sendable (String) -> [String],
    _ body: () async throws -> Void
) async throws {
    try await ApiSSRFGuard.$taskTestDNSResolver.withValue(resolver) {
        try await body()
    }
}

@Suite("ApiRequestPinnedDial", .serialized)
struct ApiRequestPinnedDialTests {
    // MARK: - SSRF Vetting Pins

    @Test
    func `Vetting pins every proven address with the original host identity`() async throws {
        try await withPinnedDNS({ _ in ["93.184.216.34", "93.184.216.35"] }) {
            let vetting = await ApiSSRFGuard.vetAsync(
                for: "https://api.example.com/v1/models",
                allowlistedOrigins: []
            )
            guard case let .dialable(pin) = vetting else {
                Issue.record("Expected a dialable pin, got: \(vetting)")
                return
            }
            #expect(pin.host == "api.example.com")
            #expect(pin.addresses == ["93.184.216.34", "93.184.216.35"])
            #expect(pin.port == 443)
            #expect(pin.isSecure)
        }
    }

    @Test
    func `Vetting refuses a name that resolves into a sensitive range`() async throws {
        try await withPinnedDNS({ _ in ["127.0.0.1"] }) {
            let vetting = await ApiSSRFGuard.vetAsync(
                for: "https://api.example.com/v1/models",
                allowlistedOrigins: []
            )
            #expect(vetting.refusal?.contains("resolves to blocked address") == true)
            if case .dialable = vetting {
                Issue.record("CRITICAL: a loopback resolution produced a dialable pin")
            }
        }
    }

    @Test
    func `Literal pins canonicalize obfuscated spellings`() async {
        let vetting = await ApiSSRFGuard.vetAsync(
            for: "http://0x7f.1/",
            allowlistedOrigins: ["127.0.0.1"]
        )
        guard case let .dialable(pin) = vetting else {
            Issue.record("Expected the allowlisted loopback literal to stay dialable, got: \(vetting)")
            return
        }
        // The wire dial uses the decoded address, never the obfuscated spelling.
        #expect(pin.addresses == ["127.0.0.1"])
        #expect(pin.port == 80)
        #expect(!pin.isSecure)
    }

    // MARK: - Pin Plumbing (Check-Then-Dial Race)

    @Test
    func `Initial dial uses the vetted address and never re-resolves the name`() async throws {
        let resolverCalls = ResolverCallRecorder()
        // A rebinding simulation: the first answer is the public proof, any
        // later answer for the same name turns loopback. A transport that
        // resolved again would receive the refused address.
        let resolver: @Sendable (String) -> [String] = { host in
            resolverCalls.record(host) == 0 ? ["93.184.216.34"] : ["127.0.0.1"]
        }
        try await withPinnedDNS(resolver) {
            let store = await makePinnedPolicyStore(SecurityPolicy(network: NetworkEgressPolicy(mode: .unrestricted)))
            // No loopback exemption: a rebinding answer must stay refused.
            let supervisor = try await OutboundEgressSupervisor.make(
                policyStore: store,
                browserConfig: BrowserConfig(searxngURL: "")
            )
            let dials = PinnedDialRecorder()
            let tool = ApiRequestTool(
                transport: PinnedScriptedTransport(recorder: dials, script: [:]),
                egressSupervisor: supervisor
            )
            let output = try await tool.execute(
                input: ToolInput(
                    toolName: "api.request",
                    argumentsJSON: #"{"method":"GET","url":"https://api.example.com/data"}"#
                ),
                context: ToolContext(conversationID: UUID())
            )
            #expect(!output.isError)
            let dial = try #require(dials.recorded.first)
            #expect(dial.url == "https://api.example.com/data")
            #expect(dial.host == "api.example.com")
            #expect(dial.addresses == ["93.184.216.34"])
            #expect(dial.port == 443)
            #expect(dial.isSecure)
            // Exactly one lookup: the vetting pass. The dial must not add one.
            #expect(resolverCalls.recorded == ["api.example.com"])
        }
    }

    @Test
    func `Every redirect hop dials its own vetted address`() async throws {
        let resolverCalls = ResolverCallRecorder()
        let addresses: [String: [String]] = [
            "first.example.com": ["93.184.216.34"],
            "second.example.com": ["93.184.216.35"]
        ]
        let resolver: @Sendable (String) -> [String] = { host in
            _ = resolverCalls.record(host)
            return addresses[host] ?? ["93.184.216.36"]
        }
        try await withPinnedDNS(resolver) {
            let store = await makePinnedPolicyStore(
                SecurityPolicy(
                    network: NetworkEgressPolicy(
                        mode: .allowlistOnly,
                        allowedDomains: ["first.example.com", "second.example.com"]
                    )
                )
            )
            let supervisor = try await OutboundEgressSupervisor.make(
                policyStore: store,
                browserConfig: BrowserConfig(searxngURL: "")
            )
            let dials = PinnedDialRecorder()
            let tool = ApiRequestTool(
                transport: PinnedScriptedTransport(
                    recorder: dials,
                    script: [
                        "https://first.example.com/start": PinnedScriptedResponse(
                            statusCode: 302,
                            location: "https://second.example.com/next"
                        )
                    ]
                ),
                egressSupervisor: supervisor
            )
            let output = try await tool.execute(
                input: ToolInput(
                    toolName: "api.request",
                    argumentsJSON: #"{"method":"GET","url":"https://first.example.com/start"}"#
                ),
                context: ToolContext(conversationID: UUID())
            )
            #expect(!output.isError)
            #expect(dials.recorded.count == 2)
            let first = try #require(dials.recorded.first)
            #expect(first.host == "first.example.com")
            #expect(first.addresses == ["93.184.216.34"])
            let second = try #require(dials.recorded.last)
            #expect(second.host == "second.example.com")
            #expect(second.addresses == ["93.184.216.35"])
            // One supervised vetting per hop, and the dials add none.
            #expect(resolverCalls.recorded == ["first.example.com", "second.example.com"])
        }
    }

    @Test
    func `A redirect into a refused resolution is stopped before that hop dials`() async throws {
        // The entry hop proves a public address; the redirect target resolves
        // into RFC 1918 space, so the second hop must be refused by its own
        // supervised vetting and must never reach the dial.
        let resolver: @Sendable (String) -> [String] = { host in
            host == "entry.example.com" ? ["93.184.216.34"] : ["10.0.0.5"]
        }
        try await withPinnedDNS(resolver) {
            let store = await makePinnedPolicyStore(
                SecurityPolicy(
                    network: NetworkEgressPolicy(
                        mode: .allowlistOnly,
                        allowedDomains: ["entry.example.com", "internal.example.com"]
                    )
                )
            )
            let supervisor = try await OutboundEgressSupervisor.make(
                policyStore: store,
                browserConfig: BrowserConfig(searxngURL: "")
            )
            let dials = PinnedDialRecorder()
            let tool = ApiRequestTool(
                transport: PinnedScriptedTransport(
                    recorder: dials,
                    script: [
                        "https://entry.example.com/start": PinnedScriptedResponse(
                            statusCode: 302,
                            location: "https://internal.example.com/collect"
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
            #expect(output.content.contains("resolves to blocked address"))
            #expect(dials.recorded.count == 1)
            #expect(dials.recorded.first?.host == "entry.example.com")
        }
    }

    @Test
    func `A refused resolution never reaches the transport`() async throws {
        try await withPinnedDNS({ _ in ["127.0.0.1"] }) {
            let store = await makePinnedPolicyStore(SecurityPolicy(network: NetworkEgressPolicy(mode: .unrestricted)))
            // No loopback exemption: the default searxng origin would otherwise
            // authorize 127.0.0.1 and mask the refusal this test pins.
            let supervisor = try await OutboundEgressSupervisor.make(
                policyStore: store,
                browserConfig: BrowserConfig(searxngURL: "")
            )
            let dials = PinnedDialRecorder()
            let tool = ApiRequestTool(
                transport: PinnedScriptedTransport(recorder: dials, script: [:]),
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
            #expect(output.content.contains("resolves to blocked address"))
            #expect(dials.recorded.isEmpty)
        }
    }

    @Test
    func `Live transport refuses a dial that carries no pin`() async throws {
        let transport = PinnedApiRequestTransport()
        let request = try URLRequest(url: #require(URL(string: "https://api.example.com/data")))
        await #expect(throws: PinnedDialError.unpinnedDialRefused) {
            _ = try await transport.data(for: request)
        }
    }

    // MARK: - Pinned Request Serialization

    @Test
    func `Serializer preserves the pinned host identity and body framing`() throws {
        var request = try URLRequest(url: #require(URL(string: "https://api.example.com:8443/v1/models?x=1")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer token", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("{}".utf8)
        let pin = SSRFDialPin(host: "api.example.com", addresses: ["93.184.216.34"], port: 8443, isSecure: true)
        let text = try String(decoding: PinnedHTTPRequestSerializer.serialize(request, pin: pin), as: UTF8.self)
        #expect(text.hasPrefix("POST /v1/models?x=1 HTTP/1.1\r\n"))
        #expect(text.contains("Host: api.example.com:8443\r\n"))
        #expect(text.contains("Authorization: Bearer token\r\n"))
        #expect(text.contains("Content-Length: 2\r\n"))
        #expect(text.hasSuffix("\r\n\r\n{}"))
    }

    @Test
    func `Serializer overrides a caller-supplied authority header`() throws {
        var request = try URLRequest(url: #require(URL(string: "https://api.example.com/")))
        request.setValue("evil.example.net", forHTTPHeaderField: "Host")
        request.setValue("gzip", forHTTPHeaderField: "Transfer-Encoding")
        let pin = SSRFDialPin(host: "api.example.com", addresses: ["93.184.216.34"], port: 443, isSecure: true)
        let text = try String(decoding: PinnedHTTPRequestSerializer.serialize(request, pin: pin), as: UTF8.self)
        #expect(text.contains("Host: api.example.com\r\n"))
        #expect(!text.contains("evil.example.net"))
        #expect(!text.contains("Transfer-Encoding"))
    }

    @Test
    func `Serializer brackets an IPv6 pin host`() throws {
        let request = try URLRequest(url: #require(URL(string: "http://localhost:8888/health")))
        let pin = SSRFDialPin(host: "::1", addresses: ["::1"], port: 8888, isSecure: false)
        let text = try String(decoding: PinnedHTTPRequestSerializer.serialize(request, pin: pin), as: UTF8.self)
        #expect(text.contains("Host: [::1]:8888\r\n"))
    }

    @Test
    func `Serializer fails closed on an unsafe pinned host`() throws {
        let request = try URLRequest(url: #require(URL(string: "https://api.example.com/")))
        let pin = SSRFDialPin(host: "api.example.com\r\nX-Injected: 1", addresses: ["93.184.216.34"], port: 443, isSecure: true)
        #expect(throws: PinnedDialError.malformedRequest("pinned host identity is not header-safe")) {
            _ = try PinnedHTTPRequestSerializer.serialize(request, pin: pin)
        }
    }

    // MARK: - Pinned Response Framing

    @Test
    func `Parser frames a fixed-length response`() throws {
        var parser = try PinnedHTTPResponseParser(
            responseURL: #require(URL(string: "https://api.example.com/data")),
            maxBodyBytes: 1024
        )
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 8\r\n\r\n{\"ok\":1}".utf8)
        guard case let .complete(response, body) = parser.feed(raw, closed: false) else {
            Issue.record("Expected a completed fixed-length response")
            return
        }
        #expect(response.statusCode == 200)
        #expect(response.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(String(decoding: body, as: UTF8.self) == #"{"ok":1}"#)
    }

    @Test
    func `Parser decodes chunked bodies and skips interim responses`() throws {
        var parser = try PinnedHTTPResponseParser(
            responseURL: #require(URL(string: "https://api.example.com/data")),
            maxBodyBytes: 1024
        )
        let raw = Data(
            (
                "HTTP/1.1 103 Early Hints\r\nLink: </s.css>; rel=preload\r\n\r\n"
                    + "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
                    + "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
            ).utf8
        )
        guard case let .complete(response, body) = parser.feed(raw, closed: false) else {
            Issue.record("Expected a completed chunked response")
            return
        }
        #expect(response.statusCode == 200)
        #expect(String(decoding: body, as: UTF8.self) == "hello world")
    }

    @Test
    func `Parser caps an oversized body and reports truncation bytes`() throws {
        var parser = try PinnedHTTPResponseParser(
            responseURL: #require(URL(string: "https://api.example.com/data")),
            maxBodyBytes: 4
        )
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Length: 20\r\n\r\n01234567890123456789".utf8)
        guard case let .complete(response, body) = parser.feed(raw, closed: false) else {
            Issue.record("Expected a capped completed response")
            return
        }
        #expect(response.statusCode == 200)
        // One byte past the cap keeps the caller's byte-cap classification true.
        #expect(body.count == 5)
    }

    @Test
    func `Parser frames a close-delimited body`() throws {
        var parser = try PinnedHTTPResponseParser(
            responseURL: #require(URL(string: "https://api.example.com/data")),
            maxBodyBytes: 1024
        )
        guard case .needMore = parser.feed(Data("HTTP/1.1 200 OK\r\n\r\npartial".utf8), closed: false) else {
            Issue.record("Expected the close-delimited body to wait for EOF")
            return
        }
        guard case let .complete(response, body) = parser.feed(Data(), closed: true) else {
            Issue.record("Expected EOF to complete the close-delimited response")
            return
        }
        #expect(response.statusCode == 200)
        #expect(String(decoding: body, as: UTF8.self) == "partial")
    }

    @Test
    func `Parser settles empty bodies without waiting for bytes`() throws {
        let url = try #require(URL(string: "https://api.example.com/data"))
        var zeroLength = PinnedHTTPResponseParser(responseURL: url, maxBodyBytes: 1024)
        guard case let .complete(zeroResponse, zeroBody) = zeroLength.feed(
            Data("HTTP/1.1 302 Found\r\nLocation: /next\r\nContent-Length: 0\r\n\r\n".utf8),
            closed: false
        )
        else {
            Issue.record("Expected a zero-length body to settle at the header block")
            return
        }
        #expect(zeroResponse.statusCode == 302)
        #expect(zeroResponse.value(forHTTPHeaderField: "Location") == "/next")
        #expect(zeroBody.isEmpty)

        var noContent = PinnedHTTPResponseParser(responseURL: url, maxBodyBytes: 1024)
        guard case let .complete(noContentResponse, noContentBody) = noContent.feed(
            Data("HTTP/1.1 204 No Content\r\n\r\n".utf8),
            closed: false
        )
        else {
            Issue.record("Expected a 204 to settle without a body")
            return
        }
        #expect(noContentResponse.statusCode == 204)
        #expect(noContentBody.isEmpty)
    }

    @Test
    func `Parser fails closed on ambiguous framing and truncation`() throws {
        let url = try #require(URL(string: "https://api.example.com/data"))
        var ambiguous = PinnedHTTPResponseParser(responseURL: url, maxBodyBytes: 1024)
        guard case .failed = ambiguous.feed(Data("HTTP/1.1 200 OK\r\nContent-Length: nope\r\n\r\n".utf8), closed: false) else {
            Issue.record("Expected a non-numeric Content-Length to fail closed")
            return
        }
        var truncated = PinnedHTTPResponseParser(responseURL: url, maxBodyBytes: 1024)
        guard case .failed = truncated.feed(Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhi".utf8), closed: true) else {
            Issue.record("Expected a short fixed-length body to fail closed")
            return
        }
    }
}
