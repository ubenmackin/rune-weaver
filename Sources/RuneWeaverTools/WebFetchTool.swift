// Rune Weaver Tools — Bounded web page fetch with per-hop safety and typed outcomes.

import Foundation
import RuneWeaverCore

/// Shared allowlist for web URLs dereferenced by fetch and search.
public enum WebURLSafety: Sendable {
    /// Whether a raw URL string is safe to dereference.
    /// - Parameter raw: Candidate URL string.
    /// - Returns: True for absolute `http`/`https` URLs with a host.
    public static func isSafeUrl(_ raw: String) -> Bool {
        // Shares the single blank agreement so whitespace-only input fails closed identically to guards.
        guard let trimmed = NormalizedText.value(raw) else { return false }
        // Control characters never appear in a legitimate dereferenceable URL.
        if trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return false
        }
        let lowered = trimmed.lowercased()
        // Scheme blocklist checked on the raw string because `URL(string:)`
        // parses some of these without a host, hiding the smuggle.
        let blockedPrefixes = ["javascript:", "vbscript:", "data:", "file:", "ftp:", "gopher:", "mailto:", "tel:"]
        for prefix in blockedPrefixes where lowered.hasPrefix(prefix) {
            return false
        }
        // Protocol-relative references inherit the caller's scheme and
        // bypass the scheme check, so they fail closed here.
        if trimmed.hasPrefix("//") {
            return false
        }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              let host = url.host, !host.isEmpty, scheme == "http" || scheme == "https"
        else {
            return false
        }
        // Userinfo (`http://user:pass@host`) would smuggle credentials into logs, envelopes, and
        // redirect chains, so any authority carrying a user or password fails closed.
        if url.user != nil || url.password != nil {
            return false
        }
        // Raw spaces mean the string was never a valid single URL.
        if trimmed.contains(" ") || trimmed.contains("\t") {
            return false
        }
        return true
    }
}

/// SSRF guard for read-only fetch hops.
public enum WebFetchSSRFGuard: Sendable {
    /// Refusal reason for a URL, or nil when the URL may be dialed.
    public static func denyReason(
        for rawURL: String,
        browserConfig: BrowserConfig,
        mediaConfig: MediaConfig? = nil,
        extraAllowlistedOrigins: Set<String> = []
    ) -> String? {
        guard let trimmed = NormalizedText.value(rawURL) else {
            return "Empty URL: web.fetch needs an absolute http(s) URL."
        }
        // Effective exemptions union the config-derived auto origins with the
        // owner-declared local grants so a policy exemption reaches the
        // initial guard; never-exempt targets stay refused inside the guard.
        let baseOrigins = ApiSSRFGuard.allowlistedOrigins(
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            llmServerURLs: []
        )
        let effective = baseOrigins.union(extraAllowlistedOrigins)
        return ApiSSRFGuard.denyReason(for: trimmed, allowlistedOrigins: effective)
    }

    /// Async refusal reason that keeps blocking DNS off the cooperative pool.
    public static func denyReasonAsync(
        for rawURL: String,
        browserConfig: BrowserConfig,
        mediaConfig: MediaConfig? = nil,
        extraAllowlistedOrigins: Set<String> = []
    ) async -> String? {
        guard let trimmed = NormalizedText.value(rawURL) else {
            return "Empty URL: web.fetch needs an absolute http(s) URL."
        }
        let baseOrigins = ApiSSRFGuard.allowlistedOrigins(
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            llmServerURLs: []
        )
        let effective = baseOrigins.union(extraAllowlistedOrigins)
        return await ApiSSRFGuard.denyReasonAsync(for: trimmed, allowlistedOrigins: effective)
    }

    /// Whether a URL may be dialed under the fetch SSRF guard.
    public static func isAllowed(
        for rawURL: String,
        browserConfig: BrowserConfig,
        mediaConfig: MediaConfig? = nil,
        extraAllowlistedOrigins: Set<String> = []
    ) -> Bool {
        denyReason(for: rawURL, browserConfig: browserConfig, mediaConfig: mediaConfig, extraAllowlistedOrigins: extraAllowlistedOrigins) == nil
    }

    /// Async allow check that keeps blocking DNS on the bounded pool.
    public static func isAllowedAsync(
        for rawURL: String,
        browserConfig: BrowserConfig,
        mediaConfig: MediaConfig? = nil,
        extraAllowlistedOrigins: Set<String> = []
    ) async -> Bool {
        await denyReasonAsync(for: rawURL, browserConfig: browserConfig, mediaConfig: mediaConfig, extraAllowlistedOrigins: extraAllowlistedOrigins) == nil
    }

