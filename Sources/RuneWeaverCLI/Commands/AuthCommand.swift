// Rune Weaver CLI — Single-owner bearer-token lifecycle commands.
//
// Rune Weaver is a personal, single-owner harness: exactly one bearer token
// guards the engine surface once it leaves loopback. This file owns the operator
// surface for that credential — generate, rotate, and inspect — so the token can
// be provisioned from the terminal without ever editing config.toml.
//
// Scope boundaries that keep the trust boundary intact:
// - Generation and rotation delegate to `ServerAuth`, which owns the 256-bit
//   CSPRNG and the atomic Keychain-plus-0600-file persistence. The CLI never
//   reimplements token minting or storage.
// - Status resolution consumes `ServerAuthTokenStore.resolve()`, the single
//   source of truth for the env → Keychain → restricted-file precedence, the
//   loose-permission check, and the credential-free source label. Only a SHA-256
//   fingerprint prefix and a source label are ever printed; the secret itself is
//   never rendered by `status`.
// - `generate` and `rotate` run in a separate process from the engine, so they
//   can only rewrite the stored credential; they cannot mutate the token a
//   running `serve`/menu-bar engine cached at boot. Only the in-process dashboard
//   Settings rotation revokes a live token. Command output states this, and the
//   persistence note reports the source the store actually resolves rather than
//   claiming the Keychain unconditionally.

import ArgumentParser
import Foundation
import RuneWeaverCore
import RuneWeaverServer

/// Manages the single-owner bearer token used for non-loopback binds.
struct AuthCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "Manage the single-owner bearer token that guards non-loopback binds.",
        subcommands: [AuthTokenCommand.self]
    )
}

/// Groups the owner-token lifecycle operations.
struct AuthTokenCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "token",
        abstract: "Generate, rotate, or inspect the owner bearer token.",
        subcommands: [
            AuthTokenGenerateCommand.self,
            AuthTokenRotateCommand.self,
            AuthTokenStatusCommand.self
        ],
        defaultSubcommand: AuthTokenStatusCommand.self
    )
}

/// Generates and stores a fresh owner token when none is configured.
struct AuthTokenGenerateCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "generate",
        abstract: "Generate and store a new owner token (256-bit, URL-safe)."
    )

    /// Config file path override.
    @Option(name: .long, help: "Path to config.toml (defaults to ~/.runeweaver/config.toml).")
    var config: String?

    /// Resolves any existing credential, refusing to overwrite, then mints one.
    mutating func run() async throws {
        let authConfig = try loadAuthConfig(path: config)
        let existing: ServerAuth?
        do {
            existing = try await ServerAuth.resolve(authConfig: authConfig)
        } catch {
            cliPrintError(TerminalStyle.error("Could not read the current owner token: \(error.localizedDescription)"))
            throw ExitCode(1)
        }
        // Generation routes through the actor's rotation path so the CSPRNG,
        // the Keychain write, and the atomic 0600 file write stay single-sourced
        // rather than forked in the CLI. An empty seed is honest here: this
        // verifier is never served, it only mints and persists. Supplying the
        // durable session store lets that rotation clear any stale session file,
        // so device logins minted under the previous credential cannot outlive
        // the token they were exchanged for.
        let store = ServerAuthTokenStore(authConfig: authConfig)
        if existing != nil {
            // The refusal is decided against the authoritative store; the same
            // accessor supplies the credential-free source label.
            let source = await (try? store.resolve())?.source
            let sourceNote = source.map { " (\($0.label))" } ?? ""
            cliPrintError(
                TerminalStyle.error(
                    "An owner token is already configured\(sourceNote). "
                        + "Use 'rune-weaver auth token rotate' to replace it."
                )
            )
            throw ExitCode(1)
        }
        let auth = ServerAuth(initialToken: "", store: store, sessionStore: ServerAuthSessionStore())
        let token = try await auth.rotate()
        printMintedToken(token, action: "Generated")
        await printPersistenceNote(authConfig, token: token)
    }
}

