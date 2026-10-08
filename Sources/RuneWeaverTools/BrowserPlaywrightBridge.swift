// Rune Weaver Tools — Playwright bridge for browser automation.
//
// `browser.navigate` (read-only open returning distilled text plus snapshot
// refs) and `browser.act` (approval-gated single validated action against one
// ref plus its snapshot URL) share one subprocess gateway and one persistent
// Chromium profile (`~/.runeweaver/browser_profiles/default`), so login
// sessions survive across calls while refs never cross pages: act re-navigates
// to the snapshot URL and re-resolves the ref, and every call closes its
// context before returning. Chromium's profile admits one live process at a
// time, so helper spawns serialize on a process-wide queue. Downloads stay
// manifest-only and never reach the host.
//
// The configured `browser.timeout_seconds` rides the request document as
// `timeoutMs`, so navigation and per-action waits honor it rather than the
// helper's legacy literals; headless runs use it directly as the kill budget, while headed runs add the
// wait cap plus cleanup headroom so the navigation plus the login wait both fit before the kill.
//
// The helper source lives single-source in `BrowserPlaywrightScript.swift`
// (ordered segments concatenating atomically) alongside the subprocess I/O
// and payload parsing here, so the screenshot budget and envelope shapes
// cannot drift across files; deny behavior is pinned single-source by the
// shared web-safety fixture. Fail-closed validation rejects non-web schemes
// and SSRF targets through the canonical guard before the helper spawns,
// and every bridge-reported redirect or post-action URL re-vets the same way
// so a public start cannot bounce into sensitive ranges; screenshots are
// opt-in per navigate call, downscaled to a 1280px longest edge and
// re-encoded to bounded JPEG under 500KB held in memory for the turn only
// (never written to disk), persisting just a content hash in the audit trail.
// Refs keep the `eNN`
// shape numbering from e1, and redirect chains collapse to a final URL plus
// count so the UI never sees a dead count.

import Foundation
import os
import RuneWeaverCore

/// Failures talking to the Playwright helper through the bridge.
public enum BrowserError: Error, Sendable, Equatable {
    /// The URL failed fail-closed validation.
    case invalidURL(String)
    /// The element ref failed fail-closed validation.
    case invalidRef(String)
    /// The action name is not one of the supported verbs.
    case invalidAction(String)
    /// The bridge subprocess reported a failure.
    case bridgeFailed(String)
    /// The bridge output could not be decoded.
    case decodeFailed(String)
    /// `python3` or the Playwright package could not be launched.
    case playwrightMissing(String)
    /// The helper exceeded the shared container timeout.
    case timedOut(String)
    /// The helper exceeded the shared bounded-output cap.
    case outputLimitExceeded(String)
}

extension BrowserError: LocalizedError {
    /// Human-readable message without any secret or page-content value.
    public var errorDescription: String? {
        switch self {
        case let .invalidURL(detail): detail
        case let .invalidRef(detail): detail
        case let .invalidAction(detail): detail
        case let .bridgeFailed(detail): detail
        case let .decodeFailed(detail): "Could not decode browser response: \(detail)"
        case let .playwrightMissing(detail): detail
        case let .timedOut(detail): detail
        case let .outputLimitExceeded(detail): detail
        }
    }
}

/// The single supported `browser.act` verb.
public enum BrowserActAction: String, Sendable, Codable, Equatable, CaseIterable {
    /// Clicks the element referenced by `ref`.
    case click
    /// Fills a text field referenced by `ref` with `text`.
    case fill
    /// Chooses an option in a select referenced by `ref` using `text`.
    case select
    /// Sends a key press (for example `Enter`) to the element or page.
    case press
    /// Scrolls the element referenced by `ref` into view.
    case scroll
}

/// One distilled interactive element from a page snapshot.
public struct BrowserElementRef: Sendable, Equatable, Codable {
    /// Snapshot-scoped identifier (for example `"e12"`).
    public let ref: String
    /// Lowercased tag or ARIA role (for example `"button"`).
    public let role: String
    /// Accessible name truncated to 80 characters (label, text, value, or placeholder).
    public let name: String

    /// Creates an element ref.
    public init(ref: String, role: String = "", name: String = "") {
        self.ref = ref
        self.role = role
        self.name = name
    }

    private enum CodingKeys: String, CodingKey {
        case ref
        case role
        case name
    }

    /// Decodes a ref, tolerating helpers that omit role or name.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ref = try container.decode(String.self, forKey: .ref)
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
    }

    /// Encodes a ref including its role and name.
    /// - Parameter encoder: Destination encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ref, forKey: .ref)
        try container.encode(role, forKey: .role)
        try container.encode(name, forKey: .name)
    }
}

/// Manifest-only description of a browser-initiated download.
public struct BrowserDownloadManifest: Sendable, Equatable, Codable {
    /// Suggested filename from the page, if known.
    public let filename: String
    /// MIME type, if known.
    public let contentType: String
    /// Byte size when reported by the page, otherwise nil.
    public let sizeBytes: Int?

    /// Creates a download manifest entry.
    public init(filename: String = "", contentType: String = "application/octet-stream", sizeBytes: Int? = nil) {
        self.filename = filename
        self.contentType = contentType
        self.sizeBytes = sizeBytes
    }

    private enum CodingKeys: String, CodingKey {
        case filename
        case contentType
        case sizeBytes
    }

