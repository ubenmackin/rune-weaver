// Rune Weaver Core — Actor-backed store for ~/.runeweaver/policy.toml.

import Foundation

/// Errors raised when a verified policy snapshot is demanded but unavailable.
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

/// Atomically read view of the externally visible policy state. Bundles the live policy with its
/// file path, load flag, and live invariant status so one isolation covers the whole read.
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

    /// Creates a snapshot. policy: Live policy held by the store.
    public init(policy: SecurityPolicy, fileURL: URL, loadedFromDisk: Bool, violations: [String], generation: UInt64 = 0) {
        self.policy = policy
        self.fileURL = fileURL
        self.loadedFromDisk = loadedFromDisk
        self.violations = violations
        self.generation = generation
    }
}

/// Actor-backed store managing `~/.runeweaver/policy.toml`. Thread-safe singleton holding the
/// active security policy.
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

    /// Policy the store accepted through `load()` or `update()`, or nil when the last attempt
    /// failed.
    private var verifiedPolicy: SecurityPolicy?

    /// Monotonic mutation generation counter tracking state revisions.
    private var generation: UInt64 = 0

    /// Shared semantic answer cache cleared on every committed policy change,
    /// so a pure answer cached under the prior posture never replays after a
    /// policy rewrite. Nil keeps the store standalone for direct-core callers.
    private var answerCache: SemanticAnswerCache?

    /// Wires the shared semantic answer cache for policy-change invalidation.
    /// - Parameter cache: Cache cleared on every committed policy mutation, or nil to detach.
    public func setAnswerCache(_ cache: SemanticAnswerCache?) {
        answerCache = cache
    }

    /// Clears the shared semantic answer cache after a committed policy change.
    private func invalidateAnswerCache() async {
        await answerCache?.invalidateOnMemoryWrite()
    }

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
    public static func makeLoaded(
        injected: PolicyStore?,
        fileURL: URL? = nil
    ) async -> PolicyStore {
        if let injected {
            return injected
        }
        let created = PolicyStore(fileURL: fileURL)
        await created.load()
        return created
    }

    /// Loads the policy from disk, falling back to safe defaults on error.
    @discardableResult
    public func load() -> SecurityPolicy {
        var diagnostics: [String] = []
        defer { lastLoadDiagnostics = diagnostics }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            diagnostics.append("Policy file not found at \(fileURL.path). Using safe defaults.")
            seedDefaultPolicyFile(.safeDefault, diagnostics: &diagnostics)
            current = .safeDefault
            loadedFromDisk = false
            // The seeded factory posture is deny-by-default and invariant-clean,
            // so a first run boots supervised instead of refusing to start.
            verifiedPolicy = .safeDefault
            return current
        }

        let text: String
        do {
            text = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            diagnostics.append("Policy file at \(fileURL.path) is unreadable. Using safe defaults.")
            RuneWeaverLog.stores.error("PolicyStore: policy file at \(fileURL.path) is unreadable: \(error.localizedDescription)")
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

    /// Updates the active policy, validating invariants before committing. If the new policy
    /// violates any invariant, the update is rejected and the current policy remains unchanged.
    @discardableResult
    public func update(_ policy: SecurityPolicy) async -> [String] {
        let violations = PolicyInvariantVerifier.verify(policy)
        guard violations.isEmpty else {
            return violations
        }
        current = policy
        verifiedPolicy = policy
        generation &+= 1
        // A committed policy change can rewrite future pure answers; clear
        // before returning so no turn can hit a stale entry between commit
        // and an unstructured clear.
        await invalidateAnswerCache()
        return []
    }

    /// Returns the accepted, invariant-clean policy snapshot.
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

    /// Persists the current policy to disk as TOML. Re-verifies the held posture at the storage
    /// boundary so a violating policy can never reach disk, mirroring the `load`/`update` gates.
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
    @discardableResult
    public func replace(_ policy: SecurityPolicy, expectedGeneration: UInt64? = nil) async throws -> SecurityPolicy {
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
        await invalidateAnswerCache()
        return policy
    }

    /// Appends an allowed domain to the policy, verifying invariants, updating state, and saving to
    /// disk.
    @discardableResult
    public func appendAllowedDomain(_ domain: String) async throws -> SecurityPolicy {
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
        await invalidateAnswerCache()
        return updated
    }

    /// Appends a blocked domain to the policy, verifying invariants, updating state, and saving to
    /// disk.
    @discardableResult
    public func appendBlockedDomain(_ domain: String) async throws -> SecurityPolicy {
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
        await invalidateAnswerCache()
        return updated
    }

    /// Ensures candidate URLs or hostnames (such as configured services and mail accounts) are
    /// present in the allowed domains list, appending any missing entries atomically.
    @discardableResult
    public func ensureServiceDomainsAllowed(urlsOrHosts: [String]) async -> SecurityPolicy {
        // `load()` leaves `verifiedPolicy` nil when the operator's file is unreadable, unparseable,
        // or invariant-violating.
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
            await invalidateAnswerCache()
        } catch {
            // Best effort write
            RuneWeaverLog.stores.error("PolicyStore: failed to persist updated security policy to '\(fileURL.path)': \(error.localizedDescription)")
        }
        return current
    }
}

