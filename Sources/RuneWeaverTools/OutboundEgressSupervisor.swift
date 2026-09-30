// Rune Weaver Tools — Outbound Egress Supervisor.
//
// Mandatory egress choke-point for `api.request`: `ApiRequestTool` is the only
// downstream consumer, built with a live supervisor so every dial — the initial
// URL and each redirect hop — passes `validate` before the transport runs. Hop
// re-validation runs over the surrogate-form headers, so the network policy and
// credential-binding gates are re-evaluated before any just-in-time injection;
// the tool drops injected credential headers whenever the origin (scheme +
// host + port) changes. Under the credential surrogation contract, surrogates
// resolve at this boundary and are never model-visible, while `sweepResponse`
// redacts any injected credential echoed back in tool output before it enters
// the model context.
//
// `validate` runs the security gates in this order:
//   1. Network Policy Gate — verify domain is allowed under NetworkEgressPolicy.
//   2. Target-Binding Check — verify surrogates are authorized for the
//      destination's effective route path.
//   3. SSRF Guard — prevent metadata, link-local, and RFC 1918 dials; an
//      allowed verdict returns the vetted numeric addresses as a dial pin.
//   4. Just-In-Time Wire Injection — swap surrogates for live Keychain secrets.
//
// Network and binding checks run before the SSRF guard resolves any hostname,
// so a denied destination causes no DNS query, no socket, and no Keychain read:
// the raw secret never enters memory. The pin returned by step 3 is what the
// transport dials, so the hostname is never resolved again after vetting and a
// rebinding answer cannot steer the connection. Production builds the
// supervisor through `make(policyStore:)`, which refuses to construct from a
// store without a verified policy; tests may still use `init` directly.

import Foundation
import RuneWeaverCore

