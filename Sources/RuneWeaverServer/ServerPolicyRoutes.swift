// Rune Weaver Server — Security Policy routes and structured validation gates.

import Foundation
import RuneWeaverCore
import RuneWeaverTools
import Vapor

// MARK: - Security Policy Helpers

/// One unresolved local-access entry that blocks a policy write.
private struct LocalAccessUnresolved: Sendable {
    let host: String
    let reason: String
}

/// Proposed grants plus reports for one re-check classification pass.
private struct RecheckClassification: Sendable {
    var proposed: Set<String>
    var neverDialable: [String]
    var unresolved: [LocalAccessUnresolved]
}

/// Maps a store invariant failure to the editor-facing 400.
private func policyInvariantAbort(_ invariant: PolicyInvariantError) -> Abort {
    switch invariant {
    case let .serializationFailed(reason):
        Abort(.badRequest, reason: "\(reason) Gate: serialization, field: policy.")
    case let .invariantViolations(violations):
        Abort(.badRequest, reason: "Security policy violates formal invariants: " + violations.joined(separator: "; ") + ". Gate: invariants, field: policy.")
    case let .notVerified(reason):
        Abort(.badRequest, reason: "\(reason). Gate: invariants, field: policy.")
    }
}

/// Canonicalizes a domain set exactly as the matcher evaluates it.
private func canonicalDomainSet(_ domains: Set<String>) -> Set<String> {
    Set(domains.map { NetworkEgressPolicy.canonicalEntry($0) })
}

/// Decodes a policy-route body, mapping wire failures to the shared 400 shape.
private func decodePolicyBody<T: Content>(_: T.Type, from req: Request, label: String) throws -> T {
    do {
        return try req.content.decode(T.self)
    } catch let abort as Abort {
        throw abort
    } catch {
        throw Abort(.badRequest, reason: "Invalid \(label) request: \(error). Gate: request, field: policy.")
    }
}

private func isWildcardOrUniversalPattern(_ host: String) -> Bool {
    let lowered = host.lowercased()
    return AllowedOriginPattern.classifyWildcard(lowered) != .none || AllowedOriginPattern.isBareUniversal(lowered)
}

private func persistPolicyCandidate(_ candidate: SecurityPolicy, store: PolicyStore, expectedGeneration: UInt64? = nil) async throws {
    do {
        try await store.replace(candidate, expectedGeneration: expectedGeneration)
    } catch let invariant as PolicyInvariantError {
        throw policyInvariantAbort(invariant)
    }
}

// MARK: - Security Policy Routes

func registerSettingsPolicyRoutes(_ settings: RoutesBuilder) {
    let policyGroup = settings.grouped(PathComponent.constant(ServerPaths.policy))
    policyGroup.get { req async throws -> PolicyResponse in try await handleGetPolicy(req: req) }
    policyGroup.put { req async throws -> PolicyResponse in try await handlePutPolicy(req: req) }
    policyGroup.post(PathComponent.constant(ServerPaths.verify)) { req async throws -> VerifyPolicyResponse in try await handleVerifyPolicy(req: req) }
    policyGroup.post(PathComponent.constant(ServerPaths.recheckLocal)) { req async throws -> RecheckLocalExemptionsResponse in
        try await handleRecheckPreview(req: req)
    }
    policyGroup.post(
        PathComponent.constant(String(ServerPaths.recheckLocalApply.split(separator: "/").first ?? "recheck-local")),
        PathComponent.constant(String(ServerPaths.recheckLocalApply.split(separator: "/").last ?? "apply"))
    ) { req async throws -> PolicyResponse in try await handleRecheckApply(req: req) }
}

private func handleGetPolicy(req: Request) async throws -> PolicyResponse {
    let snapshot = await req.application.runeWeaver.policyStore.readSnapshot()
    let dto = makePolicyDTO(from: snapshot.policy)
    return PolicyResponse(policy: dto, path: snapshot.fileURL.path, loadedFromDisk: snapshot.loadedFromDisk, violations: snapshot.violations)
}

