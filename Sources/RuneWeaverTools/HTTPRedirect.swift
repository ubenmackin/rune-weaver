// Rune Weaver Tools — Shared HTTP redirect follower for web and API hops.

import Foundation

/// Shared redirect policy for manual 5-hop chains.
public enum HTTPRedirectFollower: Sendable {
    /// Maximum redirects followed before failing closed.
    public static let maxRedirects = 5

    /// Resolves a redirect `Location` against the current URL.
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

/// Session delegate that surfaces redirects instead of following them. `api.request` uses the
/// pinned dialer instead, since a URLSession dial re-resolves the hostname and cannot preserve the
/// SSRF gate's address pin.
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

/// Helper that surfaces redirects without following them and caps downloaded bytes,
/// terminating the async streaming sequence once maxBytes is reached to prevent unbounded memory exhaustion.
enum CappedNoRedirectDelegate: Sendable {
    /// Performs one capped HTTP download without following redirects.
    static func downloadCapped(
        request: URLRequest,
        maxBytes: Int,
        timeoutSeconds: Double
    ) async throws -> (Data, URLResponse) {
        var mutable = request
        if mutable.timeoutInterval < 1 {
            mutable.timeoutInterval = timeoutSeconds
        }
        let delegate = NoRedirectDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: mutable, delegate: delegate)
        var buffer = Data()
        buffer.reserveCapacity(min(maxBytes + 1, 65536))
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count > maxBytes {
                break
            }
        }
        return (buffer, response)
    }
}
