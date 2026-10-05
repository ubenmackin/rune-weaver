// Rune Weaver Tools Tests — Web search parsing and caps plus fetch redirect, auth, and safety.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

/// Stubs and envelope shapes for the web suites.
private enum WebTestSupport {
    /// Ensurer stub that succeeds without touching the network.
    struct SucceedEnsurer: SearXNGEnsuring, Sendable {
        func ensure(browser _: BrowserConfig) async throws {}
    }

    /// Ensurer stub that fails closed with guidance.
    struct FailEnsurer: SearXNGEnsuring, Sendable {
        let message: String
        func ensure(browser _: BrowserConfig) async throws {
            throw NSError(domain: "RuneWeaverSearXNG", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    /// Search transport returning one canned body with a 200 response.
    struct StubSearchTransport: WebSearchTransport, Sendable {
        let body: Data
        let statusCode: Int
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let fallbackURL = URL(string: "http://127.0.0.1:8888/search") ?? URL(fileURLWithPath: "/")
            let response = HTTPURLResponse(
                url: request.url ?? fallbackURL,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ) ?? HTTPURLResponse(url: request.url ?? fallbackURL, mimeType: "application/json", expectedContentLength: 0, textEncodingName: nil)
            return (body, response)
        }
    }

    /// Fetch transport routing by URL for redirect-chain tests.
    struct RoutingFetchTransport: WebFetchTransport, Sendable {
        let handler: @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            try handler(request)
        }
    }

    /// Builds a 200 text response for a URL.
    static func okResponse(for url: URL, contentType: String = "text/html") -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": contentType])
            ?? HTTPURLResponse(url: url, mimeType: contentType, expectedContentLength: 0, textEncodingName: nil)
    }

    /// Builds a redirect response carrying a Location header.
    static func redirectResponse(for url: URL, location: String) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": location])
            ?? HTTPURLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
    }

    /// Builds a status-only response (401/403/415) for a URL.
    static func statusResponse(for url: URL, statusCode: Int, contentType: String = "text/html") -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: ["Content-Type": contentType])
            ?? HTTPURLResponse(url: url, mimeType: contentType, expectedContentLength: 0, textEncodingName: nil)
    }

    /// Decoded search envelope for assertions.
    struct SearchEnvelope: Decodable {
        let query: String
        let count: Int
        let results: [Hit]
        struct Hit: Decodable {
            let title: String
            let url: String
            let snippet: String
        }
    }

    /// Decoded fetch envelope for assertions.
    struct FetchEnvelope: Decodable {
        let status: String
        let finalUrl: String
        let url: String?
        let contentType: String?
        let content: String?
        let truncated: Bool?
        let suggestedNext: String?
        let reason: String?
    }

    /// SearXNG fixture with key drift: content vs snippet, url vs link.
    static func mixedKeysFixture() -> Data {
        Data("""
        {"results": [
          {"title": "First", "url": "https://example.com/a", "content": "Snippet A"},
          {"title": "Second", "link": "https://example.com/b", "snippet": "Snippet B"},
          {"title": "", "url": "https://example.com/c", "content": "Snippet C"},
          {"title": "No URL", "url": "", "content": "dropped"}
        ]}
        """.utf8)
    }

    /// Publishes canned public proof so fetch guards stay hermetic without touching the network.
    /// Production still fails closed on real DNS; the stub clears after each test so proof never leaks.
    /// Task-scoped binding keeps parallel suites isolated: the process-global
    /// holder is shared, so publishing here could redirect another suite's
    /// lookups while a concurrent clear could drop this suite's proof mid-test.
    static func stubPublicDNS() {
        ApiSSRFGuard.testDNSResolver = { _ in ["93.184.216.34"] }
    }

    /// Restores system resolution after a stubbed test.
    static func clearDNS() {
        ApiSSRFGuard.testDNSResolver = nil
    }

    /// Runs `body` with canned public proof bound to the current task.
    /// Task-scoped so parallel suites can neither replace nor clear this
    /// suite's proof mid-chain; matches `OutboundEgressSupervisorTests`
    /// and `ApiRequestPinnedDialTests` which bind per-task for the same reason.
    static func withPublicDNS<T>(_ body: () async throws -> T) async throws -> T {
        let proof: @Sendable (String) -> [String] = { _ in ["93.184.216.34"] }
        return try await ApiSSRFGuard.$taskTestDNSResolver.withValue(proof) {
            try await body()
        }
    }
}

@Suite("Web Search Parsing and Caps")
struct WebSearchParsingTests {
    @Test
    func `Parsing tolerates key drift and drops empty URLs`() throws {
        let hits = try WebSearchTool.parseSearchPayload(WebTestSupport.mixedKeysFixture())
        #expect(hits.count == 3)
        #expect(hits[0].title == "First")
        #expect(hits[0].url == "https://example.com/a")
        #expect(hits[0].snippet == "Snippet A")
        #expect(hits[1].url == "https://example.com/b")
        #expect(hits[1].snippet == "Snippet B")
        // Blank titles fall back to the URL so the row stays openable.
        #expect(hits[2].title == "https://example.com/c")
    }

    @Test
    func `Effective limit honors the smaller of caller and config`() {
        #expect(WebSearchTool.effectiveLimit(requested: 10, browserConfig: BrowserConfig(maxResults: 3)) == 3)
        #expect(WebSearchTool.effectiveLimit(requested: 3, browserConfig: BrowserConfig(maxResults: 10)) == 3)
        #expect(WebSearchTool.effectiveLimit(requested: 100, browserConfig: BrowserConfig(maxResults: 100)) == 50)
    }

