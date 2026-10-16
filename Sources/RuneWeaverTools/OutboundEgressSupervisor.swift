// Rune Weaver Tools — Outbound Egress Supervisor.

import Foundation
import RuneWeaverCore

/// Unified outbound egress supervisor enforcing the security policy pipeline.
public actor OutboundEgressSupervisor {
    /// The policy store providing the active security policy.
    private let policyStore: PolicyStore
    /// Secrets manager for just-in-time credential resolution.
    private let secrets: SecretsManager
    /// Browser config for SSRF guard loopback exemptions.
    private let browserConfig: BrowserConfig
    /// Media config for SSRF guard LAN exemptions.
    private let mediaConfig: MediaConfig?
    /// Configured LLM server URLs for loopback exemptions.
    private var llmServerURLs: [String]
    /// Per-session allowed domains granted interactively during an active chat turn.
    private var sessionAllowedDomains: [UUID: SessionGrant] = [:]
    /// Ephemeral one-shot domains keyed by owning session (nil for grants
    /// filed without a session context).
    private var oneShotAllowedDomains: [UUID?: Set<String>] = [:]
    /// Issue time per one-shot key for TTL eviction, including the nil key.
    private var oneShotIssuedAt: [UUID?: Date] = [:]

    /// Permission gate consulted for covering domain allow rules and ephemeral grants.
    private var permissionGate: PermissionGate?

    /// One session's interactive grants with their issue time for TTL eviction.
    private struct SessionGrant: Sendable {
        var domains: Set<String>
        var issuedAt: Date
    }

    /// Maximum age of an interactive session grant before it expires.
    private static let sessionGrantTTL: TimeInterval = 24 * 60 * 60
    /// Maximum age of an unconsumed one-shot grant before it expires.
    private static let oneShotGrantTTL: TimeInterval = 24 * 60 * 60
    /// Maximum sessions tracked before the oldest grants evict. Fail-closed bound on the grant
    /// table so a process that never reports teardown still cannot grow this state without limit.
    private static let maxTrackedSessions = 1000

    /// Creates an outbound egress supervisor.
    public init(
        policyStore: PolicyStore,
        secrets: SecretsManager,
        browserConfig: BrowserConfig = BrowserConfig(),
        mediaConfig: MediaConfig? = nil,
        emailConfig _: EmailConfig? = nil,
        llmServerURLs: [String] = []
    ) {
        self.policyStore = policyStore
        self.secrets = secrets
        self.browserConfig = browserConfig
        self.mediaConfig = mediaConfig
        self.llmServerURLs = llmServerURLs
    }

    /// Builds the production supervisor from a policy store. The only permissible construction path
    /// outside tests.
    public static func make(
        policyStore: PolicyStore,
        secrets: SecretsManager? = nil,
        browserConfig: BrowserConfig = BrowserConfig(),
        mediaConfig: MediaConfig? = nil,
        emailConfig _: EmailConfig? = nil,
        llmServerURLs: [String] = []
    ) async throws -> OutboundEgressSupervisor {
        _ = try await policyStore.snapshot()
        return OutboundEgressSupervisor(
            policyStore: policyStore,
            secrets: secrets ?? SecretsManager(),
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            llmServerURLs: llmServerURLs
        )
    }

    /// Refreshes the configured LLM server URLs in place.
    public func updateLLMServerURLs(_ urls: [String]) {
        llmServerURLs = urls
    }

    /// Wires the permission gate whose covering domain allows authorize egress. Blocked hosts still
    /// deny first, so wiring never softens a refusal.
    public func setPermissionGate(_ gate: PermissionGate?) {
        permissionGate = gate
    }

    /// Grants egress permission to a domain for the duration of a session.
    public func allowDomainForSession(sessionID: UUID, domain: String) {
        evictStaleSessionGrants()
        let canonical = SensitiveAddressNormalization.normalizedHost(domain)
        let existing = sessionAllowedDomains[sessionID]
        sessionAllowedDomains[sessionID] = SessionGrant(
            domains: (existing?.domains ?? []).union([canonical]),
            issuedAt: Date()
        )
        enforceSessionGrantBound()
    }

    /// Grants one-time ephemeral egress permission scoped to one session.
    public func allowDomainOnce(domain: String, sessionID: UUID?) {
        evictStaleSessionGrants()
        let canonical = SensitiveAddressNormalization.normalizedHost(domain)
        oneShotAllowedDomains[sessionID, default: []].insert(canonical)
        oneShotIssuedAt[sessionID] = Date()
        enforceOneShotBound()
    }

    /// Clears any ephemeral domains granted for the given session. Grants also expire via TTL
    /// eviction and the tracked-session bound below, so the table cannot grow without bound when no
    /// explicit lifecycle signal arrives.
    public func clearSession(sessionID: UUID) {
        sessionAllowedDomains.removeValue(forKey: sessionID)
        oneShotAllowedDomains.removeValue(forKey: sessionID)
        oneShotIssuedAt.removeValue(forKey: sessionID)
    }

    /// Reports the interactive grants the given session can still spend.
    public func activeGrants(sessionID: UUID?) async -> EgressGrantSummary {
        let sessionDomains: [String] = if let sessionID {
            sessionAllowedDomains[sessionID]?.domains.sorted() ?? []
        } else {
            []
        }
        var oneShot = oneShotAllowedDomains[nil] ?? []
        if let sessionID {
            oneShot.formUnion(oneShotAllowedDomains[sessionID] ?? [])
        }
        return EgressGrantSummary(sessionDomains: sessionDomains, oneShotDomains: oneShot.sorted())
    }

    /// Snapshot of one session's spendable interactive grants. Read-only view over the supervisor's
    /// live grant tables for display or diagnostics; granting, spending, and clearing stay the only
    /// mutation paths.
    public struct EgressGrantSummary: Sendable, Equatable {
        /// Domains granted for the life of the reported session.
        public let sessionDomains: [String]
        /// Unspent one-shot domains spendable by the reported session,
        /// including any filed without a session.
        public let oneShotDomains: [String]

        public init(sessionDomains: [String], oneShotDomains: [String]) {
            self.sessionDomains = sessionDomains
            self.oneShotDomains = oneShotDomains
        }
    }

    /// Result of a successful egress verification. Contains wire-ready headers
    /// with secrets injected, plus the list of injected secrets for response sweeping.
    public struct EgressResult: Sendable {
        /// Headers with surrogates replaced by live secret values.
        public let resolvedHeaders: [String: String]
        /// Live secret values that were injected (for response sweeping).
        public let resolvedSecrets: [String]
        /// Vetted dial pin produced by the SSRF gate.
        public let dialPin: SSRFDialPin
    }

    /// Outcome of an egress validation check.
    public enum EgressVerdict: Sendable {
        /// The request passed all policy checks. Contains wire-ready headers.
        case allowed(EgressResult)
        /// The request was denied. Contains a human-readable reason.
        case denied(String)
        /// The host is unlisted in policy.toml (eligible for interactive triage prompt).
        case unlistedDomain(host: String, reason: String)
    }

    /// Validates an outbound request against the full security policy pipeline. Every hop first
    /// reads the verified policy snapshot, failing closed when no policy was ever accepted, before
    /// evaluating the gates below.
    public func validate(
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        sessionID: UUID? = nil,
        resolvesCredentials: Bool = true
    ) async -> EgressVerdict {
        let policy: SecurityPolicy
        do {
            policy = try await policyStore.snapshot()
        } catch {
            return .denied(error.localizedDescription)
        }
        guard let host = url.host, !host.isEmpty else {
            return .denied("Invalid URL: missing host component.")
        }
        let canonicalHost = SensitiveAddressNormalization.normalizedHost(host)
        if let verdict = await networkGateVerdict(policy: policy, host: host, canonicalHost: canonicalHost, sessionID: sessionID) {
            return verdict
        }
        let binding = bindingGateContext(policy: policy, headers: headers, url: url, method: method, host: host)
        if let verdict = binding.verdict {
            return verdict
        }
        let exemptions = ssrfExemptions(policy: policy)
        if let verdict = literalGateVerdict(
            urlString: url.absoluteString,
            origins: exemptions.origins,
            hasLLMOrigins: exemptions.hasLLMOrigins
        ) {
            return verdict
        }
        let pinResult = await vettedPin(
            urlString: url.absoluteString,
            origins: exemptions.origins,
            hasLLMOrigins: exemptions.hasLLMOrigins
        )
        let dialPin: SSRFDialPin
        switch pinResult {
        case let .dialable(pin):
            dialPin = pin
        case let .refused(reason):
            return .denied(reason)
        }
        if let verdict = await credentialPreflightVerdict(
            headers: headers,
            surrogateKeys: binding.surrogateKeys,
            resolvesCredentials: resolvesCredentials
        ) {
            return verdict
        }
        return await wireVerdict(headers: headers, dialPin: dialPin, resolvesCredentials: resolvesCredentials)
    }

    /// Validates a URL for credential-free read-only checks. Applies the network policy gate
    /// (including session and one-shot grants) plus the SSRF guard — no credential binding and no
    /// Keychain access.
    public func validateReadOnly(url: URL, sessionID: UUID? = nil) async -> String? {
        // Read-only checks fail closed on the same verified snapshot so an
        // unverified store never reports a destination as reachable.
        let policy: SecurityPolicy
        do {
            policy = try await policyStore.snapshot()
        } catch {
            return error.localizedDescription
        }

        guard let host = url.host, !host.isEmpty else {
            return "Invalid URL: missing host component."
        }
        let canonicalHost = SensitiveAddressNormalization.normalizedHost(host)

        // Network policy gate honors interactive grants like the full gate,
        // so Allow During Session and Allow Once cover read-only checks.
        switch policy.network.hostStatus(for: host) {
        case .allowed:
            break
        case let .explicitlyBlocked(reason):
            return reason
        case let .unlisted(reason):
            evictStaleSessionGrants()
            if consumeOneShot(host: canonicalHost, sessionID: sessionID) {
                break
            }
            if let sessionID, sessionAllowedDomains[sessionID]?.domains.contains(canonicalHost) == true {
                break
            }
            // A covering domain allow in the gate authorizes the read: durable
            // egress allows and task grants live there, so honoring them here
            // keeps a covered next call from re-parking at execution.
            if let gate = permissionGate,
               await gate.egressAllowCovers(host: canonicalHost, toolName: nil, sessionID: sessionID)
            {
                break
            }
            return reason
        }

        // SSRF guard over the same effective exemptions the full gate uses, so
        // read-only checks honor a live policy exemption identically.
        let ssrfOrigins = ApiSSRFGuard.allowlistedOrigins(
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            llmServerURLs: llmServerURLs
        ).union(policy.network.localExemptions)
        return await ApiSSRFGuard.denyReasonAsync(
            for: url.absoluteString,
            allowlistedOrigins: ssrfOrigins,
            hasLLMOrigins: !llmServerURLs.isEmpty
        )
    }

    /// Compares screened dials against caller-declared hosts.
    public nonisolated func checkHosts(_ screenedHosts: [String], against declaredHosts: [String]) -> [String] {
        let declared = Set(declaredHosts.map { SensitiveAddressNormalization.normalizedHost($0) }.filter { !$0.isEmpty })
        var seen = Set<String>()
        var undeclared: [String] = []
        for raw in screenedHosts {
            let canonical = SensitiveAddressNormalization.normalizedHost(raw)
            guard !canonical.isEmpty else { continue }
            guard !seen.contains(canonical) else { continue }
            seen.insert(canonical)
            if !declared.contains(canonical) {
                undeclared.append(raw)
            }
        }
        return undeclared
    }

    /// Sweeps resolved secret values from response content.
    public nonisolated func sweepResponse(_ content: String, secrets: [String]) -> String {
        self.secrets.redactResolved(content, secrets: secrets)
    }
}