    /// Normalizes a URL host for sensitive-range comparison.
    public static func canonicalHost(_ host: String) -> String {
        ApiSSRFGuard.normalizedHost(host)
    }

    /// Parses an IPv4 literal in decimal, octal, hex, or short form.
    public static func ipv4Value(_ host: String) -> UInt32? {
        guard let octets = ApiSSRFGuard.canonicalIPv4Octets(host) else { return nil }
        return (UInt32(octets.firstOctet) << 24) | (UInt32(octets.secondOctet) << 16)
            | (UInt32(octets.thirdOctet) << 8) | UInt32(octets.fourthOctet)
    }

    /// Whether a 32-bit IPv4 value dials a sensitive range.
    /// Single-sourced through `ApiSSRFGuard` so fetch and API guards share
    /// one range table across obfuscated spellings.
    public static func isSensitiveIPv4Value(_ value: UInt32) -> Bool {
        ApiSSRFGuard.isSensitiveIPv4Value(value)
    }

    /// Whether a canonical host is a sensitive IPv6 literal.
    /// Single-sourced through `ApiSSRFGuard` (loopback, link-local, ULA,
    /// mapped sensitive tails) so the two web guards cannot diverge.
    public static func isSensitiveIPv6Host(_ canonical: String) -> Bool {
        ApiSSRFGuard.isSensitiveIPv6Host(canonical)
    }
}

/// Arguments for the `web.fetch` tool.
public struct WebFetchArgs: Sendable, Equatable, Decodable {
    /// Page URL to fetch.
    public let url: String

    /// Memberwise initializer.
    /// - Parameter url: Page URL.
    public init(url: String) {
        self.url = url
    }

    private enum CodingKeys: String, CodingKey {
        case url
    }

    /// Decodes canonical fetch arguments. Strict wire carries only `url` so retired `uri`/`link`
    /// spellings fail closed under additionalProperties false and wire plus decoder agree.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let url = try container.decodeIfPresent(String.self, forKey: .url)
            ?? ""
        self.url = url
    }

    /// Trimmed URL.
    /// Shares the single blank agreement so empty input collapses identically for guards.
    public var trimmedURL: String {
        NormalizedText.value(url, fallback: "")
    }
}

/// Typed outcome for one fetch.
public struct WebFetchEnvelope: Sendable, Equatable, Codable {
    /// Outcome: `ok`, `auth_required`, or `unsupported`.
    public let status: String
    /// Terminal URL after following redirects (or the failing hop).
    public let finalUrl: String
    /// Original request URL.
    public let url: String?
    /// Response MIME type when a response was received.
    public let contentType: String?
    /// Extracted readable text (only for `ok`).
    public let content: String?
    /// Whether the download or the returned text was cut short.
    public let truncated: Bool?
    /// Follow-up hint (`browser.navigate` for `auth_required`).
    public let suggestedNext: String?
    /// Human-readable reason for non-`ok` outcomes.
    public let reason: String?
    /// Ordered hop URLs including the terminal URL, when followed.
    public let redirectChain: [String]?
    /// Collapsed redirect count (chain length minus one, floor zero).
    public let redirectCount: Int?

    /// Status for a readable page.
    public static let statusOK = "ok"
    /// Status for a login wall.
    public static let statusAuthRequired = "auth_required"
    /// Status for an undisplayable or unsafe payload.
    public static let statusUnsupported = "unsupported"

    /// Creates an envelope.
    public init(
        status: String,
        finalUrl: String,
        url: String? = nil,
        contentType: String? = nil,
        content: String? = nil,
        truncated: Bool? = nil,
        suggestedNext: String? = nil,
        reason: String? = nil,
        redirectChain: [String]? = nil,
        redirectCount: Int? = nil
    ) {
        self.status = status
        self.finalUrl = finalUrl
        self.url = url
        self.contentType = contentType
        self.content = content
        self.truncated = truncated
        self.suggestedNext = suggestedNext
        self.reason = reason
        self.redirectChain = redirectChain
        self.redirectCount = redirectCount
    }
}

/// Transport for fetch HTTP round trips, injectable for hermetic tests.
public protocol WebFetchTransport: Sendable {
    /// Performs one HTTP round trip without following redirects.
    /// - Parameter request: Request to send.
    /// - Returns: Body bytes plus the URL response.
    func data(for request: URLRequest) async throws -> (Data, URLResponse)

    /// Performs one HTTP round trip against the SSRF-vetted dial pin.
    func data(for request: URLRequest, pin: SSRFDialPin) async throws -> (Data, URLResponse)
}

