// Rune Weaver Tools — Constrained API request tool with bounded I/O.
//
// The tool is the narrow, approval-gated replacement for shell curl: a closed
// GET/POST/PUT/PATCH/DELETE surface with an allowlisted header subset, a 64KB body
// cap, and a 256KB truncated response budget. File pulls stay manifest-only so
// no remote bytes reach the host filesystem, and dry runs preview the redacted
// shape without dialing.
//
// The SSRF guard lives single-source in `ApiSSRFGuard.swift` and validation in
// `ApiRequestValidation.swift`; this file keeps the args, envelope, transport
// choice, and manual redirect chain. Every hop re-validates through the mandatory
// supervisor with the surrogate-form headers so the network policy and
// credential-binding gates cover redirect hops too, and that same supervised
// vetting produces the dial pin (vetted numeric addresses plus the original
// host identity) the transport must use. The hostname is never resolved again
// after vetting, so a DNS name that rebinds between the gate and the
// connection cannot reach a destination the SSRF gate refused. The encoded
// envelope is swept through that same supervisor at the output boundary, so
// the choke-point that injected a live credential is also the one that removes
// any echoed copy. An origin change (scheme + host + port) drops every
// injected credential header, cross-origin 307/308
// method-plus-body forwarding is refused, and only same-origin 307/308
// preserve method plus body. Envelopes encode through the shared
// `ToolEnvelopeEncoding` helper.
//
// The supervisor is a required collaborator, not an optional enhancement: the
// network policy and credential-binding gates run before any DNS resolution or
// Keychain access, so a denied destination is refused without a resolver query,
// a socket, or a secret read. There is no surrogate fallback path.

import Foundation
import RuneWeaverCore

/// HTTP method accepted by `api.request`.
public enum ApiMethod: String, Sendable, Codable, CaseIterable {
    /// Safe read, typically without a body.
    case GET
    /// Create or invoke with an optional body.
    case POST
    /// Replace with an optional body.
    case PUT
    /// Partial update with an optional body.
    case PATCH
    /// Remove, typically without a body.
    case DELETE

    /// Normalizes a raw method string to a known verb.
    /// - Parameter raw: Candidate verb in any casing with surrounding whitespace.
    /// - Returns: Matching method, or nil when the verb is outside the closed set.
    public static func normalized(_ raw: String) -> ApiMethod? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return ApiMethod(rawValue: trimmed)
    }
}

/// Arguments for the `api.request` tool.
public struct ApiRequestArgs: Sendable, Equatable, Decodable {
    /// HTTP method (GET, POST, PUT, PATCH, DELETE in any casing).
    public let method: String
    /// Absolute http(s) URL to request.
    public let url: String
    /// Optional headers restricted to the allowlist.
    public let headers: [String: String]?
    /// Optional request body as text (64KB cap).
    public let body: String?