// MARK: - Grant maintenance plus per-hop gates

extension OutboundEgressSupervisor {
    /// Extracts all surrogate key names from header values without resolving them.
    private func extractSurrogateKeys(from headers: [String: String]) -> Set<String> {
        var keys = Set<String>()
        for (_, value) in headers {
            let found = SecretsManager.surrogates(in: value)
            for key in found {
                keys.insert(key)
            }
        }
        return keys
    }

    /// Network policy gate for one hop, honoring interactive grants. Fail-closed callers treat any
    /// returned verdict as terminal and continue only on nil.
    private func networkGateVerdict(
        policy: SecurityPolicy,
        host: String,
        canonicalHost: String,
        sessionID: UUID?
    ) async -> EgressVerdict? {
        switch policy.network.hostStatus(for: host) {
        case let .explicitlyBlocked(reason):
            return .denied(reason)
        case .allowed:
            return nil
        case let .unlisted(reason):
            evictStaleSessionGrants()
            if consumeOneShot(host: canonicalHost, sessionID: sessionID) {
                return nil
            }
            if let sessionID, sessionAllowedDomains[sessionID]?.domains.contains(canonicalHost) == true {
                return nil
            }
            // A covering domain allow in the gate authorizes the hop: durable
            // egress allows and task grants live there, so honoring them here
            // keeps a covered next call from re-parking at execution.
            if let gate = permissionGate,
               await gate.egressAllowCovers(host: canonicalHost, toolName: nil, sessionID: sessionID)
            {
                return nil
            }
            return .unlistedDomain(host: host, reason: reason)
        }
    }

