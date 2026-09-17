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

@Suite("Web Fetch Safety and Outcomes")
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

    @Test
    func `Redirect chain resolves relative locations and reports finalUrl`() async throws {
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

    @Test
    func `Auth statuses return auth_required with browser hint`() async throws {
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

    @Test
    func `Non-text payloads are unsupported with finalUrl`() async throws {
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

    @Test
    func `Too many redirects fail as unsupported`() async throws {
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
        // failure renders once without nesting stage fragments.
        let chained = "stage: daemon, exit: 1, detail: xpc down; stage: run, exit: 1, detail: pull failed; stage: poll, (timed out after 10s)"
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
        // Poll-only timeouts (external bases, flap retries) render as not
        // reachable plus the single hatch, with the timed-out fragment kept in
        // diagnostics rather than nested as a second guidance wrapper.
        let pollDetail = SearXNGEnsurer.failureMessage(stage: "poll", exitCode: nil, output: nil, timedOut: true, timeoutSeconds: 10)
        let error = SearXNGEnsurer.unreachableError(baseURL: "http://127.0.0.1:8888", detail: pollDetail)
        let banner = error.localizedDescription
        #expect(banner.lowercased().contains("not reachable"))
        #expect(banner.components(separatedBy: "scripts/searxng-up.sh").count - 1 == 1)
        #expect(!banner.contains("stage:"))
        #expect((SearXNGEnsurer.diagnostics(from: error) ?? "").contains("stage: poll"))
    }

    @Test
    func `Ensure report threads banner plus diagnostics separately`() {
        // The non-throwing report keeps the trimmed banner apart from the chained
        // diagnostics so routes can warn with both while inline slots show one.
        let report = SearXNGEnsurer.EnsureReport(reachable: false, started: false, message: "banner", diagnostics: "stage: poll, (timed out after 10s)")
        #expect(report.message == "banner")
        #expect(report.diagnostics?.contains("stage: poll") == true)
        let blanked = SearXNGEnsurer.EnsureReport(reachable: false, started: false, message: "  ", diagnostics: "  ")
        #expect(blanked.message == nil)
        #expect(blanked.diagnostics == nil)
    }
}
