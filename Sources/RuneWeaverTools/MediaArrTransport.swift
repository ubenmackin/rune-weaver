// Rune Weaver Tools — Transport abstraction for Sonarr & Radarr HTTP communication.
//
// Purpose: isolates one no-follow HTTP round trip so the client can validate
// every redirect hop before dialing, with hermetic stubs for tests.
// Scope: single-request send only; timeouts, redirect budgets, and SSRF checks
// live with the client layer. Architectural role: the dial seam shared by the
// read and write tools — production uses an ephemeral session, tests inject a
// stub. Secrets never flow here directly; the session carries no persistent
// state and never auto-forwards credentials across hops.

import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Transport abstraction for media requests, enabling hermetic testing.
public protocol MediaArrTransport: Sendable {
    /// Executes one HTTP request without following redirects.
    /// Redirect responses surface as 3xx so the client can re-validate each hop
    /// before dialing; the session never forwards credentials automatically.
    func send(request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Standard production transport using `URLSession`.
public struct URLSessionMediaArrTransport: MediaArrTransport {
    /// Default request timeout, mirroring the web/API live transports.
    public static let timeoutSeconds: Double = 15

    /// Request timeout applied when the incoming request carries none.
    public let requestTimeoutSeconds: Double

    public init(timeoutSeconds: Double = URLSessionMediaArrTransport.timeoutSeconds) {
        self.requestTimeoutSeconds = timeoutSeconds
    }

    public func send(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var mutable = request
        if mutable.timeoutInterval < 1 {
            mutable.timeoutInterval = requestTimeoutSeconds
        }
        // Ephemeral session that surfaces 3xx instead of following: a compromised
        // LAN host must not forward the API key via 302 before the client
        // re-validates the next hop and strips credentials on cross-host moves.
        let delegate = NoRedirectDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: mutable)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, httpResponse)
    }
}
