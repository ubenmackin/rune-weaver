// Rune Weaver Core — Actor-backed store for ~/.runeweaver/policy.toml.
//
// Manages loading, parsing, validating, and persisting the declarative
// security policy. Auto-creates a safe default policy.toml on first run.
// Parse errors or invariant violations fall back to the immutable safe
// factory posture and record diagnostics for the caller — the engine never
// runs unprotected.
//
// `current` always holds a usable posture for display paths, while
// `snapshot()` is the security-critical accessor: it exposes only a policy
// the store actually accepted, so a corrupt file leaves the supervisor
// factory throwing instead of running with an implicit fallback.

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
}

extension PolicyInvariantError: LocalizedError {
    /// Human-readable refusal naming the failing gate without secret bytes.
    public var errorDescription: String? {
        switch self {
        case let .notVerified(reason):
            "Security policy is not verified: \(reason)"
        case let .invariantViolations(violations):
            "Security policy violates formal invariants: " + violations.joined(separator: "; ")
        }
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
    /// - Parameter injected: Shared store when the caller already owns one.
    /// - Returns: The single store every supervisor in this process reads.
    public static func makeLoaded(injected: PolicyStore?) async -> PolicyStore {
        if let injected {
            return injected
        }
        let created = PolicyStore()
        await created.load()
        return created
    }

    /// Loads the policy from disk, falling back to safe defaults on error.
    ///
    /// If the file does not exist, creates a default policy file and uses
    /// the safe default. If the file exists but is malformed, records the
    /// reason in `lastLoadDiagnostics` (surfaced verbatim by `snapshot()`
    /// rejections) and falls back to the safe default. A missing file still
    /// counts as a successful (deny-by-default) load so a stock install
    /// boots; an unreadable, unparseable, or invariant-violating file does
    /// not, so `snapshot()` keeps throwing until a later `load()` or
    /// `update()` accepts a policy.
    @discardableResult
    public func load() -> SecurityPolicy {
        var diagnostics: [String] = []
        defer { lastLoadDiagnostics = diagnostics }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            diagnostics.append("Policy file not found at \(fileURL.path). Using safe defaults.")
            seedDefaultPolicyFile(diagnostics: &diagnostics)
            current = .safeDefault
            loadedFromDisk = false
            // The seeded factory posture is deny-by-default and invariant-clean,
            // so a first run boots supervised instead of refusing to start.
            verifiedPolicy = .safeDefault
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
        let toml = Self.serialize(current)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try toml.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Appends an allowed domain to the policy, verifying invariants, updating state, and saving to disk.
    ///
    /// Fail-closed and atomic: the candidate verifies before any file write,
    /// the file writes before any in-memory commit, so a disk-write throw
    /// leaves memory and file agreeing instead of diverging with memory
    /// mutated while the file stayed behind.
    @discardableResult
    public func appendAllowedDomain(_ domain: String) throws -> SecurityPolicy {
        let updated = current.appendingAllowedDomain(domain)
        let violations = PolicyInvariantVerifier.verify(updated)
        guard violations.isEmpty else {
            throw PolicyInvariantError.invariantViolations(violations)
        }
        let toml = Self.serialize(updated)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try toml.write(to: fileURL, atomically: true, encoding: .utf8)
        current = updated
        verifiedPolicy = updated
        return updated
    }

    /// Appends a blocked domain to the policy, verifying invariants, updating state, and saving to disk.
    ///
    /// Fail-closed and atomic like `appendAllowedDomain`: file-first commit
    /// keeps a throwing write from leaving an unpersisted policy masquerading
    /// as applied.
    @discardableResult
    public func appendBlockedDomain(_ domain: String) throws -> SecurityPolicy {
        let updated = current.appendingBlockedDomain(domain)
        let violations = PolicyInvariantVerifier.verify(updated)
        guard violations.isEmpty else {
            throw PolicyInvariantError.invariantViolations(violations)
        }
        let toml = Self.serialize(updated)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try toml.write(to: fileURL, atomically: true, encoding: .utf8)
        current = updated
        verifiedPolicy = updated
        return updated
    }

    // MARK: - TOML Parsing

    /// Parses a TOML string into a `SecurityPolicy`.
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
        let filesystem = parseFilesystemPolicy(from: root.tables["filesystem"])
        let tools = parseToolPolicies(from: root.tables["tools"])

        return SecurityPolicy(
            version: version,
            network: network,
            credentials: credentials,
            filesystem: filesystem,
            tools: tools
        )
    }

    private static func parseNetworkPolicy(from node: TOMLNode?) -> NetworkEgressPolicy {
        guard let node else { return .safeDefault }

        let mode: EgressMode = if case let .string(raw) = node.values["mode"] {
            EgressMode(rawValue: raw) ?? .allowlistOnly
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

        return NetworkEgressPolicy(mode: mode, allowedDomains: allowed, blockedDomains: blocked)
    }

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

    private static func parseFilesystemPolicy(from node: TOMLNode?) -> FilesystemPolicy {
        guard let node else { return .safeDefault }

        // A declared `deny_paths` list augments rather than replaces the
        // protected set: the invariant verifier and the Seatbelt builder both
        // always apply `SeatbeltProfileBuilder.defaultDeniedPaths`, so an
        // empty or narrowed list can never widen the safe posture.
        let roots: [String] = if case let .stringArray(arr) = node.values["allow_roots"] {
            arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        } else {
            []
        }

        let denies: [String] = if case let .stringArray(arr) = node.values["deny_paths"] {
            arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        } else {
            SeatbeltProfileBuilder.defaultDeniedPaths
        }

        return FilesystemPolicy(allowRoots: roots, denyPaths: denies)
    }

    private static func parseToolPolicies(from node: TOMLNode?) -> [String: ToolPolicy] {
        guard let node else { return [:] }
        var result: [String: ToolPolicy] = [:]
        for (key, table) in node.tables {
            let level: PermissionLevel = if case let .string(raw) = table.values["level"] {
                PermissionLevel(rawValue: raw) ?? .requiresApproval
            } else {
                .requiresApproval
            }

            let allowGraduated: Bool = if case let .boolean(graduatedAllowed) = table.values["allow_graduated_trust"] {
                graduatedAllowed
            } else {
                true
            }

            result[key] = ToolPolicy(level: level, allowGraduatedTrust: allowGraduated)
        }
        return result
    }

    // MARK: - TOML Serialization

    /// Serializes a `SecurityPolicy` to TOML text.
    public static func serialize(_ policy: SecurityPolicy) -> String {
        var lines: [String] = []
        lines.append("# Rune Weaver Security Policy")
        lines.append("# Declarative security boundaries — credential bindings, network egress,")
        lines.append("# filesystem access, and tool permission overrides.")
        lines.append("#")
        lines.append("# Edit via the Web Dashboard Security tab or directly in this file.")
        lines.append("# The engine validates invariants on load; violations fall back to safe defaults.")
        lines.append("")
        lines.append("version = \(policy.version)")
        lines.append("")

        // [network]
        lines.append("[network]")
        lines.append("mode = \"\(policy.network.mode.rawValue)\"")
        lines.append("allowed_domains = [\(serializeStringArray(Array(policy.network.allowedDomains.sorted())))]")
        lines.append("blocked_domains = [\(serializeStringArray(Array(policy.network.blockedDomains.sorted())))]")
        lines.append("")

        // [credentials.*]
        // Keys quote like `[tools.*]` below: a surrogate key may legally
        // contain `.`, and an unquoted dotted key would parse as nested
        // tables, so the file written here could not be reloaded.
        for key in policy.credentials.keys.sorted() {
            guard let binding = policy.credentials[key] else { continue }
            lines.append("[credentials.\"\(key)\"]")
            lines.append("allowed_hosts = [\(serializeStringArray(Array(binding.allowedHosts.sorted())))]")
            if !binding.allowedMethods.isEmpty {
                lines.append("allowed_methods = [\(serializeStringArray(Array(binding.allowedMethods.sorted())))]")
            }
            if !binding.allowedPathPrefixes.isEmpty {
                lines.append("allowed_path_prefixes = [\(serializeStringArray(binding.allowedPathPrefixes))]")
            }
            lines.append("")
        }

        // [filesystem]
        lines.append("[filesystem]")
        if !policy.filesystem.allowRoots.isEmpty {
            lines.append("allow_roots = [\(serializeStringArray(policy.filesystem.allowRoots))]")
        }
        lines.append("deny_paths = [\(serializeStringArray(policy.filesystem.denyPaths))]")
        lines.append("")

        // [tools.*]
        for key in policy.tools.keys.sorted() {
            guard let toolPolicy = policy.tools[key] else { continue }
            lines.append("[tools.\"\(key)\"]")
            lines.append("level = \"\(toolPolicy.level.rawValue)\"")
            lines.append("allow_graduated_trust = \(toolPolicy.allowGraduatedTrust)")
            lines.append("")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func serializeStringArray(_ values: [String]) -> String {
        values.map { "\"\($0)\"" }.joined(separator: ", ")
    }

    // MARK: - Default Seeding

    /// Writes a default policy.toml if none exists.
    private func seedDefaultPolicyFile(diagnostics: inout [String]) {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let toml = Self.serialize(.safeDefault)
            try toml.write(to: fileURL, atomically: true, encoding: .utf8)
            diagnostics.append("Created default policy file at \(fileURL.path).")
        } catch {
            diagnostics.append("Could not seed default policy file: \(error.localizedDescription)")
        }
    }
}
