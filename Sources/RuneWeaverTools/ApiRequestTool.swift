// Rune Weaver Tools — Constrained API request tool with bounded I/O.
//
// The tool is the narrow, approval-gated replacement for shell curl: a closed
// GET/POST/PUT/DELETE surface with an allowlisted header subset, a 64KB body
// cap, and a 256KB truncated response budget. File pulls stay manifest-only so
// no remote bytes reach the host filesystem, and dry runs preview the redacted
// shape without dialing.
//
// The SSRF guard lives single-source in `ApiSSRFGuard.swift` and validation in
// `ApiRequestValidation.swift`; this file keeps the args, envelope, transport,
// and manual redirect chain. Every hop re-validates with the shared allowlist
// plus `ApiSSRFGuard` (refusing link-local, loopback except configured
// origins, metadata hosts, and file URLs), cross-host redirects drop
// `Authorization`, and only 307/308 preserve method plus body. Envelopes encode
// through the shared `ToolEnvelopeEncoding` helper.

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
    /// HTTP method (GET, POST, PUT, or DELETE in any casing).
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
        case verb
        case url
        case uri
        case link
        case headers
        case header
        case body
        case payload
        case data
    }

    /// Decodes arguments, accepting `verb` for `method`, `uri`/`link` for
    /// `url`, `header` for `headers`, and `payload`/`data` for `body` so model
    /// drift keeps working without widening the approved surface.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let direct = try container.decodeIfPresent(String.self, forKey: .method), !direct.isEmpty {
            method = direct
        } else if let verb = try container.decodeIfPresent(String.self, forKey: .verb), !verb.isEmpty {
            method = verb
        } else {
            method = ""
        }
        if let direct = try container.decodeIfPresent(String.self, forKey: .url), !direct.isEmpty {
            url = direct
        } else if let uri = try container.decodeIfPresent(String.self, forKey: .uri), !uri.isEmpty {
            url = uri
        } else if let link = try container.decodeIfPresent(String.self, forKey: .link), !link.isEmpty {
            url = link
        } else {
            url = ""
        }
        if let direct = try container.decodeIfPresent([String: String].self, forKey: .headers) {
            headers = direct
        } else if let single = try container.decodeIfPresent([String: String].self, forKey: .header) {
            headers = single
        } else {
            headers = nil
        }
        body = try container.decodeIfPresent(String.self, forKey: .body)
            ?? container.decodeIfPresent(String.self, forKey: .payload)
            ?? container.decodeIfPresent(String.self, forKey: .data)
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
}

/// Live API transport that never follows redirects automatically.
public struct URLSessionApiRequestTransport: ApiRequestTransport, Sendable {
    /// Request timeout in seconds.
    public let timeoutSeconds: Double

    /// Creates a live transport.
    /// - Parameter timeoutSeconds: Request timeout. Defaults to 15 seconds.
    public init(timeoutSeconds: Double = ApiRequestTool.timeoutSeconds) {
        self.timeoutSeconds = timeoutSeconds
    }

    /// Sends one request, surfacing 3xx instead of following.
    /// - Parameter request: Request to send.
    /// - Returns: Body plus response.
    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        var mutable = request
        if mutable.timeoutInterval < 1 {
            mutable.timeoutInterval = timeoutSeconds
        }
        let delegate = NoRedirectDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await session.data(for: mutable)
    }
}

/// Constrained `api.request` tool for smoke checks and simple downloads.
public struct ApiRequestTool: Tool, Sendable {
    /// Stable tool name referenced by the LLM and memory.
    public let name = "api.request"
    /// When the LLM should use this tool.
    public let description =
        "Performs one constrained HTTP API request (GET, POST, PUT, or DELETE) for smoke checks and simple downloads. "
            + "Use for API health checks or small JSON fetches instead of shell curl. "
            + "Requires approval with method plus URL plus body preview; "
            + "SSRF targets (private RFC 1918, 169.254.0.0/16, loopback except searxng_url and LLM endpoints, "
            + "unique-local IPv6, metadata hosts, file:) are refused. "
            + "Headers are limited to Accept, Content-Type, and Authorization; "
            + "body is capped at 64KB and responses at 256KB truncated. "
            + "File pulls return a manifest only and never write to the host."
    /// Function-calling contract for method, URL, headers, and body.
    /// Every decoder alias (`verb`, `uri`/`link`, `header`, `payload`/`data`)
    /// is advertised so a compliant validator accepts what the decoder handles.
    public let inputSchema =
        JSONSchema(
            rawValue: #"{"type":"object","properties":{"method":{"type":"string","enum":["GET","POST","PUT","DELETE"],"#
                + #""description":"HTTP method"},"verb":{"type":"string","description":"Alias for method"},"#
                + #""url":{"type":"string","description":"Absolute http(s) URL to request"},"uri":{"type":"string","#
                + #""description":"Alias for url"},"link":{"type":"string","description":"Alias for url"},"#
                + #""headers":{"type":"object","description":"Optional headers (Accept, Content-Type, Authorization only)","#
                + #""additionalProperties":{"type":"string"}},"header":{"type":"object","description":"Alias for headers","#
                + #""additionalProperties":{"type":"string"}},"body":{"type":"string","description":"Optional request body (64KB cap)"},"#
                + #""payload":{"type":"string","description":"Alias for body"},"data":{"type":"string","description":"Alias for body"}},"#
                + #""allOf":[{"anyOf":[{"required":["method"]}, {"required":["verb"]}]}, "#
                + #"{"anyOf":[{"required":["url"]}, {"required":["uri"]}, {"required":["link"]}]}],"#
                + #""additionalProperties":false}"#
        )
    /// Always gated: even GET parks so the SSRF guard and caps stay human-visible.
    public let permissionLevel = PermissionLevel.requiresApproval

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

