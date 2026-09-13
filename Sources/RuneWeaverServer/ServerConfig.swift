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
    /// Single source for port validation: `ServerConfig.init` preconditions
    /// on it and the `serve` command validates `--port` against it so the
    /// two cannot drift.
    public static let validPortRange = 1 ... 65535
    /// Interface to bind. Loopback only by design.
    public var hostname: String
    /// TCP port to bind. Must lie in `validPortRange`.
    public var port: Int

    /// Creates a server config.
    ///
    /// - Precondition: `port` must lie in `validPortRange`; traps otherwise
    ///   so direct/test construction fails fast instead of surfacing as an
    ///   obscure Vapor bind failure.
    /// - Parameters:
    ///   - hostname: Interface to bind. Defaults to loopback.
    ///   - port: TCP port. Defaults to 8082 (MLX uses 8080, llama.cpp uses 8081).
    public init(hostname: String = "127.0.0.1", port: Int = 8082) {
        precondition(
            Self.validPortRange.contains(port),
            "port must be in \(Self.validPortRange) (got \(port))"
        )
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

    /// Preconditions loopback-only binding.
    ///
    /// Auth-before-exposure: authentication must land before the service
    /// binds a non-loopback interface or leaves the machine. Traps with
    /// `fatalError` (never `precondition`, which is stripped in
    /// `-Ounchecked`) when `hostname` is not loopback so a misconfigured
    /// non-loopback bind never silently exposes the no-auth surface, even
    /// in release builds.
    public func requireLoopback() {
        guard isLoopbackOnly else {
            fatalError(
                "Refusing to bind non-loopback hostname '\(hostname)' without authentication. " +
                    "Bind loopback (\(ServerConfig.default.hostname)) until auth lands."
            )
        }
    }
}