private func classifyPutAddedHosts(_ added: Set<String>) async -> RecheckClassification {
    var proposed: Set<String> = []
    var neverDialable: [String] = []
    var unresolved: [LocalAccessUnresolved] = []
    for host in added.sorted() {
        guard AllowedOriginPattern.classifyWildcard(host.lowercased()) == .none else { continue }
        switch await ApiSSRFGuard.classifyLocalAccess(forHost: host) {
        case .localNetwork: proposed.insert(host)
        case .neverDialable: neverDialable.append(host)
        case .publicDestination: break
        case let .unresolved(reason): unresolved.append(LocalAccessUnresolved(host: host, reason: reason))
        }
    }
    return RecheckClassification(proposed: proposed, neverDialable: neverDialable, unresolved: unresolved)
}

private func unresolvedAbort(_ unresolved: [LocalAccessUnresolved]) -> Abort {
    let listed = unresolved.sorted(by: { $0.host < $1.host }).map { "\($0.host) (\($0.reason))" }.joined(separator: ", ")
    return Abort(
        .badRequest,
        reason: "Local access classification failed for: \(listed). Nothing was saved. Gate: classification, field: network.allowed_domains."
    )
}

private func handlePutPolicy(req: Request) async throws -> PolicyResponse {
    let body: UpdatePolicyRequest = try decodePolicyBody(UpdatePolicyRequest.self, from: req, label: "policy")
    let store = req.application.runeWeaver.policyStore
    let candidate = try validateStructuredPolicyInput(body.policy)
    return try await req.application.runeWeaver.policyWriteLock.withLock {
        let stored: SecurityPolicy
        do {
            stored = try await store.snapshot()
        } catch let invariant as PolicyInvariantError {
            throw policyInvariantAbort(invariant)
        }
        let snapshotBefore = await store.readSnapshot()
        let expectedGeneration = snapshotBefore.generation
        let storedAllowed = canonicalDomainSet(stored.network.allowedDomains)
        let candidateAllowed = canonicalDomainSet(candidate.network.allowedDomains)
        let outcome = await classifyPutAddedHosts(candidateAllowed.subtracting(storedAllowed))
        guard outcome.unresolved.isEmpty else { throw unresolvedAbort(outcome.unresolved) }
        let retained = Set(
            stored.network.localExemptions.filter { entry in
                if isWildcardOrUniversalPattern(entry) {
                    return true
                }
                return candidateAllowed.contains(NetworkEgressPolicy.canonicalEntry(entry))
            }.map {
                NetworkEgressPolicy.canonicalEntry($0)
            }
        )
        let finalExemptions = retained.union(outcome.proposed)
        let finalCandidate = makeSecurityPolicy(
            version: candidate.version, mode: candidate.network.mode,
            allowedDomains: Set(candidate.network.allowedDomains), blockedDomains: Set(candidate.network.blockedDomains),
            credentials: candidate.credentials, localExemptions: finalExemptions
        )
        try await persistPolicyCandidate(finalCandidate, store: store, expectedGeneration: expectedGeneration)
        await refreshNetworkToolsAfterPolicySave(context: req.application.runeWeaver)
        let snapshot = await store.readSnapshot()
        let dto = makePolicyDTO(from: snapshot.policy)
        let storedExemptions = canonicalDomainSet(stored.network.localExemptions)
        let report = PolicyLocalAccessReport(
            granted: finalExemptions.subtracting(storedExemptions).sorted(),
            removed: storedExemptions.subtracting(finalExemptions).sorted(),
            neverDialable: outcome.neverDialable.sorted()
        )
        return PolicyResponse(
            policy: dto, path: snapshot.fileURL.path, loadedFromDisk: snapshot.loadedFromDisk, violations: snapshot.violations, localAccess: report
        )
    }
}

