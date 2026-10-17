// Rune Weaver Core — Periodic security probe suite for the verified system pulse.

import CryptoKit
import Foundation

// MARK: - Report

/// One completed periodic security probe report. Carries the bounded outcome set plus a stable hash
/// over the outcomes alone.
public struct ProbeReport: Sendable, Equatable, Codable {
    /// Maximum probes one report carries; extras are dropped, never widened.
    public static let maxProbes = 12
    /// Total wall-clock budget for one suite run.
    public static let totalTimeoutSeconds: TimeInterval = 30
    /// Per-probe wall-clock budget inside the total.
    public static let perProbeTimeoutSeconds: TimeInterval = 5

    /// Bounded outcomes, sorted by verifier name.
    public let probes: [HealthProbeOutcome]
    /// When the suite run started.
    public let startedAt: Date
    /// When the suite run finished.
    public let finishedAt: Date
    /// SHA-256 hex over the canonical outcome set; equal outcomes compare equal.
    public let hash: String

    /// Whether every recorded verifier passed.
    public var passed: Bool {
        probes.allSatisfy(\.passed)
    }

    /// Whether a fail-closed verifier failed, which blocks serve boot.
    public var failedCritical: Bool {
        probes.contains { !$0.passed && $0.failClosed }
    }

    /// Creates a report, normalizing the outcome set.
    public init(probes: [HealthProbeOutcome], startedAt: Date, finishedAt: Date) {
        self.probes = Array(
            probes.sorted { $0.name < $1.name }.prefix(Self.maxProbes)
        )
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.hash = Self.hash(of: self.probes)
    }

    /// Stable digest over the outcome set alone.
    /// - Parameter probes: Outcomes to digest.
    /// - Returns: Lowercase SHA-256 hex of the canonical outcome lines.
    public static func hash(of probes: [HealthProbeOutcome]) -> String {
        let canonical = probes
            .sorted { $0.name < $1.name }
            .map { "\($0.name)|\($0.passed)|\($0.failClosed)|\($0.detail ?? "")" }
            .joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Suite

/// Periodic security probe suite. Runs the fixed verifier set under the suite bounds and returns
/// one report.
public enum SecurityProbeSuite {
    /// Runs every verifier under the suite bounds.
    /// - Returns: The completed report, never empty by construction.
    public static func runAll() async -> ProbeReport {
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(ProbeReport.totalTimeoutSeconds)
        var outcomes: [HealthProbeOutcome] = []
        for verifier in Self.verifiers {
            let outcome = await runBounded(verifier, deadline: deadline)
            outcomes.append(outcome)
        }
        // A run always emits one outcome per verifier, so an empty set is unreachable by
        // construction. The synthetic entry keeps a hypothetical empty set failing closed: absence
        // of evidence is not evidence of safety.
        if outcomes.isEmpty {
            outcomes = [
                HealthProbeOutcome(
                    name: "suite",
                    passed: false,
                    failClosed: true,
                    detail: "probe suite emitted no verifier outcomes"
                )
            ]
        }
        return ProbeReport(probes: outcomes, startedAt: startedAt, finishedAt: Date())
    }

    /// The fixed verifier set in run order.
    private static let verifiers: [(name: String, failClosed: Bool)] = [
        (ProbeName.traversal, true),
        (ProbeName.symlinkEscape, true),
        (ProbeName.replay, true),
        (ProbeName.firewallRedaction, false),
        (ProbeName.ledgerIntegrity, false),
        (ProbeName.zeroSocket, false),
        (ProbeName.vaultRoundTrip, false)
    ]

    /// Runs one verifier against the remaining suite budget. The per-verifier budget never exceeds
    /// the remaining suite budget, so a hung verifier consumes at most its own slice and never the
    /// whole run.
    private static func runBounded(_ verifier: (name: String, failClosed: Bool), deadline: Date) async -> HealthProbeOutcome {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            return HealthProbeOutcome(
                name: verifier.name,
                passed: false,
                failClosed: verifier.failClosed,
                detail: "suite budget expired before this verifier ran"
            )
        }
        let budget = min(ProbeReport.perProbeTimeoutSeconds, remaining)
        let nanoseconds = UInt64((budget * 1_000_000_000).rounded())
        let verifierName = verifier.name
        let outcome = await withTaskGroup(of: HealthProbeOutcome?.self) { group in
            group.addTask { await SecurityProbeSuite.runVerifier(named: verifierName) }
            group.addTask {
                try? await Task.sleep(nanoseconds: nanoseconds)
                return nil
            }
            // First finisher wins: the verifier returning, or the timeout
            // yielding nil; the losing task is cancelled with the group.
            for await outcome in group {
                group.cancelAll()
                return outcome
            }
            return nil
        }
        guard let outcome else {
            return HealthProbeOutcome(
                name: verifier.name,
                passed: false,
                failClosed: verifier.failClosed,
                detail: "verifier exceeded its \(Int(budget.rounded()))s budget"
            )
        }
        return outcome
    }

    /// Dispatches one verifier by its stable name.
    /// - Parameter name: Verifier name from the fixed set.
    /// - Returns: That verifier's outcome.
    private static func runVerifier(named name: String) async -> HealthProbeOutcome {
        switch name {
        case ProbeName.traversal:
            await probeTraversal()
        case ProbeName.symlinkEscape:
            await probeSymlinkEscape()
        case ProbeName.replay:
            await probeReplay()
        case ProbeName.firewallRedaction:
            await probeFirewallRedaction()
        case ProbeName.ledgerIntegrity:
            await probeLedgerIntegrity()
        case ProbeName.zeroSocket:
            await probeZeroSocket()
        case ProbeName.vaultRoundTrip:
            await probeVaultRoundTrip()
        default:
            HealthProbeOutcome(
                name: name,
                passed: false,
                failClosed: false,
                detail: "no verifier is registered under this name"
            )
        }
    }
}

// MARK: - Verifier Identities

/// Stable verifier names recorded into the pulse.
private enum ProbeName {
    static let traversal = "traversal"
    static let symlinkEscape = "symlink-escape"
    static let replay = "replay"
    static let firewallRedaction = "firewall-redaction"
    static let ledgerIntegrity = "ledger-integrity"
    static let zeroSocket = "zero-socket"
    static let vaultRoundTrip = "vault-round-trip"

