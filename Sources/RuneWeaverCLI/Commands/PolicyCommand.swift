// Rune Weaver CLI — Security policy management and verification surface.
//
// Provides commands to inspect, verify, and initialize ~/.runeweaver/policy.toml.
// Verifies mathematical safety invariants using PolicyInvariantVerifier.

import ArgumentParser
import Foundation
import RuneWeaverCore

/// Displays, verifies, and initializes declarative security policies.
struct PolicyCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "policy",
        abstract: "Inspect and verify declarative security policies.",
        subcommands: [
            PolicyShowCommand.self,
            PolicyVerifyCommand.self,
            PolicyInitCommand.self
        ],
        defaultSubcommand: PolicyShowCommand.self
    )
}

/// Displays the active or file-backed security policy.
struct PolicyShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Display the active security policy."
    )

    @Option(name: .long, help: "Path to policy.toml (defaults to ~/.runeweaver/policy.toml).")
    var policy: String?

    @Flag(name: .long, help: "Display raw TOML file instead of parsed summary.")
    var raw: Bool = false

    mutating func run() async throws {
        let fileURL: URL = if let policy {
            URL(fileURLWithPath: (policy as NSString).expandingTildeInPath)
        } else {
            PolicyStore.defaultFileURL()
        }

        // Existence is sampled before `load()`, which seeds a default file when
        // none exists — a seeded first run must not look like a rejected file.
        let fileExistsBeforeLoad = FileManager.default.fileExists(atPath: fileURL.path)

        let store = PolicyStore(fileURL: fileURL)
        let loaded = await store.load()

        if raw {
            if FileManager.default.fileExists(atPath: fileURL.path),
               let text = try? String(contentsOf: fileURL, encoding: .utf8)
            {
                print(text)
            } else {
                print(PolicyStore.serialize(loaded))
            }
            return
        }

        let loadedFromDisk = await store.loadedFromDisk

        // A present-but-rejected file (unreadable, unparseable, or
        // invariant-violating) must surface its diagnostics and exit nonzero:
        // only a genuinely absent file is a healthy factory-default fallback.
        if !loadedFromDisk, fileExistsBeforeLoad {
            let diagnostics = await store.lastLoadDiagnostics
            try Self.reportRejectedPolicy(at: fileURL, diagnostics: diagnostics)
        }

        if !loadedFromDisk {
            print(TerminalStyle.dim("No custom policy found at \(fileURL.path); active policy uses safe factory defaults."))
        } else {
            print(TerminalStyle.dim("Policy: \(fileURL.path)"))
        }
        print("")

        // Network
        print("[network]")
        print("mode = \(loaded.network.mode.rawValue)")
        let allowed = loaded.network.allowedDomains.sorted().joined(separator: ", ")
        print("allowed_domains = [\(allowed)]")
        let blocked = loaded.network.blockedDomains.sorted().joined(separator: ", ")
        print("blocked_domains = [\(blocked)]")
        print("")

        // Credentials
        if !loaded.credentials.isEmpty {
            print("[credentials]")
            for key in loaded.credentials.keys.sorted() {
                guard let binding = loaded.credentials[key] else { continue }
                print("  \(key):")
                print("    allowed_hosts = [\(binding.allowedHosts.sorted().joined(separator: ", "))]")
                if !binding.allowedMethods.isEmpty {
                    print("    allowed_methods = [\(binding.allowedMethods.sorted().joined(separator: ", "))]")
                }
                if !binding.allowedPathPrefixes.isEmpty {
                    print("    allowed_path_prefixes = [\(binding.allowedPathPrefixes.joined(separator: ", "))]")
                }
            }
            print("")
        }

        // Filesystem
        print("[filesystem]")
        if !loaded.filesystem.allowRoots.isEmpty {
            print("allow_roots = [\(loaded.filesystem.allowRoots.joined(separator: ", "))]")
        }
        print("deny_paths = [\(loaded.filesystem.denyPaths.count) protected paths]")
        print("")

        // Tools
        if !loaded.tools.isEmpty {
            print("[tools]")
            for key in loaded.tools.keys.sorted() {
                guard let tool = loaded.tools[key] else { continue }
                print("  \(key): level=\(tool.level.rawValue), graduated_trust=\(tool.allowGraduatedTrust)")
            }
            print("")
        }

        // Invariant status check
        let violations = PolicyInvariantVerifier.verify(loaded)
        if violations.isEmpty {
            print(TerminalStyle.success("✓ All formal security invariants verified."))
        } else {
            print(TerminalStyle.error("✗ Invariant violations detected (\(violations.count)):"))
            for violation in violations {
                print("  - \(violation)")
            }
        }
    }

    /// Reports a file-backed policy rejection and exits nonzero.
    ///
    /// Reached only when the file existed before `load()` but the store did not
    /// accept it, so the diagnostics describe real corruption: printing the
    /// fallback's healthy invariant check here would launder a rejected policy
    /// into an apparent success.
    /// - Parameters:
    ///   - fileURL: The rejected policy file's location.
    ///   - diagnostics: Store diagnostics recorded by the failed load.
    /// - Throws: `ExitCode.failure` after reporting, so scripts see the rejection.
    private static func reportRejectedPolicy(at fileURL: URL, diagnostics: [String]) throws {
        print(TerminalStyle.error("Policy file at \(fileURL.path) was rejected; active policy falls back to safe factory defaults."))
        for diagnostic in diagnostics {
            print("  - \(diagnostic)")
        }
        throw ExitCode.failure
    }
}