/// Unified outbound egress supervisor enforcing the security policy pipeline.
///
/// `ApiRequestTool` is the only consumer: its outbound traffic routes through
/// this supervisor, which layers the security policy's domain allowlist, the
/// SSRF guard, and credential target-binding verification into a single,
/// auditable choke-point.
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

    /// Creates an outbound egress supervisor.
    public init(
        policyStore: PolicyStore,
        secrets: SecretsManager,
        browserConfig: BrowserConfig = BrowserConfig(),
        mediaConfig: MediaConfig? = nil,
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
    ///   - llmServerURLs: Configured LLM `server_url` values exempted from the SSRF loopback deny.
    /// - Returns: A supervisor bound to the verified policy.
    /// - Throws: `PolicyInvariantError` when the store holds no verified policy.
    public static func make(
        policyStore: PolicyStore,
        secrets: SecretsManager? = nil,
        browserConfig: BrowserConfig = BrowserConfig(),
        mediaConfig: MediaConfig? = nil,
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
    ///    and returns the proven numeric addresses as a dial pin.
    /// 4. **Wire Injection**: Swaps surrogates for live Keychain secrets.
    ///
    /// If any step fails, the method returns a `.denied` with a human-readable reason.
    /// On binding failure, the Keychain is **never accessed**. Network and binding
    /// checks run before the SSRF guard resolves any hostname, so a denied
    /// destination causes no DNS query, no socket, and no Keychain read. An allowed
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
    ///   - resolvesCredentials: When false, the pipeline stops after the SSRF gate
    ///     and returns the headers unchanged with no injected secrets. Dry-run
    ///     previews use this so an approval card reflects the policy and binding
    ///     posture without ever touching the Keychain.
    /// - Returns: `.allowed` with resolved headers and secrets, or `.denied` with reason.
    public func validate(
        url: URL,
        method: String,
        headers: [String: String],
        resolvesCredentials: Bool = true
    ) async -> EgressVerdict {
        // Every hop reads the verified snapshot rather than the displayable
        // fallback, so a store that never accepted a policy fails closed here
        // instead of authorizing from a posture that was never verified.
        let policy: SecurityPolicy
        do {
            policy = try await policyStore.snapshot()
        } catch {
            return .denied(error.localizedDescription)
        }

        // --- Step 1: Network Policy Gate ---
        guard let host = url.host, !host.isEmpty else {
            return .denied("Invalid URL: missing host component.")
        }
        if let denyReason = policy.network.denyReason(for: host) {
            return .denied(denyReason)
        }

        // --- Step 2: Target-Binding Gate ---
        // Extract all surrogate keys from headers and verify each one is authorized
        // for this destination BEFORE touching the Keychain or querying DNS.
        let surrogateKeys = extractSurrogateKeys(from: headers)
        // Bindings authorize a path prefix, so the comparison must run against
        // the effective path the origin server routes to: the shared resolver
        // percent-decodes the raw path, removes dot segments per RFC 3986, and
        // refuses encoded separators or encoded dot segments whose destination
        // depends on how a proxy decodes them. An ambiguous destination refuses
        // outright — credentials or not — because the routed resource itself is
        // undecidable, and redirect hops re-enter this same gate, so a Location
        // header cannot walk a bound credential off its authorized prefix.
        let path: String
        switch EffectiveRequestPath.resolve(for: url) {
        case let .effective(effectivePath):
            path = effectivePath
        case let .rejected(reason):
            return .denied("Security Policy Violation: \(reason)")
        }
        let upperedMethod = method.uppercased()

        for key in surrogateKeys {
            guard let binding = policy.credentials[key] else {
                return .denied(
                    "Security Policy Violation: credential '\(key)' has no binding in policy.toml. "
                        + "Add a [credentials.\(key)] section with allowed_hosts to authorize this credential."
                )
            }
            if let bindingDeny = binding.denyReason(key: key, host: host, method: upperedMethod, path: path) {
                return .denied("Security Policy Violation: \(bindingDeny)")
            }
        }

        // --- Step 3: SSRF Guard (delegates to existing ApiSSRFGuard) ---
        // The SSRF guard checks independently of the policy allowlist because it
        // protects against IP-level attacks (metadata endpoints, link-local, etc.)
        // that domain names might resolve to. The same pass returns the dial pin:
        // the numeric addresses it proved, so the caller dials the proof instead
        // of re-resolving the hostname after this check (DNS rebinding).
        let dialPin: SSRFDialPin
        switch await ApiSSRFGuard.vetAsync(
            for: url.absoluteString,
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            llmServerURLs: llmServerURLs
        ) {
        case let .refused(ssrfReason):
            return .denied(ssrfReason)
        case let .dialable(pin):
            dialPin = pin
        }

        // --- Step 4: Wire Injection ---
        // A credential-free verdict keeps dry-run previews clear of live secret bytes.
        guard resolvesCredentials else {
            return .allowed(EgressResult(resolvedHeaders: headers, resolvedSecrets: [], dialPin: dialPin))
        }
        // All binding checks passed. Now resolve surrogates to live secrets.
        do {
            let result = try await resolveSurrogateHeaders(headers, dialPin: dialPin)
            return .allowed(result)
        } catch let error as SecretsError {
            return .denied(secretsErrorMessage(error))
        } catch {
            return .denied("Credential resolution failed: \(error.localizedDescription)")
        }
    }

    /// Validates a URL for credential-free read-only checks.
    ///
    /// Applies only the network policy gate and the SSRF guard — no credential
    /// binding and no Keychain access.
    ///
    /// - Parameter url: The target URL to validate.
    /// - Returns: `nil` when allowed, or a human-readable refusal reason.
    public func validateReadOnly(url: URL) async -> String? {
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

        // Network policy gate
        if let denyReason = policy.network.denyReason(for: host) {
            return denyReason
        }

        // SSRF guard
        return await ApiSSRFGuard.denyReasonAsync(
            for: url.absoluteString,
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            llmServerURLs: llmServerURLs
        )
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

    // MARK: - Private Helpers

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
