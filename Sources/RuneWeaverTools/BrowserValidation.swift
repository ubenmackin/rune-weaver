// Rune Weaver Tools — Browser bridge validation and SSRF enforcement.

import Foundation
import RuneWeaverCore

/// Fail-closed validation for browser bridge inputs.
public enum BrowserValidation: Sendable {
    /// Validates a navigation or act URL, rejecting control bytes, non-web schemes, and SSRF targets.
    public static func validateURL(_ url: String, allowlistedOrigins: Set<String> = []) throws -> String {
        let trimmed = try validatedURLLiteral(url)
        // Shares the single SSRF range table with the web and API tools, honoring
        // any configured allowlisted origins or homelab patterns.
        if let refusal = ApiSSRFGuard.denyReason(for: trimmed, allowlistedOrigins: allowlistedOrigins) {
            throw BrowserError.invalidURL("Invalid URL: \(refusal)")
        }
        return trimmed
    }

    /// Async URL validation keeping blocking DNS off the cooperative pool.
    public static func validateURLAsync(_ url: String, allowlistedOrigins: Set<String> = []) async throws -> String {
        let trimmed = try validatedURLLiteral(url)
        if let refusal = await ApiSSRFGuard.denyReasonAsync(for: trimmed, allowlistedOrigins: allowlistedOrigins) {
            throw BrowserError.invalidURL("Invalid URL: \(refusal)")
        }
        return trimmed
    }

    /// Configured exemption set for one browser egress check.
    private struct EgressPolicy: Sendable {
        let browserConfig: BrowserConfig
        let mediaConfig: MediaConfig?
        let llmServerURLs: [String]
        let extraAllowlistedOrigins: Set<String>
        let egressSupervisor: OutboundEgressSupervisor?
        let sessionID: UUID?

        func effectiveOrigins() -> Set<String> {
            var effective = ApiSSRFGuard.allowlistedOrigins(
                browserConfig: browserConfig, mediaConfig: mediaConfig, llmServerURLs: llmServerURLs
            )
            effective.formUnion(extraAllowlistedOrigins)
            return effective
        }

        func denyReason(for trimmed: String) -> String? {
            if extraAllowlistedOrigins.isEmpty {
                return ApiSSRFGuard.denyReason(
                    for: trimmed, browserConfig: browserConfig, mediaConfig: mediaConfig, llmServerURLs: llmServerURLs
                )
            }
            return ApiSSRFGuard.denyReason(for: trimmed, allowlistedOrigins: effectiveOrigins())
        }

        func denyReasonAsync(for trimmed: String) async -> String? {
            if extraAllowlistedOrigins.isEmpty {
                return await ApiSSRFGuard.denyReasonAsync(
                    for: trimmed, browserConfig: browserConfig, mediaConfig: mediaConfig, llmServerURLs: llmServerURLs
                )
            }
            return await ApiSSRFGuard.denyReasonAsync(for: trimmed, allowlistedOrigins: effectiveOrigins())
        }

        func validateURL(_ url: String) throws -> String {
            // Synchronous path stays SSRF-only by design: the supervisor
            // rides solely on the async path so a sync caller can never
            // believe policy was enforced.
            let trimmed = try BrowserValidation.validatedURLLiteral(url)
            if let refusal = denyReason(for: trimmed) {
                throw BrowserError.invalidURL("Invalid URL: \(refusal)")
            }
            return trimmed
        }

        func validateURLAsync(_ url: String) async throws -> String {
            let trimmed = try BrowserValidation.validatedURLLiteral(url)
            if let supervisor = egressSupervisor, let parsed = URL(string: trimmed) {
                // Supervisor first: its network gate precedes the SSRF stage,
                // so a policy-denied destination causes no DNS side effect;
                // the canonical guard below re-vets resolved addresses.
                let verdict = await supervisor.validate(url: parsed, sessionID: sessionID)
                switch verdict {
                case .allowed:
                    break
                case let .denied(reason):
                    throw BrowserError.invalidURL("Egress blocked: \(reason)")
                case let .unlistedDomain(host, reason):
                    throw BrowserError.invalidURL("Egress blocked for unlisted host '\(host)': \(reason)")
                }
            }
            if let refusal = await denyReasonAsync(for: trimmed) {
                throw BrowserError.invalidURL("Invalid URL: \(refusal)")
            }
            return trimmed
        }

        func validateEgressURL(_ url: String) throws -> String {
            let trimmed = try BrowserValidation.egressTrimmed(url)
            return try validateURL(trimmed)
        }