    /// Memberwise initializer.
    public init(method: String, url: String, headers: [String: String]? = nil, body: String? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    private enum CodingKeys: String, CodingKey {
        case method
        case url
        case headers
        case body
    }

    /// Decodes canonical request arguments.
    /// Strict wire carries only `method`/`url`/`headers`/`body` so retired
    /// spellings fail closed under additionalProperties false and wire plus
    /// decoder agree.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let direct = try container.decodeIfPresent(String.self, forKey: .method), !direct.isEmpty {
            method = direct
        } else {
            method = ""
        }
        if let direct = try container.decodeIfPresent(String.self, forKey: .url), !direct.isEmpty {
            url = direct
        } else {
            url = ""
        }
        if let direct = try container.decodeIfPresent([String: String].self, forKey: .headers) {
            headers = direct
        } else {
            headers = nil
        }
        body = try container.decodeIfPresent(String.self, forKey: .body)
    }

    /// Trimmed method verb.
    public var trimmedMethod: String {
        method.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trimmed URL.
    public var trimmedURL: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Manifest-only description of a file pull.
public struct ApiDownloadManifest: Sendable, Equatable, Codable {
    /// Filename derived from `Content-Disposition` or the URL path.
    public let filename: String
    /// Response MIME type, or `application/octet-stream` when absent.
    public let contentType: String
    /// Response byte count observed (before the output cap).
    public let sizeBytes: Int

    /// Creates a manifest.
    public init(filename: String, contentType: String, sizeBytes: Int) {
        self.filename = filename
        self.contentType = contentType
        self.sizeBytes = sizeBytes
    }
}

/// Typed outcome for one API request.
public struct ApiRequestEnvelope: Sendable, Equatable, Codable {
    /// Outcome: `ok`, `download`, `preview`, or `error` (transport failure).
    public let status: String
    /// Uppercased method that ran (or would run for previews).
    public let method: String
    /// Original request URL.
    public let url: String
    /// Terminal URL after following redirects (or the failing hop).
    public let finalUrl: String
    /// HTTP status code when a response was received (nil for previews).
    public let statusCode: Int?
    /// Response MIME type when a response was received.
    public let contentType: String?
    /// Truncated text body (only for `ok`).
    public let body: String?
    /// Whether the response body was cut at the output cap.
    public let truncated: Bool
    /// Whether this envelope previews without dialing.
    public let dryRun: Bool?
    /// Manifest-only file description (only for `download`).
    public let download: ApiDownloadManifest?
    /// Redacted request headers echoed for previews only.
    public let requestHeaders: [String: String]?
    /// Request body preview for previews only (bounded, never the full secret).
    public let bodyPreview: String?
    /// Human-readable follow-up hint.
    public let note: String?

    /// Status for a text response.
    public static let statusOK = "ok"
    /// Status for a manifest-only file pull.
    public static let statusDownload = "download"
    /// Status for a dry-run preview.
    public static let statusPreview = "preview"
    /// Status for a transport failure with no HTTP response (never `ok`).
    public static let statusError = "error"

    /// Creates an envelope.
    public init(
        status: String,
        method: String,
        url: String,
        finalUrl: String,
        statusCode: Int? = nil,
        contentType: String? = nil,
        body: String? = nil,
        truncated: Bool = false,
        dryRun: Bool? = nil,
        download: ApiDownloadManifest? = nil,
        requestHeaders: [String: String]? = nil,
        bodyPreview: String? = nil,
        note: String? = nil
    ) {
        self.status = status
        self.method = method
        self.url = url
        self.finalUrl = finalUrl
        self.statusCode = statusCode
        self.contentType = contentType
        self.body = body
        self.truncated = truncated
        self.dryRun = dryRun
        self.download = download
        self.requestHeaders = requestHeaders
        self.bodyPreview = bodyPreview
        self.note = note
    }
}

/// Transport for API HTTP round trips, injectable for hermetic tests.
public protocol ApiRequestTransport: Sendable {
    /// Performs one HTTP round trip without following redirects.
    /// - Parameter request: Request to send.
    /// - Returns: Body bytes plus the URL response.
    func data(for request: URLRequest) async throws -> (Data, URLResponse)

    /// Performs one HTTP round trip against the SSRF-vetted dial pin.
    ///
    /// Declared as a requirement (not only an extension method) so a concrete
    /// live transport's pinning implementation is dispatched dynamically
    /// through the existential the tool holds; a plain extension method would
    /// statically dispatch to the stub-forwarding default and silently dial by
    /// name. The pinned dial must not resolve the hostname again: it connects
    /// to the pin's addresses and preserves the pin's host identity for the
    /// HTTP `Host` header and TLS server name.
    /// - Parameters:
    ///   - request: Request to send, with the original destination URL.
    ///   - pin: Vetted addresses plus original host identity.
    /// - Returns: Body bytes plus the URL response.
    func data(for request: URLRequest, pin: SSRFDialPin) async throws -> (Data, URLResponse)
}

public extension ApiRequestTransport {
    /// Default pinned entry for stub transports.
    ///
    /// Hermetic suites keep implementing only the unpinned entry; production's
    /// live transport overrides this with the pinned dialer, so the default is
    /// never the production path.
    func data(for request: URLRequest, pin _: SSRFDialPin) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }
}

/// Live API transport that dials only the address the SSRF gate pinned.
///
/// URLSession cannot satisfy the pinning contract: dialing a hostname
/// re-resolves at connect time, and dialing an IP literal cannot present the
/// original TLS server name. This transport instead opens its own HTTP/1.1
/// connection to the pinned numbers, sends the original `Host` header, and
/// completes TLS with the original host as the server name and certificate
/// identity, so DNS rebinding between the gate and the dial has no effect.
/// The unpinned entry refuses: there is no production path that dials by name.
public struct PinnedApiRequestTransport: ApiRequestTransport, Sendable {
    /// Request timeout in seconds.
    public let timeoutSeconds: Double

    /// Creates a live pinned transport.
    /// - Parameter timeoutSeconds: Request timeout. Defaults to the tool budget.
    public init(timeoutSeconds: Double = ApiRequestTool.timeoutSeconds) {
        self.timeoutSeconds = timeoutSeconds
    }

    /// Refuses an unpinned dial: a hostname reaching this entry would bypass
    /// the SSRF gate's dial-time proof, so it fails closed instead.
    public func data(for _: URLRequest) async throws -> (Data, URLResponse) {
        throw PinnedDialError.unpinnedDialRefused
    }

    /// Sends one request against the pinned addresses, surfacing 3xx instead of
    /// following.
    /// - Parameters:
    ///   - request: Request to send.
    ///   - pin: Vetted addresses plus original host identity.
    /// - Returns: Body plus response.
    public func data(for request: URLRequest, pin: SSRFDialPin) async throws -> (Data, URLResponse) {
        try await PinnedHTTPDialer.perform(
            request: request,
            pin: pin,
            maxBytes: ApiRequestTool.maxOutputBytes,
            timeoutSeconds: timeoutSeconds
        )
    }
}