/// Statically verifies a policy file against formal safety invariants.
struct PolicyVerifyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Formally verify security policy invariants."
    )

    @Option(name: .long, help: "Path to policy.toml to verify (defaults to ~/.runeweaver/policy.toml).")
    var policy: String?

    mutating func run() async throws {
        let fileURL: URL = if let policy {
            URL(fileURLWithPath: (policy as NSString).expandingTildeInPath)
        } else {
            PolicyStore.defaultFileURL()
        }

        print("Verifying policy at: \(fileURL.path)...")

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print(TerminalStyle.dim("File does not exist. Verifying safe factory default posture..."))
            let violations = PolicyInvariantVerifier.verify(.safeDefault)
            if violations.isEmpty {
                print(TerminalStyle.success("✓ Safe default posture satisfies all formal invariants."))
            } else {
                print(TerminalStyle.error("✗ Invariant violations in safe default:"))
                for violation in violations {
                    print("  - \(violation)")
                }
            }
            return
        }

        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            print(TerminalStyle.error("Could not read policy file at \(fileURL.path)."))
            throw ExitCode.failure
        }

        let parsed: SecurityPolicy
        do {
            parsed = try PolicyStore.parse(text)
        } catch {
            print(TerminalStyle.error("TOML Parse Error: \(error)"))
            throw ExitCode.failure
        }

        let violations = PolicyInvariantVerifier.verify(parsed)
        if violations.isEmpty {
            print(TerminalStyle.success("✓ PASSED: All 4 formal security invariants verified successfully."))
            print("  1. Path Containment Safety: Verified")
            print("  2. Credential Binding Confinement: Verified")
            print("  3. Rule Shadow Prevention: Verified")
            print("  4. Critical Tool Lock: Verified")
        } else {
            print(TerminalStyle.error("✗ FAILED: Policy violates \(violations.count) formal security invariant(s):"))
            for (idx, violation) in violations.enumerated() {
                print("  [\(idx + 1)] \(violation)")
            }
            throw ExitCode.failure
        }
    }
}

/// Initializes a fresh policy.toml with safe defaults if none exists.
struct PolicyInitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Initialize a default ~/.runeweaver/policy.toml file."
    )

    @Option(name: .long, help: "Target path (defaults to ~/.runeweaver/policy.toml).")
    var path: String?

    @Flag(name: .long, help: "Overwrite existing file.")
    var force: Bool = false

    mutating func run() async throws {
        let fileURL: URL = if let path {
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } else {
            PolicyStore.defaultFileURL()
        }

        if FileManager.default.fileExists(atPath: fileURL.path), !force {
            print(TerminalStyle.error("Policy file already exists at \(fileURL.path). Use --force to overwrite."))
            return
        }

        let store = PolicyStore(fileURL: fileURL)
        do {
            try await store.save()
            print(TerminalStyle.success("Created default policy file at \(fileURL.path)"))
        } catch {
            print(TerminalStyle.error("Failed to write policy file: \(error.localizedDescription)"))
            throw ExitCode.failure
        }
    }
}