extension WebFetchTransport {
    /// Default pinned entry for stub transports. Hermetic suites keep implementing only the
    /// unpinned entry; production's live transport overrides this with the pinned dialer, so the
    /// default is never the production path.
    public func data(for request: URLRequest, pin _: SSRFDialPin) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }
}

/// Live fetch transport that dials only the address the SSRF gate pinned.
public struct URLSessionWebFetchTransport: WebFetchTransport, Sendable {
    /// Request timeout in seconds.
    public let timeoutSeconds: Double

    /// Creates a live transport.
    /// - Parameter timeoutSeconds: Request timeout. Defaults to 15 seconds.
    public init(timeoutSeconds: Double = 15) {
        self.timeoutSeconds = timeoutSeconds
    }

    /// Refuses an unpinned dial: a hostname reaching this entry would bypass
    /// the SSRF gate's dial-time proof, so it fails closed instead.
    public func data(for _: URLRequest) async throws -> (Data, URLResponse) {
        throw PinnedDialError.unpinnedDialRefused
    }

    /// Sends one request against the pinned addresses, surfacing 3xx instead of following.
    public func data(for request: URLRequest, pin: SSRFDialPin) async throws -> (Data, URLResponse) {
        try await PinnedHTTPDialer.perform(
            request: request,
            pin: pin,
            maxBytes: WebFetchTool.maxFetchBytes,
            timeoutSeconds: timeoutSeconds
        )
    }
}

/// Read-only `web.fetch` tool for bounded page reads.
public struct WebFetchTool: Tool, Sendable {
    /// Stable tool name referenced by the LLM and memory.
    public let name = "web.fetch"
    /// When the LLM should use this tool.
    public let description =
        "Fetches one web page as readable text. "
            + "Use when the user asks to open, quote, or summarize a URL. "
            + "Follows up to 5 redirects with a 1 MB cap; automatically escalates to interactive browser on auth walls."
    /// Function-calling contract for `url`.
    /// Schema advertises only the canonical key; retired spellings stay out of
    /// the schema as removed aliases so strict validators and the decoder agree.
    public let inputSchema =
        JSONSchema(
            rawValue: """
            {
              "type": "object",
              "properties": {
                "url": {
                  "type": "string",
                  "description": "Absolute http(s) URL to fetch"
                }
              },
              "required":["url"],
              "additionalProperties": false
            }
            """
        )
    /// Always allowed at the gate level; unsafe URLs fail with guidance instead.
    public let permissionLevel = PermissionLevel.readOnly
    /// Network-derived bytes may carry injected directives, so results enter as labeled data.
    public var contentTrustLevel: ContentTrustLevel {
        .untrustedExternal
    }

    /// Maximum redirects followed before failing closed (shared with `api.request`).
    public static let maxRedirects = HTTPRedirectFollower.maxRedirects
    /// Maximum body bytes retained per call (1 MB).
    public static let maxFetchBytes = 1_048_576
    /// Maximum characters returned after text extraction, bounding context.
    public static let maxReturnedChars = 20000
    /// User-Agent identifying engine fetches to origin servers.
    /// Single-sourced through `RuneWeaverVersion` so fetch, API, provider,
    /// and health versions cannot drift.
    public static var userAgent: String {
        RuneWeaverVersion.userAgent
    }

    /// Browser policy supplying timeouts and the `searxng_url` SSRF exemption.
    private let browserConfig: BrowserConfig
    /// Media automation policy supplying Sonarr/Radarr auto-allowed origins.
    private let mediaConfig: MediaConfig?
    /// HTTP transport (live session by default, stub in tests).
    private let transport: any WebFetchTransport
    /// Optional Playwright gateway for automatic browser escalation on auth walls or challenge pages.
    private let gateway: any BrowserPlaywrightGateway?
    /// Optional egress supervisor enforcing declarative security policy.
    private let egressSupervisor: OutboundEgressSupervisor?
    /// Owner-declared local grants unioned with the config-derived origins.
    /// Keeps the approval-free initial guard from rejecting an internal URL
    /// the supervised hop gate would allow.
    private let extraAllowlistedOrigins: Set<String>

