// Rune Weaver Tools — Execution-time email credential resolution.

import Foundation
import RuneWeaverCore

/// Resolved credentials for one email account.
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
    /// Optional SMTP hostname override (nil means derive from the IMAP host).
    public let smtpHost: String?
    /// Optional SMTP submission port override (nil means 587/465 fallback).
    public let smtpPort: Int?
    /// SMTP transport security (defaults to `auto`).
    public let smtpSecurity: EmailSMTPSecurity

    /// Creates resolved credentials from explicit fields.
    public init(
        accountName: String,
        host: String,
        port: Int,
        username: String,
        password: String,
        smtpHost: String? = nil,
        smtpPort: Int? = nil,
        smtpSecurity: EmailSMTPSecurity = .auto
    ) {
        self.accountName = accountName
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        let trimmedHost = smtpHost?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.smtpHost = (trimmedHost?.isEmpty == false) ? trimmedHost : nil
        self.smtpPort = smtpPort
        self.smtpSecurity = smtpSecurity
    }

    /// Creates credentials from an account plus a resolved password.
    public init(account: EmailAccount, password: String) {
        self.init(
            accountName: account.name,
            host: account.host,
            port: account.port,
            username: account.username,
            password: password,
            smtpHost: account.smtpHost,
            smtpPort: account.smtpPort,
            smtpSecurity: account.smtpSecurity
        )
    }
}

extension ResolvedEmailCredentials: CustomStringConvertible, CustomDebugStringConvertible {
    /// Redacted summary echoing only host, port, and username.
    ///
    /// Never includes the password so logging this value is safe.
    public var description: String {
        "Email(\(accountName): \(username)@\(host):\(port))"
    }

    /// Redacted debug summary mirroring description so LLDB po, debugPrint,
    /// and String(reflecting:) never leak the plaintext password.
    public var debugDescription: String {
        description
    }
}

/// Failures resolving or reaching an email account.
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
public enum EmailCredentialResolver {
    /// Variable name holding the account's password.
    /// - Parameter account: Configured account.
    /// - Returns: `EMAIL_<UPPERCASED_NAME>_PASSWORD`.
    public static func passwordEnvVar(for account: EmailAccount) -> String {
        account.passwordEnvVar
    }

    /// Resolves the password via the shared secrets lookup.
    public static func resolvePassword(for account: EmailAccount) async -> String? {
        let envVar = passwordEnvVar(for: account)
        let secrets = SecretsManager()
        do {
            return try await secrets.retrieve(key: envVar)
        } catch is CancellationError {
            return nil
        } catch {
            RuneWeaverLog.tools.debug("resolvePassword: failed to retrieve secret for \(envVar): \(error.localizedDescription)")
            return nil
        }
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
    public static func requirePassword(for account: EmailAccount) async throws -> String {
        if let password = await resolvePassword(for: account) {
            return password
        }
        throw missingPasswordError(for: account)
    }

    /// Resolves full credentials or throws a missing-credential error.
    public static func resolvedCredentials(for account: EmailAccount) async throws -> ResolvedEmailCredentials {
        try await ResolvedEmailCredentials(account: account, password: requirePassword(for: account))
    }

    /// Formats a connection failure echoing host, port, and username.
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

/// Well-known IMAP details for the iCloud account.
public enum EmailICloud: Sendable {
    /// Account nickname used in `[email.accounts]`.
    public static let accountName = "icloud"
    /// iCloud IMAP hostname.
    public static let host = "imap.mail.me.com"
    /// iCloud IMAP port (IMAP over TLS).
    public static let port = 993
    /// Variable holding the iCloud app-specific password.
    public static let passwordEnvVar = "EMAIL_ICLOUD_PASSWORD"
    /// Where to generate the app-specific password.
    public static let appSpecificPasswordHelp =
        "Generate at Apple Account > Sign-In and Security > App-Specific Passwords "
            + "(requires two-factor authentication); use the generated value for EMAIL_ICLOUD_PASSWORD, "
            + "never the Apple Account password."

    /// Builds the configured iCloud account entry.
    /// - Parameter username: iCloud login username (e.g. `user@icloud.com`).
    /// - Returns: `EmailAccount` for `imap.mail.me.com:993`.
    public static func account(username: String) -> EmailAccount {
        EmailAccount(name: accountName, type: "imap", host: host, port: port, username: username)
    }

    /// Whether an account entry targets iCloud IMAP.
    /// - Parameter account: Configured account to check.
    /// - Returns: True when the host and port match iCloud IMAP.
    public static func matches(_ account: EmailAccount) -> Bool {
        account.host.lowercased() == host && account.port == port
    }
}