    /// Target-binding gate context for one hop.
    private func bindingGateContext(
        policy: SecurityPolicy,
        headers: [String: String],
        url: URL,
        method: String,
        host: String
    ) -> (surrogateKeys: Set<String>, verdict: EgressVerdict?) {
        let surrogateKeys = extractSurrogateKeys(from: headers)
        let path: String
        switch EffectiveRequestPath.resolve(for: url) {
        case let .effective(effectivePath):
            path = effectivePath
        case let .rejected(reason):
            return (surrogateKeys, .denied("Security Policy Violation: \(reason)"))
        }
        let upperedMethod = method.uppercased()
        for key in surrogateKeys {
            guard let binding = policy.credentials[key] else {
                return (
                    surrogateKeys,
                    .denied(
                        "Security Policy Violation: credential '\(key)' has no binding in policy.toml. "
                            + "Add a [credentials.\(key)] section with allowed_hosts to authorize this credential."
                    )
                )
            }
            if let bindingDeny = binding.denyReason(key: key, host: host, method: upperedMethod, path: path) {
                return (surrogateKeys, .denied("Security Policy Violation: \(bindingDeny)"))
            }
        }
        return (surrogateKeys, nil)
    }

    /// Effective SSRF exemptions for one hop.
    private func ssrfExemptions(policy: SecurityPolicy) -> (origins: Set<String>, hasLLMOrigins: Bool) {
        let origins = ApiSSRFGuard.allowlistedOrigins(
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            llmServerURLs: llmServerURLs
        ).union(policy.network.localExemptions)
        return (origins, !llmServerURLs.isEmpty)
    }