// MARK: - Static TOML and Seeding Helpers

/// Parsing, serialization, and seeding helpers split from the actor body: they operate on values
/// plus the file URL only, so keeping them together here leaves the isolated policy state and
/// mutation paths scannable in one place.
extension PolicyStore {
    /// Extracts a comparable host from a bare service entry without a scheme.
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

    /// Rejects a domain entry that TOML cannot represent safely. Blank input stays a no-op so
    /// appenders keep discarding entries that could only match an empty host.
    private static func validateDomainEntry(_ domain: String) throws {
        let canonical = NetworkEgressPolicy.canonicalEntry(domain)
        guard canonical.isEmpty || !containsTOMLBreakingScalar(canonical) else {
            throw PolicyInvariantError.invariantViolations(["Domain entry carries a quote or control character; refusing to write policy.toml."])
        }
    }

    /// Whether policy text carries scalars a TOML basic string must escape: the double quote, C0
    /// controls, and DEL. These never survive the serializer/parser pair intact, so callers reject
    /// rather than write.
    public static func containsTOMLBreakingScalar(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0 == "\"" || $0.value < 0x20 || $0.value == 0x7F }
    }

    /// Serializes a policy and proves the bytes reparse to the same policy.
    public static func verifiedTOML(for policy: SecurityPolicy) throws -> String {
        let toml = serialize(policy)
        guard let reparsed = try? parse(toml), reparsed == policy else {
            throw PolicyInvariantError.serializationFailed(reason: "Serialized policy does not round-trip; refusing to write policy.toml.")
        }
        return toml
    }

    // MARK: - TOML Parsing

    /// Parses a TOML string into a `SecurityPolicy`. The policy file owns network plus credentials
    /// only.
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
    public static func containsLocalExemptionsKey(in text: String) -> Bool {
        guard let root = try? TOMLParser.parse(text) else { return false }
        return root.tables["network"]?.values["local_exemptions"] != nil
    }

    /// Parses the `[network]` table, defaulting a missing file or table to the deny-by-default
    /// posture.
    private static func parseNetworkPolicy(from node: TOMLNode?) -> NetworkEgressPolicy {
        guard let node else { return .safeDefault }

        let mode: EgressMode = if case let .string(raw) = node.values["mode"] {
            EgressMode(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .allowlistOnly
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

    /// Serializes a `SecurityPolicy` to TOML text. Emits `version` plus `[network]` plus one
    /// `[credentials.<key>]` block per binding only.
    public static func serialize(_ policy: SecurityPolicy) -> String {
        var lines: [String] = []
        lines.append("# Rune Weaver Security Policy")
        lines.append("# Declarative security boundaries — network egress plus credential bindings.")
        lines.append("#")
        lines.append("# Edit via Settings -> Access (Network/Credentials) or directly in this file.")
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

        // [credentials.*] A surrogate key may legally contain `.`, and an unquoted dotted key would
        // parse as nested tables, so the file written here could not be reloaded.
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

    /// Renders one inline string array with each element escaped through the shared `tomlQuoted`
    /// helper.
    private static func serializeStringArray(_ values: [String]) -> String {
        values.map { RuneWeaverConfig.tomlQuoted($0) }.joined(separator: ", ")
    }

    // MARK: - Default Seeding

    /// Writes a policy.toml if none exists.
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