private func handleVerifyPolicy(req: Request) async throws -> VerifyPolicyResponse {
    let body: VerifyPolicyRequest = try decodePolicyBody(VerifyPolicyRequest.self, from: req, label: "verify")
    do {
        _ = try validateStructuredPolicyInput(body.policy)
        return VerifyPolicyResponse(valid: true, violations: [])
    } catch let abort as Abort {
        return VerifyPolicyResponse(valid: false, violations: [abort.reason])
    } catch {
        return VerifyPolicyResponse(valid: false, violations: [error.localizedDescription])
    }
}

private func handleRecheckPreview(req: Request) async throws -> RecheckLocalExemptionsResponse {
    let body: RecheckLocalExemptionsRequest = try decodePolicyBody(RecheckLocalExemptionsRequest.self, from: req, label: "recheck")
    let candidate = try validateStructuredPolicyInput(body.policy)
    let stored = try await verifiedPolicySnapshotForRecheck(store: req.application.runeWeaver.policyStore)
    let candidateAllowed = canonicalDomainSet(candidate.network.allowedDomains)
    let classification = await classifyRecheckLocalExemptions(
        candidateAllowed: candidateAllowed,
        storedExemptions: canonicalDomainSet(stored.network.localExemptions)
    )
    let storedCanonical = canonicalDomainSet(stored.network.localExemptions)
    let proposed = classification.proposed.filter { host in
        isWildcardOrUniversalPattern(host) || candidateAllowed.contains(host)
    }
    return RecheckLocalExemptionsResponse(
        added: proposed.subtracting(storedCanonical).sorted(),
        removed: storedCanonical.subtracting(proposed).sorted(),
        unchanged: proposed.intersection(storedCanonical).sorted(),
        unresolved: classification.unresolved.map(\.host).sorted()
    )
}

private func handleRecheckApply(req: Request) async throws -> PolicyResponse {
    let body: RecheckLocalExemptionsRequest = try decodePolicyBody(RecheckLocalExemptionsRequest.self, from: req, label: "recheck")
    let candidate = try validateStructuredPolicyInput(body.policy)
    return try await req.application.runeWeaver.policyWriteLock.withLock {
        let stored = try await verifiedPolicySnapshotForRecheck(store: req.application.runeWeaver.policyStore)
        let snapshotBefore = await req.application.runeWeaver.policyStore.readSnapshot()
        let expectedGeneration = snapshotBefore.generation
        let candidateAllowed = canonicalDomainSet(candidate.network.allowedDomains)
        let classification = await classifyRecheckLocalExemptions(
            candidateAllowed: candidateAllowed,
            storedExemptions: canonicalDomainSet(stored.network.localExemptions)
        )
        guard classification.unresolved.isEmpty else { throw unresolvedAbort(classification.unresolved) }
        let finalExemptions = classification.proposed.filter { host in
            isWildcardOrUniversalPattern(host) || candidateAllowed.contains(host)
        }
        let finalCandidate = makeSecurityPolicy(
            version: candidate.version,
            mode: candidate.network.mode,
            allowedDomains: Set(candidate.network.allowedDomains),
            blockedDomains: Set(candidate.network.blockedDomains),
            credentials: candidate.credentials,
            localExemptions: finalExemptions
        )
        let store = req.application.runeWeaver.policyStore
        try await persistPolicyCandidate(finalCandidate, store: store, expectedGeneration: expectedGeneration)
        await refreshNetworkToolsAfterPolicySave(context: req.application.runeWeaver)
        let snapshot = await store.readSnapshot()
        let dto = makePolicyDTO(from: snapshot.policy)
        let storedCanonical = canonicalDomainSet(stored.network.localExemptions)
        let report = PolicyLocalAccessReport(
            granted: finalExemptions.subtracting(storedCanonical).sorted(),
            removed: storedCanonical.subtracting(finalExemptions).sorted(),
            neverDialable: classification.neverDialable.sorted()
        )
        return PolicyResponse(
            policy: dto,
            path: snapshot.fileURL.path,
            loadedFromDisk: snapshot.loadedFromDisk,
            violations: snapshot.violations,
            localAccess: report
        )
    }
}

/// HTTP methods a credential binding may name. Empty stays Any, so the list only narrows when
/// present.
private let allowedPolicyMethods: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