    /// Literal-only SSRF pre-check with no DNS and no Keychain read.
    private func literalGateVerdict(urlString: String, origins: Set<String>, hasLLMOrigins: Bool) -> EgressVerdict? {
        switch ApiSSRFGuard.preDNSOutcome(
            for: urlString,
            allowlistedOrigins: origins,
            hasLLMOrigins: hasLLMOrigins
        ) {
        case let .denied(reason):
            .denied(reason)
        case .allowed, .needsDNS:
            nil
        }
    }

    /// Live-only credential resolvability preflight after DNS vetting. Runs only after the SSRF
    /// gate produces its dial pin, so an SSRF-denied destination never pulls live Keychain secrets
    /// into memory.
    private func credentialPreflightVerdict(
        headers: [String: String],
        surrogateKeys: Set<String>,
        resolvesCredentials: Bool
    ) async -> EgressVerdict? {
        guard resolvesCredentials else { return nil }
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            if SecretsManager.surrogates(in: value).isEmpty,
               SecretsManager.containsSurrogatePrefix(value)
            {
                return .denied(
                    "header '\(name)' contains a malformed secret surrogate (expected rwsecret:<key>)"
                )
            }
        }
        for key in surrogateKeys.sorted() {
            do {
                let existing = try await secrets.retrieve(key: key)
                guard let existing, !existing.isEmpty else {
                    return .denied(secretsErrorMessage(.unknownSurrogate(key: key)))
                }
            } catch let error as SecretsError {
                return .denied(secretsErrorMessage(error))
            } catch {
                return .denied("Credential resolution failed: \(error.localizedDescription)")
            }
        }
        return nil
    }

    /// Full DNS vetting producing the dial pin for one hop.
    private func vettedPin(
        urlString: String,
        origins: Set<String>,
        hasLLMOrigins: Bool
    ) async -> ApiSSRFVetting {
        await ApiSSRFGuard.vetAsync(
            for: urlString,
            allowlistedOrigins: origins,
            hasLLMOrigins: hasLLMOrigins
        )
    }

    /// Final wire-injection verdict for one hop.
    private func wireVerdict(
        headers: [String: String],
        dialPin: SSRFDialPin,
        resolvesCredentials: Bool
    ) async -> EgressVerdict {
        guard resolvesCredentials else {
            return .allowed(EgressResult(resolvedHeaders: headers, resolvedSecrets: [], dialPin: dialPin))
        }
        do {
            let result = try await resolveSurrogateHeaders(headers, dialPin: dialPin)
            return .allowed(result)
        } catch let error as SecretsError {
            return .denied(secretsErrorMessage(error))
        } catch {
            return .denied("Credential resolution failed: \(error.localizedDescription)")
        }
    }

    /// Resolves surrogate references in validated header values.
    private func resolveSurrogateHeaders(_ headers: [String: String], dialPin: SSRFDialPin) async throws -> EgressResult {
        var resolved: [String: String] = [:]
        resolved.reserveCapacity(headers.count)
        var collectedSecrets: [String] = []

        for (name, value) in headers {
            guard SecretsManager.containsSurrogate(value) else {
                if SecretsManager.containsSurrogatePrefix(value) {
                    throw SecretsError.invalidInput(
                        reason: "header '\(name)' contains a malformed secret surrogate (expected rwsecret:<key>)"
                    )
                }
                resolved[name] = value
                continue
            }
            let outcome = try await secrets.resolveValueContainingSurrogates(value)
            resolved[name] = outcome.resolved
            collectedSecrets.append(contentsOf: outcome.secrets)
        }

        return EgressResult(resolvedHeaders: resolved, resolvedSecrets: collectedSecrets, dialPin: dialPin)
    }

    /// Converts a SecretsError to a human-readable message.
    private func secretsErrorMessage(_ error: SecretsError) -> String {
        switch error {
        case let .unknownSurrogate(key):
            "Unknown secret surrogate 'rwsecret:\(key)': no stored secret for key '\(key)'."
        case let .invalidInput(reason):
            reason
        case let .keychainError(status):
            "Credential resolution failed (keychain status \(status))."
        case .encodingError:
            "Credential resolution failed (encoding error)."
        }
    }
}

