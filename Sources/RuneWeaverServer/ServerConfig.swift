// Rune Weaver Server — Service configuration and network binding policy.

import Foundation

/// Configuration for the engine HTTP API.
public struct ServerConfig: Sendable, Codable, Equatable {
    /// Valid TCP port range shared by direct construction and the CLI.
    public static let validPortRange = 1 ... 65535
    /// Interface to bind. Loopback only by design.
    public var hostname: String
    /// TCP port to bind. Must lie in `validPortRange`.
    public var port: Int

    /// Creates a server config.
    public init(hostname: String = "127.0.0.1", port: Int = 8082) {
        self.hostname = hostname
        self.port = port
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

    /// Preconditions loopback-only binding on a valid port.
    public func requireLoopback() throws {
        try requireValidPort()
        guard isLoopbackOnly else {
            throw ServerConfigError.nonLoopbackRefused(hostname)
        }
    }

    /// Preconditions a bindable port.
    public func requireValidPort() throws {
        guard isValidPort else {
            throw ServerConfigError.invalidPort(port)
        }
    }
}

/// Errors raised when validating server configuration.
public enum ServerConfigError: Error, LocalizedError, Sendable {
    case nonLoopbackRefused(String)
    case invalidPort(Int)

    public var errorDescription: String? {
        switch self {
        case let .nonLoopbackRefused(host):
            "Refusing to bind non-loopback hostname '\(host)' without authentication. Bind loopback (\(ServerConfig.default.hostname)) until auth lands."
        case let .invalidPort(port):
            "Invalid port \(port): must be in \(ServerConfig.validPortRange)."
        }
    }
}
