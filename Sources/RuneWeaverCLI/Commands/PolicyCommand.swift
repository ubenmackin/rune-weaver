// Rune Weaver CLI — Declarative security policy verification surface.

import ArgumentParser
import Foundation
import RuneWeaverCore

/// Verifies declarative security policies on demand.
struct PolicyCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "policy",
        abstract: "Verify declarative security policies.",
        subcommands: [PolicyVerifyCommand.self]
    )
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

        let text: String
        do {
            text = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            print(TerminalStyle.error("Could not read policy file at \(fileURL.path): \(error.localizedDescription)"))
            throw ExitCode.failure
        }

        let parsed: SecurityPolicy
        do {
            parsed = try PolicyStore.parse(text)
        } catch {
            print(TerminalStyle.error("TOML Parse Error: \(error)"))
            throw ExitCode.failure
        }

        // Only the three owned invariants decide the verdict: legacy filesystem and tool tables
        // parse for compatibility but never fail verification, so an old file with those sections
        // still verifies when its network and credential bindings are sound.
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
