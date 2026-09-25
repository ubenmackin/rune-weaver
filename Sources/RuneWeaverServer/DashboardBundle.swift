// Rune Weaver Server — Static web dashboard bundle resolution and delivery.

import Foundation
import Vapor

/// Static dashboard bundle served by the engine process.
public struct DashboardBundle: Sendable, Equatable {
    /// Bundle directory containing `index.html` plus hashed assets, or
    /// nil when the bundle was never built.
    public var directoryURL: URL?

    /// Creates a bundle reference.
    /// - Parameter directoryURL: Bundle directory, or nil when missing.
    public init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL
    }

    /// Relative path from the package root to the compiled bundle.
    public static let relativeDistPath = "Web/dist"

    /// Environment variable overriding the bundle directory.
    public static let environmentKey = "RUNEWEAVER_DASHBOARD_DIR"

    /// Value sent on every dashboard response so clients can tell a real
    /// bundle from the missing-build stub without parsing bodies.
    public static let bundleHeader = "X-RuneWeaver-Dashboard"

    /// Cache-Control applied to HTML entry points (index.html, root, and SPA client-side routes).
    /// Enforces no-store so new application builds and asset hashes are picked up immediately
    /// without requiring users to clear browser caches.
    public static let htmlCacheControl = "no-store, no-cache, must-revalidate, max-age=0"

    /// Cache-Control applied to fingerprinted bundle assets in `assets/`.
    public static let assetCacheControl = "public, max-age=31536000, immutable"

    /// Cache-Control applied to non-fingerprinted static files (favicons, manifests, etc.).
    public static let staticFileCacheControl = "no-cache, must-revalidate"

    /// Resolves the bundle directory without failing when Node/npm never ran.
    public static func resolve(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DashboardBundle {
        var candidates: [URL] = []
        if let override = environment[environmentKey], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        if let bundleResources = Bundle.main.resourceURL {
            candidates.append(bundleResources.appendingPathComponent("web", isDirectory: true))
        }
        candidates.append(URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(relativeDistPath, isDirectory: true))
        let sourceFile = URL(fileURLWithPath: #filePath)
        let packageRoot = sourceFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        candidates.append(packageRoot.appendingPathComponent(relativeDistPath, isDirectory: true))
        for candidate in candidates where isBundleDirectory(candidate, fileManager: fileManager) {
            return DashboardBundle(directoryURL: candidate)
        }
        return DashboardBundle(directoryURL: nil)
    }

    /// Whether a directory holds a built bundle.
    public static func isBundleDirectory(_ url: URL, fileManager: FileManager = .default) -> Bool {
        let index = url.appendingPathComponent("index.html", isDirectory: false)
        return fileManager.fileExists(atPath: index.path)
    }

    /// Whether the bundle directory holds an `index.html` right now.
    /// - Returns: True when a built bundle can be served.
    public var isAvailable: Bool {
        bundleAvailable()
    }

    /// Whether the bundle directory holds an `index.html` right now.
    /// - Parameter fileManager: Filesystem accessor. Defaults to shared.
    /// - Returns: True when a built bundle can be served.
    public func bundleAvailable(using fileManager: FileManager = .default) -> Bool {
        guard let directoryURL else { return false }
        return Self.isBundleDirectory(directoryURL, fileManager: fileManager)
    }

    /// Hint shown when the bundle was never built.
    public static var stubHint: String {
        "Dashboard bundle not built. Run `cd Web && npm ci && npm run build`, then restart the engine."
    }

    /// Placeholder page served for `GET /` when `Web/dist` is missing.
    public static var stubHTML: String {
        """
        <!doctype html>
        <html lang="en">
        <head><meta charset="utf-8" /><title>Rune Weaver Dashboard</title></head>
        <body>
        <main>
        <h1>Rune Weaver Dashboard</h1>
        <p>\(stubHint)</p>
        <p>Requires Node.js 20 or later plus npm. The bundle is compiled once with npm and served
        by the engine on this same loopback origin with no runtime Node server and no CORS.</p>
        </main>
        </body>
        </html>
        """
    }

    /// Content type for a bundle file name.
    /// - Parameter path: File name or request path.
    /// - Returns: Content type including charset for text types.
    public static func contentType(for path: String) -> String {
        let lower = path.lowercased()
        if lower.hasSuffix(".html") {
            return "text/html; charset=utf-8"
        }
        if lower.hasSuffix(".js") || lower.hasSuffix(".mjs") {
            return "text/javascript; charset=utf-8"
        }
        if lower.hasSuffix(".css") {
            return "text/css; charset=utf-8"
        }
        if lower.hasSuffix(".json") || lower.hasSuffix(".map") {
            return "application/json; charset=utf-8"
        }
        if lower.hasSuffix(".webmanifest") {
            return "application/manifest+json; charset=utf-8"
        }
        if lower.hasSuffix(".svg") {
            return "image/svg+xml"
        }
        if lower.hasSuffix(".png") {
            return "image/png"
        }
        if lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") {
            return "image/jpeg"
        }
        if lower.hasSuffix(".ico") {
            return "image/x-icon"
        }
        if lower.hasSuffix(".woff2") {
            return "font/woff2"
        }
        if lower.hasSuffix(".woff") {
            return "font/woff"
        }
        if lower.hasSuffix(".txt") {
            return "text/plain; charset=utf-8"
        }
        return "application/octet-stream"
    }

    /// Sanitizes a request path into path components.
    public static func sanitizedComponents(for requestPath: String) -> [String]? {
        var trimmed = requestPath.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasPrefix("/") {
            trimmed.removeFirst()
        }
        if trimmed.isEmpty {
            return []
        }
        let raw = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var components: [String] = []
        for part in raw {
            let decoded = part.removingPercentEncoding ?? part
            if decoded == ".." {
                return nil
            }
            if decoded == "." || decoded.isEmpty {
                continue
            }
            if decoded.contains("/") {
                return nil
            }
            components.append(decoded)
        }
        return components
    }

    /// File URL for a request path when that exact file exists.
    public func localFileURL(for requestPath: String, fileManager: FileManager = .default) -> URL? {
        guard let directoryURL, let components = Self.sanitizedComponents(for: requestPath) else { return nil }
        guard !components.isEmpty else { return nil }
        var url = directoryURL
        for component in components {
            url.appendPathComponent(component, isDirectory: false)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return nil }
        let resolvedDir = directoryURL.resolvingSymlinksInPath().standardized
        let resolvedCandidate = url.resolvingSymlinksInPath().standardized
        let dirPrefix = resolvedDir.path.hasSuffix("/") ? resolvedDir.path : resolvedDir.path + "/"
        guard resolvedCandidate.path.hasPrefix(dirPrefix) else { return nil }
        return url
    }

    /// File URL for the bundle entry point.
    public func indexFileURL(fileManager: FileManager = .default) -> URL? {
        guard let directoryURL, Self.isBundleDirectory(directoryURL, fileManager: fileManager) else { return nil }
        let candidate = directoryURL.appendingPathComponent("index.html", isDirectory: false)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return nil }
        let resolvedDir = directoryURL.resolvingSymlinksInPath().standardized
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardized
        let dirPrefix = resolvedDir.path.hasSuffix("/") ? resolvedDir.path : resolvedDir.path + "/"
        guard resolvedCandidate.path.hasPrefix(dirPrefix) else { return nil }
        return candidate
    }

    /// Whether a request path looks like a client-side route.
    public static func isClientRoute(_ requestPath: String) -> Bool {
        guard let components = sanitizedComponents(for: requestPath), !components.isEmpty else { return false }
        guard let last = components.last else { return false }
        return (last as NSString).pathExtension.isEmpty
    }

    /// Builds the HTTP response for one dashboard request path (streaming via Vapor Request).
    /// Sole entry point wired into routes so bundle bytes stream without blocking the event loop.
    public func response(for req: Request, requestPath: String, fileManager: FileManager = .default) async throws -> Response {
        switch route(for: requestPath, fileManager: fileManager) {
        case .stubIndex:
            Self.stubIndexResponse()
        case .stubMissing:
            Self.stubMissingResponse()
        case .invalidPath:
            jsonError(status: .badRequest, message: "Invalid dashboard path", fileManager: fileManager)
        case .index:
            try await fileResponse(
                req: req,
                at: indexFileURL(fileManager: fileManager),
                bundleState: "bundle",
                cacheControl: Self.htmlCacheControl,
                fileManager: fileManager
            )
        case let .file(url, cacheControl):
            try await fileResponse(
                req: req,
                at: url,
                bundleState: "bundle",
                cacheControl: cacheControl,
                fileManager: fileManager
            )
        case .clientFallback:
            try await fileResponse(
                req: req,
                at: indexFileURL(fileManager: fileManager),
                bundleState: "bundle",
                cacheControl: Self.htmlCacheControl,
                fileManager: fileManager
            )
        case .notFound:
            jsonError(status: .notFound, message: "Not found", fileManager: fileManager)
        }
    }

    /// Builds the HTTP response for one dashboard request path (synchronous test-only fallback).
    /// Production routes must use `response(for:req:requestPath:)` above so bundle bytes stream
    /// without blocking the event loop; this entry point exists only for unit tests that have no
    /// `Request` and must never be wired into routes.
    public func response(for requestPath: String, fileManager: FileManager = .default) -> Response {
        switch route(for: requestPath, fileManager: fileManager) {
        case .stubIndex:
            Self.stubIndexResponse()
        case .stubMissing:
            Self.stubMissingResponse()
        case .invalidPath:
            jsonError(status: .badRequest, message: "Invalid dashboard path", fileManager: fileManager)
        case .index:
            fileResponse(
                at: indexFileURL(fileManager: fileManager),
                bundleState: "bundle",
                cacheControl: Self.htmlCacheControl,
                fileManager: fileManager
            )
        case let .file(url, cacheControl):
            fileResponse(at: url, bundleState: "bundle", cacheControl: cacheControl, fileManager: fileManager)
        case .clientFallback:
            fileResponse(
                at: indexFileURL(fileManager: fileManager),
                bundleState: "bundle",
                cacheControl: Self.htmlCacheControl,
                fileManager: fileManager
            )
        case .notFound:
            jsonError(status: .notFound, message: "Not found", fileManager: fileManager)
        }
    }

    /// Single routing decision shared by both response entry points.
    /// Centralizing stub, validation, and cache policy here keeps the
    /// streaming and synchronous deliveries from drifting on edge cases.
    private enum DashboardRoute: Equatable {
        case stubIndex
        case stubMissing
        case invalidPath
        case index
        case file(URL, cacheControl: String)
        case clientFallback
        case notFound
    }

    /// Classifies one request path into a routing decision.
    /// - Parameters:
    ///   - requestPath: Raw request path.
    ///   - fileManager: Filesystem accessor.
    /// - Returns: Routing decision covering stub and bundle states.
    private func route(for requestPath: String, fileManager: FileManager = .default) -> DashboardRoute {
        guard bundleAvailable(using: fileManager) else {
            return Self.isStubIndexPath(requestPath) ? .stubIndex : .stubMissing
        }
        guard let components = Self.sanitizedComponents(for: requestPath) else {
            return .invalidPath
        }
        // Slash-trimmed comparison keeps `/`, ``, and `index.html` on the entry point.
        let trimmed = requestPath.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty || trimmed == "index.html" {
            return .index
        }
        if let file = localFileURL(for: requestPath, fileManager: fileManager) {
            let lastComponent = components.last ?? ""
            let hasExtension = !(lastComponent as NSString).pathExtension.isEmpty
            // Only fingerprinted assets under assets/ carry content hashes and can cache immutably;
            // unhashed root assets (favicons, manifests, etc.) require revalidation before reuse.
            let isHashedAsset = components.first == "assets" && hasExtension
            let cacheControl = isHashedAsset ? Self.assetCacheControl : Self.staticFileCacheControl
            return .file(file, cacheControl: cacheControl)
        }
        if Self.isClientRoute(requestPath) {
            return .clientFallback
        }
        return .notFound
    }

    /// Whether a request path targets the stub entry page when no bundle exists.
    private static func isStubIndexPath(_ requestPath: String) -> Bool {
        let trimmed = requestPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return bare.isEmpty || bare == "index.html"
    }
}