        func validateEgressURLAsync(_ url: String) async throws -> String {
            let trimmed = try BrowserValidation.egressTrimmed(url)
            return try await validateURLAsync(trimmed)
        }
    }

    /// Builds the egress policy for one call's configured exemption set.
    private static func egressPolicy(
        browserConfig: BrowserConfig,
        mediaConfig: MediaConfig?,
        llmServerURLs: [String],
        extraAllowlistedOrigins: Set<String>,
        egressSupervisor: OutboundEgressSupervisor? = nil,
        sessionID: UUID? = nil
    ) -> EgressPolicy {
        EgressPolicy(
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            llmServerURLs: llmServerURLs,
            extraAllowlistedOrigins: extraAllowlistedOrigins,
            egressSupervisor: egressSupervisor,
            sessionID: sessionID
        )
    }

    /// Shared bridge-reported URL literal check without any resolver use.
    /// Centralized so egress entry and redirect hops cannot drift on empty
    /// versus unsafe-target wording; each caller adds only its DNS stage after.
    private static func egressTrimmed(_ url: String) throws -> String {
        guard let trimmed = NormalizedText.value(url), !trimmed.isEmpty else {
            throw BrowserError.invalidURL("Invalid URL: bridge reported an empty redirect URL")
        }
        guard WebURLSafety.isSafeUrl(trimmed) else {
            throw BrowserError.invalidURL("Invalid URL: Unsafe redirect target: refusing to dereference \(trimmed).")
        }
        return trimmed
    }

    /// Validates a navigation or act URL against the configured exemption set. Synchronous
    /// SSRF-only check: never consults the declarative egress policy.
    public static func validateURL(
        _ url: String,
        browserConfig: BrowserConfig,
        mediaConfig: MediaConfig? = nil,
        llmServerURLs: [String] = [],
        extraAllowlistedOrigins: Set<String> = []
    ) throws -> String {
        try egressPolicy(
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            llmServerURLs: llmServerURLs,
            extraAllowlistedOrigins: extraAllowlistedOrigins
        ).validateURL(url)
    }

    /// Async URL validation against the configured exemption set.
    public static func validateURLAsync(
        _ url: String,
        browserConfig: BrowserConfig,
        mediaConfig: MediaConfig? = nil,
        llmServerURLs: [String] = [],
        extraAllowlistedOrigins: Set<String> = [],
        egressSupervisor: OutboundEgressSupervisor? = nil,
        sessionID: UUID? = nil
    ) async throws -> String {
        try await egressPolicy(
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            llmServerURLs: llmServerURLs,
            extraAllowlistedOrigins: extraAllowlistedOrigins,
            egressSupervisor: egressSupervisor,
            sessionID: sessionID
        ).validateURLAsync(url)
    }

    /// Re-validates one bridge-reported URL before it enters tool output. Synchronous SSRF-only
    /// check: never consults the declarative egress policy.
    public static func validateEgressURL(
        _ url: String,
        browserConfig: BrowserConfig,
        mediaConfig: MediaConfig? = nil,
        llmServerURLs: [String] = [],
        extraAllowlistedOrigins: Set<String> = []
    ) throws -> String {
        try egressPolicy(
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            llmServerURLs: llmServerURLs,
            extraAllowlistedOrigins: extraAllowlistedOrigins
        ).validateEgressURL(url)
    }

    /// Async re-validation for one bridge-reported URL.
    public static func validateEgressURLAsync(
        _ url: String,
        browserConfig: BrowserConfig,
        mediaConfig: MediaConfig? = nil,
        llmServerURLs: [String] = [],
        extraAllowlistedOrigins: Set<String> = [],
        egressSupervisor: OutboundEgressSupervisor? = nil,
        sessionID: UUID? = nil
    ) async throws -> String {
        try await egressPolicy(
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            llmServerURLs: llmServerURLs,
            extraAllowlistedOrigins: extraAllowlistedOrigins,
            egressSupervisor: egressSupervisor,
            sessionID: sessionID
        ).validateEgressURLAsync(url)
    }

    /// Re-validates a full bridge-reported redirect chain plus its final URL. Synchronous SSRF-only
    /// check: never consults the declarative egress policy.
    public static func validateRedirectChain(
        _ chain: [BrowserRedirectStep],
        finalURL: String,
        browserConfig: BrowserConfig,
        mediaConfig: MediaConfig? = nil,
        llmServerURLs: [String] = [],
        extraAllowlistedOrigins: Set<String> = []
    ) throws {
        let policy = egressPolicy(
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            llmServerURLs: llmServerURLs,
            extraAllowlistedOrigins: extraAllowlistedOrigins
        )
        for step in chain {
            _ = try policy.validateEgressURL(step.url)
        }
        _ = try policy.validateEgressURL(finalURL)
    }

