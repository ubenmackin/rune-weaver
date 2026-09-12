// Rune Weaver Tests — Static dashboard bundle delivery and SPA routing tests.
//
// Verifies dashboard directory discovery, MIME type resolution, static asset
// serving, 404 handling, and single-page application fallback to index.html.

import Foundation
@testable import RuneWeaverServer
import Testing
import Vapor

/// Creates a temporary dashboard bundle directory for tests.
/// - Parameters:
///   - indexHTML: Entry point contents. Defaults to a stub page.
///   - assets: Extra files relative to the bundle root.
/// - Returns: Bundle directory URL for cleanup by the caller.
private func makeBundleDirectory(
    indexHTML: String = "<html><body>dashboard</body></html>",
    assets: [String: String] = [:]
) throws -> URL {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    try indexHTML.write(to: base.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    for (relative, contents) in assets {
        let url = base.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
    return base
}

@Suite("Dashboard Bundle")
struct DashboardBundleTests {
    @Test
    func `Bundle constants describe the npm build output`() {
        #expect(DashboardBundle.relativeDistPath == "Web/dist")
        #expect(DashboardBundle.environmentKey == "RUNEWEAVER_DASHBOARD_DIR")
        #expect(DashboardBundle.bundleHeader == "X-RuneWeaver-Dashboard")
    }

    @Test
    func `Stub reports the Node build steps`() {
        #expect(DashboardBundle.stubHint.contains("npm ci"))
        #expect(DashboardBundle.stubHint.contains("npm run build"))
        #expect(DashboardBundle.stubHTML.contains("npm ci"))
        #expect(DashboardBundle.stubHTML.contains("Node.js 20"))
        #expect(DashboardBundle.stubHTML.contains("no runtime Node server"))
        #expect(DashboardBundle.stubHTML.contains("no CORS"))
    }

    @Test
    func `Content types cover the Vite output`() {
        #expect(DashboardBundle.contentType(for: "index.html").contains("text/html"))
        #expect(DashboardBundle.contentType(for: "assets/app.js").contains("javascript"))
        #expect(DashboardBundle.contentType(for: "assets/app.css").contains("text/css"))
        #expect(DashboardBundle.contentType(for: "data.json").contains("application/json"))
        #expect(DashboardBundle.contentType(for: "logo.svg").contains("image/svg+xml"))
        #expect(DashboardBundle.contentType(for: "icon.png").contains("image/png"))
    }

    @Test
    func `Sanitized components reject traversal`() {
        #expect(DashboardBundle.sanitizedComponents(for: "") == [])
        #expect(DashboardBundle.sanitizedComponents(for: "/") == [])
        #expect(DashboardBundle.sanitizedComponents(for: "assets/app.js") == ["assets", "app.js"])
        #expect(DashboardBundle.sanitizedComponents(for: "../secret") == nil)
        #expect(DashboardBundle.sanitizedComponents(for: "assets/../../etc") == nil)
    }

    @Test
    func `Client routes fall back while hashed assets do not`() {
        #expect(DashboardBundle.isClientRoute("approvals") == true)
        #expect(DashboardBundle.isClientRoute("") == false)
        #expect(DashboardBundle.isClientRoute("assets/app-abc123.js") == false)
        #expect(DashboardBundle.isClientRoute("index.html") == false)
    }

    @Test
    func `Bundle directory detection needs index html`() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(DashboardBundle.isBundleDirectory(empty) == false)
        let built = try makeBundleDirectory()
        defer { try? FileManager.default.removeItem(at: built) }
        #expect(DashboardBundle.isBundleDirectory(built) == true)
        #expect(DashboardBundle(directoryURL: nil).isAvailable == false)
        #expect(DashboardBundle(directoryURL: empty).isAvailable == false)
        #expect(DashboardBundle(directoryURL: built).isAvailable == true)
    }

    @Test
    func `Missing bundle stubs the entry point and reports assets`() {
        let bundle = DashboardBundle(directoryURL: nil)
        let root = bundle.response(for: "")
        #expect(root.status == .ok)
        #expect(root.headers.first(name: DashboardBundle.bundleHeader) == "stub")
        #expect(root.headers.contentType?.description.contains("text/html") == true)
        let asset = bundle.response(for: "assets/app.js")
        #expect(asset.status == .serviceUnavailable)
        #expect(asset.headers.first(name: DashboardBundle.bundleHeader) == "stub")
    }

    @Test
    func `Available bundle serves the entry point`() throws {
        let built = try makeBundleDirectory(indexHTML: "<html>entry</html>")
        defer { try? FileManager.default.removeItem(at: built) }
        let bundle = DashboardBundle(directoryURL: built)
        let root = bundle.response(for: "")
        #expect(root.status == .ok)
        #expect(root.headers.first(name: DashboardBundle.bundleHeader) == "bundle")
        let index = bundle.response(for: "index.html")
        #expect(index.status == .ok)
    }

    @Test
    func `Available bundle serves hashed assets with immutable caching`() throws {
        let built = try makeBundleDirectory(assets: ["assets/app.js": "console.log(1)"])
        defer { try? FileManager.default.removeItem(at: built) }
        let bundle = DashboardBundle(directoryURL: built)
        #expect(bundle.localFileURL(for: "assets/app.js") != nil)
        let response = bundle.response(for: "assets/app.js")
        #expect(response.status == .ok)
        #expect(response.headers.first(name: DashboardBundle.bundleHeader) == "bundle")
        #expect(response.headers.first(name: "Content-Type")?.contains("javascript") == true)
        #expect(response.headers.first(name: "Cache-Control")?.contains("immutable") == true)
    }

    @Test
    func `Available bundle falls back to index for client routes`() throws {
        let built = try makeBundleDirectory(indexHTML: "<html>entry</html>")
        defer { try? FileManager.default.removeItem(at: built) }
        let bundle = DashboardBundle(directoryURL: built)
        #expect(bundle.response(for: "approvals").status == .ok)
    }

    @Test
    func `Available bundle 404s missing hashed assets`() throws {
        let built = try makeBundleDirectory()
        defer { try? FileManager.default.removeItem(at: built) }
        let bundle = DashboardBundle(directoryURL: built)
        #expect(bundle.localFileURL(for: "assets/missing.js") == nil)
        #expect(bundle.response(for: "assets/missing.js").status == .notFound)
    }

    @Test
    func `Available bundle rejects traversal`() throws {
        let built = try makeBundleDirectory()
        defer { try? FileManager.default.removeItem(at: built) }
        let bundle = DashboardBundle(directoryURL: built)
        #expect(bundle.response(for: "../secret").status == .badRequest)
    }
}