// MARK: - Security Headers & Response Formatting

extension DashboardBundle {
    /// Content Security Policy applied to dashboard responses.
    public static let contentSecurityPolicy = [
        "default-src 'self';",
        "script-src 'self';",
        "style-src 'self' 'unsafe-inline';",
        "img-src 'self' data: blob:;",
        "font-src 'self';",
        "connect-src 'self' ws: wss:;",
        "frame-ancestors 'none';",
        "base-uri 'self';",
        "object-src 'none';"
    ].joined(separator: " ")

    /// Injects standard defense-in-depth HTTP security headers into dashboard responses.
    public static func applySecurityHeaders(to headers: inout HTTPHeaders) {
        headers.replaceOrAdd(name: "Content-Security-Policy", value: contentSecurityPolicy)
        headers.replaceOrAdd(name: "X-Frame-Options", value: "DENY")
        headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        headers.replaceOrAdd(name: "Referrer-Policy", value: "strict-origin-when-cross-origin")
    }

    /// Placeholder page for `GET /` when the bundle was never built.
    private static func stubIndexResponse() -> Response {
        var headers = HTTPHeaders([
            ("Content-Type", "text/html; charset=utf-8"),
            (bundleHeader, "stub")
        ])
        applySecurityHeaders(to: &headers)
        return Response(
            status: .ok,
            headers: headers,
            body: .init(string: stubHTML)
        )
    }

