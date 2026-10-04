// Rune Weaver Core — Actor-backed store for ~/.runeweaver/policy.toml.
//
// Manages loading, parsing, validating, and persisting the network-plus-
// credentials declarative policy. The store owns network plus credentials
// only: legacy `[filesystem]` and `[tools.*]` tables are tolerated on load
// and ignored, and never serialized back, so older files keep booting while
// a resaved file sheds retired sections. Every load and update runs the two
// owned invariants — credential confinement plus rule-shadow prevention —
// before acceptance; parse errors or violations fall back to the immutable
// safe factory posture and record diagnostics for the caller, so the engine
// never runs unprotected. A legacy `deny_by_default` mode parses as
// `allowlist_only`, preserving its fail-closed intent.
//
// Serialization is store-owned with a reparse round-trip proof: the bytes
// must reload to the verified object, otherwise quoting or control bytes
// would persist differently than they verified. The dashboard therefore edits
// the structured shape and never raw TOML, keeping file and supervisor in
// agreement on every edge.
//
// `current` always holds a usable posture for display paths, while
// `snapshot()` is the security-critical accessor: it exposes only a policy
// the store actually accepted, so a corrupt file leaves the supervisor
// factory throwing instead of running with an implicit fallback. Writes apply
// live through this shared instance with no restart plus no watcher: an
// accepted write is immediately visible to the egress supervisor, with
// file-first commits so a throwing disk write never diverges memory from
// file.
//
// `load(legacyLocalOrigins:)` runs the one-time migration off the retired
// `browser.allowed_origins` config list: a pre-exemption file imports the
// entries the exemption gates accept into `[network].local_exemptions`,
// persists the merge before memory commits, and stops consulting the legacy
// list as soon as the key exists, so the migration can never run twice.

import Foundation

/// Errors raised when a verified policy snapshot is demanded but unavailable.
///
/// The egress supervisor factory is the primary thrower: it refuses to build
/// a choke-point from a store that never accepted a policy, so a corrupt
/// `policy.toml` fails boot rather than silently degrading to a permissive
/// posture.
public enum PolicyInvariantError: Error, Sendable, Equatable {
    /// No policy has been accepted yet (never loaded, or the last load failed).
    case notVerified(reason: String)
    /// The held policy stopped satisfying the formal invariants.
    case invariantViolations([String])
    /// The policy verified but its serialized bytes do not reparse identically.
    case serializationFailed(reason: String)
}

extension PolicyInvariantError: LocalizedError {
    /// Human-readable refusal naming the failing gate without secret bytes.
    public var errorDescription: String? {
        switch self {
        case let .notVerified(reason):
            "Security policy is not verified: \(reason)"
        case let .invariantViolations(violations):
            "Security policy violates formal invariants: " + violations.joined(separator: "; ")
        case let .serializationFailed(reason):
            "Serialized policy failed verification: \(reason)"
        }
    }
}

/// Atomically read view of the externally visible policy state.
///
/// Bundles the live policy with its file path, load flag, and live
/// invariant status so one isolation covers the whole read.
public struct PolicySnapshot: Sendable, Equatable {
    /// Live policy held by the store.
    public let policy: SecurityPolicy
    /// Path to `policy.toml` on disk.
    public let fileURL: URL
    /// Whether the policy was loaded from disk.
    public let loadedFromDisk: Bool
    /// Live invariant violations for the returned policy.
    public let violations: [String]
    /// Monotonic mutation generation counter.
    public let generation: UInt64

    /// Creates a snapshot.
    /// - Parameters:
    ///   - policy: Live policy held by the store.
    ///   - fileURL: Path to `policy.toml` on disk.
    ///   - loadedFromDisk: Whether the policy was loaded from disk.
    ///   - violations: Live invariant violations for the returned policy.
    ///   - generation: Monotonic mutation generation counter.
    public init(policy: SecurityPolicy, fileURL: URL, loadedFromDisk: Bool, violations: [String], generation: UInt64 = 0) {
        self.policy = policy
        self.fileURL = fileURL
        self.loadedFromDisk = loadedFromDisk
        self.violations = violations
        self.generation = generation
    }
}