/// Validates a structured policy candidate from the REST contract.
func validateStructuredPolicyInput(_ dto: SecurityPolicyDTO) throws -> SecurityPolicy {
    guard dto.version >= 1 else {
        throw Abort(
            .badRequest,
            reason: "Invalid policy version '\(dto.version)': must be >= 1. Gate: version, field: version."
        )
    }
    let mode = try validatedPolicyMode(dto.network.mode)
    let allowed = try normalizedPolicyDomains(dto.network.allowedDomains, field: "allowed_domains")
    let blocked = try normalizedPolicyDomains(dto.network.blockedDomains, field: "blocked_domains")
    var normalizedCredentials: [String: CredentialBinding] = [:]
    normalizedCredentials.reserveCapacity(dto.credentials.count)
    for (rawKey, bindingDTO) in dto.credentials {
        let key = try validatedCredentialKey(rawKey)
        normalizedCredentials[key] = try normalizedCredentialBinding(key: key, dto: bindingDTO)
    }
    // `localExemptions` is server-owned: the pane renders it display-only and
    // no client value is trusted for writes. The PUT derives the stored set
    // from server-side classification, so any supplied array is ignored here.
    _ = dto.network.localExemptions
    let candidate = makeSecurityPolicy(
        version: dto.version,
        mode: mode,
        allowedDomains: Set(allowed),
        blockedDomains: Set(blocked),
        credentials: normalizedCredentials,
        localExemptions: []
    )
    let violations = PolicyInvariantVerifier.verify(candidate)
    guard violations.isEmpty else {
        throw Abort(
            .badRequest,
            reason: "Security policy violates formal invariants: " + violations.joined(separator: "; ") + ". Gate: invariants, field: policy."
        )
    }
    return candidate
}

/// Reads the verified store snapshot for re-check endpoints.
private func verifiedPolicySnapshotForRecheck(store: PolicyStore) async throws -> SecurityPolicy {
    do {
        return try await store.snapshot()
    } catch let invariant as PolicyInvariantError {
        throw policyInvariantAbort(invariant)
    }
}

/// One re-check classification pass shared by preview and apply.
private func classifyRecheckLocalExemptions(candidateAllowed: Set<String>, storedExemptions: Set<String>) async -> RecheckClassification {
    var proposed: Set<String> = []
    var neverDialable: [String] = []
    var unresolved: [LocalAccessUnresolved] = []
    for host in candidateAllowed.sorted() {
        guard AllowedOriginPattern.classifyWildcard(host.lowercased()) == .none else {
            if storedExemptions.contains(host) {
                proposed.insert(host)
            }
            continue
        }
        switch await ApiSSRFGuard.classifyLocalAccess(forHost: host) {
        case .localNetwork:
            proposed.insert(host)
        case .neverDialable:
            neverDialable.append(host)
        case .publicDestination:
            break
        case let .unresolved(reason):
            unresolved.append(LocalAccessUnresolved(host: host, reason: reason))
        }
    }
    // Preserve stored wildcard grants independent of candidateAllowed presence,
    // maintaining migration parity for non-leading/bare shapes that cannot be
    // entered in allowed_domains.
    for stored in storedExemptions where isWildcardOrUniversalPattern(stored) {
        proposed.insert(stored)
    }
    return RecheckClassification(proposed: proposed, neverDialable: neverDialable, unresolved: unresolved)
}

/// Resolves the validated egress posture. Only the two surviving spellings persist.
private func validatedPolicyMode(_ rawValue: String) throws -> EgressMode {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed == EgressMode.allowlistOnly.rawValue || trimmed == EgressMode.unrestricted.rawValue else {
        throw Abort(
            .badRequest,
            reason: "Invalid network.mode '\(rawValue)': must be 'allowlist_only' "
                + "or 'unrestricted'. Gate: mode, field: network.mode."
        )
    }
    return EgressMode(rawValue: trimmed) ?? .allowlistOnly
}

