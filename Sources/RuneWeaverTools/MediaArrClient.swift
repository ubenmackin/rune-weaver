// Rune Weaver Tools — Client for Sonarr & Radarr v3 REST API.

import Foundation
import RuneWeaverCore
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Client for communicating with Sonarr and Radarr instances.
public struct MediaArrClient: Sendable {
    /// Redirect budget shared with the web/API manual chains so LAN hosts cannot bounce the key forever.
    static let maxRedirects = HTTPRedirectFollower.maxRedirects
    /// Explicit per-request timeout so a hung LAN host stalls one turn, not the run.
    static let defaultTimeoutSeconds: Double = 15
    /// Per-response decode budget shared with `web.fetch`; over-cap payloads fail closed before parsing.
    static let maxResponseBytes = WebFetchTool.maxFetchBytes
    /// Error-body preview cap so a large payload never inflates a thrown message.
    private static let maxErrorPreviewBytes = 1024

    private let mediaConfig: MediaConfig
    private let transport: any MediaArrTransport
    private let secrets: SecretsManager

    private var requestTimeoutSeconds: Double {
        Double(mediaConfig.timeoutSeconds)
    }

    public init(
        mediaConfig: MediaConfig,
        transport: any MediaArrTransport? = nil,
        secrets: SecretsManager? = nil
    ) {
        self.mediaConfig = mediaConfig
        self.transport = transport ?? URLSessionMediaArrTransport(timeoutSeconds: Double(mediaConfig.timeoutSeconds))
        self.secrets = secrets ?? SecretsManager()
    }

    private struct ArrServiceConfig {
        let url: String
        let apiKeyEnv: String
        let defaultQuality: String?
        let defaultRoot: String?
    }

    /// Executes a media operation.
    public func execute(args: MediaArrArgs, dryRun: Bool = false) async throws -> String {
        // Dry-run previews never dial: return the shared no-dial shape before
        // touching secrets or URL validation so a missing credential or an
        // unconfigured base cannot fail a preview.
        if dryRun {
            return MediaArrDryRun.preview(for: args)
        }
        let config = try resolveServiceConfig(service: args.service)

        guard let apiKey = try await secrets.retrieve(key: config.apiKeyEnv), !apiKey.isEmpty else {
            throw ToolExecutionError.missingCredential(
                "Missing API key for \(args.service.rawValue.capitalized). Set environment variable '\(config.apiKeyEnv)' "
                    + "or store it in macOS Keychain (service: 'com.runeweaver.secrets', account: '\(config.apiKeyEnv)')."
            )
        }

        // Fail closed before any dial: the configured base must be absolute http(s) without
        // credentials, and never a metadata, link-local, or unspecified target in any obfuscated
        // spelling.
        try Self.validateBaseURL(config.url, service: args.service)
        guard let baseURL = URL(string: config.url) else {
            throw ToolExecutionError.invalidURL(
                "Invalid base URL for \(args.service.rawValue): check [media.\(args.service.rawValue)] url is an absolute http(s) URL."
            )
        }

        switch args.action {
        case .status:
            return try await checkStatus(service: args.service, baseURL: baseURL, apiKey: apiKey)
        case .queue:
            return try await checkQueue(service: args.service, baseURL: baseURL, apiKey: apiKey)
        case .search:
            guard let query = args.query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
                throw ToolExecutionError.badArgument("Action 'search' requires a 'query' parameter.")
            }
            return try await searchTitles(service: args.service, baseURL: baseURL, apiKey: apiKey, query: query)
        case .add:
            return try await addTitle(
                service: args.service,
                baseURL: baseURL,
                apiKey: apiKey,
                args: args,
                configuredQuality: config.defaultQuality,
                configuredRoot: config.defaultRoot
            )
        }
    }
}

