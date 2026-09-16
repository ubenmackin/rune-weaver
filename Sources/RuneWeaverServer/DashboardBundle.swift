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

    /// Builds the HTTP response for one dashboard request path.
    public func response(for requestPath: String, fileManager: FileManager = .default) -> Response {
        guard bundleAvailable(using: fileManager) else {
            let trimmed = requestPath.trimmingCharacters(in: .whitespacesAndNewlines)
            let bare = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if bare.isEmpty || bare == "index.html" {
                return Response(
                    status: .ok,
                    headers: HTTPHeaders([
                        ("Content-Type", "text/html; charset=utf-8"),
                        (Self.bundleHeader, "stub")
                    ]),
                    body: .init(string: Self.stubHTML)
                )
            }
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
            return Response(
                status: .serviceUnavailable,
                headers: HTTPHeaders([
                    ("Content-Type", "application/json; charset=utf-8"),
                    (Self.bundleHeader, "stub")
                ]),
                body: .init(data: payload)
            )
        }
        if Self.sanitizedComponents(for: requestPath) == nil {
            return jsonError(status: .badRequest, message: "Invalid dashboard path", fileManager: fileManager)
        }
        let trimmed = requestPath.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty || trimmed == "index.html" {
            return fileResponse(at: indexFileURL(fileManager: fileManager), bundleState: "bundle", fileManager: fileManager)
        }
        if let file = localFileURL(for: requestPath, fileManager: fileManager) {
            let lastComponent = Self.sanitizedComponents(for: requestPath)?.last ?? ""
            let hasExtension = !(lastComponent as NSString).pathExtension.isEmpty
            let cacheControl = hasExtension ? "public, max-age=31536000, immutable" : "no-cache"
            return fileResponse(at: file, bundleState: "bundle", cacheControl: cacheControl, fileManager: fileManager)
        }
        if Self.isClientRoute(requestPath) {
            return fileResponse(at: indexFileURL(fileManager: fileManager), bundleState: "bundle", cacheControl: "no-cache", fileManager: fileManager)
        }
        return jsonError(status: .notFound, message: "Not found", fileManager: fileManager)
    }

    /// Reads a file URL into a 200 response.
    private func fileResponse(at url: URL?, bundleState: String, cacheControl: String = "no-cache", fileManager: FileManager = .default) -> Response {
        guard let url, let data = try? Data(contentsOf: url) else {
            return jsonError(status: .internalServerError, message: "Dashboard bundle unreadable", fileManager: fileManager)
        }
        return Response(
            status: .ok,
            headers: HTTPHeaders([
                ("Content-Type", Self.contentType(for: url.lastPathComponent)),
                ("Cache-Control", cacheControl),
                (Self.bundleHeader, bundleState)
            ]),
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
        return Response(
            status: status,
            headers: HTTPHeaders([
                ("Content-Type", "application/json; charset=utf-8"),
                (Self.bundleHeader, bundleAvailable(using: fileManager) ? "bundle" : "stub")
            ]),
            body: .init(data: payload)
        )
    }
}