    @Test
    func `Search caps hits at the browser max`() async throws {
        var rows: [[String: String]] = []
        for index in 0 ..< 8 {
            rows.append(["title": "Hit \(index)", "url": "https://example.com/\(index)", "content": "Snippet \(index)"])
        }
        let body = try JSONSerialization.data(withJSONObject: ["results": rows])
        let tool = WebSearchTool(
            browserConfig: BrowserConfig(searxngURL: "http://127.0.0.1:8888", searchTimeoutSeconds: 10, maxResults: 3),
            transport: WebTestSupport.StubSearchTransport(body: body, statusCode: 200),
            ensurer: WebTestSupport.SucceedEnsurer()
        )
        let output = try await tool.execute(
            input: ToolInput(toolName: "web.search", argumentsJSON: #"{"query":"caps","limit":8}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(!output.isError)
        let envelope = try JSONDecoder().decode(WebTestSupport.SearchEnvelope.self, from: Data(output.content.utf8))
        #expect(envelope.count == 3)
        #expect(envelope.results.count == 3)
        #expect(envelope.query == "caps")
    }

    @Test
    func `Search request targets the JSON endpoint`() {
        let request = WebSearchTool.searchRequest(baseURL: "http://127.0.0.1:8888", query: "hello world", timeout: 10)
        let urlString = request?.url?.absoluteString ?? ""
        #expect(urlString.contains("/search"))
        #expect(urlString.contains("format=json"))
        #expect(urlString.contains("q=hello"))
    }
}

/// Guards the failure taxonomy at the boundary the finding lived on: a runtime or
/// configuration failure must never present as an argument-syntax failure, while
/// genuine argument-shape and unknown-tool failures keep their distinct kinds.
@Suite("Web Search Error Taxonomy")
struct WebSearchTaxonomyTests {
    /// Builds a tool whose configured base URL can never form a request, so the
    /// configuration guard is the failure under test rather than a network path.
    private func configFailingTool() -> WebSearchTool {
        WebSearchTool(
            browserConfig: BrowserConfig(searxngURL: "not a url"),
            transport: WebTestSupport.StubSearchTransport(body: Data(), statusCode: 200),
            ensurer: WebTestSupport.SucceedEnsurer()
        )
    }

    @Test
    func `Configuration failure classifies as executionError through the bus`() async throws {
        let tool = configFailingTool()
        let output = try await tool.execute(
            input: ToolInput(toolName: "web.search", argumentsJSON: #"{"query":"taxonomy"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError)
        #expect(output.errorKind == .executionError)
        // The bus must preserve the tool's explicit kind instead of re-sniffing the
        // message wording, which is what masked this failure as invalid_syntax.
        let bus = ToolBus()
        await bus.register(tool: tool)
        let result = await bus.execute(
            toolCall: ToolInput(toolName: "web.search", argumentsJSON: #"{"query":"taxonomy"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(result.isError)
        #expect(result.errorKind == .executionError)
    }

    @Test
    func `Argument shape failure classifies as invalidSyntax`() async throws {
        // A JSON object that decodes but omits the required query keeps this on the
        // argument-validation path, so invalid_syntax stays reachable.
        let tool = WebSearchTool(
            browserConfig: BrowserConfig(),
            transport: WebTestSupport.StubSearchTransport(body: Data(), statusCode: 200),
            ensurer: WebTestSupport.SucceedEnsurer()
        )
        let output = try await tool.execute(
            input: ToolInput(toolName: "web.search", argumentsJSON: #"{"limit":5}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError)
        #expect(output.errorKind == .invalidSyntax)
    }

    @Test
    func `Unknown tool still classifies as invalidTool`() async {
        let bus = ToolBus()
        let result = await bus.execute(
            toolCall: ToolInput(toolName: "web.search", argumentsJSON: #"{"query":"x"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(result.isError)
        #expect(result.errorKind == .invalidTool)
    }
}

/// Serialized plus per-test task-scoped DNS stub: each fetch test binds its
/// canned public proof to its own task, so parallel suites can neither replace
/// nor clear the proof mid-chain and fail closed on real DNS.
@Suite("Web Fetch Safety and Outcomes", .serialized)
struct WebFetchSafetyTests {
    @Test
    func `Allowlist passes http and rejects smuggled schemes`() {
        #expect(WebURLSafety.isSafeUrl("https://example.com/page") == true)
        #expect(WebURLSafety.isSafeUrl("http://127.0.0.1:8888/search?q=x") == true)
        #expect(WebURLSafety.isSafeUrl("javascript:alert(1)") == false)
        #expect(WebURLSafety.isSafeUrl("JaVaScRiPt:alert(1)") == false)
        #expect(WebURLSafety.isSafeUrl("data:text/html,<h1>x</h1>") == false)
        #expect(WebURLSafety.isSafeUrl("vbscript:msgbox(1)") == false)
        #expect(WebURLSafety.isSafeUrl("file:///etc/passwd") == false)
        #expect(WebURLSafety.isSafeUrl("//example.com/page") == false)
        #expect(WebURLSafety.isSafeUrl("ftp://example.com/file") == false)
        #expect(WebURLSafety.isSafeUrl("") == false)
        #expect(WebURLSafety.isSafeUrl("not a url") == false)
        #expect(WebURLSafety.isSafeUrl("https://example.com/a b") == false)
    }

    @Test
    func `Redirect to unsafe target denies with finalUrl`() async throws {
        // Canned public proof keeps the stubbed redirect hermetic without a production bypass.
        try await WebTestSupport.withPublicDNS {
            let start = try #require(URL(string: "https://example.com/start"))
            let transport = WebTestSupport.RoutingFetchTransport { request in
                if request.url?.absoluteString == start.absoluteString {
                    return (Data(), WebTestSupport.redirectResponse(for: start, location: "javascript:alert(1)"))
                }
                throw NSError(domain: "test", code: 0)
            }
            let tool = WebFetchTool(browserConfig: BrowserConfig(), transport: transport)
            let output = try await tool.execute(
                input: ToolInput(toolName: "web.fetch", argumentsJSON: #"{"url":"https://example.com/start"}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError)
            let envelope = try JSONDecoder().decode(WebTestSupport.FetchEnvelope.self, from: Data(output.content.utf8))
            #expect(envelope.status == "unsupported")
            #expect(!envelope.finalUrl.isEmpty)
        }
    }

    @Test
    func `Redirect chain resolves relative locations and reports finalUrl`() async throws {
        // Canned public proof keeps the stubbed chain hermetic without a production bypass.
        try await WebTestSupport.withPublicDNS {
            let first = try #require(URL(string: "https://example.com/a"))
            let second = try #require(URL(string: "https://example.com/b"))
            let transport = WebTestSupport.RoutingFetchTransport { request in
                switch request.url?.absoluteString {
                case first.absoluteString:
                    return (Data(), WebTestSupport.redirectResponse(for: first, location: "/b"))
                case second.absoluteString:
                    let body = Data("<html><body><p>Hello world</p></body></html>".utf8)
                    return (body, WebTestSupport.okResponse(for: second))
                default:
                    throw NSError(domain: "test", code: 0)
                }
            }
            let tool = WebFetchTool(browserConfig: BrowserConfig(), transport: transport)
            let output = try await tool.execute(
                input: ToolInput(toolName: "web.fetch", argumentsJSON: #"{"url":"https://example.com/a"}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(!output.isError)
            let envelope = try JSONDecoder().decode(WebTestSupport.FetchEnvelope.self, from: Data(output.content.utf8))
            #expect(envelope.status == "ok")
            #expect(envelope.finalUrl == "https://example.com/b")
            #expect((envelope.content ?? "").contains("Hello world"))
        }
    }

    @Test
    func `Auth statuses return auth_required with browser hint`() async throws {
        // Canned public proof keeps stubbed auth responses hermetic without a production bypass.
        try await WebTestSupport.withPublicDNS {
            for code in [401, 403] {
                let page = try #require(URL(string: "https://example.com/private"))
                let transport = WebTestSupport.RoutingFetchTransport { _ in
                    (Data(), WebTestSupport.statusResponse(for: page, statusCode: code))
                }
                let tool = WebFetchTool(browserConfig: BrowserConfig(), transport: transport)
                let output = try await tool.execute(
                    input: ToolInput(toolName: "web.fetch", argumentsJSON: #"{"url":"https://example.com/private"}"#),
                    context: ToolContext(conversationID: UUID())
                )
                #expect(!output.isError)
                let envelope = try JSONDecoder().decode(WebTestSupport.FetchEnvelope.self, from: Data(output.content.utf8))
                #expect(envelope.status == "auth_required", "Expected auth_required for HTTP \(code)")
                #expect(envelope.suggestedNext == "browser.navigate")
                #expect(envelope.finalUrl == "https://example.com/private")
            }
        }
    }

    @Test
    func `Non-text payloads are unsupported with finalUrl`() async throws {
        // Canned public proof keeps the stubbed payload hermetic without a production bypass.
        try await WebTestSupport.withPublicDNS {
            let page = try #require(URL(string: "https://example.com/photo.png"))
            let transport = WebTestSupport.RoutingFetchTransport { _ in
                (Data(repeating: 0x89, count: 16), WebTestSupport.okResponse(for: page, contentType: "image/png"))
            }
            let tool = WebFetchTool(browserConfig: BrowserConfig(), transport: transport)
            let output = try await tool.execute(
                input: ToolInput(toolName: "web.fetch", argumentsJSON: #"{"url":"https://example.com/photo.png"}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(!output.isError)
            let envelope = try JSONDecoder().decode(WebTestSupport.FetchEnvelope.self, from: Data(output.content.utf8))
            #expect(envelope.status == "unsupported")
            #expect(envelope.finalUrl == "https://example.com/photo.png")
        }
    }

    @Test
    func `Too many redirects fail as unsupported`() async throws {
        // Canned public proof keeps the looping chain hermetic without a production bypass.
        try await WebTestSupport.withPublicDNS {
            let transport = WebTestSupport.RoutingFetchTransport { request in
                let fallback = try #require(URL(string: "https://example.com/0"))
                let url = request.url ?? fallback
                // Every hop redirects forward so the chain never terminates.
                let next = try #require(URL(string: "https://example.com/next"))
                return (Data(), WebTestSupport.redirectResponse(for: url, location: next.absoluteString))
            }
            let tool = WebFetchTool(browserConfig: BrowserConfig(), transport: transport)
            let output = try await tool.execute(
                input: ToolInput(toolName: "web.fetch", argumentsJSON: #"{"url":"https://example.com/0"}"#),
                context: ToolContext(conversationID: UUID())
            )
            let envelope = try JSONDecoder().decode(WebTestSupport.FetchEnvelope.self, from: Data(output.content.utf8))
            #expect(envelope.status == "unsupported")
            #expect(!envelope.finalUrl.isEmpty)
        }
    }

    @Test
    func `Extra origins exempt a private literal in the fetch guard`() async {
        // Private literals need no DNS proof, so no stub is required: the
        // literal stage alone decides with and without the extra set.
        let privateURL = "http://192.168.1.10/status"
        let denied = await WebFetchSSRFGuard.denyReasonAsync(
            for: privateURL,
            browserConfig: BrowserConfig(),
            mediaConfig: nil,
            extraAllowlistedOrigins: []
        )
        #expect(denied != nil)
        let allowed = await WebFetchSSRFGuard.denyReasonAsync(
            for: privateURL,
            browserConfig: BrowserConfig(),
            mediaConfig: nil,
            extraAllowlistedOrigins: ["192.168.1.10"]
        )
        #expect(allowed == nil)
        // Never-exempt targets stay refused even when the extra set names
        // them, so a policy exemption cannot launder metadata or link-local.
        let metadata = await WebFetchSSRFGuard.denyReasonAsync(
            for: "http://169.254.169.254/latest/meta-data",
            browserConfig: BrowserConfig(),
            mediaConfig: nil,
            extraAllowlistedOrigins: ["169.254.169.254"]
        )
        #expect(metadata != nil)
    }

    @Test
    func `Fetch initial guard honors extra origins end to end`() async throws {
        // Private literals settle without DNS, so the stub transport alone
        // keeps this hermetic: without the extra set the initial guard
        // rejects before the transport, while the merged set reaches it.
        let privateURLString = "http://192.168.1.10/status"
        let privateURL = try #require(URL(string: privateURLString))
        let transport = WebTestSupport.RoutingFetchTransport { request in
            let body = Data("<html><body><p>homelab ok</p></body></html>".utf8)
            return (body, WebTestSupport.okResponse(for: request.url ?? privateURL))
        }
        let deniedTool = WebFetchTool(browserConfig: BrowserConfig(), transport: transport)
        let deniedOutput = try await deniedTool.execute(
            input: ToolInput(toolName: "web.fetch", argumentsJSON: #"{"url":"http://192.168.1.10/status"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(deniedOutput.isError)
        let deniedEnvelope = try JSONDecoder().decode(WebTestSupport.FetchEnvelope.self, from: Data(deniedOutput.content.utf8))
        #expect(deniedEnvelope.status == "unsupported")
        let allowedTool = WebFetchTool(
            browserConfig: BrowserConfig(),
            transport: transport,
            extraAllowlistedOrigins: ["192.168.1.10"]
        )
        let allowedOutput = try await allowedTool.execute(
            input: ToolInput(toolName: "web.fetch", argumentsJSON: #"{"url":"http://192.168.1.10/status"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(!allowedOutput.isError)
        let allowedEnvelope = try JSONDecoder().decode(WebTestSupport.FetchEnvelope.self, from: Data(allowedOutput.content.utf8))
        #expect(allowedEnvelope.status == "ok")
        #expect((allowedEnvelope.content ?? "").contains("homelab ok"))
        // The factory threads the same set so a built web tool set honors
        // the exemption without callers reaching for the concrete type.
        let built = WebTools.makeTools(
            browserConfig: BrowserConfig(),
            fetchTransport: transport,
            extraAllowlistedOrigins: ["192.168.1.10"]
        )
        let builtFetch = try #require(built.first(where: { $0.name == "web.fetch" }))
        let builtOutput = try await builtFetch.execute(
            input: ToolInput(toolName: "web.fetch", argumentsJSON: #"{"url":"http://192.168.1.10/status"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(!builtOutput.isError)
    }
}

@Suite("Browser Config")
struct BrowserConfigTests {
    @Test
    func `Defaults match the documented loopback contract`() {
        let browser = BrowserConfig()
        #expect(browser.searxngURL == "http://127.0.0.1:8888")
        #expect(browser.searchTimeoutSeconds == 10)
        #expect(browser.maxResults == 10)
    }

    @Test
    func `Absent browser table keeps defaults and validates`() throws {
        let root = try TOMLParser.parse("[engine]\nname = \"Rune Weaver\"\n")
        let config = try RuneWeaverConfig(decoding: root)
        #expect(config.browser.searxngURL == BrowserConfig.defaultSearxngURL)
        try config.validate()
    }

    @Test
    func `Browser table decodes and round-trips`() throws {
        let text = """
        [browser]
        searxng_url = "http://127.0.0.1:8888"
        search_timeout_seconds = 12
        max_results = 7
        """
        let config = try RuneWeaverConfig(decoding: TOMLParser.parse(text))
        #expect(config.browser.searxngURL == "http://127.0.0.1:8888")
        #expect(config.browser.searchTimeoutSeconds == 12)
        #expect(config.browser.maxResults == 7)
        try config.validate()
        let rendered = config.renderTOML()
        let reparsed = try RuneWeaverConfig(decoding: TOMLParser.parse(rendered))
        #expect(reparsed.browser == config.browser)
    }

    @Test
    func `Out-of-range browser values fail closed`() throws {
        let text = """
        [browser]
        searxng_url = "http://127.0.0.1:8888"
        search_timeout_seconds = 0
        max_results = 10
        """
        let config = try RuneWeaverConfig(decoding: TOMLParser.parse(text))
        do {
            try config.validate()
            Issue.record("Expected validation error for search_timeout_seconds")
        } catch let error as ConfigError {
            guard case let .validationError(field, _) = error else {
                Issue.record("Expected validationError, got \(error)")
                return
            }
            #expect(field == "browser.search_timeout_seconds")
        }
    }
}

@Suite("SearXNG Runtime Search")
struct SearXNGEnsurerRuntimeTests {
    @Test
    func `Minimal PATH still finds a fallback install`() {
        // A GUI-launched process often carries a minimal PATH without
        // Homebrew; the fallback keeps the standard install discoverable so
        // the cascade never misses a present binary.
        let minimalPATH = "/usr/bin:/bin"
        let directories = SearXNGEnsurer.runtimeSearchDirectories(pathValue: minimalPATH)
        #expect(Array(directories.prefix(2)) == ["/usr/bin", "/bin"])
        #expect(directories.contains("/opt/homebrew/bin"))
        #expect(directories.contains("/usr/local/bin"))
        let resolved = SearXNGEnsurer.resolveRuntimeURL(
            pathValue: minimalPATH,
            isExecutable: { $0 == "/opt/homebrew/bin/container" }
        )
        #expect(resolved?.path == "/opt/homebrew/bin/container")
    }

    @Test
    func `Missing runtime returns nil while naming where it looked`() {
        // A miss preserves the fail-closed contract (nil, no Docker probe)
        // while the directory list lets the banner explain the miss alone.
        let directories = SearXNGEnsurer.runtimeSearchDirectories(pathValue: "/usr/bin:/bin")
        let resolved = SearXNGEnsurer.resolveRuntimeURL(pathValue: "/usr/bin:/bin", isExecutable: { _ in false })
        #expect(resolved == nil)
        #expect(directories.contains("/opt/homebrew/bin"))
        #expect(directories.contains("/usr/local/bin"))
        let guidance = SearXNGEnsurer.installGuidanceMessage(searchedDirectories: directories)
        #expect(guidance.contains("/opt/homebrew/bin"))
        #expect(guidance.contains("/usr/local/bin"))
    }

    @Test
    func `Runtime miss guidance carries a single install pointer`() {
        // One miss carries one cause plus one command: the install link
        // appears exactly once and the engine-unreachable hatch never wraps
        // it, so callers surface a single actionable message.
        let directories = ["/usr/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        let message = SearXNGEnsurer.runtimeNotFoundError(searchedDirectories: directories).localizedDescription
        let installHits = message.components(separatedBy: SearXNGEnsurer.appleContainerInstallURL).count - 1
        #expect(installHits == 1)
        #expect(!message.lowercased().contains("not reachable"))
        #expect(!message.contains("searxng-up.sh"))
        #expect(message.contains("/opt/homebrew/bin"))
    }

    @Test
    func `Detonation lookup shares the fallback ordering`() {
        // Detonation and search must converge on the same install: a minimal
        // PATH plus a stubbed Homebrew binary resolves on both sides, and a
        // PATH that already carries a fallback probes it once with PATH first.
        let minimalPATH = "/usr/bin:/bin"
        let coreDirectories = ContainerMachineManager.runtimeSearchDirectories(pathValue: minimalPATH)
        #expect(coreDirectories.contains("/opt/homebrew/bin"))
        #expect(coreDirectories.contains("/usr/local/bin"))
        let coreResolved = ContainerMachineManager.resolveRuntimeURL(
            runtime: "container",
            pathValue: minimalPATH,
            isExecutable: { $0 == "/opt/homebrew/bin/container" }
        )
        #expect(coreResolved?.path == "/opt/homebrew/bin/container")
        let crowded = SearXNGEnsurer.runtimeSearchDirectories(pathValue: "/opt/homebrew/bin:/usr/bin")
        #expect(crowded.filter { $0 == "/opt/homebrew/bin" }.count == 1)
        #expect(crowded.first == "/opt/homebrew/bin")
    }

    @Test
    func `Fresh runs track the latest image`() {
        // Deliberate tracking keeps fresh installs on upstream without a version
        // bump; reproducibility pins via SEARXNG_IMAGE instead of a baked tag.
        #expect(SearXNGEnsurer.containerImage == "searxng/searxng:latest")
    }

    @Test
    func `Unreachable banner holds terminal cause plus one remediation`() {
        // Full cascade chains stay in diagnostics for warn logs plus collapsed
        // UI; the banner holds one generic cause plus one hatch command so each
        // failure renders once without nesting stage fragments. The trailing
        // watch fragment mirrors the live readiness backstop.
        let waitingTail = SearXNGEnsurer.failureMessage(stage: "waiting", exitCode: nil, output: nil, timedOut: true, timeoutSeconds: SearXNGEnsurer.readinessWatchTimeoutSeconds)
        let chained = "stage: daemon, exit: 1, detail: xpc down; stage: run, exit: 1, detail: pull failed; \(waitingTail)"
        let error = SearXNGEnsurer.unreachableError(baseURL: "http://127.0.0.1:8888", detail: chained)
        let banner = error.localizedDescription
        #expect(!banner.contains("stage:"))
        #expect(banner.components(separatedBy: "scripts/searxng-up.sh").count - 1 == 1)
        #expect(!banner.contains("container start"))
        let chainedDiagnostics = SearXNGEnsurer.diagnostics(from: error) ?? ""
        #expect(chainedDiagnostics.contains("stage:"))
        #expect(chainedDiagnostics == chained)
    }

    @Test
    func `Pull failures carry generic guidance with raw tail in diagnostics`() {
        // Run output never leaks raw registry text into the banner; the run
        // banner names only the run cause while pull wording lives solely on
        // the pull-specific banners, with the capped tail kept in diagnostics.
        let runDetail = SearXNGEnsurer.failureMessage(stage: "run", exitCode: 1, output: "pull access denied for searxng", timedOut: false)
        let error = SearXNGEnsurer.unreachableError(baseURL: "http://127.0.0.1:8888", detail: runDetail)
        let banner = error.localizedDescription
        #expect(banner.contains("run failed"))
        #expect(!banner.lowercased().contains("pull"))
        #expect(banner.contains("scripts/searxng-up.sh"))
        #expect(!banner.contains("stage:"))
        let raw = SearXNGEnsurer.diagnostics(from: error) ?? ""
        #expect(raw.contains("stage: run"))
        #expect(SearXNGEnsurer.pullFailedBanner().lowercased().contains("pull"))
        #expect(SearXNGEnsurer.pullTimeoutBanner().lowercased().contains("pull"))
    }

    @Test
    func `Timeout banner names reachability with one hatch command`() {
        // Waiting-watch backstop (no terminal crash to name) renders the
        // backstop banner plus the single hatch, with the timed-out waiting
        // fragment kept in diagnostics rather than nested as a second wrapper.
        let baseURL = "http://127.0.0.1:8888"
        let waitingDetail = SearXNGEnsurer.failureMessage(stage: "waiting", exitCode: nil, output: nil, timedOut: true, timeoutSeconds: SearXNGEnsurer.readinessWatchTimeoutSeconds)
        let error = SearXNGEnsurer.unreachableError(baseURL: baseURL, detail: waitingDetail)
        let banner = error.localizedDescription
        #expect(banner == SearXNGEnsurer.readinessBackstopBanner(baseURL: baseURL))
        #expect(banner.components(separatedBy: "scripts/searxng-up.sh").count - 1 == 1)
        #expect(!banner.contains("stage:"))
        #expect((SearXNGEnsurer.diagnostics(from: error) ?? "").contains("stage: waiting"))
        #expect((SearXNGEnsurer.diagnostics(from: error) ?? "").contains("timed out after \(Int(SearXNGEnsurer.readinessWatchTimeoutSeconds))s"))
    }

    @Test
    func `Ensure report threads banner plus diagnostics separately`() {
        // The non-throwing report keeps the trimmed banner apart from the chained
        // diagnostics so routes can warn with both while inline slots show one.
        // The waiting fragment mirrors the live watch backstop.
        let waitingDiagnostics = SearXNGEnsurer.failureMessage(
            stage: "waiting", exitCode: nil, output: nil, timedOut: true, timeoutSeconds: SearXNGEnsurer.readinessWatchTimeoutSeconds
        )
        let report = SearXNGEnsurer.EnsureReport(
            reachable: false, started: false, message: "banner", diagnostics: waitingDiagnostics
        )
        #expect(report.message == "banner")
        #expect(report.diagnostics?.contains("stage: waiting") == true)
        let blanked = SearXNGEnsurer.EnsureReport(reachable: false, started: false, message: "  ", diagnostics: "  ")
        #expect(blanked.message == nil)
        #expect(blanked.diagnostics == nil)
    }

    @Test
    func `DNS resolution timeout is five seconds`() {
        #expect(ApiSSRFGuard.dnsResolutionTimeoutSeconds == 5.0)
    }

    @Test
    func `Allowlisted origins extracts auto service origins`() {
        // The runtime exemption set carries the auto service
        // origins (`searxng_url`, enabled media LAN URLs, LLM server URLs).
        // Owner grants arrive via the snapshot's `local_exemptions`, unioned
        // by callers.
        let browser = BrowserConfig(searxngURL: "http://127.0.0.1:8888")
        let media = MediaConfig(
            sonarr: ArrInstanceConfig(url: "http://sonarr.local:8989"),
            radarr: ArrInstanceConfig(url: "http://10.0.0.2:7878")
        )
        let origins = ApiSSRFGuard.allowlistedOrigins(
            browserConfig: browser,
            mediaConfig: media,
            llmServerURLs: ["http://127.0.0.1:11434"]
        )
        #expect(origins.contains("127.0.0.1:8888"))
        #expect(origins.contains("127.0.0.1:11434"))
        #expect(origins.contains("sonarr.local:8989"))
        #expect(origins.contains("sonarr.local"))
        #expect(origins.contains("10.0.0.2:7878"))
        #expect(origins.contains("10.0.0.2"))
        #expect(ApiSSRFGuard.denyReason(for: "http://192.168.1.120:8080/status", browserConfig: browser, mediaConfig: media) != nil)
        #expect(ApiSSRFGuard.denyReason(for: "http://192.168.1.120:8080/status", allowlistedOrigins: origins.union(["192.168.1.*"])) == nil)
    }

    @Test
    func `Explicit owner exemptions authorize matching hosts while link-local stays denied`() {
        let browser = BrowserConfig()
        let explicit: Set = ["*.homelab.local", "192.168.1.*"]
        #expect(ApiSSRFGuard.vettedIPListDenial(
            host: "nas.homelab.local", addresses: ["192.168.1.10"], origins: explicit
        ) == nil)
        // Rebinding an allowlisted name to link-local stays denied.
        #expect(ApiSSRFGuard.vettedIPListDenial(
            host: "nas.homelab.local", addresses: ["169.254.169.254"], origins: explicit
        ) != nil)
        // Without an owner exemption, private literal refuses.
        #expect(ApiSSRFGuard.denyReason(for: "http://192.168.1.120:8080/status", browserConfig: browser) != nil)
        // Different IP not matched
        #expect(ApiSSRFGuard.denyReason(for: "http://10.0.0.1/admin", browserConfig: browser) != nil)
        // Link-local is never allowed
        #expect(ApiSSRFGuard.denyReason(for: "http://169.254.169.254/latest/meta-data", browserConfig: browser) != nil)
    }

    @Test
    func `CGNAT metadata and special-purpose literals are refused so the runtime table matches the verifier`() {
        let browser = BrowserConfig()
        // Alibaba's metadata service answers in CGNAT shared space
        // (`100.100.100.200`), which the policy verifier already lists as a
        // forbidden credential target; the runtime guard must reach the same
        // verdict for the literal and for every obfuscated spelling of it.
        let denied = [
            "http://100.100.100.200/latest/meta-data",
            "http://100.64.0.1/",
            "http://100.127.255.255:8080/",
            "http://0x64.0x64.0x64.0xc8/latest/meta-data",
            "http://1684301000/latest/meta-data",
            "http://192.0.2.10/",
            "http://198.18.0.1/",
            "http://203.0.113.5/",
            "http://224.0.0.1/",
            "http://240.0.0.1/"
        ]
        for url in denied {
            #expect(ApiSSRFGuard.denyReason(for: url, browserConfig: browser) != nil, "expected a refusal for \(url)")
        }
        // Only `100.64.0.0/10` widened: its boundary neighbors are ordinary
        // public unicast and stay dialable.
        #expect(!ApiSSRFGuard.isSensitiveIPv4Value(0x643F_FFFF)) // 100.63.255.255
        #expect(!ApiSSRFGuard.isSensitiveIPv4Value(0x6480_0000)) // 100.128.0.0
        for url in ["http://100.63.255.255/", "http://100.128.0.0/", "http://93.184.216.34/"] {
            #expect(ApiSSRFGuard.denyReason(for: url, browserConfig: browser) == nil, "expected \(url) to stay dialable")
        }
    }

    @Test
    func `Resolved metadata literal stays refused through an allowlisted name`() {
        // Metadata refusals ignore allowlist exemptions, so a rebinding name
        // cannot launder the CGNAT metadata literal behind an allowed suffix.
        let origins: Set = ["nas.homelab.local", "nas.homelab.local:443"]
        #expect(ApiSSRFGuard.vettedIPListDenial(
            host: "nas.homelab.local", addresses: ["100.100.100.200"], origins: origins
        ) != nil)
        // The same allowlisted name still proves ordinary private resolutions.
        #expect(ApiSSRFGuard.vettedIPListDenial(
            host: "nas.homelab.local", addresses: ["192.168.1.10"], origins: origins
        ) == nil)
    }

    @Test
    func `Universal wildcard never authorizes a host`() {
        #expect(ApiSSRFGuard.isHostAllowed("example.com", origins: ["*"]) == false)
        #expect(ApiSSRFGuard.isHostAllowed("192.168.1.10", origins: ["*.*"]) == false)
        #expect(ApiSSRFGuard.isHostAllowed("example.com", origins: ["*.example.com"]) == true)
    }

    @Test
    func `Port-qualified wildcard stays denied while plain wildcard matches`() {
        // A port-qualified wildcard could never match a port-less host, so it
        // fails closed at validation instead of lingering as a dead entry.
        #expect(AllowedOriginPattern.classifyWildcard("*.example.com:8080") == .invalidShape)
        #expect(ApiSSRFGuard.isHostAllowed("foo.example.com", origins: ["*.example.com:8080"]) == false)
        #expect(ApiSSRFGuard.isHostAllowed("foo.example.com", origins: ["*.example.com"]) == true)
    }

    @Test
    func `Media servers are auto-allowed without double entry`() {
        let browser = BrowserConfig()
        let media = MediaConfig(
            sonarr: ArrInstanceConfig(url: "http://192.168.1.50:8989")
        )
        // Without media config, 192.168.1.50 is denied
        #expect(ApiSSRFGuard.denyReason(for: "http://192.168.1.50:8989/api/v3", browserConfig: browser) != nil)
        // With media config, Sonarr is auto-allowed
        #expect(ApiSSRFGuard.denyReason(for: "http://192.168.1.50:8989/api/v3", browserConfig: browser, mediaConfig: media) == nil)
    }
}

@Suite("SSRF IPv4-Embedded IPv6 Spellings")
struct SSRFEmbeddedIPv4SpellingTests {
    /// Origin set allowlisting one public name, so decoded targets can be
    /// checked against the same exemption path their dotted twins use.
    private static let allowlistedName: Set<String> = ["api.example.com", "api.example.com:443"]

    @Test
    func `NAT64 6to4 and IPv4-compatible hextet literals are refused`() {
        let browser = BrowserConfig()
        // Each hextet spelling embeds a metadata, link-local, private, or
        // loopback address, so none may pass as a plain public IPv6 literal.
        let deniedURLs = [
            "http://[64:ff9b::a9fe:a9fe]/latest/meta-data", // NAT64 → 169.254.169.254
            "http://[64:ff9b::a00:1]/", // NAT64 → 10.0.0.1
            "http://[64:ff9b::7f00:1]/", // NAT64 → 127.0.0.1
            "http://[64:ff9b:1:a9fe:a9:fe00::]/", // local-use NAT64 → 169.254.169.254
            "http://[2002:a9fe:a9fe::]/", // 6to4 → 169.254.169.254
            "http://[2002:a00:1::]/", // 6to4 → 10.0.0.1
            "http://[::a9fe:a9fe]/", // IPv4-compatible → 169.254.169.254
            "http://[::7f00:1]/", // IPv4-compatible → 127.0.0.1
            "http://[::a00:1]/" // IPv4-compatible → 10.0.0.1
        ]
        for url in deniedURLs {
            #expect(ApiSSRFGuard.denyReason(for: url, browserConfig: browser) != nil, "expected a refusal for \(url)")
        }
    }

    @Test
    func `Dotted and hextet spellings of an embedded address decide alike`() {
        // Regression: `[64:ff9b::169.254.169.254]` was denied while the
        // equivalent hextet spelling was waved through as a public literal.
        // Metadata and link-local targets are never exempt, so those spellings
        // must refuse together, and like the direct dotted twin they decode to,
        // under any browser config.
        let browser = BrowserConfig()
        let neverExemptPairs = [
            ("http://[64:ff9b::169.254.169.254]/", "http://[64:ff9b::a9fe:a9fe]/", "http://169.254.169.254/"),
            ("http://[::169.254.169.254]/", "http://[::a9fe:a9fe]/", "http://169.254.169.254/")
        ]
        for (dotted, hextet, twin) in neverExemptPairs {
            #expect(ApiSSRFGuard.denyReason(for: dotted, browserConfig: browser) != nil, "expected a refusal for \(dotted)")
            #expect(ApiSSRFGuard.denyReason(for: hextet, browserConfig: browser) != nil, "expected a refusal for \(hextet)")
            #expect(ApiSSRFGuard.denyReason(for: twin, browserConfig: browser) != nil, "expected a refusal for \(twin)")
        }
        // Loopback is exemptible rather than never-dialable, and the default
        // searxng origin lives on `127.0.0.1`, so every mapped spelling must
        // inherit the decision of the direct loopback twin it decodes to.
        let loopbackTwin = "http://127.0.0.1/"
        let mappedLoopbackSpellings = ["http://[::ffff:127.0.0.1]/", "http://[::ffff:7f00:1]/"]
        let exemptedTwin = ApiSSRFGuard.denyReason(for: loopbackTwin, browserConfig: browser)
        #expect(exemptedTwin == nil, "expected the configured searxng loopback origin to exempt \(loopbackTwin)")
        for spelling in mappedLoopbackSpellings {
            #expect(ApiSSRFGuard.denyReason(for: spelling, browserConfig: browser) == nil, "expected \(spelling) to decide like its dotted twin \(loopbackTwin)")
        }
        // With the search origin off loopback the same spellings refuse
        // together: neither embedded form launders a verdict its dotted twin
        // would not get.
        let publicSearch = BrowserConfig(searxngURL: "https://search.example.com")
        let refusedTwin = ApiSSRFGuard.denyReason(for: loopbackTwin, browserConfig: publicSearch)
        #expect(refusedTwin != nil, "expected \(loopbackTwin) to refuse without a loopback origin")
        for spelling in mappedLoopbackSpellings {
            #expect(ApiSSRFGuard.denyReason(for: spelling, browserConfig: publicSearch) != nil, "expected \(spelling) to decide like its dotted twin \(loopbackTwin)")
        }
    }

    @Test
    func `Decoded sensitive targets refuse before the public-literal fast path`() {
        // The literal fast path exists to skip DNS, not to authorize a
        // decoded address: the range verdict runs first.
        #expect(ApiSSRFGuard.isIPAddressLiteral("64:ff9b::a9fe:a9fe") == true)
        #expect(ApiSSRFGuard.denyReason(for: "http://[64:ff9b::6464:64c8]/", browserConfig: BrowserConfig()) != nil)
    }

    @Test
    func `Public IPv6 destinations stay dialable`() {
        let browser = BrowserConfig()
        let allowedURLs = [
            "http://[2606:4700:4700::1111]/", // native public
            "http://[64:ff9b::5db8:d822]/", // NAT64 → 93.184.216.34
            "http://[64:ff9b:1:5db8:d8:2200::]/", // local-use NAT64 → 93.184.216.34
            "http://[2002:5db8:d822::]/", // 6to4 → 93.184.216.34
            "http://[::ffff:5db8:d822]/" // mapped → 93.184.216.34
        ]
        for url in allowedURLs {
            #expect(ApiSSRFGuard.denyReason(for: url, browserConfig: browser) == nil, "expected \(url) to stay dialable")
        }
    }

    @Test
    func `Resolved embedded never-exempt targets cannot ride an allowlisted name`() {
        // Regression: a *.example.com name whose DNS64 answer is the NAT64
        // spelling of the metadata endpoint passed vettedIPListDenial.
        let neverExempt = [
            "64:ff9b::a9fe:a9fe", // NAT64 → 169.254.169.254
            "64:ff9b::169.254.169.254", // dotted NAT64 twin
            "64:ff9b:1:a9fe:a9:fe00::", // local-use NAT64 → 169.254.169.254
            "2002:a9fe:a9fe::", // 6to4 → 169.254.169.254
            "::a9fe:a9fe", // IPv4-compatible → 169.254.169.254
            "64:ff9b::6464:64c8" // NAT64 → 100.100.100.200 metadata literal
        ]
        for address in neverExempt {
            let denial = ApiSSRFGuard.vettedIPListDenial(host: "api.example.com", addresses: [address], origins: Self.allowlistedName)
            #expect(denial != nil, "expected a refusal for embedded address \(address)")
        }
    }

    @Test
    func `Resolved private and public embedded addresses follow their dotted twins`() {
        // The exemption semantics stay spelling-independent: a private
        // embedded address rides an allowlisted name exactly like its dotted
        // twin, and a public embedded address stays dialable.
        let twins = [
            "64:ff9b::c0a8:178", // NAT64 → 192.168.1.120
            "192.168.1.120", // dotted twin
            "64:ff9b::a00:1", // NAT64 → 10.0.0.1
            "10.0.0.1" // dotted twin
        ]
        for address in twins {
            let denial = ApiSSRFGuard.vettedIPListDenial(host: "api.example.com", addresses: [address], origins: Self.allowlistedName)
            #expect(denial == nil, "expected the allowlisted-name exemption for '\(address)'")
        }
        let publicAddresses = [
            "64:ff9b::5db8:d822", // NAT64 → 93.184.216.34
            "64:ff9b:1:5db8:d8:2200::", // local-use NAT64 → 93.184.216.34
            "2002:5db8:d822::", // 6to4 → 93.184.216.34
            "2606:4700:4700::1111" // native public
        ]
        for address in publicAddresses {
            let denial = ApiSSRFGuard.vettedIPListDenial(host: "example.com", addresses: [address])
            #expect(denial == nil, "expected '\(address)' to stay dialable")
        }
    }
}

@Suite("SSRF Local Access Classification")
struct LocalAccessClassificationTests {
    /// Reason carried by a refusal-shaped verdict, or nil for grant verdicts.
    private static func reason(_ verdict: LocalAccessVerdict) -> String? {
        switch verdict {
        case .publicDestination, .localNetwork:
            nil
        case let .neverDialable(reason), let .unresolved(reason):
            reason
        }
    }

    /// Whether the verdict refuses even under an exemption.
    private static func isNeverDialable(_ verdict: LocalAccessVerdict) -> Bool {
        if case .neverDialable = verdict {
            return true
        }
        return false
    }

    /// Whether the verdict fails closed without a proven address.
    private static func isUnresolved(_ verdict: LocalAccessVerdict) -> Bool {
        if case .unresolved = verdict {
            return true
        }
        return false
    }

    /// Bare-host URL shape the guard's URL APIs need, bracketing IPv6 literals.
    private static func urlString(forHost host: String) -> String {
        let cleaned = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "http:///" }
        if cleaned.contains(":"), !cleaned.hasPrefix("[") {
            return "http://[\(cleaned)]/"
        }
        return "http://\(cleaned)/"
    }

    @Test
    func `Literal matrix classifies public local and never-dialable spellings`() async {
        let publicHosts = [
            "93.184.216.34",
            "8.8.8.8",
            "2606:4700:4700::1111",
            "64:ff9b::5db8:d822"
        ]
        for host in publicHosts {
            let verdict = await ApiSSRFGuard.classifyLocalAccess(forHost: host)
            #expect(verdict == .publicDestination, "expected a public verdict for \(host), got \(verdict)")
        }
        // Loopback, private, CGNAT, reserved, and unique-local stay in the
        // exemption-eligible local bucket rather than never-dialable.
        let localHosts = [
            "127.0.0.1",
            "::1",
            "0.0.0.0",
            "localhost",
            "10.0.0.1",
            "172.16.0.1",
            "192.168.1.10",
            "100.64.0.1",
            "198.18.0.1",
            "240.0.0.1",
            "fd00::1",
            "64:ff9b::a00:1"
        ]
        for host in localHosts {
            let verdict = await ApiSSRFGuard.classifyLocalAccess(forHost: host)
            #expect(verdict == .localNetwork, "expected a local-network verdict for \(host), got \(verdict)")
        }
        // Metadata, link-local, and embedded translations of either refuse
        // before any exemption can apply.
        let neverHosts = [
            "metadata.google.internal",
            "metadata",
            "100.100.100.200",
            "169.254.169.254",
            "fe80::1",
            "64:ff9b::a9fe:a9fe",
            "64:ff9b:1:a9fe:a9:fe00::",
            "2002:a9fe:a9fe::",
            "::a9fe:a9fe"
        ]
        for host in neverHosts {
            let verdict = await ApiSSRFGuard.classifyLocalAccess(forHost: host)
            #expect(Self.isNeverDialable(verdict), "expected a never-dialable verdict for \(host), got \(verdict)")
            #expect(Self.reason(verdict) != nil, "expected a refusal reason for \(host)")
        }
    }

    @Test
    func `Hostname matrix proves answers through the task-scoped resolver`() async {
        let answers: [String: [String]] = [
            "airflow.int.volcrypt.com": ["10.100.5.34"],
            "public.example.com": ["93.184.216.34", "93.184.216.35"],
            "mixed.example.com": ["93.184.216.34", "10.0.0.5"],
            "loopback.example.com": ["127.0.0.1"],
            "link-local.example.com": ["169.254.169.254"],
            "metadata-literal.example.com": ["100.100.100.200"],
            "embedded.example.com": ["64:ff9b::a9fe:a9fe"],
            "empty.example.com": []
        ]
        let resolver: @Sendable (String) -> [String] = { answers[$0] ?? [] }
        await ApiSSRFGuard.$taskTestDNSResolver.withValue(resolver) {
            let airflow = await ApiSSRFGuard.classifyLocalAccess(forHost: "airflow.int.volcrypt.com")
            #expect(airflow == .localNetwork, "expected the homelab answer to classify local, got \(airflow)")
            let publicVerdict = await ApiSSRFGuard.classifyLocalAccess(forHost: "public.example.com")
            #expect(publicVerdict == .publicDestination, "expected a public answer to stay public, got \(publicVerdict)")
            // One sensitive address makes the whole name local: a host that
            // answers both must never be stored as public-only.
            let mixed = await ApiSSRFGuard.classifyLocalAccess(forHost: "mixed.example.com")
            #expect(mixed == .localNetwork, "expected a mixed answer to classify local, got \(mixed)")
            let loopback = await ApiSSRFGuard.classifyLocalAccess(forHost: "loopback.example.com")
            #expect(loopback == .localNetwork, "expected a loopback answer to classify local, got \(loopback)")
            for host in ["link-local.example.com", "metadata-literal.example.com", "embedded.example.com"] {
                let verdict = await ApiSSRFGuard.classifyLocalAccess(forHost: host)
                #expect(Self.isNeverDialable(verdict), "expected never-dialable for \(host), got \(verdict)")
            }
            let empty = await ApiSSRFGuard.classifyLocalAccess(forHost: "empty.example.com")
            #expect(Self.isUnresolved(empty), "expected an empty answer to fail closed, got \(empty)")
            let unmapped = await ApiSSRFGuard.classifyLocalAccess(forHost: "unmapped.example.com")
            #expect(Self.isUnresolved(unmapped), "expected an unknown host to fail closed, got \(unmapped)")
        }
    }

    @Test
    func `Blank hosts fail closed to unresolved`() async {
        let blank = await ApiSSRFGuard.classifyLocalAccess(forHost: "")
        #expect(Self.isUnresolved(blank), "expected an empty host to fail closed, got \(blank)")
        let whitespace = await ApiSSRFGuard.classifyLocalAccess(forHost: "   ")
        #expect(Self.isUnresolved(whitespace), "expected a blank host to fail closed, got \(whitespace)")
    }

    @Test
    func `A wedged resolver times out to unresolved`() async {
        // Block the bounded pool well past the fail-closed budget; the
        // classifier must answer unresolved instead of waiting for the wedged
        // lookup.
        let resolver: @Sendable (String) -> [String] = { _ in
            Thread.sleep(forTimeInterval: ApiSSRFGuard.dnsResolutionTimeoutSeconds + 5)
            return ["93.184.216.34"]
        }
        let verdict = await ApiSSRFGuard.$taskTestDNSResolver.withValue(resolver) {
            await ApiSSRFGuard.classifyLocalAccess(forHost: "wedged.example.com")
        }
        #expect(Self.isUnresolved(verdict), "expected the timeout to fail closed, got \(verdict)")
    }

    @Test
    func `Verdicts agree with the unexempted guard refusal`() async {
        let answers: [String: [String]] = [
            "airflow.int.volcrypt.com": ["10.100.5.34"],
            "public.example.com": ["93.184.216.34"],
            "mixed.example.com": ["93.184.216.34", "10.0.0.5"],
            "loopback.example.com": ["127.0.0.1"],
            "blocked.example.com": ["169.254.169.254"],
            "empty.example.com": []
        ]
        let resolver: @Sendable (String) -> [String] = { answers[$0] ?? [] }
        let hosts = [
            "airflow.int.volcrypt.com",
            "public.example.com",
            "mixed.example.com",
            "loopback.example.com",
            "blocked.example.com",
            "empty.example.com",
            "93.184.216.34",
            "10.0.0.1",
            "127.0.0.1",
            "169.254.169.254",
            "fe80::1",
            "metadata.google.internal",
            "100.100.100.200",
            "64:ff9b::a9fe:a9fe",
            "fd00::1",
            "2606:4700:4700::1111",
            ""
        ]
        await ApiSSRFGuard.$taskTestDNSResolver.withValue(resolver) {
            for host in hosts {
                let verdict = await ApiSSRFGuard.classifyLocalAccess(forHost: host)
                let refusal = await ApiSSRFGuard.denyReasonAsync(
                    for: Self.urlString(forHost: host),
                    allowlistedOrigins: []
                )
                if verdict == .publicDestination {
                    #expect(refusal == nil, "expected no guard refusal for public host '\(host)'")
                } else {
                    #expect(refusal != nil, "expected a guard refusal for '\(host)' with verdict \(verdict)")
                }
            }
        }
    }

    @Test
    func `Refusal-shaped verdicts reuse the guard wording`() async {
        let answers: [String: [String]] = [
            "blocked.example.com": ["169.254.169.254"],
            "empty.example.com": []
        ]
        let resolver: @Sendable (String) -> [String] = { answers[$0] ?? [] }
        let pairs: [(host: String, url: String)] = [
            ("metadata.google.internal", "http://metadata.google.internal/"),
            ("100.100.100.200", "http://100.100.100.200/"),
            ("169.254.169.254", "http://169.254.169.254/"),
            ("fe80::1", "http://[fe80::1]/"),
            ("64:ff9b::a9fe:a9fe", "http://[64:ff9b::a9fe:a9fe]/"),
            ("blocked.example.com", "http://blocked.example.com/"),
            ("empty.example.com", "http://empty.example.com/")
        ]
        await ApiSSRFGuard.$taskTestDNSResolver.withValue(resolver) {
            for pair in pairs {
                let verdict = await ApiSSRFGuard.classifyLocalAccess(forHost: pair.host)
                let denial = await ApiSSRFGuard.denyReasonAsync(for: pair.url, allowlistedOrigins: [])
                #expect(Self.reason(verdict) == denial, "expected shared wording for '\(pair.host)': verdict \(verdict) vs denial \(denial ?? "nil")")
            }
        }
    }
}