extension MediaArrClient {
    private func resolveServiceConfig(service: MediaArrService) throws -> ArrServiceConfig {
        switch service {
        case .sonarr:
            let cfg = mediaConfig.sonarr
            guard cfg.enabled else {
                throw ToolExecutionError.serviceDisabled("Sonarr integration is disabled in configuration.")
            }
            guard let url = cfg.url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else {
                throw ToolExecutionError.unconfigured("Sonarr URL is not configured. Set [media.sonarr] url in ~/.runeweaver/config.toml or Settings.")
            }
            let keyEnv = cfg.apiKeyEnv?.trimmingCharacters(in: .whitespacesAndNewlines)
            let apiKeyEnv = (keyEnv?.isEmpty == false ? keyEnv : nil) ?? "SONARR_API_KEY"
            return ArrServiceConfig(
                url: url,
                apiKeyEnv: apiKeyEnv,
                defaultQuality: cfg.defaultQualityProfile,
                defaultRoot: cfg.defaultRootFolder
            )

        case .radarr:
            let cfg = mediaConfig.radarr
            guard cfg.enabled else {
                throw ToolExecutionError.serviceDisabled("Radarr integration is disabled in configuration.")
            }
            guard let url = cfg.url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else {
                throw ToolExecutionError.unconfigured("Radarr URL is not configured. Set [media.radarr] url in ~/.runeweaver/config.toml or Settings.")
            }
            let keyEnv = cfg.apiKeyEnv?.trimmingCharacters(in: .whitespacesAndNewlines)
            let apiKeyEnv = (keyEnv?.isEmpty == false ? keyEnv : nil) ?? "RADARR_API_KEY"
            return ArrServiceConfig(
                url: url,
                apiKeyEnv: apiKeyEnv,
                defaultQuality: cfg.defaultQualityProfile,
                defaultRoot: cfg.defaultRootFolder
            )
        }
    }

    private func makeRequest(url: URL, method: String = "GET", apiKey: String, body: Data? = nil) -> URLRequest {
        // Explicit timeout keeps a hung LAN host from stalling the turn on the shared default.
        var req = URLRequest(url: url, timeoutInterval: requestTimeoutSeconds)
        req.httpMethod = method
        req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        return req
    }

    /// Sends one request through the no-follow transport, resolving redirects manually.
    private func sendFollowingRedirects(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var current = request
        if current.timeoutInterval < 1 {
            var bounded = current
            bounded.timeoutInterval = requestTimeoutSeconds
            current = bounded
        }
        // Fail closed on the initial hop before any dial: a safe config cannot launder an unsafe
        // first URL, and metadata/link-local/unspecified literals fail here even when the shared
        // allowlist passes them.
        if let initialURL = current.url {
            try await Self.validateMediaHopURLAsync(initialURL.absoluteString)
        }
        var hops = 0
        while true {
            let (data, response) = try await transport.send(request: current)
            guard (300 ..< 400).contains(response.statusCode) else {
                guard data.count <= Self.maxResponseBytes else {
                    throw ToolExecutionError.httpError(
                        status: response.statusCode,
                        body: "Response exceeded \(Self.maxResponseBytes) byte cap; refusing to decode."
                    )
                }
                return (data, response)
            }
            guard hops < Self.maxRedirects else {
                throw ToolExecutionError.httpError(
                    status: response.statusCode,
                    body: "Too many redirects (more than \(Self.maxRedirects))."
                )
            }
            guard let currentURL = current.url,
                  let next = HTTPRedirectFollower.redirectTarget(http: response, currentURL: currentURL)
            else {
                // `redirectTarget` returns nil for both a missing Location and a present-but-unsafe
                // one the resolver refused; distinguish here so an unsafe hop fails closed instead
                // of reading as a plain error.
                if let rawLocation = response.value(forHTTPHeaderField: "Location")?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !rawLocation.isEmpty
                {
                    throw ToolExecutionError.invalidURL(
                        "Unsafe redirect target: refusing to dereference \(Self.redactedURL(rawLocation))."
                    )
                }
                throw ToolExecutionError.httpError(
                    status: response.statusCode,
                    body: "Redirect without a valid Location header (status \(response.statusCode))."
                )
            }
            // Each redirect target re-enters the same never-dialable check as the base URL so a LAN
            // instance cannot bounce the key into metadata, link-local, or unspecified space;
            // resolved addresses vet through the shared helpers so a hostname rebound to such space.
            do {
                try await Self.validateMediaHopURLAsync(next.absoluteString)
            } catch {
                throw ToolExecutionError.invalidURL(
                    "Unsafe redirect target: refusing to dereference \(Self.redactedURL(next.absoluteString))."
                )
            }
            // Only 307/308 preserve method and body; every other redirect becomes
            // a plain GET without a body, mirroring the constrained API chain.
            let preservesMethod = response.statusCode == 307 || response.statusCode == 308
            var nextRequest = URLRequest(url: next, timeoutInterval: requestTimeoutSeconds)
            nextRequest.httpMethod = preservesMethod ? (current.httpMethod ?? "GET") : "GET"
            let currentHost = currentURL.host.map { ApiSSRFGuard.normalizedHost($0) }
            let nextHost = next.host.map { ApiSSRFGuard.normalizedHost($0) }
            let crossedHost = currentHost != nextHost
            for (field, value) in current.allHTTPHeaderFields ?? [:] {
                let lowered = field.lowercased()
                // Never forward credentials across hosts; the LAN key stays with its origin.
                if crossedHost, lowered == "x-api-key" || lowered == "authorization" {
                    continue
                }
                if !preservesMethod, lowered == "content-type" {
                    continue
                }
                nextRequest.setValue(value, forHTTPHeaderField: field)
            }
            if preservesMethod {
                nextRequest.httpBody = current.httpBody
            }
            current = nextRequest
            hops += 1
        }
    }

