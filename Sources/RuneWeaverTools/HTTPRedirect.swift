// Rune Weaver Tools — Shared HTTP redirect follower for web and API hops.
//
// Manual redirect chains stay single-source here so `web.fetch` and `api.request`
// cannot diverge on hop budget, relative-Location resolution, or redirect
// surfacing. Both transports disable automatic following and resolve every hop
// against the current URL, then re-validate the next hop with the shared URL
// allowlist plus the SSRF guard before dialing; a safe start can never launder
// an unsafe redirect target through the session follower.

import Foundation

/// Shared redirect policy for manual 5-hop chains.
public enum HTTPRedirectFollower: Sendable {
    /// Maximum redirects followed before failing closed.
    public static let maxRedirects = 5

    /// Resolves a redirect `Location` against the current URL.
    /// Fails closed on absolute non-web targets (`javascript:`, `data:`,
    /// `file:`, and friends): the shared policy never hands callers a URL
    /// they must re-validate, so an unsafe hop cannot launder through the
    /// session follower. Relative targets inherit the current http(s) scheme.
    public static func resolveRedirect(current: URL, location: String) -> URL? {
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let resolved = URL(string: trimmed, relativeTo: current)?.absoluteURL,
              let scheme = resolved.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return resolved
    }

    /// Resolves a redirect `Location` header from a response.
    public static func redirectTarget(http: HTTPURLResponse, currentURL: URL) -> URL? {
        guard let location = http.value(forHTTPHeaderField: "Location")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !location.isEmpty
        else {
            return nil
        }
        return resolveRedirect(current: currentURL, location: location)
    }
}

/// Single-source JSON encoding for tool output envelopes.
///
/// Every tool envelope (`web.search`, `web.fetch`, `browser.navigate`/`browser.act`,
/// `api.request`) encodes through this helper with sorted, pretty-printed keys so
/// the four surfaces cannot drift on formatting; per-tool encoder copies are
/// intentionally absent.
public enum ToolEnvelopeEncoding: Sendable {
    /// Encodes one envelope as the tool output document.
    /// - Parameter envelope: Encodable envelope value.
    /// - Returns: Sorted, pretty-printed JSON document.
    public static func encode(_ envelope: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(envelope)
        return String(bytes: data, encoding: .utf8) ?? ""
    }
}

/// Session delegate that surfaces redirects instead of following them.
///
/// Single-sourced no-follow policy shared by the `web.fetch` and `api.request`
/// live transports. Both chains follow redirects manually so every hop can be
/// re-validated; a per-tool delegate copy would risk one transport silently
/// auto-following while the other surfaces 3xx.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