/// Context and error-formatting helper for host entry validation.
private struct HostValidationContext {
    let gate: String
    let field: String
    let isBinding: Bool
    let bindingKey: String
    let shortField: String

    init(field: String, gate: String) {
        self.gate = gate
        self.field = field
        self.isBinding = gate == "binding"
        if isBinding {
            if field.hasPrefix("credentials."), field.hasSuffix(".allowed_hosts") {
                let start = field.index(field.startIndex, offsetBy: "credentials.".count)
                let end = field.index(field.endIndex, offsetBy: -".allowed_hosts".count)
                self.bindingKey = String(field[start ..< end])
            } else {
                self.bindingKey = field
            }
            self.shortField = "allowed_hosts"
        } else {
            self.bindingKey = ""
            if field.hasPrefix("network.") {
                self.shortField = String(field.dropFirst("network.".count))
            } else {
                self.shortField = field
            }
        }
    }

    func shapeReason(trimmed: String, detail: String) -> String {
        if isBinding {
            return "Invalid credentials '\(bindingKey)' field 'allowed_hosts' value '\(trimmed)': "
                + detail + "Gate: \(gate), field: \(field)."
        }
        return "Invalid network field '\(shortField)' value '\(trimmed)': "
            + detail + "Gate: \(gate), field: \(field)."
    }

    func blankAbort() -> Abort {
        if isBinding {
            return Abort(
                .badRequest,
                reason: "Invalid credentials '\(bindingKey)' field 'allowed_hosts': "
                    + "must not contain blank entries. "
                    + "Gate: \(gate), field: \(field)."
            )
        }
        return Abort(
            .badRequest,
            reason: "Invalid network field '\(shortField)': must not contain blank entries. "
                + "Gate: \(gate), field: \(field)."
        )
    }

    func tomlBreakingAbort(trimmed: String) -> Abort {
        if isBinding {
            return Abort(
                .badRequest,
                reason: "Invalid credentials '\(bindingKey)' field 'allowed_hosts' value '\(trimmed)': "
                    + "carries TOML-breaking characters. "
                    + "Gate: serialization, field: \(field)."
            )
        }
        return Abort(
            .badRequest,
            reason: "Invalid network field '\(shortField)' value '\(trimmed)': "
                + "carries TOML-breaking characters. "
                + "Gate: serialization, field: \(field)."
        )
    }
}

/// Validates bracketed IPv6 literals for credential bindings.
private func validateBracketedIPv6Host(_ trimmed: String, context: HostValidationContext) throws {
    guard trimmed.hasPrefix("["),
          trimmed.hasSuffix("]"),
          trimmed.filter({ $0 == "[" }).count == 1,
          trimmed.filter({ $0 == "]" }).count == 1
    else {
        throw Abort(.badRequest, reason: context.shapeReason(trimmed: trimmed, detail: "must be an exact host or a single leading '*.example.com' edge. "))
    }
    let inner = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !inner.isEmpty,
          inner.contains(":"),
          !inner.contains("["),
          !inner.contains("]"),
          !inner.contains("*"),
          !inner.contains(" ")
    else {
        throw Abort(.badRequest, reason: context.shapeReason(trimmed: trimmed, detail: "must be an exact host or a single leading '*.example.com' edge. "))
    }
}

/// Enforces the wildcard domain constraint (single leading `*.example.com`).
private func validateWildcardHost(_ lowered: String, trimmed: String, context: HostValidationContext) throws {
    switch AllowedOriginPattern.classifyWildcard(lowered) {
    case .leading:
        break
    case .none, .trailing, .invalidShape, .invalidSuffix, .invalidStem:
        throw Abort(.badRequest, reason: context.shapeReason(trimmed: trimmed, detail: "only a single leading '*.example.com' edge authorizes. "))
    }
    let bare = String(lowered.dropFirst(2))
    guard lowered.hasPrefix("*."), !bare.isEmpty,
          !bare.hasPrefix("."), !bare.hasSuffix(".")
    else {
        throw Abort(.badRequest, reason: context.shapeReason(trimmed: trimmed, detail: "only a single leading '*.example.com' edge authorizes. "))
    }
    if lowered.contains(":") {
        throw Abort(.badRequest, reason: context.shapeReason(trimmed: trimmed, detail: "only a single leading '*.example.com' edge authorizes. "))
    }
}