    /// Bounds error bodies so a large payload never inflates the thrown message.
    private func errorPreview(_ data: Data) -> String {
        let capped = data.count > Self.maxErrorPreviewBytes ? Data(data.prefix(Self.maxErrorPreviewBytes)) : data
        return String(data: capped, encoding: .utf8) ?? ""
    }

    /// Validates the configured base URL before any dial, without echoing it. raw:
    /// Configured base URL string.
    static func validateBaseURL(_ raw: String, service: MediaArrService) throws {
        do {
            try validateMediaHopURL(raw)
        } catch {
            // Generic message names the config field instead of echoing the
            // raw value so embedded userinfo never reaches model output.
            throw ToolExecutionError.invalidURL(
                "Invalid base URL for \(service.rawValue): check [media.\(service.rawValue)] url is an absolute http(s) URL without credentials."
            )
        }
    }

    /// Validates one media hop URL without dialing.
    static func validateMediaHopURL(_ raw: String) throws {
        guard WebURLSafety.isSafeUrl(raw), let url = URL(string: raw), let host = url.host, !host.isEmpty else {
            throw ToolExecutionError.invalidURL("Unsafe media URL: expected an absolute http(s) URL without credentials.")
        }
        if ApiSSRFGuard.isMetadataHost(host) {
            throw ToolExecutionError.invalidURL("Refusing metadata host for media URL.")
        }
        if ApiSSRFGuard.isLinkLocalIPv4(host) || ApiSSRFGuard.isLinkLocalIPv6(host) {
            throw ToolExecutionError.invalidURL("Refusing link-local address for media URL.")
        }
        if isUnspecifiedIPv4(host) || isUnspecifiedIPv6(host) {
            throw ToolExecutionError.invalidURL("Refusing unspecified address for media URL.")
        }
    }

    /// Validates one media hop URL including DNS-resolved vetting.
    static func validateMediaHopURLAsync(_ raw: String) async throws {
        try validateMediaHopURL(raw)
        guard let url = URL(string: raw), let host = url.host, !host.isEmpty else {
            return
        }
        // IP literals already vetted spelling-by-spelling above; only DNS
        // names can launder a blocked address behind a benign literal.
        if ApiSSRFGuard.isIPAddressLiteral(host) {
            return
        }
        let addresses = await resolveMediaHostAddresses(host)
        guard !addresses.isEmpty else {
            throw ToolExecutionError.invalidURL("Refusing unverified media redirect host: DNS unavailable (fail closed).")
        }
        for address in addresses {
            if ApiSSRFGuard.isLinkLocalIPv4(address) || ApiSSRFGuard.isLinkLocalIPv6(address) {
                throw ToolExecutionError.invalidURL("Refusing link-local resolved address for media URL.")
            }
            if isUnspecifiedIPv4(address) || isUnspecifiedIPv6(address) {
                throw ToolExecutionError.invalidURL("Refusing unspecified resolved address for media URL.")
            }
        }
    }

