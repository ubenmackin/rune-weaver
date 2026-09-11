import Foundation
import RuneWeaverCore

/// Resolved credentials for one email account.
///
/// Bundles the non-sensitive connection fields from `EmailAccount` with
/// the runtime-resolved password. The password is held in memory only:
/// `description` redacts it, and `EmailCredentialError` messages never
/// include it.
public struct ResolvedEmailCredentials: Sendable, Equatable {
    /// Account nickname (e.g. `icloud`).
    public let accountName: String
    /// IMAP hostname.
    public let host: String
    /// IMAP port.
    public let port: Int
    /// Login username.
    public let username: String
    /// Runtime-resolved password. Never log or print.
    public let password: String

    /// Creates resolved credentials from explicit fields.
    /// - Parameters:
    ///   - accountName: Account nickname.
    ///   - host: IMAP hostname.
    ///   - port: IMAP port.
    ///   - username: Login username.
    ///   - password: Runtime-resolved password. Never logged.
    public init(accountName: String, host: String, port: Int, username: String, password: String) {
        self.accountName = accountName
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }

    /// Creates credentials from an account plus a resolved password.
    /// - Parameters:
    ///   - account: Configured account (host, port, username).
    ///   - password: Runtime-resolved password. Never logged.
    public init(account: EmailAccount, password: String) {
        self.init(
            accountName: account.name,
            host: account.host,
            port: account.port,
            username: account.username,
            password: password
        )
    }
}

extension ResolvedEmailCredentials: CustomStringConvertible {
    /// Redacted summary echoing only host, port, and username.
    ///
    /// Never includes the password so logging this value is safe.
    public var description: String {
        "Email(\(accountName): \(username)@\(host):\(port))"
    }
}

/// Failures resolving or reaching an email account.
///
/// Messages echo only non-sensitive fields (account name, expected
/// variable name, host, port, username) so misconfiguration is quick to
/// fix. Secret values are never included.
public enum EmailCredentialError: Error, Sendable, Equatable {
    /// No password found in the environment or Keychain.
    case missingPassword(accountName: String, envVar: String, host: String, port: Int, username: String)
    /// The host could not be reached.
    case unreachable(accountName: String, host: String, port: Int, username: String, reason: String)
}

extension EmailCredentialError: LocalizedError {
    /// Human-readable message echoing host, port, and username.
    ///
    /// Never includes the secret value.
    public var errorDescription: String? {
        switch self {
        case let .missingPassword(accountName, envVar, host, port, username):
            "Missing password for email account '\(accountName)' (expected \(envVar) "
                + "in environment or Keychain service com.runeweaver.secrets) for \(username)@\(host):\(port)"
        case let .unreachable(accountName, host, port, username, reason):
            "Email account '\(accountName)' unreachable at \(username)@\(host):\(port): \(reason)"
        }
    }
}

/// Resolves email account passwords at runtime.
///
/// Passwords live outside `config.toml` under
/// `EMAIL_<UPPERCASED_ACCOUNT_NAME>_PASSWORD` (see
/// `EmailAccount.passwordEnvVar`). Lookup is environment-first with a
/// Keychain fallback under service `com.runeweaver.secrets` — the same
/// order `CLIProviderBuilder` uses for `ProviderConfig.apiKeyEnv`.
/// Raw values are held in memory only and are never printed or logged.
public enum EmailCredentialResolver {
    /// Variable name holding the account's password.
    /// - Parameter account: Configured account.
    /// - Returns: `EMAIL_<UPPERCASED_NAME>_PASSWORD`.
    public static func passwordEnvVar(for account: EmailAccount) -> String {
        account.passwordEnvVar
    }

    /// Resolves the password via the shared secrets lookup.
    ///
    /// Single-sourced through `SecretsManager.retrieve(key:)` (live
    /// environment first, launch-time snapshot second, then the Keychain
    /// item `(service: com.runeweaver.secrets, account: envVar)`) so
    /// concurrent callers issue one `getenv` each instead of two. Returns
    /// `nil` when unset everywhere. Never logs the value.
    /// - Parameter account: Configured account.
    /// - Returns: Password, or `nil` when missing.
    public static func resolvePassword(for account: EmailAccount) async -> String? {
        let envVar = passwordEnvVar(for: account)
        let secrets = SecretsManager()
        return try? await secrets.retrieve(key: envVar)
    }

    /// Resolves every account's password, skipping missing ones.
    /// - Parameter email: Decoded `[email]` section.
    /// - Returns: Passwords keyed by account name.
    public static func resolvePasswords(for email: EmailConfig) async -> [String: String] {
        var resolved: [String: String] = [:]
        for account in email.accounts {
            if let password = await resolvePassword(for: account) {
                resolved[account.name] = password
            }
        }
        return resolved
    }

    /// Builds the missing-password error for an account.
    ///
    /// Echoes host, port, username, and the expected variable name —
    /// never the secret value.
    /// - Parameter account: Configured account.
    /// - Returns: Missing-password error.
    public static func missingPasswordError(for account: EmailAccount) -> EmailCredentialError {
        .missingPassword(
            accountName: account.name,
            envVar: passwordEnvVar(for: account),
            host: account.host,
            port: account.port,
            username: account.username
        )
    }

    /// Resolves the password or throws a missing-credential error.
    /// - Parameter account: Configured account.
    /// - Returns: Password.
    /// - Throws: `EmailCredentialError.missingPassword` when unset.
    public static func requirePassword(for account: EmailAccount) async throws -> String {
        if let password = await resolvePassword(for: account) {
            return password
        }
        throw missingPasswordError(for: account)
    }

    /// Resolves full credentials or throws a missing-credential error.
    /// - Parameter account: Configured account.
    /// - Returns: Connection fields plus the resolved password.
    /// - Throws: `EmailCredentialError.missingPassword` when unset.
    public static func resolvedCredentials(for account: EmailAccount) async throws -> ResolvedEmailCredentials {
        try await ResolvedEmailCredentials(account: account, password: requirePassword(for: account))
    }

    /// Formats a connection failure echoing host, port, and username.
    /// - Parameters:
    ///   - account: Configured account.
    ///   - reason: Transport detail (e.g. connection refused).
    /// - Returns: Unreachable error without any secret value.
    public static func unreachableError(for account: EmailAccount, reason: String) -> EmailCredentialError {
        .unreachable(
            accountName: account.name,
            host: account.host,
            port: account.port,
            username: account.username,
            reason: reason
        )
    }
}