    /// Async re-validation for a bridge-reported redirect chain plus its final URL.
    public static func validateRedirectChainAsync(
        _ chain: [BrowserRedirectStep],
        finalURL: String,
        browserConfig: BrowserConfig,
        mediaConfig: MediaConfig? = nil,
        llmServerURLs: [String] = [],
        extraAllowlistedOrigins: Set<String> = [],
        egressSupervisor: OutboundEgressSupervisor? = nil,
        sessionID: UUID? = nil
    ) async throws {
        let policy = egressPolicy(
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            llmServerURLs: llmServerURLs,
            extraAllowlistedOrigins: extraAllowlistedOrigins,
            egressSupervisor: egressSupervisor,
            sessionID: sessionID
        )
        let ssrfPolicy = egressPolicy(
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            llmServerURLs: llmServerURLs,
            extraAllowlistedOrigins: extraAllowlistedOrigins,
            egressSupervisor: nil,
            sessionID: sessionID
        )
        // Single policy charge per host within the chain: every hop re-vets
        // SSRF, while repeats of an already-vetted host skip the stateful
        // gate so a one-shot grant is not consumed twice on an echoed host.
        var vettedHosts = Set<String>()
        for step in chain {
            if let host = normalizedURLHost(step.url), vettedHosts.contains(host) {
                _ = try await ssrfPolicy.validateEgressURLAsync(step.url)
                continue
            }
            _ = try await policy.validateEgressURLAsync(step.url)
            if let host = normalizedURLHost(step.url) {
                vettedHosts.insert(host)
            }
        }
        if let finalHost = normalizedURLHost(finalURL), vettedHosts.contains(finalHost) {
            _ = try await ssrfPolicy.validateEgressURLAsync(finalURL)
        } else {
            _ = try await policy.validateEgressURLAsync(finalURL)
        }
    }

    /// Shared literal URL checks without any resolver use.
    private static func validatedURLLiteral(_ url: String) throws -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BrowserError.invalidURL("Invalid URL: URL must not be empty")
        }
        guard trimmed.count <= BrowserBounds.maxURLChars else {
            throw BrowserError.invalidURL("Invalid URL: URL must be at most \(BrowserBounds.maxURLChars) characters")
        }
        if trimmed.unicodeScalars.contains(where: { $0.value == 13 || $0.value == 10 || $0.value == 0 }) {
            throw BrowserError.invalidURL("Invalid URL: URL must not contain CR, LF, or NUL")
        }
        guard let parsed = URL(string: trimmed),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = parsed.host, !host.isEmpty
        else {
            throw BrowserError.invalidURL("Invalid URL: URL must be an http(s) URL with a host")
        }
        return trimmed
    }
}

// MARK: - Snapshot Refs and Act Arguments

extension BrowserValidation {
    /// Canonical host for per-call redirect dedupe, nil when unparseable.
    static func normalizedURLHost(_ urlString: String) -> String? {
        guard let host = URL(string: urlString)?.host, !host.isEmpty else { return nil }
        let canonical = SensitiveAddressNormalization.normalizedHost(host)
        return canonical.isEmpty ? nil : canonical
    }