    /// Resolves a media hostname off the cooperative pool.
    private static func resolveMediaHostAddresses(_ host: String) async -> [String] {
        #if DEBUG
            if let stub = ApiSSRFGuard.activeTestDNSResolver {
                return stub(host)
            }
        #endif
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: resolveMediaHostAddressesSync(host))
            }
        }
    }

    /// Blocking hostname resolution shared by the async media vetting path.
    /// Returns numeric address strings via the system resolver; an empty
    /// result reads as unverified and fails closed upstream.
    private static func resolveMediaHostAddressesSync(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = Int32(SOCK_STREAM)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else {
            return []
        }
        defer { freeaddrinfo(res) }
        var addresses: [String] = []
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let ptr = current {
            let addr = ptr.pointee
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr.ai_addr, addr.ai_addrlen, &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                let resolved = hostname.withUnsafeBufferPointer { buf in
                    let bytes = buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
                    return String(bytes: bytes, encoding: .utf8) ?? ""
                }
                if !resolved.isEmpty {
                    addresses.append(resolved)
                }
            }
            current = addr.ai_next
        }
        return addresses
    }

    /// Whether a host dials unspecified 0.0.0.0/8 in any resolver spelling.
    private static func isUnspecifiedIPv4(_ host: String) -> Bool {
        guard let octets = ApiSSRFGuard.canonicalIPv4Octets(host) else { return false }
        return octets.firstOctet == 0
    }

    /// Whether an IPv6 literal is the unspecified address.
    /// All-zero hextets mean `::`; `::1` stays allowed so IPv6 loopback keeps
    /// working while the unspecified wildcard fails closed.
    private static func isUnspecifiedIPv6(_ host: String) -> Bool {
        guard let hextets = ApiSSRFGuard.ipv6Hextets(host) else { return false }
        return hextets.allSatisfy { $0 == 0 }
    }

    /// Strips userinfo for error display so credentials never reach model output.
    /// Falls back to a generic placeholder when the value does not parse, rather
    /// than echoing the raw string that may carry `user:pass@`.
    static func redactedURL(_ raw: String) -> String {
        guard let url = URL(string: raw), let host = url.host, !host.isEmpty else {
            return "[unparseable URL]"
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "\(url.scheme?.lowercased() ?? "http")://\(host)"
        }
        components.user = nil
        components.password = nil
        return components.url?.absoluteString ?? "\(url.scheme?.lowercased() ?? "http")://\(host)"
    }
}