/// Constrained `api.request` tool for smoke checks and simple downloads.
public struct ApiRequestTool: Tool, Sendable {
    /// Stable tool name referenced by the LLM and memory.
    public let name = "api.request"
    /// When the LLM should use this tool.
    public let description =
        "Performs one constrained HTTP API request (GET, POST, PUT, PATCH, DELETE) for smoke checks and simple downloads. "
            + "Use for API health checks or small JSON fetches instead of shell curl. "
            + "Requires approval with method plus URL plus body preview; "
            + "SSRF targets (private RFC 1918, 169.254.0.0/16, loopback except searxng_url and LLM endpoints, "
            + "unique-local IPv6, metadata hosts, file:) are refused. "
            + "Headers are limited to Accept, Content-Type, and Authorization; "
            + "header values may reference stored secrets as rwsecret:<KEY> (for example \"Bearer rwsecret:MY_API_KEY\"), "
            + "resolved just-in-time at the network boundary so previews, logs, and persistence never carry real values; "
            + "never paste real secret values into arguments. "
            + "Body is capped at 64KB and responses at 256KB truncated. "
            + "File pulls return a manifest only and never write to the host."
    /// Function-calling contract for method, URL, headers, and body.
    /// Schema advertises only canonical keys; retired spellings stay out of the
    /// schema as removed aliases so strict validators and the decoder agree.
    public let inputSchema =
        JSONSchema(
            rawValue: """
            {
              "type": "object",
              "properties": {
                "method": {
                  "type": "string",
                  "enum": ["GET", "POST", "PUT", "PATCH", "DELETE"],
                  "description": "HTTP method"
                },
                "url": {
                  "type": "string",
                  "description": "Absolute http(s) URL to request"
                },
                "headers": {
                  "type": "object",
                  "description": "Optional headers (Accept, Content-Type, Authorization only; values may use rwsecret:<KEY> references)",
                  "additionalProperties": {
                    "type": "string"
                  }
                },
                "body": {
                  "type": "string",
                  "description": "Optional request body (64KB cap)"
                }
              },
              "required":["method","url"],
              "additionalProperties": false
            }
            """
        )
    /// Always gated: even GET parks so the SSRF guard and caps stay human-visible.
    public let permissionLevel = PermissionLevel.requiresApproval
    /// Network-derived bytes may carry injected directives, so results enter as labeled data.
    public var contentTrustLevel: ContentTrustLevel {
        .untrustedExternal
    }

    /// Maximum redirects followed before failing closed (shared with `web.fetch`).
    public static let maxRedirects = HTTPRedirectFollower.maxRedirects
    /// Request timeout in seconds.
    public static let timeoutSeconds: Double = 15
    /// Maximum request body bytes (64KB).
    public static let maxBodyBytes = ApiRequestValidation.maxBodyBytes
    /// Maximum response bytes retained (256KB, truncated).
    public static let maxOutputBytes = ApiRequestValidation.maxOutputBytes
    /// User-Agent identifying engine API calls to origin servers.
    /// Single-sourced through `RuneWeaverVersion` so fetch, API, provider,
    /// and health versions cannot drift.
    public static var userAgent: String {
        RuneWeaverVersion.userAgent
    }

    /// HTTP transport (live pinned dialer by default, stub in tests).
    private let transport: any ApiRequestTransport
    /// Mandatory egress supervisor enforcing policy allowlist, target-binding, and SSRF.
    ///
    /// Non-optional by design: a production `api.request` without this
    /// choke-point would silently fall back to unsupervised surrogate
    /// resolution, so the supervisor is required at construction. The
    /// supervisor also owns the SSRF exemption set (`searxng_url`, media, and
    /// LLM origins) and returns the dial pin for every hop, so the tool carries
    /// no second copy of that configuration.
    private let egressSupervisor: OutboundEgressSupervisor

    public let timeoutSeconds: Double

    /// Creates an API request tool.
    /// - Parameters:
    ///   - transport: HTTP transport; the live pinned dialer when nil.
    ///   - browserConfig: Optional browser config supplying fetchTimeoutSeconds.
    ///   - timeoutSeconds: Optional explicit timeout override in seconds.
    ///   - egressSupervisor: Live egress supervisor; required at every
    ///     production construction site.
    public init(
        transport: (any ApiRequestTransport)? = nil,
        browserConfig: BrowserConfig? = nil,
        timeoutSeconds: Double? = nil,
        egressSupervisor: OutboundEgressSupervisor
    ) {
        let resolvedTimeout = timeoutSeconds ?? Double(browserConfig?.fetchTimeoutSeconds ?? Int(Self.timeoutSeconds))
        self.timeoutSeconds = resolvedTimeout
        if let transport {
            self.transport = transport
        } else {
            self.transport = PinnedApiRequestTransport(timeoutSeconds: resolvedTimeout)
        }
        self.egressSupervisor = egressSupervisor
    }