    /// Machine-readable stub error for asset paths when the bundle was never built.
    private static func stubMissingResponse() -> Response {
        let payload: Data
        do {
            payload = try JSONSerialization.data(
                withJSONObject: [
                    "error": "dashboard-not-built",
                    "hint": Self.stubHint
                ],
                options: []
            )
        } catch {
            payload = Data(#"{"error":"dashboard-not-built","hint":"ok"}"#.utf8)
        }
        var headers = HTTPHeaders([
            ("Content-Type", "application/json; charset=utf-8"),
            (Self.bundleHeader, "stub")
        ])
        applySecurityHeaders(to: &headers)
        return Response(
            status: .serviceUnavailable,
            headers: headers,
            body: .init(data: payload)
        )
    }

    private func fileResponse(
        req: Request,
        at url: URL?,
        bundleState: String,
        cacheControl: String = htmlCacheControl,
        fileManager: FileManager = .default
    ) async throws -> Response {
        guard let url else {
            return jsonError(status: .internalServerError, message: "Dashboard bundle unreadable", fileManager: fileManager)
        }
        let res = try await req.fileio.asyncStreamFile(at: url.path)
        res.headers.replaceOrAdd(name: "Content-Type", value: Self.contentType(for: url.lastPathComponent))
        res.headers.replaceOrAdd(name: "Cache-Control", value: cacheControl)
        if cacheControl == Self.htmlCacheControl {
            res.headers.replaceOrAdd(name: "Pragma", value: "no-cache")
            res.headers.replaceOrAdd(name: "Expires", value: "0")
        }
        res.headers.replaceOrAdd(name: Self.bundleHeader, value: bundleState)
        Self.applySecurityHeaders(to: &res.headers)
        return res
    }

    /// Reads a file URL into a 200 response (synchronous test-only fallback).
    /// Blocking file I/O stays confined to unit tests here; production routes use the streaming
    /// `fileResponse(req:at:bundleState:cacheControl:fileManager:)` above so the event loop never blocks.
    private func fileResponse(
        at url: URL?,
        bundleState: String,
        cacheControl: String = htmlCacheControl,
        fileManager: FileManager = .default
    ) -> Response {
        guard let url, let data = try? Data(contentsOf: url) else {
            return jsonError(status: .internalServerError, message: "Dashboard bundle unreadable", fileManager: fileManager)
        }
        var headers = HTTPHeaders([
            ("Content-Type", Self.contentType(for: url.lastPathComponent)),
            ("Cache-Control", cacheControl),
            (Self.bundleHeader, bundleState)
        ])
        if cacheControl == Self.htmlCacheControl {
            headers.replaceOrAdd(name: "Pragma", value: "no-cache")
            headers.replaceOrAdd(name: "Expires", value: "0")
        }
        Self.applySecurityHeaders(to: &headers)
        return Response(
            status: .ok,
            headers: headers,
            body: .init(data: data)
        )
    }

    /// Builds a small JSON error response.
    private func jsonError(status: HTTPResponseStatus, message: String, fileManager: FileManager = .default) -> Response {
        let payload: Data
        do {
            payload = try JSONSerialization.data(withJSONObject: ["error": message], options: [])
        } catch {
            payload = Data(#"{"error":"ok"}"#.utf8)
        }
        var headers = HTTPHeaders([
            ("Content-Type", "application/json; charset=utf-8"),
            (Self.bundleHeader, bundleAvailable(using: fileManager) ? "bundle" : "stub")
        ])
        Self.applySecurityHeaders(to: &headers)
        return Response(
            status: status,
            headers: headers,
            body: .init(data: payload)
        )
    }
}