extension MediaArrClient {
    private func checkStatus(service: MediaArrService, baseURL: URL, apiKey: String) async throws -> String {
        let statusURL = baseURL.appendingPathComponent("api/v3/system/status")
        let req = makeRequest(url: statusURL, apiKey: apiKey)
        let (data, resp) = try await sendFollowingRedirects(request: req)
        guard resp.statusCode == 200 else {
            throw ToolExecutionError.httpError(status: resp.statusCode, body: errorPreview(data))
        }

        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let appName = json["appName"] as? String ?? service.rawValue.capitalized
                let version = json["version"] as? String ?? "unknown"
                return "\(appName) is online and reachable. Version: \(version)."
            }
        } catch {
            RuneWeaverLog.tools.debug("MediaArrClient: could not parse status json: \(error.localizedDescription)")
        }
        return "\(service.rawValue.capitalized) is online."
    }

    private func checkQueue(service: MediaArrService, baseURL: URL, apiKey: String) async throws -> String {
        let queueURL = baseURL.appendingPathComponent("api/v3/queue")
        let req = makeRequest(url: queueURL, apiKey: apiKey)
        let (data, resp) = try await sendFollowingRedirects(request: req)
        guard resp.statusCode == 200 else {
            throw ToolExecutionError.httpError(status: resp.statusCode, body: errorPreview(data))
        }

        let json: [String: Any]?
        do {
            json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            RuneWeaverLog.tools.debug("checkQueue: JSON parsing failed: \(error.localizedDescription)")
            json = nil
        }
        guard let json, let records = json["records"] as? [[String: Any]] else {
            return "Unable to parse queue response."
        }

        if records.isEmpty {
            return "\(service.rawValue.capitalized) download queue is currently empty."
        }

        var lines = ["\(service.rawValue.capitalized) Download Queue (\(records.count) item(s)):"]
        for item in records.prefix(10) {
            let title = item["title"] as? String ?? "Unknown Title"
            let status = item["status"] as? String ?? "unknown"
            let timeleft = item["timeleft"] as? String ?? ""
            var detail = "- \(title) [\(status)]"
            if !timeleft.isEmpty {
                detail += " ETA: \(timeleft)"
            }
            lines.append(detail)
        }
        return lines.joined(separator: "\n")
    }

    private func searchTitles(service: MediaArrService, baseURL: URL, apiKey: String, query: String) async throws -> String {
        let endpoint = service == .sonarr ? "api/v3/series/lookup" : "api/v3/movie/lookup"
        var components = URLComponents(url: baseURL.appendingPathComponent(endpoint), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "term", value: query)]
        guard let url = components?.url else {
            throw ToolExecutionError.invalidURL("Could not construct search URL for query: \(query)")
        }

        let req = makeRequest(url: url, apiKey: apiKey)
        let (data, resp) = try await sendFollowingRedirects(request: req)
        guard resp.statusCode == 200 else {
            throw ToolExecutionError.httpError(status: resp.statusCode, body: errorPreview(data))
        }

        let list: [[String: Any]]?
        do {
            list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        } catch {
            RuneWeaverLog.tools.debug("searchTitles: JSON parsing failed: \(error.localizedDescription)")
            list = nil
        }
        guard let list else {
            return "No matching titles found."
        }

        if list.isEmpty {
            return "No results found for '\(query)' in \(service.rawValue.capitalized)."
        }

        var results = ["Found \(list.count) result(s) for '\(query)':"]
        for (idx, item) in list.prefix(5).enumerated() {
            let title = item["title"] as? String ?? "Unknown"
            let year = item["year"] as? Int ?? 0
            let inLibrary = (item["id"] as? Int ?? 0) > 0
            let overview = (item["overview"] as? String ?? "").prefix(120)

            var entry = "\(idx + 1). \(title) (\(year))"
            if service == .sonarr {
                let tvdbId = item["tvdbId"] as? Int ?? 0
                entry += " [TVDB ID: \(tvdbId)]"
            } else {
                let tmdbId = item["tmdbId"] as? Int ?? 0
                entry += " [TMDB ID: \(tmdbId)]"
            }
            if inLibrary {
                entry += " (Already in library)"
            }
            if !overview.isEmpty {
                entry += "\n   Overview: \(overview)..."
            }
            results.append(entry)
        }
        return results.joined(separator: "\n")
    }

    private func addTitle(
        service: MediaArrService,
        baseURL: URL,
        apiKey: String,
        args: MediaArrArgs,
        configuredQuality: String?,
        configuredRoot: String?
    ) async throws -> String {
        // 1. Lookup title
        let lookupEndpoint = service == .sonarr ? "api/v3/series/lookup" : "api/v3/movie/lookup"
        let queryTerm = args.query ?? (args.id.map { "\(service == .sonarr ? "tvdb:" : "tmdb:")\($0)" } ?? "")
        guard !queryTerm.isEmpty else {
            throw ToolExecutionError.badArgument("Adding a title requires a 'query' or 'id'.")
        }

        var components = URLComponents(url: baseURL.appendingPathComponent(lookupEndpoint), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "term", value: queryTerm)]
        guard let searchURL = components?.url else {
            throw ToolExecutionError.invalidURL("Could not construct lookup URL")
        }

        let searchReq = makeRequest(url: searchURL, apiKey: apiKey)
        let (searchData, searchResp) = try await sendFollowingRedirects(request: searchReq)
        guard searchResp.statusCode == 200 else {
            throw ToolExecutionError.httpError(status: searchResp.statusCode, body: errorPreview(searchData))
        }

        let searchResults: [[String: Any]]?
        do {
            searchResults = try JSONSerialization.jsonObject(with: searchData) as? [[String: Any]]
        } catch {
            RuneWeaverLog.tools.debug("titleLookup: JSON parsing failed: \(error.localizedDescription)")
            searchResults = nil
        }
        guard let searchResults, let firstCandidate = searchResults.first else {
            throw ToolExecutionError.notFound("No matching \(service.rawValue) title found for '\(queryTerm)'")
        }

        // If ID provided, try finding exact match
        var candidate = firstCandidate
        if let id = args.id {
            let idKey = service == .sonarr ? "tvdbId" : "tmdbId"
            if let exact = searchResults.first(where: { ($0[idKey] as? Int) == id }) {
                candidate = exact
            }
        }

        let title = candidate["title"] as? String ?? "Unknown"
        if let existingId = candidate["id"] as? Int, existingId > 0 {
            return "'\(title)' is already present in your \(service.rawValue.capitalized) library (ID: \(existingId))."
        }

        // 2. Resolve Root Folder
        let rootFolder = try await resolveRootFolder(service: service, baseURL: baseURL, apiKey: apiKey, override: args.rootFolder ?? configuredRoot)

        // 3. Resolve Quality Profile
        let (profileId, profileName) = try await resolveQualityProfile(
            service: service,
            baseURL: baseURL,
            apiKey: apiKey,
            override: args.qualityProfile ?? configuredQuality
        )

        // 4. Build minimal add payload per v3: only the fields the create
        // endpoint needs, so lookup metadata (overview, images, seasons)
        // never rides along into the POST body.
        let idKey = service == .sonarr ? "tvdbId" : "tmdbId"
        let externalId = (candidate[idKey] as? Int) ?? args.id ?? 0
        guard externalId > 0 else {
            throw ToolExecutionError.badArgument(
                "Lookup for '\(title)' is missing its \(idKey); try again with an explicit 'id'."
            )
        }
        let payload: [String: Any] = if service == .sonarr {
            [
                "title": title,
                "tvdbId": externalId,
                "qualityProfileId": profileId,
                "rootFolderPath": rootFolder,
                "monitored": true,
                "addOptions": ["searchForMissingEpisodes": true]
            ]
        } else {
            [
                "title": title,
                "tmdbId": externalId,
                "qualityProfileId": profileId,
                "rootFolderPath": rootFolder,
                "monitored": true,
                "addOptions": ["searchForMovie": true]
            ]
        }

        let addEndpoint = service == .sonarr ? "api/v3/series" : "api/v3/movie"
        let addURL = baseURL.appendingPathComponent(addEndpoint)
        let postData = try JSONSerialization.data(withJSONObject: payload)
        let addReq = makeRequest(url: addURL, method: "POST", apiKey: apiKey, body: postData)

        let (addData, addResp) = try await sendFollowingRedirects(request: addReq)
        guard addResp.statusCode == 201 || addResp.statusCode == 200 else {
            throw ToolExecutionError.httpError(status: addResp.statusCode, body: errorPreview(addData))
        }

        return "Successfully added '\(title)' to \(service.rawValue.capitalized)!\n"
            + "- Quality Profile: \(profileName)\n"
            + "- Root Folder: \(rootFolder)\n"
            + "- Monitoring: enabled\n"
            + "- Automatic search triggered."
    }

    private func resolveRootFolder(service: MediaArrService, baseURL: URL, apiKey: String, override: String?) async throws -> String {
        // An explicit override must be a trimmed absolute POSIX path without
        // traversal so a model-supplied value cannot escape the library root;
        // absent or unprovided input falls through to the server list.
        if let validated = try validatedRootFolderOverride(override) {
            return validated
        }
        let url = baseURL.appendingPathComponent("api/v3/rootfolder")
        let req = makeRequest(url: url, apiKey: apiKey)
        let (data, resp) = try await sendFollowingRedirects(request: req)
        guard resp.statusCode == 200 else {
            throw ToolExecutionError.httpError(status: resp.statusCode, body: errorPreview(data))
        }
        let folders: [[String: Any]]?
        do {
            folders = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        } catch {
            RuneWeaverLog.tools.debug("resolveRootFolder: JSON parsing failed: \(error.localizedDescription)")
            folders = nil
        }
        guard let folders, let firstPath = folders.first?["path"] as? String else {
            throw ToolExecutionError.notFound(
                "No root folders configured in \(service.rawValue.capitalized). "
                    + "Please configure root folders in \(service.rawValue.capitalized) settings."
            )
        }
        return firstPath
    }

    private func resolveQualityProfile(service: MediaArrService, baseURL: URL, apiKey: String, override: String?) async throws -> (Int, String) {
        let url = baseURL.appendingPathComponent("api/v3/qualityprofile")
        let req = makeRequest(url: url, apiKey: apiKey)
        let (data, resp) = try await sendFollowingRedirects(request: req)
        guard resp.statusCode == 200 else {
            throw ToolExecutionError.httpError(status: resp.statusCode, body: errorPreview(data))
        }
        let profiles: [[String: Any]]?
        do {
            profiles = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        } catch {
            RuneWeaverLog.tools.debug("resolveQualityProfile: JSON parsing failed: \(error.localizedDescription)")
            profiles = nil
        }
        guard let profiles, !profiles.isEmpty else {
            throw ToolExecutionError.notFound("No quality profiles configured in \(service.rawValue.capitalized).")
        }

        // A named override must match exactly (case-insensitive); an unknown
        // name fails with the available list instead of silently taking the
        // first profile and recording with the wrong quality.
        if let rawOverride = override?.trimmingCharacters(in: .whitespacesAndNewlines), !rawOverride.isEmpty {
            let lowered = rawOverride.lowercased()
            if let matched = profiles.first(where: { (($0["name"] as? String)?.lowercased()) == lowered }) {
                let id = matched["id"] as? Int ?? 1
                let name = matched["name"] as? String ?? rawOverride
                return (id, name)
            }
            let available = profiles.compactMap { $0["name"] as? String }.joined(separator: ", ")
            throw ToolExecutionError.badArgument(
                "Unknown quality profile '\(rawOverride)' for \(service.rawValue.capitalized). Available: \(available.isEmpty ? "none" : available)."
            )
        }

        // Default to first profile
        let first = profiles[0]
        let id = first["id"] as? Int ?? 1
        let name = first["name"] as? String ?? "Default"
        return (id, name)
    }

    /// Validates an explicit root-folder override as an absolute POSIX path.
    private func validatedRootFolderOverride(_ override: String?) throws -> String? {
        guard let override else { return nil }
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolExecutionError.badArgument(
                "Invalid rootFolder override: must be a non-empty absolute path (e.g. /data/media/tv)."
            )
        }
        guard trimmed.hasPrefix("/") else {
            throw ToolExecutionError.badArgument(
                "Invalid rootFolder override '\(trimmed)': must be an absolute path starting with '/'."
            )
        }
        let segments = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        if segments.contains(where: { $0 == "." || $0 == ".." }) {
            throw ToolExecutionError.badArgument(
                "Invalid rootFolder override '\(trimmed)': '..' traversal is not allowed."
            )
        }
        return trimmed
    }
}

/// Errors raised during media tool operations.
public enum ToolExecutionError: LocalizedError, Sendable {
    case serviceDisabled(String)
    case unconfigured(String)
    case missingCredential(String)
    case invalidURL(String)
    case badArgument(String)
    case notFound(String)
    case httpError(status: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case let .serviceDisabled(msg),
             let .unconfigured(msg),
             let .missingCredential(msg),
             let .invalidURL(msg),
             let .badArgument(msg),
             let .notFound(msg):
            msg
        case let .httpError(status, body):
            "Server responded with HTTP \(status): \(body.prefix(200))"
        }
    }
}