    /// Tool name the replay verifier parks in its throwaway queue.
    static let probeToolName = "security.probe"

    /// Vault key the redaction verifier sweeps under.
    static let firewallProbeKey = "firewall_probe"

    /// Vault key the round-trip verifier exercises.
    static let vaultProbeKey = "vault_probe"
}

// MARK: - Verifiers

extension SecurityProbeSuite {
    /// Workspace traversal containment.
    private static func probeTraversal() async -> HealthProbeOutcome {
        let name = ProbeName.traversal
        guard let scratch = ProbeScratch.make(prefix: "rune-probe-traversal") else {
            return HealthProbeOutcome(
                name: name, passed: false, failClosed: true, detail: "could not create the probe scratch tree"
            )
        }
        defer { ProbeScratch.remove(scratch) }
        let nested = scratch.root.appendingPathComponent("nested", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: nested, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return HealthProbeOutcome(
                name: name, passed: false, failClosed: true,
                detail: "could not create the probe nested directory: \(error.localizedDescription)"
            )
        }
        let inside = nested.appendingPathComponent("inside.txt")
        try? Data("probe".utf8).write(to: inside)
        let escaped = scratch.outside.appendingPathComponent("outside.txt")
        let dotted = scratch.root.appendingPathComponent("../\(scratch.outside.lastPathComponent)/outside.txt")
        guard WorkspaceContainment.isContained(path: inside.path, inside: scratch.root) else {
            return HealthProbeOutcome(
                name: name, passed: false, failClosed: true, detail: "containment refused an in-root path"
            )
        }
        guard !WorkspaceContainment.isContained(path: escaped.path, inside: scratch.root) else {
            return HealthProbeOutcome(
                name: name, passed: false, failClosed: true, detail: "containment accepted an outside absolute path"
            )
        }
        guard !WorkspaceContainment.isContained(path: dotted.path, inside: scratch.root) else {
            return HealthProbeOutcome(
                name: name, passed: false, failClosed: true, detail: "containment accepted a dot-dot escape spelling"
            )
        }
        guard WorkspaceContainment.escapesRoot(
            canonical: WorkspaceContainment.canonical(escaped),
            expectedRoot: WorkspaceContainment.canonical(scratch.root)
        ) else {
            return HealthProbeOutcome(
                name: name, passed: false, failClosed: true,
                detail: "the escape check did not flag a resolved outside path"
            )
        }
        return HealthProbeOutcome(name: name, passed: true)
    }