    /// Validates and performs (or previews under dry-run) one API request.
    public func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput {
        let args: ApiRequestArgs
        do {
            args = try JSONDecoder().decode(ApiRequestArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            return .failure(
                "Invalid api.request arguments: expected {\"method\": \"GET|POST|PUT|PATCH|DELETE\", \"url\": \"<http(s)://...>\"}.",
                callID: input.callID
            )
        }
        guard let method = ApiMethod.normalized(args.trimmedMethod) else {
            return .failure(
                "Invalid api.request method '\(args.trimmedMethod)': must be one of GET, POST, PUT, PATCH, DELETE.",
                callID: input.callID
            )
        }
        let rawURL = args.trimmedURL
        guard !rawURL.isEmpty else {
            return .failure("Invalid api.request arguments: 'url' must not be empty.", callID: input.callID)
        }
        guard let requestURL = URL(string: rawURL) else {
            return .failure("Invalid api.request arguments: 'url' is not a valid URL.", callID: input.callID)
        }
        let headers: [String: String]
        do {
            headers = try ApiHeaderPolicy.validated(args.headers)
        } catch let error as ApiRequestError {
            return .failure(error.message, callID: input.callID)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
        do {
            try ApiRequestValidation.validateBody(args.body)
        } catch let error as ApiRequestError {
            return .failure(error.message, callID: input.callID)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
        let bodyString = (args.body?.isEmpty == true) ? nil : args.body
        // Surrogates resolve just-in-time at this boundary through the
        // mandatory supervisor: agent-authored arguments carry only
        // `rwsecret:<key>`, while the wire request below carries the live
        // value. The supervisor evaluates the declarative network policy and
        // credential target binding before its SSRF guard resolves any
        // hostname, so a denied destination fails closed as a typed error
        // without a DNS query, a socket, or a Keychain read. Dry runs take the
        // same gates with credential resolution disabled, so a preview keeps
        // the surrogate reference and never touches the live secret.
        let resolvedHeaders: [String: String]
        let resolvedSecrets: [String]
        let initialPin: SSRFDialPin
        do {
            let resolved = try await resolveOutboundHeaders(
                headers: headers,
                requestURL: requestURL,
                method: method,
                resolvesCredentials: !context.dryRun
            )
            resolvedHeaders = resolved.headers
            resolvedSecrets = resolved.secrets
            initialPin = resolved.pin
        } catch let error as ApiRequestError {
            return .failure(error.message, callID: input.callID)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
        if context.dryRun {
            return dryRunOutput(method: method, url: rawURL, headers: headers, body: bodyString, callID: input.callID)
        }
        // Log the outbound shape with the secret already redacted so the
        // audit trail never carries the raw `Authorization` value.
        let headerSummary = ApiHeaderPolicy.logSummary(resolvedHeaders, resolvedSecrets: resolvedSecrets)
        let bodyByteCount = bodyString?.utf8.count ?? 0
        RuneWeaverLog.tools.info(
            "api.request \(method.rawValue) \(rawURL) headers=\(headerSummary) bodyBytes=\(bodyByteCount)"
        )
        do {
            let initialHop = ApiRequestHop(
                url: requestURL,
                method: method,
                body: bodyString,
                headers: resolvedHeaders,
                surrogateHeaders: headers,
                dialPin: initialPin
            )
            let outcome = try await requestChain(
                initialHop: initialHop,
                initialSecrets: resolvedSecrets,
                originalURL: rawURL
            )
            let envelope = outcome.envelope
            let encoded = try ToolEnvelopeEncoding.encode(envelope)
            // Sweep every resolved value the server echoed back (a reflected
            // credential in a body, for example) before the output reaches the
            // model, mirroring the header redaction above. The sweep runs
            // through the supervisor that injected the values, so the same
            // choke-point owns both halves of the credential contract. The
            // list spans all hops because a same-origin redirect re-injects
            // from the same surrogate form.
            let content = egressSupervisor.sweepResponse(encoded, secrets: outcome.injectedSecrets)
            RuneWeaverLog.tools.info(
                "api.request done \(method.rawValue) \(envelope.finalUrl) status=\(envelope.statusCode.map(String.init) ?? "-") truncated=\(envelope.truncated)"
            )
            return .success(content, callID: input.callID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failure("api.request failed for \(rawURL): \(error.localizedDescription)", callID: input.callID)
        }
    }

    // MARK: - Preview

    /// Builds the dry-run preview without touching the network.
    private func dryRunOutput(method: ApiMethod, url: String, headers: [String: String], body: String?, callID: String) -> ToolOutput {
        let preview: String? = if let body, !body.isEmpty {
            ApiRequestValidation.bodyPreview(body, limit: ApiRequestValidation.maxDryRunPreviewChars)
        } else {
            nil
        }
        let envelope = ApiRequestEnvelope(
            status: ApiRequestEnvelope.statusPreview,
            method: method.rawValue,
            url: url,
            finalUrl: url,
            statusCode: nil,
            contentType: nil,
            body: nil,
            truncated: false,
            dryRun: true,
            download: nil,
            requestHeaders: ApiHeaderPolicy.redacted(headers),
            bodyPreview: preview,
            note: "Dry run: would send '\(method.rawValue)' to \(url) without dialing."
        )
        do {
            let content = try ToolEnvelopeEncoding.encode(envelope)
            return .success(content, callID: callID)
        } catch {
            return .failure(error.localizedDescription, callID: callID)
        }
    }

    // MARK: - Chain

    /// Performs the request, following redirects with per-hop validation.
    ///
    /// The initial hop arrives already validated by `execute`, which pins the
    /// addresses the supervised SSRF gate proved for it; every redirect target
    /// is resolved to a safe URL, checked by `validateHopURL`, then re-validated
    /// through the mandatory egress supervisor before its wire headers are
    /// built, so no hop can escape the network policy or ride a credential
    /// binding that covered a different origin. The hop's dial then uses that
    /// supervised pin, never the hostname. Failures that never reach a dial
    /// (unresolved targets, hop budget, missing status) stay typed error
    /// envelopes; a hop the supervisor refuses throws so the tool reports a
    /// failure rather than a success-shaped refusal.
    private func requestChain(
        initialHop: ApiRequestHop,
        initialSecrets: [String],
        originalURL: String
    ) async throws -> (envelope: ApiRequestEnvelope, injectedSecrets: [String]) {
        var hop = initialHop
        // Every live value injected on any hop, swept from the response at the end.
        var injectedSecrets = initialSecrets
        var hops = 0
        while true {
            try validateHopURL(hop.url.absoluteString)
            let request = ApiRequestChain.chainRequest(
                url: hop.url,
                method: hop.method,
                headers: hop.headers,
                body: hop.body,
                timeoutSeconds: self.timeoutSeconds,
                userAgent: Self.userAgent
            )
            let (data, response) = try await transport.data(for: request, pin: hop.dialPin)
            guard let http = response as? HTTPURLResponse else {
                // Transport failure is never `ok`: no status arrived, so the
                // envelope reports `error` instead of an empty success.
                return (
                    ApiRequestChain.errorEnvelope(
                        method: hop.method,
                        originalURL: originalURL,
                        currentURL: hop.url,
                        http: nil,
                        note: "No HTTP response from \(hop.url.absoluteString)."
                    ),
                    injectedSecrets
                )
            }
            let statusCode = http.statusCode
            guard (300 ..< 400).contains(statusCode) else {
                return (
                    ApiRequestChain.terminalEnvelope(
                        data: data,
                        http: http,
                        currentURL: hop.url,
                        originalURL: originalURL,
                        currentMethod: hop.method
                    ),
                    injectedSecrets
                )
            }
            guard hops < Self.maxRedirects else {
                return (
                    ApiRequestChain.errorEnvelope(
                        method: hop.method,
                        originalURL: originalURL,
                        currentURL: hop.url,
                        http: http,
                        note: "Too many redirects (more than \(Self.maxRedirects))."
                    ),
                    injectedSecrets
                )
            }
            guard let next = ApiRequestChain.redirectTarget(http: http, currentURL: hop.url) else {
                // `redirectTarget` stays single-source nil for both a missing
                // `Location` and a present-but-unsafe target that
                // `resolveRedirect` refused, so the failure envelope keeps the
                // distinction instead of reporting a plain `ok` success.
                return (
                    ApiRequestChain.redirectFailureEnvelope(
                        http: http,
                        currentURL: hop.url,
                        originalURL: originalURL,
                        method: hop.method
                    ),
                    injectedSecrets
                )
            }
            try validateHopURL(next.absoluteString)
            let advanced = try await validatedRedirectHop(statusCode: statusCode, current: hop, nextURL: next)
            hop = advanced.hop
            injectedSecrets.append(contentsOf: advanced.injectedSecrets)
            hops += 1
        }
    }

    /// Rejects one hop URL that fails the shared web-safety stage.
    ///
    /// The SSRF range vetting and the dial pin are not duplicated here: they
    /// belong to the mandatory supervisor, whose SSRF gate runs the same guard
    /// once per hop and returns the pin that hop dials. This stage keeps the
    /// early typed refusal for non-web and credential-bearing URLs.
    private func validateHopURL(_ urlString: String) throws {
        guard WebURLSafety.isSafeUrl(urlString) else {
            throw ApiRequestError.unsafeURL(
                "Unsafe redirect target: refusing to dereference \(urlString)."
            )
        }
    }

    // MARK: - Pure helpers (covered by unit tests)

    /// Resolves a redirect `Location` against the current URL.
    /// Single-sourced through `ApiRequestChain` so the tool and the chain
    /// share one redirect policy.
    public static func resolveRedirect(current: URL, location: String) -> URL? {
        ApiRequestChain.resolveRedirect(current: current, location: location)
    }
}

// MARK: - Surrogates & Egress

/// Wire-ready result of one supervised egress validation for a hop.
///
/// Bundles the three values every hop carries — wire headers, the live secret
/// values injected for response sweeping, and the vetted dial pin — so the
/// validation seam returns one named value instead of a three-member tuple.
private struct ResolvedEgressHeaders: Sendable {
    /// Wire headers with live secrets injected by the supervisor.
    let headers: [String: String]
    /// Live secret values injected for this hop, swept from the final output.
    let secrets: [String]
    /// Vetted addresses plus original host identity this hop must dial.
    let pin: SSRFDialPin
}

extension ApiRequestTool {
    /// Resolves outbound headers, live secrets, and the dial pin through the mandatory egress supervisor.
    ///
    /// Called once for the initial URL and again for every redirect hop, so the
    /// supervisor's gates apply to the whole chain rather than only the
    /// approved origin. There is no surrogate fallback: the supervisor owns the
    /// network policy, credential-binding, SSRF, and wire-injection gates, so a
    /// denied destination or unbound credential fails closed as a typed error
    /// before any DNS query or Keychain read. The returned pin is the SSRF
    /// gate's proof for this hop: its addresses are what the transport dials,
    /// so the hostname is never resolved a second time after vetting.
    /// - Parameters:
    ///   - headers: Validated headers possibly holding `rwsecret:<key>` surrogates.
    ///   - requestURL: Destination URL under evaluation.
    ///   - method: HTTP method feeding the credential-binding gate.
    ///   - resolvesCredentials: False for dry runs, which keep the surrogate
    ///     reference and never read the live secret.
    /// - Returns: Wire-ready headers, inserted live values for sweeping, and the vetted dial pin.
    private func resolveOutboundHeaders(
        headers: [String: String],
        requestURL: URL,
        method: ApiMethod,
        resolvesCredentials: Bool
    ) async throws -> ResolvedEgressHeaders {
        let verdict = await egressSupervisor.validate(
            url: requestURL,
            method: method.rawValue,
            headers: headers,
            resolvesCredentials: resolvesCredentials
        )
        switch verdict {
        case let .allowed(outcome):
            return ResolvedEgressHeaders(
                headers: outcome.resolvedHeaders,
                secrets: outcome.resolvedSecrets,
                pin: outcome.dialPin
            )
        case let .denied(reason), let .unlistedDomain(_, reason):
            RuneWeaverLog.tools.warning("api.request denied by egress supervisor: \(reason)")
            throw ApiRequestError.invalidArguments(reason)
        }
    }

    /// Builds and validates the next hop for one redirect response.
    ///
    /// Redirect hops re-enter the same mandatory supervisor `validate` gate the
    /// initial URL passed, evaluated over the surrogate-form headers so the
    /// network policy and credential-binding gates run before any Keychain read
    /// or resolver query: a hop cannot escape `[network].allowed_domains` or
    /// reach `blocked_domains`, and a same-origin hop still has its
    /// `allowed_path_prefixes` re-checked. Each hop's pin comes from that same
    /// supervised vetting pass, so the dial never re-resolves the name. An
    /// origin change (scheme + host +
    /// port) drops every credential-bearing header, and a 307/308 that would
    /// forward the approved method plus body across origins is refused because
    /// the approval descriptor covered the original URL only. A bodyless GET is
    /// the one cross-origin 307/308 shape allowed to continue, since it carries
    /// nothing a 302-to-GET would not.
    /// - Parameters:
    ///   - statusCode: Redirect status of the previous hop.
    ///   - current: Validated state of the previous hop.
    ///   - nextURL: Redirect target that already passed `validateHopURL`.
    /// - Returns: Wire-ready state for the next hop plus the values injected for it.
    /// - Throws: `ApiRequestError` when the target fails supervisor validation
    ///   or would forward the approved method plus body across origins.
    private func validatedRedirectHop(
        statusCode: Int,
        current: ApiRequestHop,
        nextURL: URL
    ) async throws -> (hop: ApiRequestHop, injectedSecrets: [String]) {
        let preservesMethodAndBody = statusCode == 307 || statusCode == 308
        let method: ApiMethod = preservesMethodAndBody ? current.method : .GET
        let body: String? = preservesMethodAndBody ? current.body : nil
        let originChanged = Self.credentialOrigin(for: nextURL) != Self.credentialOrigin(for: current.url)
        var surrogateHeaders = current.surrogateHeaders
        if originChanged {
            // The approval and every credential binding were scoped to the
            // previous origin, so no injected credential header survives.
            surrogateHeaders = Self.strippedCredentialHeaders(surrogateHeaders)
        }
        if !preservesMethodAndBody {
            // Only 307/308 keep a body, so Content-Type is stale on every other
            // redirect once the body is dropped.
            surrogateHeaders = surrogateHeaders.filter { $0.key.lowercased() != "content-type" }
        }
        // Cross-origin method-plus-body forwarding is refused before any
        // supervised vetting, so a denied hop never causes a resolver query or
        // a Keychain read: the approval covered the original origin only, and a
        // bodyless GET is the one shape a 302-to-GET would already produce.
        if originChanged, preservesMethodAndBody, method != .GET || body != nil {
            throw ApiRequestError.unsafeURL(
                "Refusing to forward \(method.rawValue) with its body across origins "
                    + "(\(current.url.absoluteString) -> \(nextURL.absoluteString)) on status \(statusCode): "
                    + "the approval covered only the original URL. Re-issue the request against the redirect target."
            )
        }
        let resolved = try await resolveOutboundHeaders(
            headers: surrogateHeaders,
            requestURL: nextURL,
            method: method,
            resolvesCredentials: true
        )
        let hop = ApiRequestHop(
            url: nextURL,
            method: method,
            body: body,
            headers: resolved.headers,
            surrogateHeaders: surrogateHeaders,
            dialPin: resolved.pin
        )
        return (hop, resolved.secrets)
    }

    /// Credential-scope origin key: scheme plus normalized host plus effective port.
    ///
    /// Reuses the SSRF guard's host normalization and scheme-default port so
    /// casing, trailing dots, brackets, or a default-port spelling cannot
    /// masquerade as a new origin, while a scheme or port change stays a real
    /// origin change: credentials never ride an https -> http downgrade or a
    /// hop to a different port on the same host.
    /// - Parameter url: URL whose origin is compared.
    /// - Returns: Comparable origin string, or nil when the URL has no host.
    private static func credentialOrigin(for url: URL) -> String? {
        guard let host = url.host, !host.isEmpty else { return nil }
        let scheme = url.scheme?.lowercased() ?? ""
        return "\(scheme)://\(ApiSSRFGuard.normalizedHost(host)):\(ApiSSRFGuard.effectivePort(for: url))"
    }

    /// Drops every header that could carry a live credential across origins.
    ///
    /// A header survives only when it neither mentions an `rwsecret:` surrogate
    /// (well-formed or malformed) nor is a plain `Authorization`; the previous
    /// cross-host `Authorization` drop is preserved, and the origin rule closes
    /// the same-host scheme/port bypass. Non-credential headers (`Accept`,
    /// `Content-Type`) ride along unchanged.
    /// - Parameter headers: Surrogate-form headers from the previous hop.
    /// - Returns: Headers safe to send to a different origin.
    private static func strippedCredentialHeaders(_ headers: [String: String]) -> [String: String] {
        headers.filter { name, value in
            let lowered = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return lowered != "authorization" && !SecretsManager.containsSurrogatePrefix(value)
        }
    }
}

// MARK: - Redirect chain

/// Validated state for one hop of the manual `api.request` redirect chain.
///
/// The chain keeps both header forms per hop: wire headers that already carry
/// injected live secrets, and the surrogate-form headers the hop was validated
/// from. Re-validating each redirect against the surrogate form is what lets a
/// hop re-enter the supervisor's binding gate without exposing live values to
/// validation, previews, or logs. The dial pin is the supervised SSRF gate's
/// proof for this hop: the transport dials exactly those addresses, so the
/// hostname is never resolved again after vetting.
private struct ApiRequestHop: Sendable {
    /// Destination URL for this hop.
    let url: URL
    /// Method this hop sends.
    let method: ApiMethod
    /// Body this hop sends, nil for bodyless hops.
    let body: String?
    /// Wire headers for this hop, with live secrets injected by the supervisor.
    let headers: [String: String]
    /// Surrogate-form headers this hop was validated from.
    let surrogateHeaders: [String: String]
    /// Vetted addresses plus original host identity this hop must dial.
    let dialPin: SSRFDialPin
}

/// Manual redirect chain builders for `api.request` hops.
///
/// Pure request shaping and failure classification live here so the tool type
/// stays within budget; every hop still re-validates through the mandatory
/// egress supervisor in the tool before dialing, and that vetting's pin is
/// what the transport connects to.
enum ApiRequestChain: Sendable {
    /// Builds one hop request with the shared timeout and User-Agent.
    static func chainRequest(
        url: URL,
        method: ApiMethod,
        headers: [String: String],
        body: String?,
        timeoutSeconds: Double,
        userAgent: String
    ) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        request.httpMethod = method.rawValue
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body, !body.isEmpty {
            request.httpBody = Data(body.utf8)
        }
        return request
    }

    /// Resolves a redirect `Location` against the current URL.
    static func redirectTarget(http: HTTPURLResponse, currentURL: URL) -> URL? {
        HTTPRedirectFollower.redirectTarget(http: http, currentURL: currentURL)
    }

    /// Builds the error envelope for a hop that produced no usable response.
    ///
    /// `http` is nil only when no HTTP response arrived at all; otherwise the
    /// status and content type are echoed so the model can see which hop failed
    /// while the envelope still reports `error` instead of a success shape.
    /// - Parameters:
    ///   - method: Method of the failing hop.
    ///   - originalURL: Original request URL reported by the envelope.
    ///   - currentURL: Failing hop URL reported as `finalUrl`.
    ///   - http: Response when one arrived, nil for transport failures.
    ///   - note: Human-readable failure reason.
    /// - Returns: Error envelope with an empty body.
    static func errorEnvelope(
        method: ApiMethod,
        originalURL: String,
        currentURL: URL,
        http: HTTPURLResponse?,
        note: String
    ) -> ApiRequestEnvelope {
        ApiRequestEnvelope(
            status: ApiRequestEnvelope.statusError,
            method: method.rawValue,
            url: originalURL,
            finalUrl: currentURL.absoluteString,
            statusCode: http?.statusCode,
            contentType: http?.mimeType,
            body: "",
            truncated: false,
            note: note
        )
    }

    /// Builds the error envelope for a 3xx whose `Location` never resolved to a
    /// safe target.
    ///
    /// `redirectTarget` stays single-source nil for both a missing `Location`
    /// and a present-but-unsafe target that `resolveRedirect` refused, so the
    /// distinction is reconstructed from the raw header: an unsafe hop fails
    /// closed with its target named, a missing hop with its status.
    /// - Parameters:
    ///   - http: Redirect response.
    ///   - currentURL: URL of the redirecting hop.
    ///   - originalURL: Original request URL reported by the envelope.
    ///   - method: Method of the redirecting hop.
    /// - Returns: Error envelope for the refused location.
    static func redirectFailureEnvelope(
        http: HTTPURLResponse,
        currentURL: URL,
        originalURL: String,
        method: ApiMethod
    ) -> ApiRequestEnvelope {
        let location = http.value(forHTTPHeaderField: "Location")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let note = if let location, !location.isEmpty {
            "Unsafe redirect target: refusing to dereference \(location)."
        } else {
            "Redirect without a valid Location header (status \(http.statusCode))."
        }
        return errorEnvelope(
            method: method,
            originalURL: originalURL,
            currentURL: currentURL,
            http: http,
            note: note
        )
    }

    /// Builds the terminal envelope for a non-redirect response.
    static func terminalEnvelope(
        data: Data,
        http: HTTPURLResponse,
        currentURL: URL,
        originalURL: String,
        currentMethod: ApiMethod
    ) -> ApiRequestEnvelope {
        let statusCode = http.statusCode
        // Status leads the classification, mirroring
        // `WebFetchTool.terminalEnvelope`: a non-2xx terminal hop is never
        // `ok` or `download`, so a 404 text page cannot read as success and a
        // 404 octet-stream cannot read as a file pull.
        guard (200 ..< 300).contains(statusCode) else {
            let authHint = WebFetchTool.isAuthStatusCode(statusCode) ? " Authentication is required for this resource." : ""
            return ApiRequestEnvelope(
                status: ApiRequestEnvelope.statusError,
                method: currentMethod.rawValue,
                url: originalURL,
                finalUrl: currentURL.absoluteString,
                statusCode: statusCode,
                contentType: http.mimeType,
                body: "",
                truncated: false,
                note: "Request returned HTTP \(statusCode) for \(currentURL.absoluteString).\(authHint)"
            )
        }
        let mimeType = (http.mimeType ?? "").lowercased()
        let byteTruncated = data.count > ApiRequestValidation.maxOutputBytes
        let cappedData = data.count > ApiRequestValidation.maxOutputBytes ? Data(data.prefix(ApiRequestValidation.maxOutputBytes)) : data
        // File pulls stay manifest-only: no bytes inline, nothing staged
        // on the host, just filename plus type plus size for the model.
        if !ApiRequestValidation.isTextContentType(mimeType) {
            let disposition = http.value(forHTTPHeaderField: "Content-Disposition")
            let filename = ApiRequestValidation.downloadFilename(
                for: currentURL,
                contentDisposition: disposition
            )
            let manifest = ApiDownloadManifest(
                filename: filename,
                contentType: http.mimeType ?? "application/octet-stream",
                sizeBytes: data.count
            )
            return ApiRequestEnvelope(
                status: ApiRequestEnvelope.statusDownload,
                method: currentMethod.rawValue,
                url: originalURL,
                finalUrl: currentURL.absoluteString,
                statusCode: http.statusCode,
                contentType: http.mimeType,
                body: nil,
                truncated: byteTruncated,
                download: manifest,
                note: "File pull is manifest-only; no file was written to the host."
            )
        }
        // Failable decoding keeps undecodable bytes out of context instead of
        // smuggling replacement characters into the envelope body.
        let bodyText = String(bytes: cappedData, encoding: .utf8) ?? ""
        let (returned, charTruncated) = ApiRequestValidation.truncateForOutput(bodyText)
        return ApiRequestEnvelope(
            status: ApiRequestEnvelope.statusOK,
            method: currentMethod.rawValue,
            url: originalURL,
            finalUrl: currentURL.absoluteString,
            statusCode: http.statusCode,
            contentType: http.mimeType,
            body: returned,
            truncated: byteTruncated || charTruncated
        )
    }

    /// Resolves a redirect `Location` against the current URL.
    static func resolveRedirect(current: URL, location: String) -> URL? {
        HTTPRedirectFollower.resolveRedirect(current: current, location: location)
    }
}

/// Factory registering the API request tool on a `ToolBus`.
public enum ApiRequestTools {
    /// Tool names in registration order.
    public static let toolNames = ["api.request"]

    /// Builds the API request tool over one shared egress supervisor.
    ///
    /// The supervisor owns the SSRF exemption set (configured searxng, media,
    /// and LLM origins) and produces the dial pin, so no exempt-origin
    /// configuration is duplicated here.
    /// - Parameter supervisor: Live egress supervisor; required so every built
    ///   tool shares the one policy-backed choke-point for this process.
    public static func makeTools(
        supervisor: OutboundEgressSupervisor,
        transport: (any ApiRequestTransport)? = nil,
        browserConfig: BrowserConfig? = nil,
        timeoutSeconds: Double? = nil
    ) -> [any Tool] {
        [
            ApiRequestTool(
                transport: transport,
                browserConfig: browserConfig,
                timeoutSeconds: timeoutSeconds,
                egressSupervisor: supervisor
            )
        ]
    }

    /// Registers the API request tool, replacing same-named entries.
    /// - Parameter supervisor: Live egress supervisor; required at every
    ///   production registration site.
    public static func register(
        on bus: ToolBus,
        supervisor: OutboundEgressSupervisor,
        transport: (any ApiRequestTransport)? = nil,
        browserConfig: BrowserConfig? = nil,
        timeoutSeconds: Double? = nil
    ) async {
        for tool in makeTools(
            supervisor: supervisor,
            transport: transport,
            browserConfig: browserConfig,
            timeoutSeconds: timeoutSeconds
        ) {
            await bus.register(tool: tool)
        }
    }
}
