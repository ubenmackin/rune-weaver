// Rune Weaver CLI — Network plus credential policy management surface.
//
// Inspects, verifies, and seeds the two-section declarative policy
// (`~/.runeweaver/policy.toml`): network egress boundaries plus per-secret
// credential bindings. The command layer is a thin display over the shared
// PolicyStore, so legacy filesystem and tool sections never surface here and
// every write flows through the store's verified persistence path.

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
        print("version = \(loaded.version)")
        print("")

        // Network egress is the first of the two owned sections: mode plus
        // allow/block counts keep the summary scannable while the full sorted
        // lists preserve the exact match surface the supervisor enforces.
        print("[network]")
        print("mode = \(loaded.network.mode.rawValue)")
        let allowedDomains = loaded.network.allowedDomains.sorted()
        print("allowed_domains (\(allowedDomains.count)) = [\(allowedDomains.joined(separator: ", "))]")
        let blockedDomains = loaded.network.blockedDomains.sorted()
        print("blocked_domains (\(blockedDomains.count)) = [\(blockedDomains.joined(separator: ", "))]")
        print("")

        // Credentials are the second owned section. Each binding pairs one key
        // with hosts plus methods plus path prefixes: an empty method or prefix
        // list authorizes any value, while an empty host list authorizes
        // nothing, so the display always names all three to avoid implying a
        // narrower grant than the supervisor checks. Legacy filesystem and tool
        // tables are intentionally never printed here.
        print("[credentials]")
        if loaded.credentials.isEmpty {
            print("(no credentials configured)")
        } else {
            for key in loaded.credentials.keys.sorted() {
                guard let binding = loaded.credentials[key] else { continue }
                print("  \(key):")
                let hosts = binding.allowedHosts.sorted().joined(separator: ", ")
                if binding.allowedHosts.isEmpty {
                    print("    allowed_hosts = [] (unusable: no destination authorized)")
                } else {
                    print("    allowed_hosts = [\(hosts)]")
                }
                if binding.allowedMethods.isEmpty {
                    print("    allowed_methods = (any)")
                } else {
                    print("    allowed_methods = [\(binding.allowedMethods.sorted().joined(separator: ", "))]")
                }
                if binding.allowedPathPrefixes.isEmpty {
                    print("    allowed_path_prefixes = (any)")
                } else {
                    print("    allowed_path_prefixes = [\(binding.allowedPathPrefixes.joined(separator: ", "))]")
                }
            }
        }
        print("")

        // The aggregate verifier owns exactly the three invariants this surface
        // reports — credential confinement, rule-shadow prevention, and local-exemption
        // safety — so a legacy filesystem or tool table can never flip the reported status.
        let violations = PolicyInvariantVerifier.verify(loaded)
        if violations.isEmpty {
            print(TerminalStyle.success(
                "✓ All 3 formal security invariants verified (credential confinement, rule-shadow prevention, local-exemption safety)."
            ))
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

/// Verifies the three owned policy invariants on demand for a policy file.
struct PolicyVerifyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Formally verify credential confinement, rule-shadow prevention, and local-exemption safety."
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
                print(TerminalStyle.success("✓ Safe default posture satisfies credential confinement, rule-shadow prevention, and local-exemption safety."))
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

        // Only the three owned invariants decide the verdict: legacy filesystem
        // and tool tables parse for compatibility but never fail verification,
        // so an old file with those sections still verifies when its network
        // and credential bindings are sound.
        let violations = PolicyInvariantVerifier.verify(parsed)
        if violations.isEmpty {
            print(TerminalStyle.success("✓ PASSED: All 3 formal security invariants verified successfully."))
            print("  1. Credential Confinement: Verified")
            print("  2. Rule Shadow Prevention: Verified")
            print("  3. Local Exemption Safety: Verified")
        } else {
            print(TerminalStyle.error("✗ FAILED: Policy violates \(violations.count) formal security invariant(s):"))
            for (idx, violation) in violations.enumerated() {
                print("  [\(idx + 1)] \(violation)")
            }
            throw ExitCode.failure
        }
    }
}

/// Seeds a fresh two-section policy.toml with safe defaults if none exists.
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

        // The store owns serialization, so the seeded file carries exactly the
        // network-plus-credentials schema with no filesystem or tool sections;
        // no raw TOML is composed on this path, keeping the verified
        // persistence boundary as the single writer.
        let store = PolicyStore(fileURL: fileURL)
        do {
            try await store.save()
            print(TerminalStyle.success("Created default policy file at \(fileURL.path)"))
            print(TerminalStyle.dim("Default policy carries network + credentials only (credential confinement, rule-shadow prevention verified)."))
        } catch {
            print(TerminalStyle.error("Failed to write policy file: \(error.localizedDescription)"))
            throw ExitCode.failure
        }
    }
}