    /// Symlink escape containment.
    private static func probeSymlinkEscape() async -> HealthProbeOutcome {
        let name = ProbeName.symlinkEscape
        guard let scratch = ProbeScratch.make(prefix: "rune-probe-symlink") else {
            return HealthProbeOutcome(
                name: name, passed: false, failClosed: true, detail: "could not create the probe scratch tree"
            )
        }
        defer { ProbeScratch.remove(scratch) }
        let link = scratch.root.appendingPathComponent("escape")
        do {
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: scratch.outside)
        } catch {
            return HealthProbeOutcome(
                name: name, passed: false, failClosed: true,
                detail: "could not plant the probe symlink: \(error.localizedDescription)"
            )
        }
        let plain = scratch.root.appendingPathComponent("plain.txt")
        try? Data("probe".utf8).write(to: plain)
        guard WorkspaceContainment.isSymlink(at: link) else {
            return HealthProbeOutcome(
                name: name, passed: false, failClosed: true, detail: "the symlink probe did not see the planted link"
            )
        }
        guard !WorkspaceContainment.isContained(path: link.path, inside: scratch.root) else {
            return HealthProbeOutcome(
                name: name, passed: false, failClosed: true,
                detail: "containment accepted a symlink resolving outside the root"
            )
        }
        guard WorkspaceContainment.escapesRoot(
            canonical: WorkspaceContainment.canonical(link),
            expectedRoot: WorkspaceContainment.canonical(scratch.root)
        ) else {
            return HealthProbeOutcome(
                name: name, passed: false, failClosed: true,
                detail: "the escape check did not flag the resolved symlink"
            )
        }
        guard !WorkspaceContainment.isSymlink(at: plain),
              WorkspaceContainment.isContained(path: plain.path, inside: scratch.root)
        else {
            return HealthProbeOutcome(
                name: name, passed: false, failClosed: true, detail: "a regular in-root file was misclassified"
            )
        }
        return HealthProbeOutcome(name: name, passed: true)
    }

    /// Approval replay protection.
    private static func probeReplay() async -> HealthProbeOutcome {
        let name = ProbeName.replay
        let queue = ApprovalQueue()
        let request = await queue.enqueue(
            toolName: ProbeName.probeToolName,
            description: "periodic security probe replay check",
            input: ToolInput(toolName: ProbeName.probeToolName, argumentsJSON: "{}")
        )
        guard await queue.request(id: request.id) != nil else {
            return HealthProbeOutcome(
                name: name, passed: false, failClosed: true, detail: "the probe approval never parked"
            )
        }
        guard await queue.decide(id: request.id, approved: true) else {
            return HealthProbeOutcome(
                name: name, passed: false, failClosed: true, detail: "the first decision was not honored"
            )
        }
        guard await queue.request(id: request.id) == nil else {
            return HealthProbeOutcome(
                name: name, passed: false, failClosed: true, detail: "a decided approval stayed pending"
            )
        }
        let replayed = await queue.decide(id: request.id, approved: true)
        guard !replayed else {
            return HealthProbeOutcome(
                name: name, passed: false, failClosed: true, detail: "a replayed decision was honored"
            )
        }
        return HealthProbeOutcome(name: name, passed: true)
    }