/// Actor-backed store managing `~/.runeweaver/policy.toml`.
///
/// Thread-safe singleton holding the active security policy. Callers
/// read `current` for the live snapshot; mutations go through `update`
/// which re-validates invariants before committing. Security-critical
/// consumers (the egress supervisor factory) read `snapshot()` instead so
/// a fallback posture is never mistaken for an accepted policy.
public actor PolicyStore {
    /// The active security policy. Always valid — parse or invariant
    /// failures fall back to `SecurityPolicy.safeDefault`.
    public private(set) var current: SecurityPolicy

    /// Path to the policy file on disk.
    public let fileURL: URL

    /// Diagnostic messages from the most recent load attempt.
    public private(set) var lastLoadDiagnostics: [String] = []

    /// Whether the current policy was loaded from disk (vs. factory default).
    public private(set) var loadedFromDisk: Bool = false

    /// Policy the store accepted through `load()` or `update()`, or nil when
    /// the last attempt failed. Held separately from `current` because
    /// `current` must stay displayable after a rejection while
    /// `snapshot()` must refuse to present the fallback as authoritative.
    private var verifiedPolicy: SecurityPolicy?

    /// Monotonic mutation generation counter tracking state revisions.
    private var generation: UInt64 = 0

    /// Returns the current mutation generation counter.
    public func currentGeneration() -> UInt64 {
        generation
    }

    /// Creates a policy store.
    /// - Parameter fileURL: Path to `policy.toml`. Defaults to `~/.runeweaver/policy.toml`.
    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.current = .safeDefault
    }

    /// Default policy file location: `~/.runeweaver/policy.toml`.
    public static func defaultFileURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".runeweaver/policy.toml")
    }

    /// Resolves the one policy store for this process.
    ///
    /// An injected store stays authoritative so a caller that already built
    /// tools keeps sharing it with the settings routes; a nil store
    /// constructs and loads the factory default, letting a missing file seed
    /// the deny-by-default posture while corruption leaves the snapshot
    /// unverified for the supervisor factory to refuse.
    /// - Parameters:
    ///   - injected: Shared store when the caller already owns one.
    ///   - fileURL: Path to `policy.toml`. Defaults to `nil` (`~/.runeweaver/policy.toml`).
    ///   - legacyLocalOrigins: Retired `browser.allowed_origins` entries used
    ///     only while loading a store here, so an injected instance already
    ///     resolved by an earlier call is returned untouched.
    /// - Returns: The single store every supervisor in this process reads.
    public static func makeLoaded(
        injected: PolicyStore?,
        fileURL: URL? = nil,
        legacyLocalOrigins: [String] = []
    ) async -> PolicyStore {
        if let injected {
            return injected
        }
        let created = PolicyStore(fileURL: fileURL)
        await created.load(legacyLocalOrigins: legacyLocalOrigins)
        return created
    }

    /// Loads the policy from disk, falling back to safe defaults on error.
    ///
    /// If the file does not exist, creates a default policy file — carrying
    /// any imported legacy origins — and uses that seeded posture. If the
    /// file exists but is malformed, records the reason in
    /// `lastLoadDiagnostics` (surfaced verbatim by `snapshot()` rejections)
    /// and falls back to the safe default. A missing file still counts as a
    /// successful (deny-by-default) load so a stock install boots; an
    /// unreadable, unparseable, or invariant-violating file does not, so
    /// `snapshot()` keeps throwing until a later `load()` or `update()`
    /// accepts a policy.
    ///
    /// A pre-exemption file (parses and verifies, yet carries no
    /// `[network].local_exemptions` key) runs the one-time migration from the
    /// retired `browser.allowed_origins` list: accepted entries land in
    /// `local_exemptions`, the file is rewritten first, and memory commits
    /// second. A throwing write keeps the merged posture live and retries on
    /// the next load because the key still is not on disk; a file that
    /// already carries the key ignores the legacy list entirely.
    /// - Parameter legacyLocalOrigins: Raw `browser.allowed_origins` entries
    ///   to import when the file predates the exemption key.
    /// - Returns: The accepted policy held by the store.
    @discardableResult
    public func load(legacyLocalOrigins: [String] = []) -> SecurityPolicy {
        var diagnostics: [String] = []
        defer { lastLoadDiagnostics = diagnostics }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            diagnostics.append("Policy file not found at \(fileURL.path). Using safe defaults.")
            let seeded = Self.importingLegacyLocalOrigins(
                into: .safeDefault,
                legacyOrigins: legacyLocalOrigins,
                diagnostics: &diagnostics
            )
            seedDefaultPolicyFile(seeded, diagnostics: &diagnostics)
            current = seeded
            loadedFromDisk = false
            // The seeded factory posture is deny-by-default and invariant-clean,
            // so a first run boots supervised instead of refusing to start; any
            // imported legacy entry passed the same exemption gate a load runs.
            verifiedPolicy = seeded
            return current
        }

        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            diagnostics.append("Policy file at \(fileURL.path) is unreadable. Using safe defaults.")
            current = .safeDefault
            loadedFromDisk = false
            verifiedPolicy = nil
            return current
        }

        do {
            let parsed = try Self.parse(text)
            let violations = PolicyInvariantVerifier.verify(parsed)
            if !violations.isEmpty {
                for violation in violations {
                    diagnostics.append("Policy invariant violation: \(violation)")
                }
                diagnostics.append("Falling back to safe defaults due to invariant violations.")
                current = .safeDefault
                loadedFromDisk = false
                verifiedPolicy = nil
                return current
            }
            // A pre-exemption file migrates exactly once: import the retired
            // list, persist file-first, then commit memory. The key on disk is
            // the migration marker, so this branch cannot run twice for one
            // file and the legacy list is never consulted again after a write.
            guard Self.containsLocalExemptionsKey(in: text) else {
                let merged = Self.importingLegacyLocalOrigins(
                    into: parsed,
                    legacyOrigins: legacyLocalOrigins,
                    diagnostics: &diagnostics
                )
                if merged != parsed {
                    let importedCount = merged.network.localExemptions.count - parsed.network.localExemptions.count
                    diagnostics.append(
                        "Migrated \(importedCount) legacy browser.allowed_origins "
                            + "\(importedCount == 1 ? "entry" : "entries") into [network].local_exemptions."
                    )
                }
                do {
                    let toml = try Self.verifiedTOML(for: merged)
                    let directory = fileURL.deletingLastPathComponent()
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try toml.write(to: fileURL, atomically: true, encoding: .utf8)
                    diagnostics.append("Policy loaded successfully from \(fileURL.path).")
                } catch {
                    // The imported grants stay active for this process: dropping
                    // back to the parsed posture would silently repeal an owner's
                    // local access, and the key still absent from disk makes the
                    // next load retry the same migration.
                    diagnostics.append(
                        "Could not persist migrated local_exemptions to \(fileURL.path); "
                            + "will retry next load: \(error.localizedDescription)"
                    )
                }
                current = merged
                loadedFromDisk = true
                verifiedPolicy = merged
                return current
            }
            current = parsed
            loadedFromDisk = true
            verifiedPolicy = parsed
            diagnostics.append("Policy loaded successfully from \(fileURL.path).")
            return current
        } catch {
            diagnostics.append("Policy parse error: \(error). Using safe defaults.")
            current = .safeDefault
            loadedFromDisk = false
            verifiedPolicy = nil
            return current
        }
    }

    /// Imports retired `browser.allowed_origins` entries into `local_exemptions`.
    ///
    /// Each raw entry re-enters the same shape plus never-exempt gates the
    /// invariant verifier runs on a stored exemption, and only then is it
    /// canonicalized through `NetworkEgressPolicy.canonicalEntry`, so a
    /// legacy value that could never match (blank, port-qualified, URL,
    /// glob, metadata, or link-local) is skipped instead of being laundered
    /// into the posture under a different spelling. Rejections land in
    /// `lastLoadDiagnostics` so the operator can repair the retired entry.
    /// - Parameters:
    ///   - policy: Parsed policy to extend.
    ///   - legacyOrigins: Raw retired `browser.allowed_origins` values.
    ///   - diagnostics: Load diagnostics collecting rejection reasons.
    /// - Returns: `policy` with every accepted entry's canonical form added.
    private static func importingLegacyLocalOrigins(
        into policy: SecurityPolicy,
        legacyOrigins: [String],
        diagnostics: inout [String]
    ) -> SecurityPolicy {
        guard !legacyOrigins.isEmpty else { return policy }
        var imported: Set<String> = []
        for raw in legacyOrigins {
            let probe = SecurityPolicy(network: NetworkEgressPolicy(localExemptions: [raw]))
            let violations = PolicyInvariantVerifier.verifyLocalExemptions(probe)
            guard violations.isEmpty else {
                diagnostics.append(
                    "Skipped legacy browser.allowed_origins entry '\(raw)': \(violations.joined(separator: " "))"
                )
                continue
            }
            imported.insert(NetworkEgressPolicy.canonicalEntry(raw))
        }
        guard !imported.isEmpty else { return policy }
        var merged = policy
        merged.network.localExemptions.formUnion(imported)
        return merged
    }

    /// Updates the active policy, validating invariants before committing.
    ///
    /// If the new policy violates any invariant, the update is rejected and
    /// the current policy remains unchanged. A committed update becomes the
    /// verified snapshot, mirroring a successful load.
    /// - Parameter policy: Proposed new policy.
    /// - Returns: Empty array on success, or invariant violation descriptions on failure.
    @discardableResult
    public func update(_ policy: SecurityPolicy) -> [String] {
        let violations = PolicyInvariantVerifier.verify(policy)
        guard violations.isEmpty else {
            return violations
        }
        current = policy
        verifiedPolicy = policy
        generation &+= 1
        return []
    }

    /// Returns the accepted, invariant-clean policy snapshot.
    ///
    /// Security-critical consumers read the store through this accessor
    /// rather than `current`: a corrupt or unverifiable file must never be
    /// laundered into an authoritative policy. A missing file still counts
    /// as loaded because the store seeds the factory-safe default posture.
    /// - Returns: The accepted policy, re-verified on read.
    /// - Throws: `PolicyInvariantError` when no policy was ever accepted or
    ///   the accepted snapshot no longer satisfies the formal invariants.
    public func snapshot() throws -> SecurityPolicy {
        guard let verifiedPolicy else {
            let diagnostics = lastLoadDiagnostics.isEmpty
                ? "the policy file was never loaded."
                : lastLoadDiagnostics.joined(separator: " ")
            throw PolicyInvariantError.notVerified(
                reason: "no verified policy is available for \(fileURL.path): \(diagnostics)"
            )
        }
        let violations = PolicyInvariantVerifier.verify(verifiedPolicy)
        guard violations.isEmpty else {
            throw PolicyInvariantError.invariantViolations(violations)
        }
        return verifiedPolicy
    }

    /// Atomically reads the externally visible policy state.
    ///
    /// One isolation holds `current`, the file path, the load flag, and the
    /// invariant status together, so a concurrent write cannot slip between
    /// separate reads and mix a pre-write policy with post-write violations
    /// in a single response. The violation branch mirrors the diagnostics
    /// rule: a present-but-rejected file reports the load diagnostics instead
    /// of laundering the fallback as healthy.
    /// - Returns: Snapshot holding policy, file URL, load flag, and live invariant violations.
    public func readSnapshot() -> PolicySnapshot {
        let policy = current
        let url = fileURL
        let loaded = loadedFromDisk
        let violations: [String]
        if !loaded, FileManager.default.fileExists(atPath: url.path) {
            do {
                let verified = try snapshot()
                violations = PolicyInvariantVerifier.verify(verified)
            } catch {
                violations = lastLoadDiagnostics.isEmpty ? [error.localizedDescription] : lastLoadDiagnostics
            }
        } else {
            violations = PolicyInvariantVerifier.verify(policy)
        }
        return PolicySnapshot(policy: policy, fileURL: url, loadedFromDisk: loaded, violations: violations, generation: generation)
    }

    /// Persists the current policy to disk as TOML.
    ///
    /// Re-verifies the held posture at the storage boundary so a violating
    /// policy can never reach disk, mirroring the `load`/`update` gates.
    /// A held violation throws instead of persisting, keeping the file as
    /// the source of truth for invariant-clean postures only.
    public func save() throws {
        let violations = PolicyInvariantVerifier.verify(current)
        guard violations.isEmpty else {
            throw PolicyInvariantError.invariantViolations(violations)
        }
        let toml = try Self.verifiedTOML(for: current)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try toml.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Replaces the active policy with a validated candidate.
    ///
    /// Verifies the formal invariants, proves the bytes reparse through
    /// the store-owned round-trip, writes the file first, then commits to
    /// memory, so a throwing disk write never leaves memory ahead of the
    /// file. Every step stays inside actor isolation, keeping the
    /// encapsulation a route-side write plus reload cannot provide.
    /// - Parameters:
    ///   - policy: Candidate to persist.
    ///   - expectedGeneration: Optional expected mutation generation for optimistic concurrency.
    /// - Returns: The committed policy.
    /// - Throws: `PolicyInvariantError` when invariants fail, concurrency conflict occurs,
    ///   or the bytes do not round-trip; filesystem errors propagate unchanged.
    @discardableResult
    public func replace(_ policy: SecurityPolicy, expectedGeneration: UInt64? = nil) throws -> SecurityPolicy {
        if let expected = expectedGeneration, expected != generation {
            throw PolicyInvariantError.invariantViolations([
                "Concurrent modification: policy was changed by another request (expected generation \(expected), current \(generation))."
            ])
        }
        let violations = PolicyInvariantVerifier.verify(policy)
        guard violations.isEmpty else {
            throw PolicyInvariantError.invariantViolations(violations)
        }
        let toml = try Self.verifiedTOML(for: policy)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try toml.write(to: fileURL, atomically: true, encoding: .utf8)
        current = policy
        verifiedPolicy = policy
        loadedFromDisk = true
        generation &+= 1
        lastLoadDiagnostics = ["Policy updated successfully from \(fileURL.path)."]
        return policy
    }

    /// Appends an allowed domain to the policy, verifying invariants, updating state, and saving to disk.
    ///
    /// Fail-closed and atomic: the candidate verifies before any file write,
    /// the file writes before any in-memory commit, so a disk-write throw
    /// leaves memory and file agreeing instead of diverging with memory
    /// mutated while the file stayed behind.
    @discardableResult
    public func appendAllowedDomain(_ domain: String) throws -> SecurityPolicy {
        try Self.validateDomainEntry(domain)
        let updated = current.appendingAllowedDomain(domain)
        let violations = PolicyInvariantVerifier.verify(updated)
        guard violations.isEmpty else {
            throw PolicyInvariantError.invariantViolations(violations)
        }
        let toml = try Self.verifiedTOML(for: updated)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try toml.write(to: fileURL, atomically: true, encoding: .utf8)
        current = updated
        verifiedPolicy = updated
        generation &+= 1
        return updated
    }

    /// Appends a blocked domain to the policy, verifying invariants, updating state, and saving to disk.
    ///
    /// Fail-closed and atomic like `appendAllowedDomain`: file-first commit
    /// keeps a throwing write from leaving an unpersisted policy masquerading
    /// as applied.
    @discardableResult
    public func appendBlockedDomain(_ domain: String) throws -> SecurityPolicy {
        try Self.validateDomainEntry(domain)
        let updated = current.appendingBlockedDomain(domain)
        let violations = PolicyInvariantVerifier.verify(updated)
        guard violations.isEmpty else {
            throw PolicyInvariantError.invariantViolations(violations)
        }
        let toml = try Self.verifiedTOML(for: updated)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try toml.write(to: fileURL, atomically: true, encoding: .utf8)
        current = updated
        verifiedPolicy = updated
        generation &+= 1
        return updated
    }

    /// Ensures candidate URLs or hostnames (such as configured services and mail accounts)
    /// are present in the allowed domains list, appending any missing entries atomically.
    ///
    /// Fail-closed on a present-but-rejected file: auto-population may extend
    /// only a posture the store actually accepted, or seed a missing file, so a
    /// corrupt `policy.toml` is never overwritten with safe-default plus service
    /// hosts and laundered into a verified snapshot.
    @discardableResult
    public func ensureServiceDomainsAllowed(urlsOrHosts: [String]) -> SecurityPolicy {
        // `load()` leaves `verifiedPolicy` nil when the operator's file is
        // unreadable, unparseable, or invariant-violating. Writing here would
        // manufacture an accepted posture from an unaccepted file, void the
        // fail-closed boot contract, and destroy the operator's content. A
        // missing file still seeds (the store either loaded its factory posture
        // or never ran), so first-run auto-population is unchanged.
        let filePresent = FileManager.default.fileExists(atPath: fileURL.path)
        guard verifiedPolicy != nil || !filePresent else { return current }
        var missing: [String] = []
        for raw in urlsOrHosts {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let host: String = if trimmed.contains("://"), let url = URL(string: trimmed), let urlHost = url.host, !urlHost.isEmpty {
                urlHost
            } else {
                Self.serviceHostFromBareEntry(trimmed)
            }
            // Reuse the shared canonicalizer so bracketed literals, casing,
            // trailing dots, and alternate numeric spellings compare exactly
            // as the matcher evaluates them.
            let normalized = NetworkEgressPolicy.canonicalEntry(host)
            guard !normalized.isEmpty else { continue }
            // Service hosts come from operator config, but the write path still
            // refuses bytes that cannot survive TOML quoting rather than
            // persisting a policy a later load might read differently.
            guard !Self.containsTOMLBreakingScalar(normalized) else { continue }
            if !current.network.allowedDomains.contains(normalized) {
                missing.append(normalized)
            }
        }
        guard !missing.isEmpty else { return current }
        var updatedPolicy = current
        for domain in missing {
            updatedPolicy = updatedPolicy.appendingAllowedDomain(domain)
        }
        let violations = PolicyInvariantVerifier.verify(updatedPolicy)
        guard violations.isEmpty else { return current }
        let directory = fileURL.deletingLastPathComponent()
        do {
            let toml = try Self.verifiedTOML(for: updatedPolicy)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try toml.write(to: fileURL, atomically: true, encoding: .utf8)
            current = updatedPolicy
            verifiedPolicy = updatedPolicy
            generation &+= 1
        } catch {
            // Best effort write
            RuneWeaverLog.stores.error("PolicyStore: failed to persist updated security policy to '\(fileURL.path)': \(error.localizedDescription)")
        }
        return current
    }
}