// MARK: - Grant maintenance

extension OutboundEgressSupervisor {
    /// Drops session grants older than the grant TTL.
    private func evictStaleSessionGrants(now: Date = Date()) {
        let expired = sessionAllowedDomains.compactMap { id, grant in
            now.timeIntervalSince(grant.issuedAt) < Self.sessionGrantTTL ? nil : id
        }
        for id in expired {
            clearSession(sessionID: id)
        }
        evictStaleOneShotGrants(now: now)
    }

    /// Drops one-shot grants older than the one-shot TTL, including the nil key.
    private func evictStaleOneShotGrants(now: Date = Date()) {
        let expired = oneShotIssuedAt.compactMap { id, issuedAt in
            now.timeIntervalSince(issuedAt) < Self.oneShotGrantTTL ? nil : id
        }
        for id in expired {
            oneShotAllowedDomains.removeValue(forKey: id)
            oneShotIssuedAt.removeValue(forKey: id)
        }
        for id in Array(oneShotAllowedDomains.keys) where oneShotAllowedDomains[id]?.isEmpty == true {
            oneShotAllowedDomains.removeValue(forKey: id)
            oneShotIssuedAt.removeValue(forKey: id)
        }
    }

    /// Evicts the oldest session grants when the table exceeds its bound.
    private func enforceSessionGrantBound() {
        guard sessionAllowedDomains.count > Self.maxTrackedSessions else { return }
        let ordered = sessionAllowedDomains.sorted { $0.value.issuedAt < $1.value.issuedAt }
        for (id, _) in ordered.prefix(sessionAllowedDomains.count - Self.maxTrackedSessions) {
            clearSession(sessionID: id)
        }
    }