    /// Credential redaction at the transport boundary.
    private static func probeFirewallRedaction() async -> HealthProbeOutcome {
        let name = ProbeName.firewallRedaction
        let vault = SecretsManager(service: "com.runeweaver.probe.\(UUID().uuidString)", inMemory: true)
        let sentinel = "rw-probe-\(UUID().uuidString)"
        do {
            try await vault.store(key: ProbeName.firewallProbeKey, secret: sentinel)
            guard try await vault.retrieve(key: ProbeName.firewallProbeKey) == sentinel else {
                return HealthProbeOutcome(
                    name: name, passed: false, detail: "the vault read-back did not match the stored credential"
                )
            }
            let echoed = "POST /v1/echo Authorization: Bearer \(sentinel) body=\(sentinel)"
            let swept = vault.redactResolved(echoed, secrets: [sentinel])
            guard !swept.contains(sentinel), swept.contains(SecretsManager.redactedPlaceholder) else {
                return HealthProbeOutcome(
                    name: name, passed: false,
                    detail: "the response sweep left the resolved credential in agent-visible output"
                )
            }
            let header = SecretsManager.redactedHeaderValue(
                "Bearer \(sentinel)", isAuthorization: true, resolvedSecrets: [sentinel]
            )
            guard !header.contains(sentinel), header.contains(SecretsManager.redactedPlaceholder) else {
                return HealthProbeOutcome(
                    name: name, passed: false,
                    detail: "the header sweep left the resolved credential in the preview"
                )
            }
            return HealthProbeOutcome(name: name, passed: true)
        } catch {
            return HealthProbeOutcome(
                name: name, passed: false, detail: "the credential sweep probe failed: \(error.localizedDescription)"
            )
        }
    }

    /// Sovereign ledger integrity. Runs a full ceremony over a throwaway ledger and store — chain
    /// recomputation, sovereign copy write, and signed checkpoint — under a probe signer that never
    /// touches operator key material.
    private static func probeLedgerIntegrity() async -> HealthProbeOutcome {
        let name = ProbeName.ledgerIntegrity
        guard let scratch = ProbeScratch.make(prefix: "rune-probe-ledger") else {
            return HealthProbeOutcome(
                name: name, passed: false, detail: "could not create the probe scratch tree"
            )
        }
        defer { ProbeScratch.remove(scratch) }
        let copyPath = scratch.root.appendingPathComponent("ledger.sovereign.jsonl").path
        let checkpointPath = scratch.root.appendingPathComponent("sovereign-checkpoint.json").path
        let store = EpisodeStore(dbPath: scratch.root.appendingPathComponent("episodes.db").path)
        let probeSecrets = SecretsManager(service: "com.runeweaver.probe.\(UUID().uuidString)", inMemory: true)
        let ledger = SovereignLedger(
            episodeStore: store,
            sovereignCopyPath: copyPath,
            checkpointPath: checkpointPath,
            signer: ProbeSigner(),
            secrets: probeSecrets,
            now: { Date() }
        )
        do {
            try await store.store(sessionID: UUID(), role: .user, content: "probe ledger entry")
            try await store.store(sessionID: UUID(), role: .assistant, content: "probe ledger reply")
            let verdict = try await ledger.verifyChain()
            guard case .verified = verdict.decision else {
                return HealthProbeOutcome(
                    name: name, passed: false,
                    detail: "a clean ledger ceremony returned \(verdict.outcome.rawValue)"
                )
            }
            try appendTamperLine(to: copyPath)
            let tampered = try? await ledger.verifyChain()
            guard case .verified? = tampered?.decision else {
                return HealthProbeOutcome(name: name, passed: true)
            }
            return HealthProbeOutcome(
                name: name, passed: false, detail: "a tampered sovereign copy still verified"
            )
        } catch {
            return HealthProbeOutcome(
                name: name, passed: false, detail: "the ledger ceremony failed: \(error.localizedDescription)"
            )
        }
    }

    /// Sandbox zero-socket posture.
    private static func probeZeroSocket() async -> HealthProbeOutcome {
        let name = ProbeName.zeroSocket
        let denied = SeatbeltProfileBuilder(allowNetwork: false).buildProfile()
        guard denied.contains("(deny network*)") else {
            return HealthProbeOutcome(
                name: name, passed: false, detail: "the network-denied sandbox profile lost the socket deny"
            )
        }
        guard !denied.contains("(allow network*)") else {
            return HealthProbeOutcome(
                name: name, passed: false, detail: "the network-denied sandbox profile still allows sockets"
            )
        }
        let permitted = SeatbeltProfileBuilder(allowNetwork: true).buildProfile()
        guard permitted.contains("(allow network*)"), !permitted.contains("(deny network*)") else {
            return HealthProbeOutcome(
                name: name, passed: false, detail: "the network-permitted sandbox profile lost the socket allow"
            )
        }
        return HealthProbeOutcome(name: name, passed: true)
    }