/// Validates unbracketed host strings against forbidden characters, port colons, and wildcard shapes.
private func validateUnbracketedHostShape(_ lowered: String, trimmed: String, context: HostValidationContext) throws {
    if lowered.contains(" ") || lowered.contains("\t")
        || lowered.contains(",") || lowered.contains("?")
        || lowered.contains("[") || lowered.contains("]")
        || lowered.contains("/") || lowered.contains("\\")
        || lowered.contains("@") || lowered.contains("#")
    {
        throw Abort(.badRequest, reason: context.shapeReason(trimmed: trimmed, detail: "must be an exact host or a single leading '*.example.com' edge. "))
    }
    // A canonical URL host never carries a port, and every valid IPv6
    // literal has at least two colons, so exactly one colon can only be a
    // port suffix that the matcher could never equal.
    if lowered.filter({ $0 == ":" }).count == 1 {
        throw Abort(.badRequest, reason: context.shapeReason(trimmed: trimmed, detail: "must be a host without a port. "))
    }
    if lowered.contains("*") {
        try validateWildcardHost(lowered, trimmed: trimmed, context: context)
    }
}

/// Validates one host entry at the network and binding ingress gates.
private func validateHostEntry(_ raw: String, field: String, gate: String) throws -> String {
    let context = HostValidationContext(field: field, gate: gate)
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw context.blankAbort()
    }
    guard !PolicyStore.containsTOMLBreakingScalar(trimmed) else {
        throw context.tomlBreakingAbort(trimmed: trimmed)
    }
    // Bracketed literals wrap an IPv6 address only: one outer pair with a colon-bearing inner and
    // no port suffix.
    if context.isBinding, trimmed.contains("[") || trimmed.contains("]") {
        try validateBracketedIPv6Host(trimmed, context: context)
        return trimmed
    }
    try validateUnbracketedHostShape(trimmed.lowercased(), trimmed: trimmed, context: context)
    return trimmed
}

/// Trims one domain list and rejects blanks, unwritable scalars, and shapes
/// the matcher could never authorize.
private func normalizedPolicyDomains(_ values: [String], field: String) throws -> [String] {
    var normalized: [String] = []
    normalized.reserveCapacity(values.count)
    for raw in values {
        try normalized.append(validateHostEntry(raw, field: "network.\(field)", gate: "network"))
    }
    return normalized
}

/// Trims a credential key and enforces the surrogate alphabet.
private func validatedCredentialKey(_ rawKey: String) throws -> String {
    let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard SecretsManager.isValidSurrogateKey(rawKey), !key.isEmpty else {
        throw Abort(
            .badRequest,
            reason: "Invalid credentials key '\(rawKey)': "
                + "must satisfy SecretsManager.isValidSurrogateKey. "
                + "Gate: credentials, field: credentials.\(rawKey)."
        )
    }
    guard !PolicyStore.containsTOMLBreakingScalar(key) else {
        throw Abort(
            .badRequest,
            reason: "Invalid credentials key '\(rawKey)': carries TOML-breaking characters. "
                + "Gate: serialization, field: credentials.\(rawKey)."
        )
    }
    return key
}

/// Normalizes one per-key binding into its host, method, and prefix scopes.
private func normalizedCredentialBinding(key: String, dto: CredentialBindingDTO) throws -> CredentialBinding {
    try CredentialBinding(
        allowedHosts: Set(normalizedBindingHosts(key: key, values: dto.allowedHosts)),
        allowedMethods: Set(normalizedBindingMethods(key: key, values: dto.allowedMethods)),
        allowedPathPrefixes: normalizedBindingPrefixes(key: key, values: dto.allowedPathPrefixes)
    )
}