    /// Whether a ref matches snapshot shape (`e` plus digits).
    /// - Parameter ref: Trimmed candidate ref.
    /// - Returns: True for `e` followed by one or more digits.
    public static func isValidRef(_ ref: String) -> Bool {
        guard ref.count >= 2, ref.count <= 12, ref.hasPrefix("e") else { return false }
        let digits = ref.dropFirst()
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return false }
        // Index zero never exists: snapshots number from e1, so e0 fails
        // instead of resolving to an off-by-one element.
        guard let index = Int(digits), index >= 1 else { return false }
        return true
    }

    /// Validates a snapshot ref against the `eNN` shape.
    /// Bare digits normalize to snapshot shape first so string "12" behaves
    /// like integer 12 from the `ref: [string, integer]` schema.
    public static func validateRef(_ ref: String) throws -> String {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = normalizedRef(trimmed)
        guard isValidRef(normalized) else {
            throw BrowserError.invalidRef("Invalid ref '\(trimmed)': ref must look like e12 from the browser.navigate snapshot")
        }
        return normalized
    }

    /// Normalizes a bare numeric ref to snapshot shape (`e` plus digits).
    public static func normalizedRef(_ ref: String) -> String {
        guard !ref.isEmpty, ref.allSatisfy(\.isNumber) else { return ref }
        return "e\(ref)"
    }

    /// Validates an act action against the single supported enum.
    public static func validateAction(_ action: String) throws -> BrowserActAction {
        let trimmed = action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let parsed = BrowserActAction(rawValue: trimmed) else {
            throw BrowserError.invalidAction(
                "Invalid action '\(trimmed)': action must be one of click, fill, hover, select, press, scroll"
            )
        }
        return parsed
    }

    /// Validates act `text` for the given action.
    public static func validateActText(action: BrowserActAction, text: String?) throws -> String? {
        guard let text else {
            switch action {
            case .fill, .select:
                throw BrowserError.invalidAction("Invalid browser.act arguments: '\(action.rawValue)' requires 'text'")
            case .click, .hover, .scroll, .press:
                return nil
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch action {
        case .fill, .select:
            guard !trimmed.isEmpty else {
                throw BrowserError.invalidAction("Invalid browser.act arguments: '\(action.rawValue)' requires non-empty 'text'")
            }
            try requireBoundedActText(trimmed)
            try requireNoNULActText(trimmed)
            return trimmed
        case .press:
            try requireBoundedActText(trimmed)
            if trimmed.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 13 || $0.value == 10 }) {
                throw BrowserError.invalidAction("Invalid browser.act arguments: press key must be a single key name like Enter")
            }
            // Whitespace-only press text counts as absent so an empty key press stays uniform with omitted text.
            return NormalizedText.value(trimmed)
        case .click, .hover:
            // Both verbs take no text; shared bound plus NUL checks keep hover fail-closed without a second branch.
            try requireBoundedActText(trimmed)
            try requireNoNULActText(trimmed)
            guard trimmed.isEmpty else {
                throw BrowserError.invalidAction("Invalid browser.act arguments: '\(action.rawValue)' takes no 'text'")
            }
            return nil
        case .scroll:
            try requireBoundedActText(trimmed)
            if trimmed.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 13 || $0.value == 10 }) {
                throw BrowserError.invalidAction("Invalid browser.act arguments: scroll direction must not contain control characters")
            }
            // Empty scrolls the element into view; nil stays nil.
            guard let normalized = NormalizedText.value(trimmed) else {
                return nil
            }
            guard let direction = normalizedScrollDirection(normalized) else {
                throw BrowserError.invalidAction("Invalid browser.act arguments: scroll direction must be one of down, up, top, bottom, or a pixel count")
            }
            return direction
        }
    }

    private static func requireBoundedActText(_ trimmed: String) throws {
        guard trimmed.count <= BrowserBounds.maxActTextChars else {
            throw BrowserError.invalidAction("Invalid browser.act arguments: 'text' must be at most \(BrowserBounds.maxActTextChars) characters")
        }
    }

    private static func requireNoNULActText(_ trimmed: String) throws {
        if trimmed.unicodeScalars.contains(where: { $0.value == 0 }) {
            throw BrowserError.invalidAction("Invalid browser.act arguments: 'text' must not contain NUL")
        }
    }

    /// Fail-closed scroll allowlist: named directions plus decimal counts only.
    private static func normalizedScrollDirection(_ normalized: String) -> String? {
        let lowered = normalized.lowercased()
        if lowered == "down" || lowered == "up" || lowered == "top" || lowered == "bottom" {
            return lowered
        }
        if !lowered.isEmpty, lowered.allSatisfy(\.isNumber) {
            return lowered
        }
        guard lowered.hasPrefix("-"), lowered.count > 1 else { return nil }
        return lowered.dropFirst().allSatisfy(\.isNumber) ? lowered : nil
    }
}

// MARK: - Bounded Outputs

extension BrowserValidation {
    /// Truncates distilled text to the shared bound, flagging the cut.
    /// - Parameter text: Raw page text.
    /// - Returns: Bounded text plus whether truncation occurred.
    public static func boundedText(_ text: String) -> (text: String, truncated: Bool) {
        guard text.count > BrowserBounds.maxTextChars else { return (text, false) }
        return (String(text.prefix(BrowserBounds.maxTextChars)), true)
    }

    /// Caps snapshot refs to the shared bound, flagging the cut.
    /// - Parameter refs: Snapshot refs in document order.
    /// - Returns: Bounded refs plus whether truncation occurred.
    public static func boundedRefs(_ refs: [BrowserElementRef]) -> (refs: [BrowserElementRef], truncated: Bool) {
        guard refs.count > BrowserBounds.maxRefs else { return (refs, false) }
        return (Array(refs.prefix(BrowserBounds.maxRefs)), true)
    }
}