    /// Evicts the oldest one-shot keys when the table exceeds its bound.
    private func enforceOneShotBound() {
        guard oneShotAllowedDomains.count > Self.maxTrackedSessions else { return }
        let ordered = oneShotIssuedAt.sorted { $0.value < $1.value }
        for (id, _) in ordered.prefix(oneShotAllowedDomains.count - Self.maxTrackedSessions) {
            oneShotAllowedDomains.removeValue(forKey: id)
            oneShotIssuedAt.removeValue(forKey: id)
        }
    }

    /// Whether a one-shot grant covers this host for this session, consuming it.
    private func consumeOneShot(host: String, sessionID: UUID?) -> Bool {
        if let sessionID, var scoped = oneShotAllowedDomains[sessionID], scoped.contains(host) {
            scoped.remove(host)
            if scoped.isEmpty {
                oneShotAllowedDomains.removeValue(forKey: sessionID)
                oneShotIssuedAt.removeValue(forKey: sessionID)
            } else {
                oneShotAllowedDomains[sessionID] = scoped
            }
            return true
        }
        if var open = oneShotAllowedDomains[nil], open.contains(host) {
            open.remove(host)
            if open.isEmpty {
                oneShotAllowedDomains.removeValue(forKey: nil)
                oneShotIssuedAt.removeValue(forKey: nil)
            } else {
                oneShotAllowedDomains[nil] = open
            }
            return true
        }
        return false
    }
}

// MARK: - EgressPolicyEvaluator Conformance

extension OutboundEgressSupervisor: EgressPolicyEvaluator {
    /// Checks whether a one-shot grant exists for this host and session without consuming it.
    private func isOneShotAllowed(host: String, sessionID: UUID?) -> Bool {
        if let sessionID, let scoped = oneShotAllowedDomains[sessionID], scoped.contains(host) {
            return true
        }
        if let open = oneShotAllowedDomains[nil], open.contains(host) {
            return true
        }
        return false
    }

    /// Evaluates host status against policy.toml, one-shot grants, and session allowlists
    /// without consuming one-shot grants or requiring full HTTP URLs.
    public func evaluateHostStatus(for host: String, sessionID: UUID?) async -> HostStatus {
        let policy: SecurityPolicy
        do {
            policy = try await policyStore.snapshot()
        } catch {
            return .explicitlyBlocked(error.localizedDescription)
        }
        let canonicalHost = SensitiveAddressNormalization.normalizedHost(host)
        switch policy.network.hostStatus(for: host) {
        case let .explicitlyBlocked(reason):
            return .explicitlyBlocked(reason)
        case .allowed:
            return .allowed
        case let .unlisted(reason):
            evictStaleSessionGrants()
            if isOneShotAllowed(host: canonicalHost, sessionID: sessionID) {
                return .allowed
            }
            if let sessionID, sessionAllowedDomains[sessionID]?.domains.contains(canonicalHost) == true {
                return .allowed
            }
            // A covering domain allow in the gate authorizes the host: durable
            // egress allows and task grants live there, so honoring them here
            // keeps the next identical call from re-parking at the gate.
            if let gate = permissionGate,
               await gate.egressAllowCovers(host: canonicalHost, toolName: nil, sessionID: sessionID)
            {
                return .allowed
            }
            return .unlisted(reason)
        }
    }
}
