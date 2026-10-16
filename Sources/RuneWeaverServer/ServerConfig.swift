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
    public var authConfigured: Bool
    /// Extra exact hostnames the Host gate accepts beside loopback and the bind hostname.
    public var allowedHosts: [String]

    /// Creates a server config.
    public init(hostname: String = "127.0.0.1", port: Int = 8082, authConfigured: Bool = false, allowedHosts: [String] = []) {
        self.hostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.authConfigured = authConfigured
        self.allowedHosts = allowedHosts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
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

    /// Whether a hostname binds loopback only. The bracketed IPv6 spelling counts because clients
    /// send either form, and surrounding whitespace or case must not flip a loopback bind into a LAN
    /// bind (or the reverse).
    public static func isLoopbackHostname(_ hostname: String) -> Bool {
        let trimmed = hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == "127.0.0.1" || trimmed == "localhost" || trimmed == "::1" || trimmed == "[::1]"
    }

    /// Whether the config binds loopback only.
    /// - Returns: True when `hostname` is a loopback address.
    public var isLoopbackOnly: Bool {
        Self.isLoopbackHostname(hostname)
    }

    /// Preconditions a bindable endpoint under the fail-closed LAN policy.
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
        case allowedHosts
    }

    /// Decodes a server config, treating an absent `authConfigured` as false so payloads written
    /// before the auth flag existed keep decoding.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawHostname = try container.decodeIfPresent(String.self, forKey: .hostname) ?? "127.0.0.1"
        self.hostname = rawHostname.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 8082
        self.authConfigured = try container.decodeIfPresent(Bool.self, forKey: .authConfigured) ?? false
        let rawHosts = try container.decodeIfPresent([String].self, forKey: .allowedHosts) ?? []
        self.allowedHosts = rawHosts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Encodes a server config including the resolved auth flag.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hostname, forKey: .hostname)
        try container.encode(port, forKey: .port)
        try container.encode(authConfigured, forKey: .authConfigured)
        try container.encode(allowedHosts, forKey: .allowedHosts)
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
                + "Configure owner auth to serve beyond this host, or bind loopback (127.0.0.1, localhost, ::1, or [::1])."
        case let .invalidPort(port):
            "Invalid port \(port): must be in \(ServerConfig.validPortRange)."
        }
    }
}