    /// Creates a fetch tool.
    public init(
        browserConfig: BrowserConfig = BrowserConfig(),
        mediaConfig: MediaConfig? = nil,
        transport: any WebFetchTransport? = nil,
        gateway: any BrowserPlaywrightGateway? = nil,
        egressSupervisor: OutboundEgressSupervisor? = nil,
        extraAllowlistedOrigins: Set<String> = []
    ) {
        self.browserConfig = browserConfig
        self.mediaConfig = mediaConfig
        self.gateway = gateway
        self.egressSupervisor = egressSupervisor
        self.extraAllowlistedOrigins = extraAllowlistedOrigins
        if let transport {
            self.transport = transport
        } else {
            self.transport = URLSessionWebFetchTransport(timeoutSeconds: Double(browserConfig.fetchTimeoutSeconds))
        }
    }

    /// Fetches the URL, following redirects with per-hop validation.
    public func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput {
        let args: WebFetchArgs
        do {
            args = try JSONDecoder().decode(WebFetchArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            return .failure(
                "Invalid web.fetch arguments: expected {\"url\": \"<http(s)://...>\"}.",
                callID: input.callID
            )
        }
        // Shares the single blank agreement so whitespace-only URLs fail as empty identically to guards.
        guard let rawURL = NormalizedText.value(args.url) else {
            return .failure("Invalid web.fetch arguments: 'url' must not be empty.", callID: input.callID)
        }
        guard WebURLSafety.isSafeUrl(rawURL) else {
            return unsupportedFailure(
                originalURL: rawURL,
                finalURL: rawURL,
                reason: "Unsafe URL: web.fetch only dereferences absolute http(s) URLs.",
                callID: input.callID
            )
        }
        // Declarative policy enforcement runs per hop inside `fetchChain` (including this initial
        // URL as its first hop) under the live session, so no stateful pre-check runs here.
        if let refusal = await WebFetchSSRFGuard.denyReasonAsync(
            for: rawURL,
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            extraAllowlistedOrigins: extraAllowlistedOrigins
        ) {
            return unsupportedFailure(
                originalURL: rawURL,
                finalURL: rawURL,
                reason: refusal,
                callID: input.callID
            )
        }
        guard let initialURL = URL(string: rawURL) else {
            return .failure("Invalid web.fetch arguments: 'url' is not a valid URL.", callID: input.callID)
        }
        do {
            var envelope = try await fetchChain(from: initialURL, originalURL: rawURL, sessionID: context.sessionID)
            if envelope.status == WebFetchEnvelope.statusAuthRequired,
               let gateway,
               !context.dryRun
            {
                if let resolved = try await escalateToBrowser(
                    targetURL: envelope.finalUrl,
                    originalURL: rawURL,
                    gateway: gateway,
                    sessionID: context.sessionID
                ) {
                    envelope = resolved
                }
            }
            let content = try ToolEnvelopeEncoding.encode(envelope)
            // Typed non-ok outcomes still return success so the model can
            // read `status`/`suggestedNext`; only invalid input is a failure.
            // Unsafe-hop, policy denials, and SSRF denials surface as failures below with the same shape.
            if envelope.status == WebFetchEnvelope.statusUnsupported,
               envelope.reason?.contains("Unsafe") == true || envelope.reason?.contains("SSRF") == true || envelope.reason?.contains("policy") == true
            {
                return .failure(content, callID: input.callID)
            }
            return .success(content, callID: input.callID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failure("web.fetch failed for \(rawURL): \(error.localizedDescription)", callID: input.callID)
        }
    }
}

// MARK: - Redirect Chain & Helpers

extension WebFetchTool {
    /// Escalates an auth-walled or challenge-blocked fetch to the browser gateway.
    /// Runs headless first; if auth/challenge is detected, escalates to headed mode for human interaction.
    private func escalateToBrowser(
        targetURL: String,
        originalURL: String,
        gateway: any BrowserPlaywrightGateway,
        sessionID: UUID?
    ) async throws -> WebFetchEnvelope? {
        var snapshot: BrowserSnapshot
        do {
            snapshot = try await gateway.navigate(
                url: targetURL,
                includeScreenshot: false,
                headed: false,
                dryRun: false,
                sessionID: sessionID
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }

        if snapshot.authRequired {
            do {
                snapshot = try await gateway.navigate(
                    url: targetURL,
                    includeScreenshot: false,
                    headed: true,
                    dryRun: false,
                    sessionID: sessionID
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return nil
            }
        }

        for step in snapshot.redirectChain {
            do {
                _ = try await BrowserValidation.validateEgressURLAsync(
                    step.url,
                    browserConfig: browserConfig,
                    mediaConfig: mediaConfig,
                    extraAllowlistedOrigins: extraAllowlistedOrigins,
                    egressSupervisor: egressSupervisor,
                    sessionID: sessionID
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return WebFetchEnvelope(
                    status: WebFetchEnvelope.statusUnsupported,
                    finalUrl: step.url,
                    url: originalURL,
                    reason: "Egress denied during browser navigation: \(error.localizedDescription)"
                )
            }
        }
        do {
            _ = try await BrowserValidation.validateEgressURLAsync(
                snapshot.url,
                browserConfig: browserConfig,
                mediaConfig: mediaConfig,
                extraAllowlistedOrigins: extraAllowlistedOrigins,
                egressSupervisor: egressSupervisor,
                sessionID: sessionID
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return WebFetchEnvelope(
                status: WebFetchEnvelope.statusUnsupported,
                finalUrl: snapshot.url,
                url: originalURL,
                reason: "Egress denied during browser navigation: \(error.localizedDescription)"
            )
        }

        if !snapshot.authRequired {
            let (returned, charTruncated) = Self.truncateForContext(snapshot.text)
            return WebFetchEnvelope(
                status: WebFetchEnvelope.statusOK,
                finalUrl: snapshot.url,
                url: originalURL,
                contentType: "text/html",
                content: returned,
                truncated: snapshot.truncated || charTruncated,
                reason: nil
            )
        } else {
            return WebFetchEnvelope(
                status: WebFetchEnvelope.statusAuthRequired,
                finalUrl: snapshot.url,
                url: originalURL,
                contentType: "text/html",
                suggestedNext: "browser.navigate",
                reason: "Page requires authentication or challenge resolution; "
                    + "operator closed browser or did not complete login in the interactive browser."
            )
        }
    }

    /// Validates hop safety against scheme, egress supervisor, and SSRF guard.
    /// Returns the refusal plus the vetted dial pin the transport must use.
    private func validateHopSafety(url: URL, sessionID: UUID?, vettedHosts: inout Set<String>) async -> (refusal: String?, pin: SSRFDialPin?) {
        guard WebURLSafety.isSafeUrl(url.absoluteString) else {
            return ("Unsafe redirect target: refusing to dereference \(url.absoluteString).", nil)
        }
        let canonicalHost = url.host.map { SensitiveAddressNormalization.normalizedHost($0) } ?? ""
        // Repeat hosts still re-enter the supervisor so blocked plus
        // credential plus SSRF checks run on every hop; the supervisor
        // carries redirect equivalence via previouslyVettedHosts.
        var vettedPin: SSRFDialPin?
        if let supervisor = egressSupervisor {
            let verdict = await supervisor.validate(
                url: url,
                method: "GET",
                headers: [:],
                sessionID: sessionID,
                resolvesCredentials: false,
                previouslyVettedHosts: vettedHosts
            )
            switch verdict {
            case let .allowed(result):
                guard !result.dialPin.addresses.isEmpty else {
                    return ("SSRF denied: vetting produced no dialable address.", nil)
                }
                vettedPin = result.dialPin
            case let .denied(reason), let .unlistedDomain(_, reason):
                return (reason, nil)
            }
        }
        if vettedPin == nil {
            // Without a supervisor the SSRF gate still proves a pin, so the
            // transport never re-resolves the hostname at dial time.
            switch await ApiSSRFGuard.vetAsync(
                for: url.absoluteString,
                allowlistedOrigins: ApiSSRFGuard.allowlistedOrigins(
                    browserConfig: browserConfig,
                    mediaConfig: mediaConfig,
                    llmServerURLs: []
                ).union(extraAllowlistedOrigins)
            ) {
            case let .dialable(pin):
                guard !pin.addresses.isEmpty else {
                    return ("SSRF denied: vetting produced no dialable address.", nil)
                }
                vettedPin = pin
            case let .refused(reason):
                return (reason, nil)
            }
        } else if let refusal = await WebFetchSSRFGuard.denyReasonAsync(
            for: url.absoluteString,
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            extraAllowlistedOrigins: extraAllowlistedOrigins
        ) {
            return (refusal, nil)
        }
        if !canonicalHost.isEmpty {
            vettedHosts.insert(canonicalHost)
        }
        guard let pin = vettedPin else {
            return ("SSRF denied: vetting produced no dialable address.", nil)
        }
        return (nil, pin)
    }

    /// Follows the redirect chain manually with per-hop validation.
    private func fetchChain(from initialURL: URL, originalURL: String, sessionID: UUID? = nil) async throws -> WebFetchEnvelope {
        var currentURL = initialURL
        var hops = 0
        var chain: [String] = [initialURL.absoluteString]
        var vettedHosts = Set<String>()
        func chainEnvelope(
            status: String,
            finalURL: String,
            contentType: String? = nil,
            content: String? = nil,
            truncated: Bool? = nil,
            suggestedNext: String? = nil,
            reason: String? = nil
        ) -> WebFetchEnvelope {
            let normalized = chain.contains(finalURL) ? chain : chain + [finalURL]
            return WebFetchEnvelope(
                status: status,
                finalUrl: finalURL,
                url: originalURL,
                contentType: contentType,
                content: content,
                truncated: truncated,
                suggestedNext: suggestedNext,
                reason: reason,
                redirectChain: normalized,
                redirectCount: max(0, normalized.count - 1)
            )
        }
        while true {
            let hop = await validateHopSafety(url: currentURL, sessionID: sessionID, vettedHosts: &vettedHosts)
            if let refusal = hop.refusal {
                return chainEnvelope(
                    status: WebFetchEnvelope.statusUnsupported,
                    finalURL: currentURL.absoluteString,
                    reason: refusal
                )
            }
            guard let pin = hop.pin else {
                return chainEnvelope(
                    status: WebFetchEnvelope.statusUnsupported,
                    finalURL: currentURL.absoluteString,
                    reason: "SSRF denied: vetting produced no dialable address."
                )
            }
            let request = makeFetchRequest(url: currentURL)
            let (data, response) = try await transport.data(for: request, pin: pin)
            guard let http = response as? HTTPURLResponse else {
                return chainEnvelope(
                    status: WebFetchEnvelope.statusUnsupported,
                    finalURL: currentURL.absoluteString,
                    reason: "No HTTP response from \(currentURL.absoluteString)."
                )
            }
            let statusCode = http.statusCode
            // Manual redirect: resolve `Location` against the current URL so
            // relative targets stay anchored instead of failing to parse.
            if (300 ..< 400).contains(statusCode) {
                guard hops < Self.maxRedirects else {
                    return chainEnvelope(
                        status: WebFetchEnvelope.statusUnsupported,
                        finalURL: currentURL.absoluteString,
                        reason: "Too many redirects (more than \(Self.maxRedirects))."
                    )
                }
                guard let next = Self.redirectTarget(http: http, currentURL: currentURL) else {
                    let failure = Self.redirectFailure(http: http, statusCode: statusCode, currentURL: currentURL)
                    return chainEnvelope(
                        status: WebFetchEnvelope.statusUnsupported,
                        finalURL: failure.finalURL,
                        reason: failure.reason
                    )
                }
                let nextHop = await validateHopSafety(url: next, sessionID: sessionID, vettedHosts: &vettedHosts)
                if let refusal = nextHop.refusal {
                    return chainEnvelope(
                        status: WebFetchEnvelope.statusUnsupported,
                        finalURL: next.absoluteString,
                        reason: refusal
                    )
                }
                currentURL = next
                chain.append(next.absoluteString)
                hops += 1
                continue
            }
            return Self.terminalResult(
                data: data,
                http: http,
                currentURL: currentURL,
                originalURL: originalURL,
                chain: chain
            )
        }
    }

    /// Classifies one terminal hop and attaches the collapsed redirect chain.
    private static func terminalResult(
        data: Data,
        http: HTTPURLResponse,
        currentURL: URL,
        originalURL: String,
        chain: [String]
    ) -> WebFetchEnvelope {
        let terminal = Self.terminalEnvelope(
            data: data,
            http: http,
            currentURL: currentURL,
            originalURL: originalURL
        )
        // Attach the collapsed chain so redirect counts render even on
        // terminal pages; the terminal classifier stays focused on
        // status and payload shape.
        let normalized = chain.contains(currentURL.absoluteString) ? chain : chain + [currentURL.absoluteString]
        return WebFetchEnvelope(
            status: terminal.status,
            finalUrl: terminal.finalUrl,
            url: terminal.url,
            contentType: terminal.contentType,
            content: terminal.content,
            truncated: terminal.truncated,
            suggestedNext: terminal.suggestedNext,
            reason: terminal.reason,
            redirectChain: normalized,
            redirectCount: max(0, normalized.count - 1)
        )
    }

    /// Builds one fetch hop request with the shared timeout and Accept framing.
    private func makeFetchRequest(url: URL) -> URLRequest {
        var request = URLRequest(
            url: url,
            timeoutInterval: Double(max(browserConfig.fetchTimeoutSeconds, 1))
        )
        request.httpMethod = "GET"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(
            "text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.1",
            forHTTPHeaderField: "Accept"
        )
        return request
    }

    /// Resolves a redirect `Location` against the current URL.
    private static func redirectTarget(http: HTTPURLResponse, currentURL: URL) -> URL? {
        HTTPRedirectFollower.redirectTarget(http: http, currentURL: currentURL)
    }

    /// Maps a missing or unsafe redirect `Location` to a fail-closed detail.
    private static func redirectFailure(http: HTTPURLResponse, statusCode: Int, currentURL: URL) -> (finalURL: String, reason: String) {
        // Shares the single blank agreement so whitespace-only locations read as missing everywhere.
        if let rawLocation = NormalizedText.value(http.value(forHTTPHeaderField: "Location")) {
            return (currentURL.absoluteString, "Unsafe redirect target: refusing to dereference \(rawLocation).")
        }
        return (currentURL.absoluteString, "Redirect without a valid Location header (status \(statusCode)).")
    }

    /// Classifies a terminal (non-redirect) response as auth, ok, or unsupported.
    private static func terminalEnvelope(
        data: Data,
        http: HTTPURLResponse,
        currentURL: URL,
        originalURL: String
    ) -> WebFetchEnvelope {
        let statusCode = http.statusCode
        // Login walls surface as a typed outcome with a browser hint
        // instead of an error so the turn can suggest the next step.
        if Self.isAuthStatusCode(statusCode) {
            return WebFetchEnvelope(
                status: WebFetchEnvelope.statusAuthRequired,
                finalUrl: currentURL.absoluteString,
                url: originalURL,
                contentType: http.mimeType,
                suggestedNext: "browser.navigate",
                reason: "Page requires authentication (HTTP \(statusCode)); "
                    + "re-navigate to \(currentURL.absoluteString) using browser.navigate."
            )
        }
        guard (200 ..< 300).contains(statusCode) else {
            // Heuristic login-page detection on error-adjacent statuses
            // stays conservative: only exact auth codes map to
            // `auth_required`; other failures are `unsupported`.
            return WebFetchEnvelope(
                status: WebFetchEnvelope.statusUnsupported,
                finalUrl: currentURL.absoluteString,
                url: originalURL,
                contentType: http.mimeType,
                reason: "Fetch returned HTTP \(statusCode) for \(currentURL.absoluteString)."
            )
        }
        let mimeType = (http.mimeType ?? "").lowercased()
        // A 200 carrying a login form URL still needs the browser hint;
        // the body sniff below confirms the wall before classifying.
        let cappedData = data.count > Self.maxFetchBytes ? Data(data.prefix(Self.maxFetchBytes)) : data
        let byteTruncated = data.count > Self.maxFetchBytes
        // Failable decoding keeps undecodable bytes out of context instead of
        // smuggling replacement characters into the envelope body.
        let bodyText = String(bytes: cappedData, encoding: .utf8) ?? ""
        if Self.looksLikeLoginPage(url: currentURL, contentType: mimeType, body: bodyText) {
            return WebFetchEnvelope(
                status: WebFetchEnvelope.statusAuthRequired,
                finalUrl: currentURL.absoluteString,
                url: originalURL,
                contentType: http.mimeType,
                suggestedNext: "browser.navigate",
                reason: "Page appears to require authentication; "
                    + "re-navigate to \(currentURL.absoluteString) using browser.navigate."
            )
        }
        guard Self.isSupportedContentType(mimeType) else {
            return WebFetchEnvelope(
                status: WebFetchEnvelope.statusUnsupported,
                finalUrl: currentURL.absoluteString,
                url: originalURL,
                contentType: http.mimeType,
                reason: "Unsupported content type '\(http.mimeType ?? "unknown")'; web.fetch returns text pages only."
            )
        }
        let extracted = Self.extractReadableText(bodyText, contentType: mimeType)
        let (returned, charTruncated) = Self.truncateForContext(extracted)
        return WebFetchEnvelope(
            status: WebFetchEnvelope.statusOK,
            finalUrl: currentURL.absoluteString,
            url: originalURL,
            contentType: http.mimeType,
            content: returned,
            truncated: byteTruncated || charTruncated,
            reason: nil
        )
    }

    /// Builds a failure envelope for invalid or unsafe input so `finalUrl` is present even on failures.
    private func unsupportedFailure(originalURL: String, finalURL: String, reason: String, callID: String) -> ToolOutput {
        let envelope = WebFetchEnvelope(
            status: WebFetchEnvelope.statusUnsupported,
            finalUrl: finalURL,
            url: originalURL,
            reason: reason
        )
        do {
            let content = try ToolEnvelopeEncoding.encode(envelope)
            return .failure(content, callID: callID)
        } catch {
            return .failure(reason, callID: callID)
        }
    }

    // MARK: - Pure helpers (covered by unit tests)

    /// Whether an HTTP status code denotes a login wall.
    public static func isAuthStatusCode(_ statusCode: Int) -> Bool {
        statusCode == 401 || statusCode == 403 || statusCode == 407
    }

    /// Whether a MIME type carries readable text.
    public static func isSupportedContentType(_ mimeType: String) -> Bool {
        ApiRequestValidation.isTextContentType(mimeType)
    }

    /// Heuristic login-page detection for 200 responses.
    public static func looksLikeLoginPage(url: URL, contentType: String, body: String) -> Bool {
        guard contentType.isEmpty || contentType.contains("html") else { return false }
        let path = url.path.lowercased()
        let hasLoginPath = path.contains("login") || path.contains("signin") || path.contains("sign-in")
            || path.contains("auth") || path.contains("account")
        guard hasLoginPath else { return false }
        let loweredBody = body.lowercased()
        // Both signals required: a password field inside a form. Either
        // alone (a docs page mentioning passwords, or a search form on a
        // login path) stays `ok`.
        return loweredBody.contains("password") && loweredBody.contains("<form")
    }

    /// Resolves a redirect `Location` against the current URL.
    public static func resolveRedirect(current: URL, location: String) -> URL? {
        HTTPRedirectFollower.resolveRedirect(current: current, location: location)
    }

    /// Extracts readable text from a body, stripping HTML tags.
    public static func extractReadableText(_ body: String, contentType: String) -> String {
        var text = body
        if contentType.isEmpty || contentType.contains("html") || contentType.contains("xml") {
            // Tag stripping is intentionally shallow: the goal is readable
            // context, not a full renderer, so scripts and styles are cut
            // first and remaining tags collapse to spaces.
            text = Self.stripScriptsAndStyles(text)
            text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            // Common entities decoded without pulling in an HTML parser.
            for (entity, replacement) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " "] {
                text = text.replacingOccurrences(of: entity, with: replacement)
            }
        }
        // Collapse runs so indented HTML does not spend context on whitespace.
        // Shares the single blank agreement so whitespace-only bodies collapse identically for callers.
        let collapsed = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return NormalizedText.value(collapsed, fallback: "")
    }

    /// Removes script and style blocks before tag stripping.
    /// - Parameter html: Raw HTML.
    /// - Returns: HTML without script/style content.
    private static func stripScriptsAndStyles(_ html: String) -> String {
        var result = html
        for pattern in ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>"] {
            result = result.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        return result
    }

    /// Truncates extracted text to the context budget.
    /// - Parameter text: Extracted readable text.
    /// - Returns: Returned prefix plus whether it was cut short.
    public static func truncateForContext(_ text: String) -> (String, Bool) {
        guard text.count > maxReturnedChars else { return (text, false) }
        return (String(text.prefix(maxReturnedChars)), true)
    }
}

/// Factory registering the fetch tool on a `ToolBus`.
public enum WebFetchTools {
    /// Tool names in registration order.
    public static let toolNames = ["web.fetch"]

    /// Builds the fetch tool for a browser and media config.
    /// - Parameter extraAllowlistedOrigins: Owner-declared local grants
    ///   unioned with the config-derived origins in the initial guard.
    public static func makeTools(
        browserConfig: BrowserConfig = BrowserConfig(),
        mediaConfig: MediaConfig? = nil,
        transport: any WebFetchTransport? = nil,
        gateway: any BrowserPlaywrightGateway? = nil,
        supervisor: OutboundEgressSupervisor? = nil,
        extraAllowlistedOrigins: Set<String> = []
    ) -> [any Tool] {
        [
            WebFetchTool(
                browserConfig: browserConfig,
                mediaConfig: mediaConfig,
                transport: transport,
                gateway: gateway,
                egressSupervisor: supervisor,
                extraAllowlistedOrigins: extraAllowlistedOrigins
            )
        ]
    }

    /// Registers the fetch tool, replacing same-named entries.
    public static func register(
        on bus: ToolBus,
        browserConfig: BrowserConfig = BrowserConfig(),
        mediaConfig: MediaConfig? = nil,
        transport: any WebFetchTransport? = nil,
        gateway: any BrowserPlaywrightGateway? = nil,
        supervisor: OutboundEgressSupervisor? = nil,
        extraAllowlistedOrigins: Set<String> = []
    ) async {
        for tool in makeTools(
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            transport: transport,
            gateway: gateway,
            supervisor: supervisor,
            extraAllowlistedOrigins: extraAllowlistedOrigins
        ) {
            await bus.register(tool: tool)
        }
    }
}