    /// Browser policy supplying `searxng_url` for the loopback exemption.
    private let browserConfig: BrowserConfig
    /// Media automation policy supplying Sonarr/Radarr auto-allowed origins.
    private let mediaConfig: MediaConfig?
    /// Configured LLM `server_url` values for the loopback exemption.
    private let llmServerURLs: [String]
    /// HTTP transport (live session by default, stub in tests).
    private let transport: any ApiRequestTransport

    /// Creates an API request tool.
    public init(
        browserConfig: BrowserConfig = BrowserConfig(),
        mediaConfig: MediaConfig? = nil,
        llmServerURLs: [String] = [],
        transport: (any ApiRequestTransport)? = nil
    ) {
        self.browserConfig = browserConfig
        self.mediaConfig = mediaConfig
        self.llmServerURLs = llmServerURLs
        if let transport {
            self.transport = transport
        } else {
            self.transport = URLSessionApiRequestTransport(timeoutSeconds: Self.timeoutSeconds)
        }
    }

    /// Validates and performs (or previews under dry-run) one API request.
    public func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput {
        let args: ApiRequestArgs
        do {
            args = try JSONDecoder().decode(ApiRequestArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            return .failure(
                "Invalid api.request arguments: expected {\"method\": \"GET|POST|PUT|DELETE\", \"url\": \"<http(s)://...>\"}.",
                callID: input.callID
            )
        }
        guard let method = ApiMethod.normalized(args.trimmedMethod) else {
            return .failure(
                "Invalid api.request method '\(args.trimmedMethod)': must be one of GET, POST, PUT, DELETE.",
                callID: input.callID
            )
        }
        let rawURL = args.trimmedURL
        guard !rawURL.isEmpty else {
            return .failure("Invalid api.request arguments: 'url' must not be empty.", callID: input.callID)
        }
        // DNS blocks its thread with no kernel cancellation, so the verdict hops
        // to the bounded pool instead of stalling shared tasks; literals still
        // resolve inline without waiting.
        if let refusal = await ApiSSRFGuard.denyReasonAsync(
            for: rawURL, browserConfig: browserConfig, mediaConfig: mediaConfig, llmServerURLs: llmServerURLs
        ) {
            RuneWeaverLog.tools.warning("api.request denied \(method.rawValue) \(rawURL) headers=\(ApiHeaderPolicy.logSummary([:])) reason=\(refusal)")
            return .failure(refusal, callID: input.callID)
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
        if context.dryRun {
            return dryRunOutput(method: method, url: rawURL, headers: headers, body: bodyString, callID: input.callID)
        }
        // Log the outbound shape with the secret already redacted so the
        // audit trail never carries the raw `Authorization` value.
        let headerSummary = ApiHeaderPolicy.logSummary(headers)
        let bodyByteCount = bodyString?.utf8.count ?? 0
        RuneWeaverLog.tools.info(
            "api.request \(method.rawValue) \(rawURL) headers=\(headerSummary) bodyBytes=\(bodyByteCount)"
        )
        do {
            let envelope = try await requestChain(
                method: method,
                headers: headers,
                bodyString: bodyString,
                initialURL: requestURL,
                originalURL: rawURL
            )
            let content = try ToolEnvelopeEncoding.encode(envelope)
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
    private func requestChain(
        method: ApiMethod,
        headers: [String: String],
        bodyString: String?,
        initialURL: URL,
        originalURL: String
    ) async throws -> ApiRequestEnvelope {
        var currentURL = initialURL
        var currentMethod = method
        var currentBody = bodyString
        var currentHeaders = headers
        var hops = 0
        while true {
            try await validateHopURL(currentURL.absoluteString)
            let request = ApiRequestChain.chainRequest(
                url: currentURL,
                method: currentMethod,
                headers: currentHeaders,
                body: currentBody,
                timeoutSeconds: Self.timeoutSeconds,
                userAgent: Self.userAgent
            )
            let (data, response) = try await transport.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                // Transport failure is never `ok`: no status arrived, so the
                // envelope reports `error` instead of an empty success.
                return ApiRequestEnvelope(
                    status: ApiRequestEnvelope.statusError,
                    method: currentMethod.rawValue,
                    url: originalURL,
                    finalUrl: currentURL.absoluteString,
                    statusCode: nil,
                    contentType: nil,
                    body: "",
                    truncated: false,
                    note: "No HTTP response from \(currentURL.absoluteString)."
                )
            }
            let statusCode = http.statusCode
            if (300 ..< 400).contains(statusCode) {
                guard hops < Self.maxRedirects else {
                    return ApiRequestEnvelope(
                        status: ApiRequestEnvelope.statusError,
                        method: currentMethod.rawValue,
                        url: originalURL,
                        finalUrl: currentURL.absoluteString,
                        statusCode: statusCode,
                        contentType: http.mimeType,
                        body: "",
                        truncated: false,
                        note: "Too many redirects (more than \(Self.maxRedirects))."
                    )
                }
                guard let next = ApiRequestChain.redirectTarget(http: http, currentURL: currentURL) else {
                    // `redirectTarget` stays single-source nil for both a missing
                    // `Location` and a present-but-unsafe target that
                    // `resolveRedirect` refused: distinguish here so an unsafe
                    // hop fails closed as an error with `finalUrl` preserved
                    // instead of a plain `ok` success.
                    if let rawLocation = http.value(forHTTPHeaderField: "Location")?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                        !rawLocation.isEmpty
                    {
                        return ApiRequestEnvelope(
                            status: ApiRequestEnvelope.statusError,
                            method: currentMethod.rawValue,
                            url: originalURL,
                            finalUrl: currentURL.absoluteString,
                            statusCode: statusCode,
                            contentType: http.mimeType,
                            body: "",
                            truncated: false,
                            note: "Unsafe redirect target: refusing to dereference \(rawLocation)."
                        )
                    }
                    return ApiRequestEnvelope(
                        status: ApiRequestEnvelope.statusError,
                        method: currentMethod.rawValue,
                        url: originalURL,
                        finalUrl: currentURL.absoluteString,
                        statusCode: statusCode,
                        contentType: http.mimeType,
                        body: "",
                        truncated: false,
                        note: "Redirect without a valid Location header (status \(statusCode))."
                    )
                }
                try await validateHopURL(next.absoluteString)
                // Cross-host redirects drop credentials so an allowlisted loopback probe cannot
                // forward `Authorization` elsewhere.
                let nextCanonicalHost = next.host.map { ApiSSRFGuard.normalizedHost($0) }
                let currentCanonicalHost = currentURL.host.map { ApiSSRFGuard.normalizedHost($0) }
                if nextCanonicalHost != currentCanonicalHost {
                    currentHeaders = currentHeaders.filter { $0.key.lowercased() != "authorization" }
                }
                // Only 307/308 preserve method and body; every other
                // redirect becomes a plain GET without a body.
                if statusCode == 307 || statusCode == 308 {
                    currentURL = next
                } else {
                    currentMethod = .GET
                    currentBody = nil
                    currentHeaders = currentHeaders.filter { $0.key.lowercased() != "content-type" }
                    currentURL = next
                }
                hops += 1
                continue
            }
            return ApiRequestChain.terminalEnvelope(
                data: data,
                http: http,
                currentURL: currentURL,
                originalURL: originalURL,
                currentMethod: currentMethod
            )
        }
    }

    /// Rejects one hop URL that fails the shared allowlist or SSRF guard.
    /// Hop checks run off the cooperative pool because DNS blocks its thread;
    /// literal refusals still return inline without waiting on the resolver.
    private func validateHopURL(_ urlString: String) async throws {
        guard WebURLSafety.isSafeUrl(urlString) else {
            throw ApiRequestError.unsafeURL(
                "Unsafe redirect target: refusing to dereference \(urlString)."
            )
        }
        if let denial = await ApiSSRFGuard.denyReasonAsync(
            for: urlString,
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            llmServerURLs: llmServerURLs
        ) {
            throw ApiRequestError.unsafeURL(denial)
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

/// Manual redirect chain builders for `api.request` hops.
///
/// Pure request shaping and terminal classification live here so the tool type
/// stays within budget; every hop still re-validates through `ApiSSRFGuard`
/// in the tool before dialing.
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

    /// Builds the API request tool for a browser config plus media and LLM endpoints.
    /// Media origins ride along so Sonarr/Radarr auto-allow matches `web.fetch`
    /// instead of diverging on self-hosted hosts.
    public static func makeTools(
        browserConfig: BrowserConfig = BrowserConfig(),
        mediaConfig: MediaConfig? = nil,
        llmServerURLs: [String] = [],
        transport: (any ApiRequestTransport)? = nil
    ) -> [any Tool] {
        [ApiRequestTool(browserConfig: browserConfig, mediaConfig: mediaConfig, llmServerURLs: llmServerURLs, transport: transport)]
    }

    /// Registers the API request tool, replacing same-named entries.
    public static func register(
        on bus: ToolBus,
        browserConfig: BrowserConfig = BrowserConfig(),
        mediaConfig: MediaConfig? = nil,
        llmServerURLs: [String] = [],
        transport: (any ApiRequestTransport)? = nil
    ) async {
        for tool in makeTools(
            browserConfig: browserConfig, mediaConfig: mediaConfig, llmServerURLs: llmServerURLs, transport: transport
        ) {
            await bus.register(tool: tool)
        }
    }
}