/// Replaces the stored owner token after explicit confirmation.
struct AuthTokenRotateCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "rotate",
        abstract: "Replace the stored owner token; a running engine must restart to adopt it."
    )

    /// Config file path override.
    @Option(name: .long, help: "Path to config.toml (defaults to ~/.runeweaver/config.toml).")
    var config: String?

    /// Non-interactive confirmation for scripted rotations.
    @Flag(name: .long, help: "Skip the interactive confirmation prompt.")
    var yes = false

    /// Confirms, then rewrites the stored token through the actor that persists
    /// before swapping its own in-memory copy.
    mutating func run() async throws {
        let authConfig = try loadAuthConfig(path: config)
        let existing: ServerAuth?
        do {
            existing = try await ServerAuth.resolve(authConfig: authConfig)
        } catch {
            cliPrintError(TerminalStyle.error("Could not read the current owner token: \(error.localizedDescription)"))
            throw ExitCode(1)
        }
        guard let auth = existing else {
            cliPrintError(
                TerminalStyle.error("No owner token is configured. Run 'rune-weaver auth token generate' first.")
            )
            throw ExitCode(1)
        }
        let source = await (try? ServerAuthTokenStore(authConfig: authConfig).resolve())?.source
        let sourceNote = source.map { " from \($0.label)" } ?? ""
        print(TerminalStyle.bold("Rotating the owner token\(sourceNote) rewrites the stored credential."))
        print(
            TerminalStyle.dim(
                "A running engine caches its token at boot, so it keeps accepting the previous token "
                    + "until you restart 'rune-weaver serve' or the menu-bar app."
            )
        )
        print(TerminalStyle.dim("For immediate live revocation, rotate from the dashboard Settings pane instead."))
        guard await confirm("Replace the current owner token? [y/N] ", assumeYes: yes) else {
            print(TerminalStyle.dim("Rotation cancelled; the current token is unchanged."))
            return
        }
        // `ServerAuth.rotate` persists the replacement before swapping its own
        // in-memory copy, so a storage failure leaves the working token valid
        // instead of stranding the owner with a credential that was never saved.
        let token = try await auth.rotate()
        printMintedToken(token, action: "Rotated")
        await printPersistenceNote(authConfig, token: token)
    }
}

/// Reports whether owner auth is configured without revealing the token.
struct AuthTokenStatusCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show whether owner auth is configured, its source, and a fingerprint prefix."
    )

    /// Config file path override.
    @Option(name: .long, help: "Path to config.toml (defaults to ~/.runeweaver/config.toml).")
    var config: String?

    /// Prints the configuration state, source, and non-secret fingerprint.
    mutating func run() async throws {
        let authConfig = try loadAuthConfig(path: config)
        let resolved: ResolvedServerAuthToken?
        do {
            resolved = try await ServerAuthTokenStore(authConfig: authConfig).resolve()
        } catch {
            cliPrintError(TerminalStyle.error("Could not read the owner token: \(error.localizedDescription)"))
            throw ExitCode(1)
        }
        guard let resolved else {
            print("\(TerminalStyle.error("○")) Owner auth: not configured")
            print(TerminalStyle.dim("  LAN binds are refused until a token exists."))
            print(TerminalStyle.dim("  Run 'rune-weaver auth token generate' to create one."))
            return
        }
        print("\(TerminalStyle.success("●")) Owner auth: configured")
        print("  source: \(resolved.source.label)")
        // Fingerprint only: a short SHA-256 prefix identifies the credential for
        // support and comparison without exposing any token material.
        print("  fingerprint: \(ServerAuth.fingerprint(resolved.token)) (SHA-256 prefix, non-secret)")
        if let tokenFile = authConfig.tokenFile?.trimmingCharacters(in: .whitespacesAndNewlines), !tokenFile.isEmpty {
            print(TerminalStyle.dim("  file fallback: \(expandedPath(tokenFile))"))
        }
    }
}

// MARK: - Config and presentation helpers