// MARK: - Static TOML and Seeding Helpers

/// Parsing, serialization, and seeding helpers split from the actor body:
/// they operate on values plus the file URL only, so keeping them together
/// here leaves the isolated policy state and mutation paths scannable in one
/// place. Members stay on `PolicyStore` itself, so no caller changes.
extension PolicyStore {
    /// Extracts a comparable host from a bare service entry without a scheme.
    ///
    /// Bracketed literals strip to their inner address (ignoring an optional
    /// numeric `:port` after `]`), mirroring the
    /// `SensitiveAddressNormalization` bracket handling; an unbracketed value
    /// with more than one colon is a bare IPv6 literal and keeps its colons,
    /// while a single colon marks a `host:port` suffix that strips. A lone
    /// `::1` therefore survives instead of truncating to an empty host, and
    /// `2001:db8::1` survives instead of truncating to `2001`.
    /// - Parameter trimmed: Whitespace-trimmed entry without a scheme.
    /// - Returns: Host text for the shared canonicalizer.
    private static func serviceHostFromBareEntry(_ trimmed: String) -> String {
        if trimmed.hasPrefix("[") {
            guard let closing = trimmed.firstIndex(of: "]") else {
                return trimmed
            }
            return String(trimmed[trimmed.index(after: trimmed.startIndex) ..< closing])
        }
        // Multiple colons with no brackets mark an unbracketed IPv6 literal,
        // which keeps its colons instead of being mistaken for host:port.
        if trimmed.filter({ $0 == ":" }).count > 1 {
            return trimmed
        }
        if let colon = trimmed.firstIndex(of: ":") {
            return String(trimmed[..<colon])
        }
        return trimmed
    }

