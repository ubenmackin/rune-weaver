// Rune Weaver Tools — Outbound Egress Supervisor.
//
// Multi-consumer mandatory egress choke-point: `api.request` plus `web.fetch`
// (`WebFetchTool.validateHopSafety`), `browser.navigate`/`browser.act` (via
// `BrowserValidation.EgressPolicy.validateURLAsync`), `bash.exec`
// (`BashTool.screenExplicitURLs`), and `desktop.action`
// (`DesktopControlBridge.screenBatchURLs`) all enter through `validate`
// before any dial, DNS, or Keychain side effect. Hop re-validation runs over
// the surrogate-form headers, so the network policy and credential-binding
// gates are re-evaluated before any just-in-time injection; the tool drops
// injected credential headers whenever the origin (scheme + host + port)
// changes. Under the credential surrogation contract, surrogates resolve at
// this boundary and are never model-visible, while `sweepResponse` redacts
// any injected credential echoed back in tool output before it enters the
// model context. Each consumer threads its calling session (`ToolContext`
// session) into `validate`, so session and one-shot grants stay scoped to
// the chat that approved them.
//
// `validate` runs the security gates in this order:
//   1. Network Policy Gate — verify domain is allowed under NetworkEgressPolicy.
//   2. Target-Binding Check — verify surrogates are authorized for the
//      destination's effective route path.
//   3. SSRF Guard — prevent metadata, link-local, and RFC 1918 dials; an
//      allowed verdict returns the vetted numeric addresses as a dial pin.
//      Exemptions are the config origins unioned with the policy's
//      `local_exemptions`, read fresh on every call. The literal stage runs
//      with no DNS and no Keychain read so obfuscated literals still refuse
//      without touching secrets; the full DNS vetting that produces the pin
//      runs next within this gate, so a literal-plus-DNS-denied destination
//      causes no secret read.
//   4. Credential Preflight plus Just-In-Time Wire Injection — a live-only
//      resolvability preflight surfaces unknown or malformed surrogates with
//      deterministic ordering after SSRF vetting, then swaps surrogates for
//      live Keychain secrets.
//
// Network, binding, and SSRF checks run before any Keychain access, and
// policy-denied plus SSRF-denied destinations cause no Keychain read
// either: the raw secret never enters memory for a destination the earlier
// gates already refused. Only a destination that clears SSRF vetting
// reaches the resolvability preflight, so an SSRF denial wins over a
// missing-key error by design. The
// pin returned by step 3 is what the
// transport dials, so the hostname is never resolved again after vetting and a
// rebinding answer cannot steer the connection. Production builds the
// supervisor through `make(policyStore:)`, which refuses to construct from a
// store without a verified policy; tests may still use `init` directly.

import Foundation
import RuneWeaverCore