/// Loads and validates the `[auth]` section for a command.
/// - Parameter path: Explicit `--config` value, if any.
/// - Returns: The declared token sources.
/// - Throws: ``ConfigError`` when the file is missing or invalid.
private func loadAuthConfig(path: String?) throws -> AuthConfig {
    let loaded = try CLIConfigLoader.loadConfig(path: path)
    if loaded.isFallback {
        print(TerminalStyle.dim("No config found at \(loaded.url.path); using built-in defaults."))
    }
    return loaded.config.auth
}

/// Expands a leading `~` in a configured path for display and file access.
/// - Parameter path: Configured token path.
/// - Returns: Absolute path with `~` expanded.
private func expandedPath(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}

/// Prints a freshly minted token exactly once, followed by its fingerprint.
/// - Parameters:
///   - token: New token value.
///   - action: Verb describing the mint (`Generated` or `Rotated`).
private func printMintedToken(_ token: String, action: String) {
    print("")
    print(TerminalStyle.success("\(action) owner token (shown once — store it now):"))
    print("  \(token)")
    print("")
    print(TerminalStyle.dim("  fingerprint: \(ServerAuth.fingerprint(token)) (SHA-256 prefix, non-secret)"))
}

/// Reports where the new token actually resolves, how to present it, and why a
/// running engine only adopts it after a restart.
///
/// Persistence always attempts the Keychain and writes the file fallback only
/// when one is configured, but a live environment override outranks both on the
/// next boot and a failed file write can pass silently once the Keychain
/// succeeded. Re-resolving through the store and comparing against the minted
/// value lets the note name the source that will be read instead of
/// unconditionally claiming the Keychain.
/// - Parameters:
///   - authConfig: Declared token sources used by the store.
///   - token: Freshly minted token compared against what the store resolves.
private func printPersistenceNote(_ authConfig: AuthConfig, token: String) async {
    do {
        let resolved = try await ServerAuthTokenStore(authConfig: authConfig).resolve()
        switch resolved {
        case let .some(current) where current.token == token:
            switch current.source {
            case .keychain:
                print(TerminalStyle.dim("Stored in the macOS Keychain account '\(AuthConfig.defaultTokenKey)'."))
            case let .environment(name):
                print(TerminalStyle.dim("Resolved from the live environment variable \(name)."))
            case let .file(path):
                print(TerminalStyle.dim("Stored in the token file \(path) (0600)."))
            }
        case let .some(current):
            // The resolved value differs from what was just minted, so a live
            // environment override outranks the stored sources and the engine
            // would keep reading the old value after a restart.
            print(
                TerminalStyle.dim(
                    "A live environment override (\(current.source.label)) still takes precedence at boot; "
                        + "update it to adopt the new token."
                )
            )
        case .none:
            print(TerminalStyle.dim("Could not resolve the persisted credential back to the new token."))
        }
    } catch {
        print(
            TerminalStyle.dim(
                "Could not re-read the stored credential to confirm its source: \(error.localizedDescription)"
            )
        )
    }
    if let tokenFile = authConfig.tokenFile?.trimmingCharacters(in: .whitespacesAndNewlines), !tokenFile.isEmpty {
        print(TerminalStyle.dim("Token file fallback configured at \(expandedPath(tokenFile)) (0600)."))
    } else {
        print(TerminalStyle.dim("No [auth] token_file is configured; set one for a headless file fallback."))
    }
    print(TerminalStyle.dim("Restart the engine ('rune-weaver serve' or the menu-bar app) so it adopts the new token."))
    print(TerminalStyle.dim("Revoking a running engine's token immediately requires rotation from the dashboard Settings pane."))
    print(TerminalStyle.dim("Present it as: Authorization: Bearer <token>"))
}

/// Asks the operator to confirm a destructive operation.
/// - Parameters:
///   - prompt: Question shown before the read.
///   - assumeYes: Whether `--yes` pre-answered the question.
/// - Returns: True only on an explicit yes/`y`.
private func confirm(_ prompt: String, assumeYes: Bool) async -> Bool {
    if assumeYes {
        return true
    }
    guard let answer = await ChatLineEditing.readLine(prompt: TerminalStyle.tool(prompt)) else {
        return false
    }
    switch answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "y", "yes":
        return true
    default:
        return false
    }
}