    /// Decodes a manifest entry, tolerating sparse helper payloads.
    /// - Parameter decoder: Decoder for the manifest document.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        filename = try container.decodeIfPresent(String.self, forKey: .filename) ?? ""
        contentType = try container.decodeIfPresent(String.self, forKey: .contentType) ?? "application/octet-stream"
        sizeBytes = try container.decodeIfPresent(Int.self, forKey: .sizeBytes)
    }

    /// Encodes a manifest entry.
    /// - Parameter encoder: Destination encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(filename, forKey: .filename)
        try container.encode(contentType, forKey: .contentType)
        try container.encodeIfPresent(sizeBytes, forKey: .sizeBytes)
    }
}

/// Distilled result of a `browser.navigate` call.
public struct BrowserSnapshot: Sendable, Equatable {
    /// Final URL after redirects.
    public let url: String
    /// Page title, possibly empty.
    public let title: String
    /// Bounded visible text distilled from the body.
    public let text: String
    /// Snapshot-scoped interactive elements in document order.
    public let refs: [BrowserElementRef]
    /// Whether the text or refs were capped at the shared bounds.
    public let truncated: Bool
    /// Whether the page presents a password field (login wall).
    public let authRequired: Bool
    /// Manifest-only downloads offered by the page (never host paths).
    public let downloads: [BrowserDownloadManifest]
    /// Ordered redirect chain from the requested URL to the final URL.
    public let redirectChain: [BrowserRedirectStep]
    /// Transient screenshot data URL for the thumbnail lightbox, never persisted.
    public let screenshotDataURL: String?
    /// Content hash of the screenshot capture for the audit trail.
    public let screenshotHash: String?

    /// Creates a snapshot.
    public init(
        url: String,
        title: String,
        text: String,
        refs: [BrowserElementRef],
        truncated: Bool = false,
        authRequired: Bool = false,
        downloads: [BrowserDownloadManifest] = [],
        redirectChain: [BrowserRedirectStep] = [],
        screenshotDataURL: String? = nil,
        screenshotHash: String? = nil
    ) {
        self.url = url
        self.title = title
        self.text = text
        self.refs = refs
        self.truncated = truncated
        self.authRequired = authRequired
        self.downloads = downloads
        self.redirectChain = redirectChain
        self.screenshotDataURL = screenshotDataURL
        self.screenshotHash = screenshotHash
    }
}

/// Result of a `browser.act` call in a fresh isolated context.
public struct BrowserActResult: Sendable, Equatable {
    /// Final URL after the action (after redirects or navigation).
    public let url: String
    /// The action that ran.
    public let action: BrowserActAction
    /// The ref the action ran against.
    public let ref: String
    /// Manifest-only downloads offered during the action (never host paths).
    public let downloads: [BrowserDownloadManifest]

    /// Creates an act result.
    public init(url: String, action: BrowserActAction, ref: String, downloads: [BrowserDownloadManifest] = []) {
        self.url = url
        self.action = action
        self.ref = ref
        self.downloads = downloads
    }
}