    /// Vault round-trip.
    private static func probeVaultRoundTrip() async -> HealthProbeOutcome {
        let name = ProbeName.vaultRoundTrip
        let vault = SecretsManager(service: "com.runeweaver.probe.\(UUID().uuidString)", inMemory: true)
        let sentinel = "rw-vault-\(UUID().uuidString)"
        do {
            try await vault.store(key: ProbeName.vaultProbeKey, secret: sentinel)
            guard try await vault.retrieve(key: ProbeName.vaultProbeKey) == sentinel else {
                return HealthProbeOutcome(
                    name: name, passed: false, detail: "the vault read-back did not match the stored credential"
                )
            }
            let surrogate = try vault.surrogate(for: ProbeName.vaultProbeKey)
            guard surrogate == SecretsManager.surrogatePrefix + ProbeName.vaultProbeKey else {
                return HealthProbeOutcome(
                    name: name, passed: false, detail: "the issued surrogate drifted from the reference shape"
                )
            }
            guard try await vault.resolveSurrogate(surrogate) == sentinel else {
                return HealthProbeOutcome(
                    name: name, passed: false, detail: "surrogate resolution did not return the stored credential"
                )
            }
            try await vault.delete(key: ProbeName.vaultProbeKey)
            guard try await vault.retrieve(key: ProbeName.vaultProbeKey) == nil else {
                return HealthProbeOutcome(
                    name: name, passed: false, detail: "a deleted credential was still readable"
                )
            }
            return HealthProbeOutcome(name: name, passed: true)
        } catch {
            return HealthProbeOutcome(
                name: name, passed: false, detail: "the vault round-trip failed: \(error.localizedDescription)"
            )
        }
    }

    /// Appends one unchainable line to a sovereign copy.
    private static func appendTamperLine(to path: String) throws {
        let ids = #"00000000-0000-0000-0000-000000000000"#
        let episode = #"{"id":"\#(ids)","session_id":"\#(ids)","role":"user","timestamp":"0.0","content":"tamper","metadata":{}}"#
        let line = #"{"seq":99,"episode":\#(episode),"prev":"deadbeef","hash":"deadbeef","hmac":"deadbeef"}"#
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
        try handle.write(contentsOf: Data([0x0A]))
    }
}

// MARK: - Probe Support

/// Scratch tree pair for one verifier run. Owner-only modes keep the probe bytes private while it
/// runs, and removal clears both halves.
private struct ProbeScratch: Sendable {
    /// Probe root the containment checks defend.
    let root: URL
    /// Sibling directory outside the root.
    let outside: URL

    /// Creates the scratch pair under the system temporary directory.
    /// - Parameter prefix: Distinct prefix per verifier.
    /// - Returns: The scratch pair, or nil when creation failed.
    static func make(prefix: String) -> ProbeScratch? {
        let base = FileManager.default.temporaryDirectory
        let scratch = ProbeScratch(
            root: base.appendingPathComponent("\(prefix)-root-\(UUID().uuidString)", isDirectory: true),
            outside: base.appendingPathComponent("\(prefix)-outside-\(UUID().uuidString)", isDirectory: true)
        )
        do {
            for url in [scratch.root, scratch.outside] {
                try FileManager.default.createDirectory(
                    at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
                )
            }
            return scratch
        } catch {
            remove(scratch)
            return nil
        }
    }

    /// Removes both halves of a scratch pair, best-effort.
    /// - Parameter scratch: Scratch pair to clear.
    static func remove(_ scratch: ProbeScratch) {
        for url in [scratch.root, scratch.outside] {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// In-memory enclave signer for the ledger verifier.
private struct ProbeSigner: SovereignSigner {
    /// Stable signer identity recorded on probe votes.
    let identity = "runeweaver-probe-enclave-hmac-sha256"

    /// Throwaway 256-bit HMAC key for one probe run.
    private let key = SymmetricKey(data: Data((0 ..< 32).map { _ in UInt8.random(in: .min ... .max) }))

    func sign(challenge: String) async throws -> String {
        EnclaveHMACSigner.hex(Data(HMAC<SHA256>.authenticationCode(for: Data(challenge.utf8), using: key)))
    }

    func verify(challenge: String, signature: String) async -> Bool {
        let candidate = signature.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let expected = EnclaveHMACSigner.hex(Data(HMAC<SHA256>.authenticationCode(for: Data(challenge.utf8), using: key)))
        return EnclaveHMACSigner.constantTimeEquals(expected, candidate)
    }
}