/// Unified outbound egress supervisor enforcing the security policy pipeline.
///
/// Multi-consumer choke-point for outbound traffic: `api.request`,
/// `web.fetch`, `browser.navigate`/`browser.act`, `bash.exec`, and
/// `desktop.action` all route through this supervisor, which layers the
/// security policy's domain allowlist, the SSRF guard, and credential
/// target-binding verification into a single, auditable gate with per-tool
/// session threading.
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
    private let llmServerURLs: [String]
    /// Per-session allowed domains granted interactively during an active chat turn.
    private var sessionAllowedDomains: [UUID: SessionGrant] = [:]
    /// Ephemeral one-shot domains keyed by owning session (nil for grants
    /// filed without a session context).
    private var oneShotAllowedDomains: [UUID?: Set<String>] = [:]
    /// Issue time per one-shot key for TTL eviction, including the nil key.
    ///
    /// Tracked separately because a one-shot grant without a session grant
    /// never appears in `sessionAllowedDomains`, so session-only eviction
    /// would leave it spendable without bound.
    private var oneShotIssuedAt: [UUID?: Date] = [:]

    /// One session's interactive grants with their issue time for TTL eviction.
    private struct SessionGrant: Sendable {
        var domains: Set<String>
        var issuedAt: Date
    }

    /// Maximum age of an interactive session grant before it expires.
    ///
    /// Bounds the grant table when no explicit teardown arrives: chat turns
    /// are minutes-scale, so a day-old grant is stale session residue rather
    /// than live intent.
    private static let sessionGrantTTL: TimeInterval = 24 * 60 * 60
    /// Maximum age of an unconsumed one-shot grant before it expires.
    ///
    /// One-shot grants are single-use, but an unspent grant (a denied turn,
    /// a client that never retries) must still age out: without its own TTL
    /// the nil key and sessions without a session grant would linger
    /// spendable past the session window.
    private static let oneShotGrantTTL: TimeInterval = 24 * 60 * 60
    /// Maximum sessions tracked before the oldest grants evict.
    ///
    /// Fail-closed bound on the grant table so a process that never reports
    /// teardown still cannot grow this state without limit.
    private static let maxTrackedSessions = 1000

    /// Creates an outbound egress supervisor.
    ///
    /// The email config stays accepted for call-site compatibility but no
    /// longer feeds an exemption: every destination needs an explicit
    /// allowlist entry or an interactive grant.
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

    /// Builds the production supervisor from a policy store.
    ///
    /// The only permissible construction path outside tests. It reads the
    /// store's verified snapshot before returning, so a process whose
    /// `policy.toml` was missing is supervised by the seeded deny-by-default
    /// posture while an unreadable, unparseable, or invariant-violating file
    /// makes boot throw instead of running supervisor-less. The hop is async
    /// because the store owns its state behind actor isolation — there is no
    /// synchronous read path by design.
    /// - Parameters:
    ///   - policyStore: The one policy store instance for this process.
    ///   - secrets: Shared secrets resolver; a fresh manager when nil.
    ///   - browserConfig: `[browser]` policy feeding the SSRF loopback exemption.
    ///   - mediaConfig: Optional media policy feeding the SSRF LAN exemption.
    ///   - emailConfig: Accepted for compatibility; carries no exemption.
    ///   - llmServerURLs: Configured LLM `server_url` values exempted from the SSRF loopback deny.
    /// - Returns: A supervisor bound to the verified policy.
    /// - Throws: `PolicyInvariantError` when the store holds no verified policy.
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
    ///
    /// Triage handlers prefer this over any session-less grant whenever the
    /// pending request carries a session: the grant is consumable only under
    /// that session, so one chat cannot spend another's approval. Every
    /// one-shot grant flows through this entry point so session scoping
    /// cannot be bypassed by choosing a different overload.
    public func allowDomainOnce(domain: String, sessionID: UUID?) {
        evictStaleSessionGrants()
        let canonical = SensitiveAddressNormalization.normalizedHost(domain)
        oneShotAllowedDomains[sessionID, default: []].insert(canonical)
        oneShotIssuedAt[sessionID] = Date()
        enforceOneShotBound()
    }

    /// Clears any ephemeral domains granted for the given session.
    ///
    /// Session owners call this on teardown (chat close, session delete) so
    /// grants die with the conversation that approved them. Grants also
    /// expire via TTL eviction and the tracked-session bound below, so the
    /// table cannot grow without bound when no explicit lifecycle signal
    /// arrives.
    public func clearSession(sessionID: UUID) {
        sessionAllowedDomains.removeValue(forKey: sessionID)
        oneShotAllowedDomains.removeValue(forKey: sessionID)
        oneShotIssuedAt.removeValue(forKey: sessionID)
    }

    /// Result of a successful egress verification. Contains wire-ready headers
    /// with secrets injected, plus the list of injected secrets for response sweeping.
    public struct EgressResult: Sendable {
        /// Headers with surrogates replaced by live secret values.
        public let resolvedHeaders: [String: String]
        /// Live secret values that were injected (for response sweeping).
        public let resolvedSecrets: [String]
        /// Vetted dial pin produced by the SSRF gate.
        ///
        /// The caller must dial exactly these addresses with the pin's host
        /// identity and must not resolve the hostname again: the pin is what
        /// closes the rebinding window between the gate and the connection.
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

    /// Validates an outbound request against the full security policy pipeline.
    ///
    /// Every hop first reads the verified policy snapshot, failing closed when
    /// no policy was ever accepted, before evaluating the gates below.
    ///
    /// Evaluation order:
    /// 1. **Network Policy Gate**: Checks the domain against the allowlist/blocklist.
    /// 2. **Target-Binding Gate**: Verifies all surrogates in headers are authorized for
    ///    this destination host, HTTP method, and effective route path — dot segments
    ///    resolved per RFC 3986, encoded separators and encoded dot segments refused.
    /// 3. **SSRF Guard**: Blocks metadata IPs, link-local, RFC 1918 (via ApiSSRFGuard)
    ///    and returns the proven numeric addresses as a dial pin. Exemptions are
    ///    the config-derived origins unioned with the snapshot's `local_exemptions`.
    ///    The pure literal stage runs first with no DNS and no Keychain read;
    ///    the DNS vetting that produces the pin runs next within this gate,
    ///    so a literal-plus-DNS-denied destination causes no secret read.
    /// 4. **Credential Preflight plus Wire Injection**: A live-only
    ///    resolvability preflight surfaces unknown or malformed surrogates
    ///    with deterministic ordering after SSRF vetting, then wire
    ///    injection swaps surrogates for live Keychain secrets.
    ///
    /// If any step fails, the method returns a `.denied` with a human-readable reason.
    /// On policy, binding, or SSRF failure, the Keychain is **never accessed**.
    /// Network, binding, and SSRF checks run before any Keychain read, so
    /// those denied destinations cause no secret read. Only a destination
    /// clearing SSRF vetting reaches the live resolvability preflight, so
    /// an SSRF denial wins over a missing-key error by design while a
    /// vetted destination still reports a missing key deterministically. An allowed
    /// verdict carries the SSRF gate's pin, and callers must dial those addresses
    /// with the pin's host identity rather than resolving the hostname again.
    ///
    /// Redirect-following callers must re-invoke this gate for every hop with
    /// the surrogate-form headers rather than the injected wire headers: the
    /// tool drops credential-bearing headers whenever the origin (scheme +
    /// host + port) changes before re-validating, so a hop can never reach a
    /// host outside the policy or reuse a credential bound to another origin.
    /// The path-prefix comparison resolves each hop's effective route path
    /// through the same shared helper as the initial URL, so a `Location`
    /// spelling a traversal (`/v1/%2e%2e/admin`) refuses identically.
    ///
    /// - Parameters:
    ///   - url: The target URL to validate.
    ///   - method: HTTP method (GET, POST, etc.).
    ///   - headers: Headers possibly containing `rwsecret:<key>` surrogates.
    ///   - sessionID: Optional active chat session ID for session-scoped allowances.
    ///   - resolvesCredentials: When false, the pipeline stops after the SSRF gate
    ///     and returns the headers unchanged with no injected secrets. Dry-run
    ///     previews use this so an approval card reflects the policy and binding
    ///     posture without ever touching the Keychain.
    /// - Returns: `.allowed` with resolved headers and secrets, or `.denied` / `.unlistedDomain` with reason.
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
        if let verdict = networkGateVerdict(policy: policy, host: host, canonicalHost: canonicalHost, sessionID: sessionID) {
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

    /// Validates a URL for credential-free read-only checks.
    ///
    /// Applies the network policy gate (including session and one-shot
    /// grants) plus the SSRF guard — no credential binding and no Keychain
    /// access. A read-only allow consumes a covering one-shot grant like the
    /// full gate, so callers must validate once per tool call rather than
    /// pre-checking before the real gate.
    ///
    /// - Parameters:
    ///   - url: The target URL to validate.
    ///   - sessionID: Optional active chat session ID for session-scoped allowances.
    /// - Returns: `nil` when allowed, or a human-readable refusal reason.
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
    ///
    /// The second opinion behind `bash.exec` `network_hosts` and desktop
    /// URL-typing: the tool extracts every host its command or typed text
    /// would dial, and this pure check reports which of those lack a
    /// declaration. Callers deny on any non-empty result before consulting
    /// `validate`, so an undeclared dial fails even when the policy would
    /// allow it. Both sides canonicalize through the shared host normalizer,
    /// so `Example.COM` covers `example.com` while distinct hosts never
    /// alias; an empty declaration means every screened host is undeclared.
    /// - Parameters:
    ///   - screenedHosts: Hosts extracted from the command or typed text.
    ///   - declaredHosts: Caller-declared `network_hosts` for this turn.
    /// - Returns: Screened hosts with no declaration, in first-seen order.
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
    ///
    /// `ApiRequestTool` calls this on every encoded envelope at its output
    /// boundary, so the choke-point that injected a live credential is also
    /// the one that removes any echoed copy before the content enters the
    /// model context. Declared `nonisolated` so the tool can sweep at that
    /// boundary without an actor hop.
    /// - Parameters:
    ///   - content: Response content possibly echoing secrets.
    ///   - secrets: Live values that were injected at the wire boundary.
    /// - Returns: Content with secret values replaced by `[redacted]`.
    public nonisolated func sweepResponse(_ content: String, secrets: [String]) -> String {
        self.secrets.redactResolved(content, secrets: secrets)
    }
}

// MARK: - Grant maintenance plus per-hop gates

extension OutboundEgressSupervisor {
    /// Extracts all surrogate key names from header values without resolving them.
    ///
    /// This runs before any Keychain access so a binding violation is caught
    /// while the secret is still safely locked away.
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

    /// Network policy gate for one hop, honoring interactive grants.
    ///
    /// Unlisted hosts park for triage even when infrastructure origins would
    /// otherwise suggest an auto-allow; a covering one-shot grant is consumed
    /// once, otherwise a session grant covers the hop. Fail-closed callers
    /// treat any returned verdict as terminal and continue only on nil.
    private func networkGateVerdict(
        policy: SecurityPolicy,
        host: String,
        canonicalHost: String,
        sessionID: UUID?
    ) -> EgressVerdict? {
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
            return .unlistedDomain(host: host, reason: reason)
        }
    }

    /// Target-binding gate context for one hop.
    ///
    /// Bindings authorize a path prefix, so the comparison runs against the
    /// effective path the origin server routes to: the shared resolver
    /// percent-decodes the raw path, removes dot segments per RFC 3986, and
    /// refuses encoded separators or encoded dot segments whose destination
    /// depends on proxy decoding. An ambiguous destination refuses outright
    /// because the routed resource itself is undecidable, and redirect hops
    /// re-enter the same gate so a Location header cannot walk a bound
    /// credential off its authorized prefix. Runs before any Keychain read or
    /// DNS query so a binding violation never causes a side effect.
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
    ///
    /// Unions the config-derived auto origins with the owner-declared local
    /// exemptions from this hop's snapshot, so a policy write applies live
    /// with no restart while never-exempt targets stay refused inside the
    /// guard. Computed once so the literal pre-check and the full DNS vetting
    /// observe identical exemptions.
    private func ssrfExemptions(policy: SecurityPolicy) -> (origins: Set<String>, hasLLMOrigins: Bool) {
        let origins = ApiSSRFGuard.allowlistedOrigins(
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            llmServerURLs: llmServerURLs
        ).union(policy.network.localExemptions)
        return (origins, !llmServerURLs.isEmpty)
    }

    /// Literal-only SSRF pre-check with no DNS and no Keychain read.
    ///
    /// Reuses the guard's single-source literal stage so the refusal shape
    /// cannot drift from the full vetting that follows; only hostnames
    /// needing proof continue to DNS vetting, then to the credential
    /// preflight once a dial pin exists.
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

    /// Live-only credential resolvability preflight after DNS vetting.
    ///
    /// Runs only after the SSRF gate produces its dial pin, so an
    /// SSRF-denied destination never pulls live Keychain secrets into
    /// memory. Surfaces an unknown or malformed surrogate with its typed
    /// name for vetted destinations. Dry runs skip entirely
    /// and never touch the Keychain, preserving the preview contract, while
    /// credential-free calls fall through with no read. A passing preflight
    /// still re-resolves at injection time, so a rotation between the two
    /// reads observes the fresher value while a deletion still fails closed.
    /// Sorted traversal keeps concurrent failures deterministic instead of
    /// following dictionary order.
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
    ///
    /// Returns the proven numeric addresses the transport must dial with the
    /// original host identity; the hostname is never resolved again after
    /// vetting so a rebinding answer cannot steer the connection.
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
    ///
    /// A credential-free verdict keeps dry-run previews clear of live secret
    /// bytes; otherwise surrogates resolve to live Keychain values at the
    /// transport boundary so earlier stages only ever see the reference.
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
    ///
    /// Each value may hold a bare reference or an embedded one; resolution
    /// happens here at the transport boundary so earlier stages (validation,
    /// dry-run previews, approval targets) only ever see the reference. The
    /// SSRF gate's dial pin rides along so the caller receives the verdict,
    /// the wire headers, and the addresses to dial as one result.
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
    ///
    /// Expired sessions clear through `clearSession` so session and one-shot
    /// grants for the same conversation evict together instead of leaving a
    /// stale one-shot spendable after its session grant aged out.
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
            return .unlisted(reason)
        }
    }
}