/// Trims binding hosts and rejects blanks, unwritable scalars, and shapes
/// the matcher could never authorize.
private func normalizedBindingHosts(key: String, values: [String]) throws -> [String] {
    var normalized: [String] = []
    normalized.reserveCapacity(values.count)
    for rawHost in values {
        try normalized.append(validateHostEntry(rawHost, field: "credentials.\(key).allowed_hosts", gate: "binding"))
    }
    guard !normalized.isEmpty else {
        throw Abort(
            .badRequest,
            reason: "Invalid credentials '\(key)' field 'allowed_hosts': must not be empty. "
                + "An empty host list authorizes nothing. "
                + "Gate: binding, field: credentials.\(key).allowed_hosts."
        )
    }
    return normalized
}

/// Trims and uppercases binding methods against the verb allowlist.
private func normalizedBindingMethods(key: String, values: [String]) throws -> [String] {
    let droppedBlanks = values.map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }
    var normalized: [String] = []
    normalized.reserveCapacity(droppedBlanks.count)
    for rawMethod in droppedBlanks {
        let uppered = rawMethod.uppercased()
        guard allowedPolicyMethods.contains(uppered) else {
            throw Abort(
                .badRequest,
                reason: "Invalid credentials '\(key)' field 'allowed_methods' value '\(rawMethod)': "
                    + "must be one of GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS. "
                    + "Gate: binding, field: credentials.\(key).allowed_methods."
            )
        }
        normalized.append(uppered)
    }
    return normalized
}

/// Trims binding prefixes and enforces the rooted-path shape.
private func normalizedBindingPrefixes(key: String, values: [String]) throws -> [String] {
    let droppedBlanks = values.map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }
    var normalized: [String] = []
    normalized.reserveCapacity(droppedBlanks.count)
    for prefix in droppedBlanks {
        guard prefix.hasPrefix("/") else {
            throw Abort(
                .badRequest,
                reason: "Invalid credentials '\(key)' field 'allowed_path_prefixes' value '\(prefix)': "
                    + "must start with '/'. "
                    + "Gate: binding, field: credentials.\(key).allowed_path_prefixes."
            )
        }
        guard !PolicyStore.containsTOMLBreakingScalar(prefix) else {
            throw Abort(
                .badRequest,
                reason: "Invalid credentials '\(key)' field 'allowed_path_prefixes' value '\(prefix)': "
                    + "carries TOML-breaking characters. "
                    + "Gate: serialization, field: credentials.\(key).allowed_path_prefixes."
            )
        }
        normalized.append(prefix)
    }
    return normalized
}

/// Builds a core policy from normalized REST fields.
private func makeSecurityPolicy(
    version: Int,
    mode: EgressMode,
    allowedDomains: Set<String>,
    blockedDomains: Set<String>,
    credentials: [String: CredentialBinding],
    localExemptions: Set<String> = []
) -> SecurityPolicy {
    SecurityPolicy(
        version: version,
        network: NetworkEgressPolicy(
            mode: mode,
            allowedDomains: allowedDomains,
            blockedDomains: blockedDomains,
            localExemptions: localExemptions
        ),
        credentials: credentials
    )
}

private func makePolicyDTO(from policy: SecurityPolicy) -> SecurityPolicyDTO {
    let networkDTO = NetworkEgressPolicyDTO(
        mode: policy.network.mode.rawValue,
        allowedDomains: policy.network.allowedDomains.sorted(),
        blockedDomains: policy.network.blockedDomains.sorted(),
        localExemptions: policy.network.localExemptions.sorted()
    )

    var credsDTO: [String: CredentialBindingDTO] = [:]
    for (credentialKey, binding) in policy.credentials {
        credsDTO[credentialKey] = CredentialBindingDTO(
            allowedHosts: binding.allowedHosts.sorted(),
            allowedMethods: binding.allowedMethods.sorted(),
            allowedPathPrefixes: binding.allowedPathPrefixes
        )
    }

    return SecurityPolicyDTO(
        version: policy.version,
        network: networkDTO,
        credentials: credsDTO
    )
}
