// Rune Weaver Server — Service configuration and network binding policy.

import Foundation

/// Configuration for the engine HTTP API.
public struct ServerConfig: Sendable, Codable, Equatable {
    /// Valid TCP port range shared by direct construction and the CLI.
    public static let validPortRange = 1 ... 65535
    /// Interface to bind. Loopback by default; non-loopback requires auth.
    public var hostname: String
    /// TCP port to bind. Must lie in `validPortRange`.
    public var port: Int
    /// Whether a resolvable owner bearer token is configured for this bind.
    ///
    /// Only the caller that resolved the token source can answer this
    /// truthfully, so it is an explicit input rather than a guess: a
    /// non-loopback endpoint is refused unless this is true. Defaults to
    /// false, preserving the v1 no-auth loopback posture.
    public var authConfigured: Bool

    /// Creates a server config.
    public init(hostname: String = "127.0.0.1", port: Int = 8082, authConfigured: Bool = false) {
        self.hostname = hostname
        self.port = port
        self.authConfigured = authConfigured
    }

    /// Whether the port lies in `validPortRange`.
    /// - Returns: True when the port is bindable.
    public var isValidPort: Bool {
        Self.validPortRange.contains(port)
    }

    /// Default loopback config: `127.0.0.1:8082`, no auth.
    public static var `default`: ServerConfig {
        ServerConfig()
    }

    /// Whether the config binds loopback only.
    /// - Returns: True when `hostname` is a loopback address.
    public var isLoopbackOnly: Bool {
        hostname == "127.0.0.1" || hostname == "localhost" || hostname == "::1"
    }

    /// Preconditions a bindable endpoint under the fail-closed LAN policy.
    ///
    /// Policy matrix: a loopback endpoint always passes; a non-loopback
    /// endpoint passes only when owner auth is configured, and otherwise
    /// throws ``ServerConfigError/nonLoopbackRefused(_:)`` rather than
    /// silently downgrading to an unauthenticated LAN bind. An out-of-range
    /// port always throws, independent of auth.
    /// - Parameter authConfigured: Resolved auth state; nil falls back to the
    ///   value captured on this config.
    public func requireBindable(authConfigured: Bool? = nil) throws {
        try requireValidPort()
        let hasAuth = authConfigured ?? self.authConfigured
        guard isLoopbackOnly || hasAuth else {
            throw ServerConfigError.nonLoopbackRefused(hostname)
        }
    }

    /// Preconditions a bindable port.
    public func requireValidPort() throws {
        guard isValidPort else {
            throw ServerConfigError.invalidPort(port)
        }
    }

    /// Wire keys mirror the JSON shape carried to in-process clients.
    private enum CodingKeys: String, CodingKey {
        case hostname
        case port
        case authConfigured
    }

    /// Decodes a server config, treating an absent `authConfigured` as false so
    /// payloads written before the auth flag existed keep decoding.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.hostname = try container.decodeIfPresent(String.self, forKey: .hostname) ?? "127.0.0.1"
        self.port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 8082
        self.authConfigured = try container.decodeIfPresent(Bool.self, forKey: .authConfigured) ?? false
    }

    /// Encodes a server config including the resolved auth flag.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hostname, forKey: .hostname)
        try container.encode(port, forKey: .port)
        try container.encode(authConfigured, forKey: .authConfigured)
    }
}

/// Errors raised when validating server configuration.
public enum ServerConfigError: Error, LocalizedError, Sendable {
    case nonLoopbackRefused(String)
    case invalidPort(Int)

    public var errorDescription: String? {
        switch self {
        case let .nonLoopbackRefused(host):
            "Refusing to bind non-loopback hostname '\(host)' without a configured owner token. "
                + "Configure owner auth to serve beyond this host, or bind loopback (\(ServerConfig.default.hostname))."
        case let .invalidPort(port):
            "Invalid port \(port): must be in \(ServerConfig.validPortRange)."
        }
    }
}