/// Shared bounds keeping browser payloads predictable for the model.
public enum BrowserBounds: Sendable {
    /// Maximum distilled text characters returned per snapshot.
    public static let maxTextChars = 8000
    /// Maximum snapshot refs returned per snapshot.
    public static let maxRefs = 200
    /// Maximum URL characters accepted before fail-closed rejection.
    public static let maxURLChars = 2048
    /// Maximum act `text` characters accepted (fill/select values and press keys).
    public static let maxActTextChars = 2000
    /// Maximum accessible-name characters kept per ref (mirrors the helper).
    public static let maxRefNameChars = 80
}

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
    /// Suspendable tool and gateway paths prefer this over the synchronous
    /// shape so a wedged resolver cannot stall shared tasks; the verdict stays
    /// point-in-time, so callers pin the address at dial time. The synchronous
    /// shape stays for callers that cannot suspend.
    public static func validateURLAsync(_ url: String, allowlistedOrigins: Set<String> = []) async throws -> String {
        let trimmed = try validatedURLLiteral(url)
        if let refusal = await ApiSSRFGuard.denyReasonAsync(for: trimmed, allowlistedOrigins: allowlistedOrigins) {
            throw BrowserError.invalidURL("Invalid URL: \(refusal)")
        }
        return trimmed
    }

    /// Configured exemption set for one browser egress check.
    /// Bundles the four-part seam so the six public validators share one
    /// origins computation and one deny core instead of threading four params
    /// through near-identical literal-guard-DNS bodies.
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

    /// Validates a navigation or act URL against the configured exemption set.
    /// Synchronous SSRF-only check: never consults the declarative egress
    /// policy. Callers needing policy enforcement must use
    /// `validateURLAsync`, which remains the sole policy path.
    /// Delegates to the canonical guard so loopback stays dialable only for the
    /// configured search, media, and model origins while metadata, link-local,
    /// and private ranges stay denied; any refusal fails closed before the
    /// bridge spawns.
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
    /// A supervised call enters the egress supervisor first, so policy
    /// denial precedes any resolver hop; the canonical guard then re-vets
    /// addresses against this call's exemptions, since the supervisor's
    /// SSRF stage judges its own. Unverified hosts deny rather than dial.
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

    /// Re-validates one bridge-reported URL before it enters tool output.
    /// Synchronous SSRF-only check: never consults the declarative egress
    /// policy. Callers needing policy enforcement must use
    /// `validateEgressURLAsync`, which remains the sole policy path.
    /// Mirrors the fetch redirect chain: the shared allowlist rejects smuggled
    /// schemes first, then the canonical guard re-vets the hop so a public
    /// start cannot bounce into loopback, link-local, metadata, or private
    /// ranges through a redirect or a post-action navigation.
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
    /// Supervised hops take the same supervisor-first order as the entry
    /// check; DNS vetting hops to the bounded pool so redirect re-checks
    /// cannot stall shared tasks, and an unverified hop fails closed.
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

    /// Re-validates a full bridge-reported redirect chain plus its final URL.
    /// Synchronous SSRF-only check: never consults the declarative egress
    /// policy. Callers needing policy enforcement must use
    /// `validateRedirectChainAsync`, which remains the sole policy path.
    /// Every hop re-enters the allowlist plus the canonical guard, so a safe
    /// start cannot launder an unsafe hop through the helper's chain surfacing.
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
    /// Hop checks share the bounded-pool DNS path with the entry check, keeping
    /// a wedged resolver from stalling shared tasks while staying fail-closed.
    /// Single charge per host within the chain: every hop re-vets SSRF, while
    /// the stateful policy gate runs once per fresh host.
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
    /// Centralized so the synchronous and async SSRF stages cannot drift on
    /// length, control-byte, or scheme policy; each caller adds only its own
    /// DNS stage after this returns the trimmed candidate.
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

    /// Canonical host for per-call redirect dedupe, nil when unparseable.
    /// Single owner for browser redirect host normalization: the gateway
    /// reuses this instead of keeping its own copy, so hop vetting shares one
    /// normalization. Unparseable hops stay deny-by-default at the egress re-check.
    static func normalizedURLHost(_ urlString: String) -> String? {
        guard let host = URL(string: urlString)?.host, !host.isEmpty else { return nil }
        let canonical = SensitiveAddressNormalization.normalizedHost(host)
        return canonical.isEmpty ? nil : canonical
    }

    /// Whether a ref matches snapshot shape (`e` plus digits).
    /// - Parameter ref: Trimmed candidate ref.
    /// - Returns: True for `e` followed by one or more digits.
    public static func isValidRef(_ ref: String) -> Bool {
        guard ref.count >= 2, ref.count <= 12 else { return false }
        guard ref.hasPrefix("e") else { return false }
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
    /// Single-sourced by the act decoder and the validator so string and
    /// integer aliases cannot diverge: all-digit input maps to `eNN`,
    /// everything else passes through unchanged for strict shape checking.
    /// - Parameter ref: Trimmed candidate ref.
    /// - Returns: `eNN` for all-digit input, else the input unchanged.
    public static func normalizedRef(_ ref: String) -> String {
        guard !ref.isEmpty, ref.allSatisfy(\.isNumber) else { return ref }
        return "e\(ref)"
    }

    /// Validates an act action against the single supported enum.
    public static func validateAction(_ action: String) throws -> BrowserActAction {
        let trimmed = action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let parsed = BrowserActAction(rawValue: trimmed) else {
            throw BrowserError.invalidAction(
                "Invalid action '\(trimmed)': action must be one of click, fill, select, press, scroll"
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
            case .click, .scroll, .press:
                return nil
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch action {
        case .fill, .select:
            guard !trimmed.isEmpty else {
                throw BrowserError.invalidAction("Invalid browser.act arguments: '\(action.rawValue)' requires non-empty 'text'")
            }
            guard trimmed.count <= BrowserBounds.maxActTextChars else {
                throw BrowserError.invalidAction("Invalid browser.act arguments: 'text' must be at most \(BrowserBounds.maxActTextChars) characters")
            }
            if trimmed.unicodeScalars.contains(where: { $0.value == 0 }) {
                throw BrowserError.invalidAction("Invalid browser.act arguments: 'text' must not contain NUL")
            }
            return trimmed
        case .press:
            guard trimmed.count <= BrowserBounds.maxActTextChars else {
                throw BrowserError.invalidAction("Invalid browser.act arguments: 'text' must be at most \(BrowserBounds.maxActTextChars) characters")
            }
            if trimmed.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 13 || $0.value == 10 }) {
                throw BrowserError.invalidAction("Invalid browser.act arguments: press key must be a single key name like Enter")
            }
            // Whitespace-only press text counts as absent so an empty key press stays uniform with omitted text.
            return NormalizedText.value(trimmed)
        case .click, .scroll:
            guard trimmed.isEmpty else {
                throw BrowserError.invalidAction("Invalid browser.act arguments: '\(action.rawValue)' takes no 'text'")
            }
            return nil
        }
    }

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

/// Browser automation gateway used by the browser tools.
public protocol BrowserPlaywrightGateway: Sendable {
    /// Navigates to `url` in a fresh isolated context and distills text plus refs.
    func navigate(url: String, includeScreenshot: Bool) async throws -> BrowserSnapshot

    /// Re-navigates to `url` in a fresh isolated context and performs one action.
    func act(action: BrowserActAction, ref: String, text: String?, url: String) async throws -> BrowserActResult

    /// Navigates without provisioning for dry-run previews.
    /// Dry runs resolve the interpreter from the fast path only so validation
    /// never pays the venv, pip, or browser budgets.
    func navigate(url: String, includeScreenshot: Bool, dryRun: Bool) async throws -> BrowserSnapshot

    /// Session-aware navigate threading the egress session grant.
    /// Declared as a requirement (not an extension default) so the live
    /// gateway's grant-aware implementation dispatches dynamically; stubs
    /// inherit the session-less fallback below.
    func navigate(
        url: String,
        includeScreenshot: Bool,
        dryRun: Bool,
        sessionID: UUID?
    ) async throws -> BrowserSnapshot

    /// Session-aware navigate threading the egress session grant and optional headed mode.
    func navigate(
        url: String,
        includeScreenshot: Bool,
        headed: Bool,
        dryRun: Bool,
        sessionID: UUID?
    ) async throws -> BrowserSnapshot

    /// Session-aware act threading the egress session grant.
    /// Declared as a requirement so the live gateway's grant-aware
    /// implementation dispatches dynamically; stubs inherit the session-less
    /// fallback below.
    func act(
        action: BrowserActAction,
        ref: String,
        text: String?,
        url: String,
        sessionID: UUID?
    ) async throws -> BrowserActResult
}

extension BrowserPlaywrightGateway {
    /// Convenience honoring the text-only default (no screenshot).
    /// - Parameter url: Already-validated http(s) URL.
    /// - Returns: Bounded snapshot without screenshot bytes.
    public func navigate(url: String) async throws -> BrowserSnapshot {
        try await navigate(url: url, includeScreenshot: false)
    }

    /// Default dry-run navigate falling back to the provisioning path.
    /// Concrete gateways that shell out override this to use the fast path
    /// only, so existing test doubles keep working without changes.
    public func navigate(url: String, includeScreenshot: Bool, dryRun: Bool) async throws -> BrowserSnapshot {
        _ = dryRun
        return try await navigate(url: url, includeScreenshot: includeScreenshot)
    }

    /// Default session-aware navigate for stubs without grant handling.
    /// Delegates to the session-less dry-run path so existing doubles keep
    /// compiling; the live gateway overrides with grant-aware validation.
    public func navigate(
        url: String,
        includeScreenshot: Bool,
        dryRun: Bool,
        sessionID _: UUID?
    ) async throws -> BrowserSnapshot {
        try await navigate(url: url, includeScreenshot: includeScreenshot, dryRun: dryRun)
    }

    /// Default headed navigate delegating to the headless overload for stubs without headed handling.
    public func navigate(
        url: String,
        includeScreenshot: Bool,
        headed: Bool,
        dryRun: Bool,
        sessionID: UUID?
    ) async throws -> BrowserSnapshot {
        _ = headed
        return try await navigate(url: url, includeScreenshot: includeScreenshot, dryRun: dryRun, sessionID: sessionID)
    }

    /// Default session-aware act for stubs without grant handling.
    /// Delegates to the session-less path so existing doubles keep
    /// compiling; the live gateway overrides with grant-aware validation.
    public func act(
        action: BrowserActAction,
        ref: String,
        text: String?,
        url: String,
        sessionID _: UUID?
    ) async throws -> BrowserActResult {
        try await act(action: action, ref: ref, text: text, url: url)
    }
}

/// Subprocess gateway shelling out to the Playwright helper.
public struct SubprocessPlaywrightGateway: BrowserPlaywrightGateway, Sendable {
    /// Environment variable overriding the Python executable.
    /// Single-sourced through `BrowserConfig` so the gateway and the managed
    /// venv ensurer never drift on the override name.
    public static var pythonEnvVar: String {
        BrowserConfig.pythonBinEnvVar
    }

    /// Maximum timeout in seconds when running headed for human login or CAPTCHA resolution.
    public static let headedProcessTimeoutSeconds: TimeInterval = 180.0
    /// Seconds reserved after the headed wait loop so `finally: context.close()` releases the profile lock before the kill.
    public static let headedCleanupHeadroomSeconds: TimeInterval = 15.0
    /// In-page headed wait cap, strictly below the kill budget so the timeout path still reaches cleanup.
    public static var headedWaitSeconds: TimeInterval {
        headedProcessTimeoutSeconds - headedCleanupHeadroomSeconds
    }

    /// Headed kill budget covering the configured navigation budget plus the wait cap plus cleanup headroom.
    public static func headedEffectiveTimeout(for timeoutSeconds: TimeInterval) -> TimeInterval {
        timeoutSeconds + headedWaitSeconds + headedCleanupHeadroomSeconds
    }

    /// Explicit Python executable path, if any.
    public let pythonExecutable: String?
    /// Seconds before the helper is terminated. Defaults to the shared container budget.
    public let timeoutSeconds: TimeInterval
    /// Maximum stdout bytes retained. Defaults to the shared detonation bound.
    public let maxOutputBytes: Int
    /// Allowlisted origin and host patterns exempted from SSRF refusals.
    public let allowlistedOrigins: Set<String>
    /// Browser policy supplying the search origin exemption.
    public let browserConfig: BrowserConfig
    /// Media policy supplying Sonarr/Radarr auto-allowed origins.
    public let mediaConfig: MediaConfig?
    /// Configured model endpoints exempted from the loopback deny.
    public let llmServerURLs: [String]
    /// Outbound egress supervisor screening destination URLs against policy.toml.
    public let egressSupervisor: OutboundEgressSupervisor?

    /// Resolves the Python executable from the explicit path or the env override.
    /// Single-sourced so the legacy and config-bound inits cannot drift on
    /// trim versus env precedence; nil keeps the managed-venv fast path.
    private static func resolvePythonBin(explicit: String?) -> String? {
        if let trimmed = NormalizedText.value(explicit) {
            return trimmed
        }
        if let configured = NormalizedText.value(ProcessInfo.processInfo.environment[Self.pythonEnvVar]) {
            return configured
        }
        return nil
    }

    /// Creates a subprocess gateway.
    /// Delegates to the designated config-bound init with a neutral policy so
    /// the precomputed explicit set stays the sole exemption source instead of
    /// gaining a default search origin the caller never configured.
    public init(
        pythonExecutable: String? = nil,
        timeoutSeconds: TimeInterval? = nil,
        maxOutputBytes: Int = StrictContainerRunner.maxProcessOutputBytes,
        allowlistedOrigins: Set<String> = [],
        egressSupervisor: OutboundEgressSupervisor? = nil
    ) {
        let bConfig = BrowserConfig(searxngURL: "")
        self.init(
            pythonExecutable: pythonExecutable,
            timeoutSeconds: timeoutSeconds ?? TimeInterval(bConfig.timeoutSeconds),
            maxOutputBytes: maxOutputBytes,
            browserConfig: bConfig,
            mediaConfig: nil,
            llmServerURLs: [],
            allowlistedOrigins: allowlistedOrigins,
            egressSupervisor: egressSupervisor
        )
    }

    /// Creates a subprocess gateway bound to the configured exemption set.
    /// Entry URLs vet through the canonical guard with search, media, and
    /// model origins exempted, and every bridge-reported hop re-vets the same
    /// way so a public start cannot bounce into sensitive ranges.
    public init(
        pythonExecutable: String? = nil,
        timeoutSeconds: TimeInterval? = nil,
        maxOutputBytes: Int = StrictContainerRunner.maxProcessOutputBytes,
        browserConfig: BrowserConfig,
        mediaConfig: MediaConfig? = nil,
        llmServerURLs: [String] = [],
        allowlistedOrigins: Set<String> = [],
        egressSupervisor: OutboundEgressSupervisor? = nil
    ) {
        self.pythonExecutable = Self.resolvePythonBin(explicit: pythonExecutable)
        self.timeoutSeconds = timeoutSeconds ?? TimeInterval(browserConfig.timeoutSeconds)
        self.maxOutputBytes = maxOutputBytes
        self.allowlistedOrigins = allowlistedOrigins
        self.browserConfig = browserConfig
        self.mediaConfig = mediaConfig
        self.llmServerURLs = llmServerURLs
        self.egressSupervisor = egressSupervisor
    }

    /// Navigates in a fresh isolated context and returns a bounded snapshot.
    public func navigate(url: String, includeScreenshot: Bool = false) async throws -> BrowserSnapshot {
        try await navigate(url: url, includeScreenshot: includeScreenshot, headed: false, dryRun: false)
    }

    /// Navigates resolving the interpreter from the fast path only when dry-running.
    ///
    /// Carries the calling session into every supervisor check so an
    /// interactive grant applies to the entry URL and each fresh redirect
    /// host exactly once; hosts already granted for this call never
    /// re-consume a one-shot grant when the chain echoes them.
    public func navigate(
        url: String,
        includeScreenshot: Bool,
        dryRun: Bool,
        sessionID: UUID? = nil
    ) async throws -> BrowserSnapshot {
        try await navigate(
            url: url,
            includeScreenshot: includeScreenshot,
            headed: false,
            dryRun: dryRun,
            sessionID: sessionID
        )
    }

    /// Navigates with optional headed mode and extended timeout for human auth.
    public func navigate(
        url: String,
        includeScreenshot: Bool,
        headed: Bool,
        dryRun: Bool,
        sessionID: UUID? = nil
    ) async throws -> BrowserSnapshot {
        let validated = try await BrowserValidation.validateURLAsync(
            url,
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            llmServerURLs: llmServerURLs,
            extraAllowlistedOrigins: allowlistedOrigins,
            egressSupervisor: egressSupervisor,
            sessionID: sessionID
        )
        let payload = BrowserSubprocessIO.navigatePayload(
            url: validated,
            includeScreenshot: includeScreenshot,
            headed: headed,
            timeoutSeconds: timeoutSeconds
        )
        let effectiveTimeout: TimeInterval = headed ? Self.headedEffectiveTimeout(for: timeoutSeconds) : timeoutSeconds
        let data = try await run(payload: payload, timeoutOverride: effectiveTimeout, dryRun: dryRun)
        let snapshot = try BrowserBridgeParsing.parseSnapshotPayload(data, fallbackURL: validated)
        // The helper surfaces its redirect chain, so every reported hop
        // re-enters the allowlist plus the canonical guard before the
        // snapshot leaves the gateway; a public start cannot launder a
        // sensitive hop through the bridge. The entry host validated above
        // is excluded from the fresh-host pass so a one-shot grant is
        // consumed once per call, not once per echoed chain entry.
        try await validateFreshRedirectChain(
            snapshot.redirectChain,
            finalURL: snapshot.url,
            entryURL: validated,
            sessionID: sessionID
        )
        return snapshot
    }

    /// Validates bridge-reported hops beyond the already-granted entry host.
    ///
    /// Single stateful pass for this navigation: every hop re-vets SSRF, and
    /// every fresh host additionally vets the declarative policy with the
    /// calling session. Hops back on the entry host reuse the pre-dial policy
    /// verdict (SSRF-only) instead of charging a one-shot grant again, so the
    /// chain still re-validates each hop without double-spending the grant.
    private func validateFreshRedirectChain(
        _ chain: [BrowserRedirectStep],
        finalURL: String,
        entryURL: String,
        sessionID: UUID?
    ) async throws {
        let entryHost = BrowserValidation.normalizedURLHost(entryURL)
        var fresh: [BrowserRedirectStep] = []
        var entryHops: [BrowserRedirectStep] = []
        var seenHosts = Set<String>()
        if let entryHost {
            seenHosts.insert(entryHost)
        }
        for step in chain {
            guard let host = BrowserValidation.normalizedURLHost(step.url) else {
                fresh.append(step)
                continue
            }
            if host == entryHost {
                entryHops.append(step)
                continue
            }
            guard !seenHosts.contains(host) else { continue }
            seenHosts.insert(host)
            fresh.append(step)
        }
        for step in entryHops {
            _ = try await BrowserValidation.validateEgressURLAsync(
                step.url,
                browserConfig: browserConfig,
                mediaConfig: mediaConfig,
                llmServerURLs: llmServerURLs,
                extraAllowlistedOrigins: allowlistedOrigins,
                egressSupervisor: nil
            )
        }
        let freshFinal: String
        if let finalHost = BrowserValidation.normalizedURLHost(finalURL), !seenHosts.contains(finalHost) {
            freshFinal = finalURL
        } else if let last = fresh.last {
            freshFinal = last.url
        } else {
            _ = try await BrowserValidation.validateEgressURLAsync(
                finalURL,
                browserConfig: browserConfig,
                mediaConfig: mediaConfig,
                llmServerURLs: llmServerURLs,
                extraAllowlistedOrigins: allowlistedOrigins,
                egressSupervisor: nil
            )
            return
        }
        try await BrowserValidation.validateRedirectChainAsync(
            fresh,
            finalURL: freshFinal,
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            llmServerURLs: llmServerURLs,
            extraAllowlistedOrigins: allowlistedOrigins,
            egressSupervisor: egressSupervisor,
            sessionID: sessionID
        )
    }

    /// Re-navigates in a fresh isolated context and performs one action.
    /// Act previews never reach this gateway: the tool returns its would-act
    /// envelope locally under `context.dryRun`, so no dry-run overload exists
    /// here and every call below touches the browser. Navigate keeps its
    /// dry-run path because read-only opens still validate through the fast
    /// interpreter without provisioning.
    ///
    /// The calling session threads into the entry and landing checks so one
    /// interactive grant covers the call; a landing back on the entry host
    /// reuses the entry verdict instead of charging a one-shot grant twice.
    /// Session-free entry satisfying the gateway protocol without a policy
    /// grant; scoped callers use the session-threaded overload below.
    public func act(
        action: BrowserActAction,
        ref: String,
        text: String?,
        url: String
    ) async throws -> BrowserActResult {
        try await act(action: action, ref: ref, text: text, url: url, sessionID: nil)
    }

    /// Session-threaded act keeping one grant across entry and landing checks.
    public func act(
        action: BrowserActAction,
        ref: String,
        text: String?,
        url: String,
        sessionID: UUID? = nil
    ) async throws -> BrowserActResult {
        let validatedURL = try await BrowserValidation.validateURLAsync(
            url,
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            llmServerURLs: llmServerURLs,
            extraAllowlistedOrigins: allowlistedOrigins,
            egressSupervisor: egressSupervisor,
            sessionID: sessionID
        )
        let validatedRef = try BrowserValidation.validateRef(ref)
        let validatedText = try BrowserValidation.validateActText(action: action, text: text)
        let payload = BrowserSubprocessIO.actPayload(
            url: validatedURL,
            action: action.rawValue,
            ref: validatedRef,
            text: validatedText,
            timeoutSeconds: timeoutSeconds
        )
        let data = try await run(payload: payload, dryRun: false)
        let result = try BrowserBridgeParsing.parseActPayload(data, action: action, ref: validatedRef, fallbackURL: validatedURL)
        // Post-action navigation can land elsewhere (click-through or
        // meta-refresh), so the reported URL re-vets before the result leaves
        // the gateway rather than trusting the helper's landing page. A
        // landing back on the granted entry host re-vets SSRF-only without a
        // second policy charge; a fresh host vets fully with the session.
        let entryHost = BrowserValidation.normalizedURLHost(validatedURL)
        let landingHost = BrowserValidation.normalizedURLHost(result.url)
        if entryHost != nil, landingHost == entryHost {
            _ = try await BrowserValidation.validateEgressURLAsync(
                result.url,
                browserConfig: browserConfig,
                mediaConfig: mediaConfig,
                llmServerURLs: llmServerURLs,
                extraAllowlistedOrigins: allowlistedOrigins,
                egressSupervisor: nil
            )
        } else {
            _ = try await BrowserValidation.validateEgressURLAsync(
                result.url,
                browserConfig: browserConfig,
                mediaConfig: mediaConfig,
                llmServerURLs: llmServerURLs,
                extraAllowlistedOrigins: allowlistedOrigins,
                egressSupervisor: egressSupervisor,
                sessionID: sessionID
            )
        }
        return result
    }

    /// Runs the helper once with the given request document.
    func run(payload: [String: Any], timeoutOverride: TimeInterval? = nil, dryRun: Bool = false) async throws -> Data {
        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw BrowserError.bridgeFailed("Could not encode browser request: \(error.localizedDescription)")
        }
        let effectiveTimeout = timeoutOverride ?? timeoutSeconds
        // First navigate or act provisions the managed venv inline so Homebrew
        // system pythons never hit externally-managed-environment: the ensurer
        // collapses concurrent callers onto one flight and publishes staged
        // progress for health polls, while explicit and env overrides skip
        // provisioning entirely. Dry-run previews resolve from the fast path
        // only so validation never pays the venv, pip, or browser budgets.
        // Timeout plus output caps stay on the bridge call below, never on
        // provisioning budgets above.
        if dryRun {
            try Task.checkCancellation()
            let effectivePython = PlaywrightPythonEnsurer.resolveDryRunPythonBin(explicit: pythonExecutable)
            return try await BrowserSubprocessIO.runBridgeIO(
                scriptSource: BrowserPlaywrightScript.source,
                payload: body,
                pythonExecutable: effectivePython,
                timeoutSeconds: effectiveTimeout,
                maxOutputBytes: maxOutputBytes
            )
        }
        let effectivePython: String?
        do {
            effectivePython = try await PlaywrightPythonEnsurer.shared.ensure(explicitPythonBin: pythonExecutable)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BrowserError {
            throw error
        } catch {
            throw BrowserError.bridgeFailed(error.localizedDescription)
        }
        return try await BrowserSubprocessIO.runBridgeIO(
            scriptSource: BrowserPlaywrightScript.source,
            payload: body,
            pythonExecutable: effectivePython,
            timeoutSeconds: effectiveTimeout,
            maxOutputBytes: maxOutputBytes
        )
    }
}

/// Explicit stub used when Playwright is unavailable and in tests.
public struct StubBrowserGateway: BrowserPlaywrightGateway, Sendable {
    /// Message surfaced instead of the marketplace canned stubs.
    public let message: String

    /// Creates a stub gateway.
    /// - Parameter message: Explicit missing-dependency message, defaulting to
    ///   the managed-venv copy naming the venv path plus manual fallback.
    public init(message: String? = nil) {
        self.message = message ?? PlaywrightPythonEnsurer.missingMessage(
            stage: nil,
            detail: "Playwright is not installed"
        )
    }

    /// Always throws the explicit missing-dependency error.
    public func navigate(url _: String, includeScreenshot _: Bool = false) async throws -> BrowserSnapshot {
        throw BrowserError.playwrightMissing(message)
    }

    /// Always throws the explicit missing-dependency error.
    public func act(action _: BrowserActAction, ref _: String, text _: String?, url _: String) async throws -> BrowserActResult {
        throw BrowserError.playwrightMissing(message)
    }
}

/// Runs blocking Playwright subprocess I/O off the async executor.
enum BrowserSubprocessIO {
    /// Process-wide serial queue for helper spawns.
    /// Chromium's persistent profile admits one live process per user-data
    /// directory, so two helpers launched together would collide on the
    /// profile's SingletonLock and fail a legitimate call. Serializing the
    /// whole blocking run — not just validation — keeps concurrent
    /// navigate/act calls safe; queued callers hold no thread until their
    /// turn, and a task-scoped process box still terminates a live run on
    /// cancellation.
    private static let bridgeRunQueue = DispatchQueue(label: "com.runeweaver.browser.playwright-bridge", qos: .utility)

    /// Runs one blocking bridge operation on the serial profile queue.
    /// Interior seam so the non-overlap contract stays testable without
    /// spawning Playwright, and so every bridge run — live or dry-run —
    /// shares the one queue the profile lock requires.
    static func runSerialized<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            bridgeRunQueue.async {
                do {
                    try continuation.resume(returning: operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Milliseconds the helper should allow for one navigation or action wait.
    /// Single-sourced from the configured `browser.timeout_seconds` so the
    /// in-page budgets and the subprocess kill budget cannot drift apart.
    static func timeoutMilliseconds(for seconds: TimeInterval) -> Int {
        max(1, Int((seconds * 1000).rounded()))
    }

    /// Builds the navigate request document sent to the helper.
    /// `timeoutMs` carries the configured budget so `page.goto` honors it
    /// instead of the helper's legacy 30s literal; every navigate key stays
    /// assembled in one place.
    static func navigatePayload(
        url: String,
        includeScreenshot: Bool,
        headed: Bool,
        timeoutSeconds: TimeInterval
    ) -> [String: Any] {
        var payload: [String: Any] = ["op": "navigate", "url": url, "timeoutMs": timeoutMilliseconds(for: timeoutSeconds)]
        if includeScreenshot {
            payload["includeScreenshot"] = true
        }
        if headed {
            payload["headed"] = true
        }
        return payload
    }

    /// Builds the act request document sent to the helper.
    /// `timeoutMs` carries the same configured budget so per-action waits
    /// honor it instead of the helper's legacy 10s literal.
    static func actPayload(
        url: String,
        action: String,
        ref: String,
        text: String?,
        timeoutSeconds: TimeInterval
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "op": "act",
            "url": url,
            "action": action,
            "ref": ref,
            "timeoutMs": timeoutMilliseconds(for: timeoutSeconds)
        ]
        if let text {
            payload["text"] = text
        }
        return payload
    }

    /// Runs blocking bridge subprocess I/O off the async executor.
    static func runBridgeIO(
        scriptSource: String,
        payload: Data,
        pythonExecutable: String?,
        timeoutSeconds: TimeInterval,
        maxOutputBytes: Int
    ) async throws -> Data {
        try Task.checkCancellation()
        // Shared box lets cancellation terminate the live helper instead of
        // leaking it: the blocking wait publishes the child before waiting
        // so a cancel racing the spawn still finds and kills it. The latch
        // also covers a cancel landing while this run waits its turn in the
        // serial queue, so a doomed helper never grabs the profile lock.
        let box = BoundedProcessRunner.ProcessBox()
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return try await withTaskCancellationHandler {
            try await runSerialized {
                // A cancel landing after this check still terminates via the
                // box handler below instead of hanging the budget.
                if cancelled.withLock({ $0 }) {
                    throw CancellationError()
                }
                return try runBridgeBlocking(
                    scriptSource: scriptSource,
                    payload: payload,
                    pythonExecutable: pythonExecutable,
                    timeoutSeconds: timeoutSeconds,
                    maxOutputBytes: maxOutputBytes,
                    processBox: box
                )
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
            box.terminateIfRunning()
        }
    }

    /// Spawns the Python helper via the shared bounded runner.
    private static func runBridgeBlocking(
        scriptSource: String,
        payload: Data,
        pythonExecutable: String?,
        timeoutSeconds: TimeInterval,
        maxOutputBytes: Int,
        processBox: BoundedProcessRunner.ProcessBox? = nil
    ) throws -> Data {
        let executableURL: URL
        let arguments: [String]
        if let pythonExecutable, !pythonExecutable.isEmpty {
            executableURL = URL(fileURLWithPath: pythonExecutable)
            arguments = ["-c", scriptSource]
        } else {
            executableURL = URL(fileURLWithPath: "/usr/bin/env")
            arguments = ["python3", "-c", scriptSource]
        }
        let stdoutLimit = max(1, maxOutputBytes)
        let result: BoundedProcessResult
        do {
            result = try BoundedProcessRunner.runSync(
                executableURL: executableURL,
                arguments: arguments,
                inputData: payload,
                timeoutSeconds: timeoutSeconds,
                maxOutputBytes: stdoutLimit,
                maxErrorBytes: 64 * 1024,
                processBox: processBox
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BoundedProcessError {
            switch error {
            case .timedOut:
                throw BrowserError.timedOut(
                    "Browser automation timed out after \(Int(timeoutSeconds))s."
                )
            case .outputLimitExceeded:
                throw BrowserError.outputLimitExceeded(
                    "Browser output exceeded the \(stdoutLimit)-byte limit and was terminated."
                )
            case let .launchFailed(detail):
                // Launch failures stay in the missing classification so the
                // dashboard renders the venv path plus manual fallback instead
                // of a bare spawn error; timeout plus output caps above stay
                // on the bridge call, never on provisioning budgets.
                let launchDetail = "Could not launch python3 for browser automation: \(detail)"
                throw BrowserError.playwrightMissing(
                    PlaywrightPythonEnsurer.missingMessage(stage: nil, detail: launchDetail, pythonPath: pythonExecutable)
                )
            }
        } catch {
            throw BrowserError.bridgeFailed("Browser helper failed: \(error.localizedDescription)")
        }
        return try Self.validatedBridgeResult(
            exitCode: result.exitCode,
            output: result.stdout,
            stderr: result.stderr
        )
    }

    /// Validates helper output, mapping empty or failing runs to typed errors.
    private static func validatedBridgeResult(
        exitCode: Int32,
        output: Data,
        stderr: Data
    ) throws -> Data {
        if exitCode != 0, output.isEmpty {
            let detail = bridgeStderrDetail(stderr)
            if detail.contains("No module named playwright") || detail.contains("Playwright is not installed") {
                // Stays in the missing classification but names the managed
                // venv plus manual fallback instead of the old generic pip
                // hint that Homebrew now refuses outside a venv.
                throw BrowserError.playwrightMissing(
                    PlaywrightPythonEnsurer.missingMessage(stage: nil, detail: detail.isEmpty ? "Playwright is not installed" : detail)
                )
            }
            if detail.isEmpty {
                throw BrowserError.bridgeFailed("Browser helper exited with status \(exitCode)")
            }
            throw BrowserError.bridgeFailed("Browser helper failed: \(detail)")
        }
        if exitCode != 0, !output.isEmpty {
            let detail = bridgeStderrDetail(stderr)
            if !detail.isEmpty {
                throw BrowserError.bridgeFailed("Browser helper failed: \(detail)")
            }
        }
        if output.isEmpty {
            let detail = bridgeStderrDetail(stderr)
            if detail.isEmpty {
                throw BrowserError.decodeFailed("Browser helper returned no output")
            }
            throw BrowserError.bridgeFailed("Browser helper failed: \(detail)")
        }
        return output
    }

    /// Decodes helper stderr to a trimmed detail string.
    private static func bridgeStderrDetail(_ stderr: Data) -> String {
        String(data: stderr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
