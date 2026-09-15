// Rune Weaver Server — Service configuration and network binding policy.
//
// Encapsulates hostname, port, and loopback verification settings for the API
// server. Enforces the auth-before-exposure invariant by rejecting non-loopback
// network interfaces at startup until an authentication system is implemented.

import Foundation

/// Configuration for the engine HTTP API.
///
/// The API binds to loopback only (`127.0.0.1:8082` by default) and serves
/// every client — iOS, macOS menu bar, and web dashboard — from one shared
/// surface with no per-client feature forks. There is no authentication:
/// single-user design trusts the local machine only; remote access over
/// WireGuard deferred until auth lands. Never bind to `0.0.0.0` or expose this port to the public
/// internet. The default port avoids the local LLM servers (MLX on 8080,
/// llama.cpp on 8081) so the engine and inference can run side by side.
///
/// Auth-before-exposure: `configureRuneWeaver` refuses to bind a
/// non-loopback interface until authentication lands.
public struct ServerConfig: Sendable, Codable, Equatable {
    /// Valid TCP port range shared by direct construction and the CLI.
    ///
    /// Single source for port validation: callers check membership before
    /// construction (the `serve` command rejects out-of-range `--port` with
    /// a `ValidationError`) and `requireValidPort()` fails closed with
    /// `ServerConfigError.invalidPort` on the serve path, so the two cannot
    /// drift and a bad port never traps the process.
    public static let validPortRange = 1 ... 65535
    /// Interface to bind. Loopback only by design.
    public var hostname: String
    /// TCP port to bind. Must lie in `validPortRange`.
    public var port: Int

    /// Creates a server config.
    ///
    /// Out-of-range ports are stored as-is (never trapped) so user-controlled
    /// input cannot crash the process; validate before construction via
    /// `validPortRange` / `isValidPort`, or fail closed on the serve path
    /// via `requireValidPort()`.
    /// - Parameters:
    ///   - hostname: Interface to bind. Defaults to loopback.
    ///   - port: TCP port. Defaults to 8082 (MLX uses 8080, llama.cpp uses 8081).
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
    ///
    /// Auth-before-exposure: authentication must land before the service
    /// binds a non-loopback interface or leaves the machine. Throws
    /// `ServerConfigError.invalidPort` when `port` lies outside
    /// `validPortRange` so a misconfigured port fails closed instead of
    /// surfacing as an obscure Vapor bind failure, and
    /// `ServerConfigError.nonLoopbackRefused` when `hostname` is not loopback so a misconfigured
    /// non-loopback bind never silently exposes the no-auth surface.
    public func requireLoopback() throws {
        try requireValidPort()
        guard isLoopbackOnly else {
            throw ServerConfigError.nonLoopbackRefused(hostname)
        }
    }

    /// Preconditions a bindable port.
    ///
    /// Fail-closed counterpart to `isValidPort` for user-controlled input
    /// (`--port`, dashboard edits, direct construction): the initializer
    /// never traps, so this is where an out-of-range port becomes an error
    /// instead of a crash or a confusing bind failure.
    /// - Throws: `ServerConfigError.invalidPort` when `port` lies outside `validPortRange`.
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