    // MARK: - Storage-Boundary Guards

    /// Rejects a domain entry that TOML cannot represent safely.
    ///
    /// Domain text reaches the store from model-influenced approval decisions,
    /// and Foundation percent-decodes `URL.host`, so a crafted host can carry
    /// a quote or control character that would otherwise close the array
    /// element and inject real policy content. Blank input stays a no-op so
    /// appenders keep discarding entries that could only match an empty host.
    private static func validateDomainEntry(_ domain: String) throws {
        let canonical = NetworkEgressPolicy.canonicalEntry(domain)
        guard canonical.isEmpty || !containsTOMLBreakingScalar(canonical) else {
            throw PolicyInvariantError.invariantViolations(["Domain entry carries a quote or control character; refusing to write policy.toml."])
        }
    }

    /// Whether policy text carries scalars a TOML basic string must escape:
    /// the double quote, C0 controls, and DEL. These never survive the
    /// serializer/parser pair intact, so callers reject rather than write.
    /// Shared by the settings REST boundary so both layers refuse the same
    /// bytes instead of keeping parallel copies that could drift.
    public static func containsTOMLBreakingScalar(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0 == "\"" || $0.value < 0x20 || $0.value == 0x7F }
    }

    /// Serializes a policy and proves the bytes reparse to the same policy.
    ///
    /// The store-owned round-trip proof every write boundary shares: `save()`,
    /// the domain appenders, default seeding, and the settings REST PUT all
    /// serialize here, so no caller can drift onto a weaker private copy.
    /// Escaping keeps hostile text inside its string; reparsing the whole
    /// document then proves it survives a load, so a candidate that would read
    /// back as different content (or fail to parse) is refused before it can
    /// replace the operator's file. Together the two steps turn "the object
    /// verified" into "the bytes on disk verify", closing the gap between the
    /// pre-serialization invariant check and what a later load reads.
    /// - Parameter policy: Invariant-clean candidate to render.
    /// - Returns: TOML bytes that reparse to `policy`.
    /// - Throws: `PolicyInvariantError.serializationFailed` when the bytes do not read back identically.
    public static func verifiedTOML(for policy: SecurityPolicy) throws -> String {
        let toml = serialize(policy)
        guard let reparsed = try? parse(toml), reparsed == policy else {
            throw PolicyInvariantError.serializationFailed(reason: "Serialized policy does not round-trip; refusing to write policy.toml.")
        }
        return toml
    }

    // MARK: - TOML Parsing

    /// Parses a TOML string into a `SecurityPolicy`.
    ///
    /// The policy file owns network plus credentials only. Legacy
    /// `[filesystem]` and `[tools.*]` tables are tolerated on load and
    /// ignored without error so older files keep booting; they never
    /// contribute to the resulting posture and are dropped on the next save.
    public static func parse(_ text: String) throws -> SecurityPolicy {
        let root = try TOMLParser.parse(text)

        let version = root.values["version"].flatMap { value -> Int? in
            if case let .integer(versionNumber) = value {
                return versionNumber
            }
            return nil
        } ?? 1

        let network = parseNetworkPolicy(from: root.tables["network"])
        let credentials = parseCredentials(from: root.tables["credentials"])

        return SecurityPolicy(
            version: version,
            network: network,
            credentials: credentials
        )
    }

    /// Whether policy text carries a `[network].local_exemptions` key.
    ///
    /// Distinguishes a pre-exemption file that must be seeded (key missing)
    /// from one the owner already edited (key present, even as an empty array),
    /// so the migration path rewrites exactly once. Unparseable text reports
    /// false because it cannot carry a readable key.
    /// - Parameter text: Candidate `policy.toml` contents.
    /// - Returns: True when `[network].local_exemptions` exists in the parsed document.
    public static func containsLocalExemptionsKey(in text: String) -> Bool {
        guard let root = try? TOMLParser.parse(text) else { return false }
        return root.tables["network"]?.values["local_exemptions"] != nil
    }

    /// Parses the `[network]` table, defaulting a missing file or table to
    /// the deny-by-default posture.
    ///
    /// A missing `mode` stays allowlist-only, the legacy `deny_by_default`
    /// spelling maps to the same posture, and any unknown string fails
    /// closed to allowlist-only rather than opening egress. Domain lists
    /// trim surrounding whitespace and drop blanks so an empty entry can
    /// never authorize an empty host. `local_exemptions` follows the same
    /// trim-and-drop rule, and a missing key yields an empty set.
    private static func parseNetworkPolicy(from node: TOMLNode?) -> NetworkEgressPolicy {
        guard let node else { return .safeDefault }

        let mode: EgressMode = if case let .string(raw) = node.values["mode"] {
            if raw.trimmingCharacters(in: .whitespacesAndNewlines) == "deny_by_default" {
                .allowlistOnly
            } else {
                EgressMode(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .allowlistOnly
            }
        } else {
            .allowlistOnly
        }

        let allowed: Set<String> = if case let .stringArray(arr) = node.values["allowed_domains"] {
            Set(arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        } else {
            NetworkEgressPolicy.safeDefault.allowedDomains
        }

        let blocked: Set<String> = if case let .stringArray(arr) = node.values["blocked_domains"] {
            Set(arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        } else {
            NetworkEgressPolicy.safeDefault.blockedDomains
        }

        let localExemptions: Set<String> = if case let .stringArray(arr) = node.values["local_exemptions"] {
            Set(arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        } else {
            []
        }

        return NetworkEgressPolicy(
            mode: mode,
            allowedDomains: allowed,
            blockedDomains: blocked,
            localExemptions: localExemptions
        )
    }

    /// Parses one `[credentials.<key>]` table into its host/method/prefix binding.
    ///
    /// One binding pairs one key with every host it may reach: the secret
    /// rides only when the request host matches, the method matches (or the
    /// binding leaves methods empty for Any), and the effective path matches
    /// a prefix (or prefixes stay empty for Any). Hosts trim, methods trim
    /// and uppercase, prefixes trim, and blanks drop so empty entries stay
    /// unusable instead of matching broadly.
    private static func parseCredentials(from node: TOMLNode?) -> [String: CredentialBinding] {
        guard let node else { return [:] }
        var result: [String: CredentialBinding] = [:]
        for (key, table) in node.tables {
            let hosts: Set<String> = if case let .stringArray(arr) = table.values["allowed_hosts"] {
                Set(arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            } else {
                []
            }

            let methods: Set<String> = if case let .stringArray(arr) = table.values["allowed_methods"] {
                Set(arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }.filter { !$0.isEmpty })
            } else {
                []
            }

            let prefixes: [String] = if case let .stringArray(arr) = table.values["allowed_path_prefixes"] {
                arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            } else {
                []
            }

            result[key] = CredentialBinding(
                allowedHosts: hosts,
                allowedMethods: methods,
                allowedPathPrefixes: prefixes
            )
        }
        return result
    }

    // MARK: - TOML Serialization

    /// Serializes a `SecurityPolicy` to TOML text.
    ///
    /// Emits `version` plus `[network]` plus one `[credentials.<key>]`
    /// block per binding only. Legacy filesystem and tool sections are
    /// never written, so a resaved file sheds them while round-tripping
    /// the network-plus-credentials posture intact. `local_exemptions`
    /// renders directly after `blocked_domains` with the same sorted,
    /// escaped string-array shape, so the round-trip proof covers grants
    /// on equal footing with the other network lists. Every string and table
    /// key renders through `RuneWeaverConfig.tomlQuoted` so policy values
    /// can never terminate their own quoting and inject document structure.
    /// `verifiedTOML(for:)` proves the result reparses to the same policy
    /// before any caller replaces the on-disk file.
    public static func serialize(_ policy: SecurityPolicy) -> String {
        var lines: [String] = []
        lines.append("# Rune Weaver Security Policy")
        lines.append("# Declarative security boundaries — network egress plus credential bindings.")
        lines.append("#")
        lines.append("# Edit via the Web Dashboard Policy tab or directly in this file.")
        lines.append("# The engine validates invariants on load; violations fall back to safe defaults.")
        lines.append("")
        lines.append("version = \(policy.version)")
        lines.append("")

        // [network]
        lines.append("[network]")
        lines.append("mode = \(RuneWeaverConfig.tomlQuoted(policy.network.mode.rawValue))")
        lines.append("allowed_domains = [\(serializeStringArray(Array(policy.network.allowedDomains.sorted())))]")
        lines.append("blocked_domains = [\(serializeStringArray(Array(policy.network.blockedDomains.sorted())))]")
        lines.append("local_exemptions = [\(serializeStringArray(Array(policy.network.localExemptions.sorted())))]")
        lines.append("")

        // [credentials.*]
        // A surrogate key may legally contain `.`, and an unquoted dotted
        // key would parse as nested tables, so the file written here could
        // not be reloaded. Quoting through `tomlQuoted` also escapes quotes
        // and control characters, so a hostile key can never close its
        // header and inject table content.
        for key in policy.credentials.keys.sorted() {
            guard let binding = policy.credentials[key] else { continue }
            lines.append("[credentials.\(RuneWeaverConfig.tomlQuoted(key))]")
            lines.append("allowed_hosts = [\(serializeStringArray(Array(binding.allowedHosts.sorted())))]")
            if !binding.allowedMethods.isEmpty {
                lines.append("allowed_methods = [\(serializeStringArray(Array(binding.allowedMethods.sorted())))]")
            }
            if !binding.allowedPathPrefixes.isEmpty {
                lines.append("allowed_path_prefixes = [\(serializeStringArray(binding.allowedPathPrefixes))]")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Renders one inline string array with each element escaped through the
    /// shared `tomlQuoted` helper. Policy entries can carry percent-decoded
    /// host text from model-influenced approvals, so raw interpolation would
    /// let a quote or newline close the array and inject policy content.
    private static func serializeStringArray(_ values: [String]) -> String {
        values.map { RuneWeaverConfig.tomlQuoted($0) }.joined(separator: ", ")
    }

    // MARK: - Default Seeding

    /// Writes a policy.toml if none exists.
    ///
    /// The seeded posture is the factory-safe default extended with any
    /// accepted legacy origins, so a first run persists the same grants it
    /// holds in memory instead of dropping them on the next boot.
    /// - Parameters:
    ///   - policy: Posture to seed.
    ///   - diagnostics: Load diagnostics collecting seed results.
    private func seedDefaultPolicyFile(_ policy: SecurityPolicy, diagnostics: inout [String]) {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let toml = try Self.verifiedTOML(for: policy)
            try toml.write(to: fileURL, atomically: true, encoding: .utf8)
            diagnostics.append("Created default policy file at \(fileURL.path).")
        } catch {
            diagnostics.append("Could not seed default policy file: \(error.localizedDescription)")
        }
    }
}
