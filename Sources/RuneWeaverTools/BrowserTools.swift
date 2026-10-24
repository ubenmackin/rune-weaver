// Rune Weaver Tools — Interactive browser navigation plus unified act.

import Foundation
import RuneWeaverCore

/// Arguments for the `browser.navigate` tool.
public struct BrowserNavigateArgs: Sendable, Equatable, Decodable {
    /// Page URL to open.
    public let url: String
    /// Whether to capture an opt-in screenshot for vision models.
    public let includeScreenshot: Bool
    /// Whether to open a headed (visible) browser session for human login or CAPTCHAs.
    public let headed: Bool

    /// Memberwise initializer.
    public init(url: String, includeScreenshot: Bool = false, headed: Bool = false) {
        self.url = url
        self.includeScreenshot = includeScreenshot
        self.headed = headed
    }

    private enum CodingKeys: String, CodingKey {
        case url
        case includeScreenshot
        case headed
        case interactive
    }

    /// Decodes canonical navigate arguments.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let direct = try container.decodeIfPresent(String.self, forKey: .url), !direct.isEmpty {
            url = direct
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.url,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Missing URL (expected 'url')"
                )
            )
        }
        // Opt-in defaults to false when absent, null, or malformed so a missing flag never produces
        // a surprise vision payload on a text-only model; mirrors `BrowserScreenshotPolicy`
        // parsing.
        let primaryFlag: Bool? = (try? container.decodeIfPresent(Bool.self, forKey: .includeScreenshot)) ?? nil
        includeScreenshot = primaryFlag ?? false

        let headedFlag: Bool? = (try? container.decodeIfPresent(Bool.self, forKey: .headed)) ?? nil
        let interactiveFlag: Bool? = (try? container.decodeIfPresent(Bool.self, forKey: .interactive)) ?? nil
        headed = headedFlag ?? interactiveFlag ?? false
    }

    /// Trimmed page URL.
    public var trimmedURL: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Arguments for the `browser.act` tool.
public struct BrowserActArgs: Sendable, Equatable, Decodable {
    /// Single action verb (click, fill, select, press, or scroll).
    public let action: String
    /// Snapshot ref (for example `"e12"`).
    public let ref: String
    /// Optional value for `fill`/`select` or key for `press`.
    public let text: String?
    /// Page URL the snapshot came from.
    public let url: String

    /// Memberwise initializer.
    public init(action: String, ref: String, text: String? = nil, url: String) {
        self.action = action
        self.ref = ref
        self.text = text
        self.url = url
    }

    private enum CodingKeys: String, CodingKey {
        case action
        case ref
        case text
        case key
        case url
    }

    /// Decodes canonical act arguments.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let direct = try container.decodeIfPresent(String.self, forKey: .action), !direct.isEmpty {
            action = direct
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.action,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Missing action (expected 'action')"
                )
            )
        }
        ref = try Self.decodeRef(from: container)
        text = try container.decodeIfPresent(String.self, forKey: .text)
            ?? container.decodeIfPresent(String.self, forKey: .key)
        if let direct = try container.decodeIfPresent(String.self, forKey: .url), !direct.isEmpty {
            url = direct
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.url,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Missing URL (expected 'url')"
                )
            )
        }
    }

    /// Decodes the element ref from string or integer input.
    private static func decodeRef(from container: KeyedDecodingContainer<CodingKeys>) throws -> String {
        // String input probes with `try?` so an integer-shaped value (for example `{"ref": 12}`)
        // does not throw a type mismatch before the integer pass maps it to snapshot shape
        // (`"e12"`).
        if let direct = try? container.decodeIfPresent(String.self, forKey: .ref),
           !direct.isEmpty
        {
            let trimmed = direct.trimmingCharacters(in: .whitespacesAndNewlines)
            return BrowserValidation.normalizedRef(trimmed.isEmpty ? direct : trimmed)
        }
        if let number = try? container.decodeIfPresent(Int.self, forKey: .ref) {
            return "e\(number)"
        }
        throw DecodingError.keyNotFound(
            CodingKeys.ref,
            DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "Missing ref (expected 'ref' like e12)"
            )
        )
    }

    /// Trimmed action verb.
    public var trimmedAction: String {
        action.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trimmed snapshot ref.
    public var trimmedRef: String {
        ref.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trimmed page URL.
    public var trimmedURL: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trimmed optional text, nil when omitted or blank.
    public var trimmedText: String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Envelope wrapping `browser.navigate` tool output.
public struct BrowserNavigateEnvelope: Sendable, Equatable, Codable {
    /// Final URL after redirects (mirrors `finalUrl`).
    public let url: String
    /// Final URL after redirects (canonical display key).
    public let finalUrl: String
    /// Page title, possibly empty.
    public let title: String
    /// Bounded visible text distilled from the body (mirrors `textSnapshot`).
    public let text: String
    /// Bounded visible text (canonical display key; mirrors `text`).
    public let textSnapshot: String
    /// Snapshot-scoped interactive elements in document order.
    public let refs: [BrowserElementRef]
    /// Ordered redirect chain from the requested URL to the final URL.
    public let redirectChain: [BrowserRedirectStep]
    /// Collapsed redirect count (chain length minus one, floor zero).
    public let redirectCount: Int
    /// Whether text or refs were capped at the shared bounds.
    public let truncated: Bool
    /// Whether the page presents a password field (login wall).
    public let authRequired: Bool
    /// Manifest-only downloads offered by the page (never host paths).
    public let downloads: [BrowserDownloadManifest]
    /// Content hash of the screenshot capture, when one was taken.
    public let screenshotHash: String?
    /// Transient data URL for the thumbnail lightbox, never persisted.
    public let screenshotDataURL: String?
    /// Human-readable follow-up hint (login escalation or download note).
    public let note: String?

    /// Creates a navigate envelope with the unified display contract.
    public init(
        url: String,
        title: String,
        text: String,
        refs: [BrowserElementRef],
        truncated: Bool = false,
        authRequired: Bool = false,
        downloads: [BrowserDownloadManifest] = [],
        redirectChain: [BrowserRedirectStep]? = nil,
        screenshotHash: String? = nil,
        screenshotDataURL: String? = nil,
        note: String? = nil
    ) {
        self.url = url
        self.finalUrl = url
        self.title = title
        self.text = text
        self.textSnapshot = text
        self.refs = refs
        let chain = redirectChain ?? [BrowserRedirectStep(url: url)]
        self.redirectChain = chain
        self.redirectCount = max(0, chain.count - 1)
        self.truncated = truncated
        self.authRequired = authRequired
        self.downloads = downloads
        self.screenshotHash = screenshotHash
        self.screenshotDataURL = screenshotDataURL
        self.note = note
    }

    /// Only envelope-only keys live here; shared wire aliases decode
    /// single-sourced through `BrowserNavigateResult` so the shape cannot drift.
    private enum CodingKeys: String, CodingKey {
        case url
        case finalUrl
        case title
        case text
        case textSnapshot
        case refs
        case redirectChain
        case redirectCount
        case truncated
        case authRequired
        case downloads
        case screenshotHash
        case screenshotDataURL
        case note
    }

    /// Decodes tolerantly across envelope shapes.
    public init(from decoder: Decoder) throws {
        let shared = try BrowserNavigateResult(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `url` stays envelope-local: the shared view owns only the
        // `finalUrl` aliases, while tool output mirrors both keys.
        let fallbackURL: String? = BrowserNavigateWire.decodeFirst(container, keys: [.url])
        let resolvedURL = [shared.finalUrl, fallbackURL].compactMap(\.self).first(where: { !$0.isEmpty }) ?? ""
        url = resolvedURL
        finalUrl = resolvedURL
        let decodedTitle: String? = BrowserNavigateWire.decodeFirst(container, keys: [.title])
        title = decodedTitle ?? ""
        let fallbackText: String? = BrowserNavigateWire.decodeFirst(container, keys: [.text])
        let resolvedText = shared.textSnapshot ?? fallbackText ?? ""
        text = resolvedText
        textSnapshot = resolvedText
        let decodedRefs: [BrowserElementRef]? = BrowserNavigateWire.decodeFirst(container, keys: [.refs])
        refs = decodedRefs ?? []
        let chain: [BrowserRedirectStep] =
            if let sharedChain = shared.redirectChain {
                sharedChain
            } else if !resolvedURL.isEmpty {
                [BrowserRedirectStep(url: resolvedURL)]
            } else {
                []
            }
        redirectChain = chain
        redirectCount = shared.redirectCount ?? max(0, chain.count - 1)
        let decodedTruncated: Bool? = BrowserNavigateWire.decodeFirst(container, keys: [.truncated])
        truncated = decodedTruncated ?? false
        authRequired = shared.authRequired ?? false
        let decodedDownloads: [BrowserDownloadManifest]? = BrowserNavigateWire.decodeFirst(container, keys: [.downloads])
        downloads = decodedDownloads ?? []
        screenshotHash = shared.screenshotHash
        screenshotDataURL = shared.screenshotDataURL
        let decodedNote: String? = BrowserNavigateWire.decodeFirst(container, keys: [.note])
        note = decodedNote
    }

    /// Encodes the unified shape with both standard and display keys.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(url, forKey: .url)
        try container.encode(finalUrl, forKey: .finalUrl)
        try container.encode(title, forKey: .title)
        try container.encode(text, forKey: .text)
        try container.encode(textSnapshot, forKey: .textSnapshot)
        try container.encode(refs, forKey: .refs)
        try container.encode(redirectChain, forKey: .redirectChain)
        try container.encode(redirectCount, forKey: .redirectCount)
        try container.encode(truncated, forKey: .truncated)
        try container.encode(authRequired, forKey: .authRequired)
        try container.encode(downloads, forKey: .downloads)
        try container.encodeIfPresent(screenshotHash, forKey: .screenshotHash)
        try container.encodeIfPresent(screenshotDataURL, forKey: .screenshotDataURL)
        try container.encodeIfPresent(note, forKey: .note)
    }

    /// Copy safe for durable history with transient pixels removed.
    public func strippedForPersistence() -> BrowserNavigateEnvelope {
        let stripped = asResult().strippedForPersistence()
        return BrowserNavigateEnvelope(
            url: url,
            title: title,
            text: text,
            refs: refs,
            truncated: truncated,
            authRequired: authRequired,
            downloads: downloads,
            redirectChain: redirectChain,
            screenshotHash: stripped.screenshotHash,
            screenshotDataURL: stripped.screenshotDataURL,
            note: note
        )
    }

    /// Shared display/audit view of this envelope for history rendering.
    /// - Returns: Result carrying the single-sourced wire fields.
    public func asResult() -> BrowserNavigateResult {
        BrowserNavigateResult(
            finalUrl: finalUrl,
            redirectCount: redirectCount,
            redirectChain: redirectChain,
            authRequired: authRequired,
            textSnapshot: textSnapshot,
            screenshotHash: screenshotHash,
            screenshotDataURL: screenshotDataURL
        )
    }

    /// Parses a raw tool output document, returning nil for non-browser payloads. Shares the
    /// `BrowserNavigateResult.parse` gate so tool output and display agree on what counts as a
    /// browser document.
    public static func parse(_ content: String) -> BrowserNavigateEnvelope? {
        guard BrowserNavigateResult.parse(content) != nil else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode(BrowserNavigateEnvelope.self, from: data)
        } catch {
            RuneWeaverLog.tools.warning("BrowserNavigateEnvelope.parse: failed to decode envelope: \(error.localizedDescription)")
            return nil
        }
    }
}

/// Envelope wrapping `browser.act` tool output.
public struct BrowserActEnvelope: Sendable, Equatable, Codable {
    /// Final URL after the action.
    public let url: String
    /// The action that ran (or would run under dry-run).
    public let action: String
    /// The ref the action ran against.
    public let ref: String
    /// Whether the action completed (false only for dry-run previews).
    public let ok: Bool
    /// Whether this envelope previews without acting.
    public let dryRun: Bool
    /// Manifest-only downloads offered during the action (never host paths).
    public let downloads: [BrowserDownloadManifest]
    /// Human-readable outcome note.
    public let note: String?
    /// Page title after the action.
    public let title: String?
    /// Distilled text after the action.
    public let text: String?
    /// Interactive snapshot refs after the action.
    public let refs: [BrowserElementRef]?

    /// Creates an act envelope.
    public init(
        url: String,
        action: String,
        ref: String,
        ok: Bool = true,
        dryRun: Bool = false,
        downloads: [BrowserDownloadManifest] = [],
        note: String? = nil,
        title: String? = nil,
        text: String? = nil,
        refs: [BrowserElementRef]? = nil
    ) {
        self.url = url
        self.action = action
        self.ref = ref
        self.ok = ok
        self.dryRun = dryRun
        self.downloads = downloads
        self.note = note
        self.title = title
        self.text = text
        self.refs = refs
    }
}

/// Read-only `browser.navigate` tool over the isolated Playwright bridge.
public struct BrowserNavigateTool: Tool, Sendable {
    /// Stable tool name referenced by the LLM and memory.
    public let name = "browser.navigate"
    /// When the LLM should use this tool.
    /// Kept to two lines so the composed prompt stays within budget across the full registry.
    public let description =
        "Opens a URL in a persistent context (default headless); returns text plus refs (e.g. e12) for browser.act. "
            + "Auth walls escalate to human login via headed=true (interactively solves challenges in-call, saves session, closes). "
            + "Navigation is SSRF-guarded: approval-free browsing must not dial loopback, link-local, metadata, or private ranges."
    /// Function-calling contract for `url`, the screenshot opt-in, and headed mode.
    public let inputSchema =
        JSONSchema(
            rawValue: """
            {
              "type": "object",
              "properties": {
                "url": {
                  "type": "string",
                  "description": "http(s) page URL to open"
                },
                "includeScreenshot": {
                  "type": "boolean",
                  "description": "Capture a downscaled JPEG screenshot for vision models (default false; vision models only)",
                  "default": false
                },
                "headed": {
                  "type": "boolean",
                  "description": "Launch a visible browser window for login or challenge resolution during this call; saves session (default false)",
                  "default": false
                }
              },
              "required":["url"],
              "additionalProperties": false
            }
            """
        )
    /// Always allowed: navigation distills without changing web state.
    public let permissionLevel = PermissionLevel.readOnly
    /// Network-derived bytes may carry injected directives, so results enter as labeled data.
    public var contentTrustLevel: ContentTrustLevel {
        .untrustedExternal
    }

    /// Playwright gateway (subprocess bridge by default, stub in tests).
    private let gateway: any BrowserPlaywrightGateway
    /// Allowlisted origin and host patterns exempted from SSRF refusals.
    private let allowlistedOrigins: Set<String>
    /// Browser policy supplying the search origin exemption.
    private let browserConfig: BrowserConfig
    /// Media policy supplying Sonarr/Radarr auto-allowed origins.
    private let mediaConfig: MediaConfig?
    /// Configured model endpoints exempted from the loopback deny.
    private let llmServerURLs: [String]
    /// Outbound egress supervisor screening destination URLs against policy.toml.
    public let egressSupervisor: OutboundEgressSupervisor?

    /// Shared gateway for live-reload reuse so a settings PUT refreshes origins
    /// without dropping an injected test double.
    public var browserGateway: any BrowserPlaywrightGateway {
        gateway
    }

    /// Creates a navigate tool.
    public init(
        gateway: any BrowserPlaywrightGateway? = nil,
        allowlistedOrigins: Set<String> = [],
        egressSupervisor: OutboundEgressSupervisor? = nil
    ) {
        self.init(
            gateway: gateway,
            browserConfig: BrowserConfig(searxngURL: ""),
            mediaConfig: nil,
            llmServerURLs: [],
            allowlistedOrigins: allowlistedOrigins,
            egressSupervisor: egressSupervisor
        )
    }

    /// Creates a navigate tool bound to the configured exemption set.
    public init(
        gateway: any BrowserPlaywrightGateway? = nil,
        browserConfig: BrowserConfig,
        mediaConfig: MediaConfig? = nil,
        llmServerURLs: [String] = [],
        allowlistedOrigins: Set<String> = [],
        egressSupervisor: OutboundEgressSupervisor? = nil
    ) {
        self.browserConfig = browserConfig
        self.mediaConfig = mediaConfig
        self.llmServerURLs = llmServerURLs
        self.allowlistedOrigins = allowlistedOrigins
        self.egressSupervisor = egressSupervisor
        self.gateway = gateway ?? SubprocessPlaywrightGateway(
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            llmServerURLs: llmServerURLs,
            allowlistedOrigins: allowlistedOrigins,
            egressSupervisor: egressSupervisor
        )
    }

    /// Opens the page and returns its distilled snapshot.
    /// Dry-run previews resolve the interpreter from the fast path only so
    /// validation never provisions the managed venv.
    public func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput {
        let args: BrowserNavigateArgs
        do {
            args = try JSONDecoder().decode(BrowserNavigateArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            return .failure(
                "Invalid browser.navigate arguments: expected {\"url\": \"https://example.com\"}.",
                callID: input.callID
            )
        }

        // Defense in depth: the raw flag and the policy parser must agree;
        // either true requests a capture so a renamed key cannot silently
        // drop a vision-model opt-in.
        let includeScreenshot = args.includeScreenshot
            || BrowserScreenshotPolicy.includeScreenshotRequested(argumentsJSON: input.argumentsJSON)
        do {
            // Single stateful policy gate lives in the gateway's session-aware path, reached
            // dynamically through the protocol requirement so every bridge honors the calling
            // session's grants.
            _ = try await BrowserValidation.validateURLAsync(
                args.trimmedURL,
                browserConfig: browserConfig,
                mediaConfig: mediaConfig,
                llmServerURLs: llmServerURLs,
                extraAllowlistedOrigins: allowlistedOrigins,
                egressSupervisor: nil
            )
            let snapshot = try await gateway.navigate(
                url: args.trimmedURL,
                includeScreenshot: includeScreenshot,
                headed: args.headed,
                dryRun: context.dryRun,
                sessionID: context.sessionID
            )
            for step in snapshot.redirectChain {
                _ = try await BrowserValidation.validateEgressURLAsync(
                    step.url,
                    browserConfig: browserConfig,
                    mediaConfig: mediaConfig,
                    llmServerURLs: llmServerURLs,
                    extraAllowlistedOrigins: allowlistedOrigins,
                    egressSupervisor: nil
                )
            }
            _ = try await BrowserValidation.validateEgressURLAsync(
                snapshot.url,
                browserConfig: browserConfig,
                mediaConfig: mediaConfig,
                llmServerURLs: llmServerURLs,
                extraAllowlistedOrigins: allowlistedOrigins,
                egressSupervisor: nil
            )
            let content = try navigateContent(for: snapshot, includeScreenshotRequested: includeScreenshot)
            return .success(content, callID: input.callID)
        } catch let browserError as BrowserError {
            return .failure(browserError.localizedDescription, callID: input.callID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
    }

    /// Encodes a snapshot as a unified navigate envelope with follow-up hints.
    private func navigateContent(for snapshot: BrowserSnapshot, includeScreenshotRequested: Bool = false) throws -> String {
        var notes: [String] = []
        if snapshot.authRequired {
            notes.append(
                "Page requires authentication (auth_required). Escalate to human login by re-navigating with headed=true; "
                    + "never re-fetch with credentials or invent credentials."
            )
        }
        if !snapshot.downloads.isEmpty {
            notes.append("Downloads are manifest-only; no file was written to the host.")
        }
        // Requested-but-absent captures stay honest: the turn records that
        // pixels were withheld (over budget or unavailable) instead of
        // silently rendering text as if vision had been served.
        var screenshotHash = snapshot.screenshotHash
        var screenshotDataURL = snapshot.screenshotDataURL
        // Text-snapshot-primary plus VisionGate: an unrequested capture never
        // reaches a text-only turn even when the gateway returns one.
        if !includeScreenshotRequested {
            screenshotDataURL = nil
            screenshotHash = nil
        } else if screenshotDataURL == nil {
            notes.append("Screenshot requested but unavailable (over budget or capture failed); text snapshot carries the page content.")
            screenshotHash = nil
        }
        // Bounded captures live in memory for this turn only: the envelope carries the transient
        // data URL while durable history keeps only the hash (`strippedForPersistence`).
        if let dataURL = screenshotDataURL,
           let bytes = BrowserBridgeParsing.screenshotBytes(from: dataURL),
           BrowserScreenshotPolicy.isWithinBudget(byteCount: bytes.count)
        {
            screenshotHash = screenshotHash ?? BrowserScreenshotPolicy.auditHash(for: bytes)
        } else if screenshotDataURL != nil {
            screenshotDataURL = nil
            screenshotHash = nil
        }
        let note = notes.isEmpty ? nil : notes.joined(separator: " ")
        let envelope = BrowserNavigateEnvelope(
            url: snapshot.url,
            title: snapshot.title,
            text: snapshot.text,
            refs: snapshot.refs,
            truncated: snapshot.truncated,
            authRequired: snapshot.authRequired,
            downloads: snapshot.downloads,
            redirectChain: snapshot.redirectChain,
            screenshotHash: screenshotHash,
            screenshotDataURL: screenshotDataURL,
            note: note
        )
        return try ToolEnvelopeEncoding.encode(envelope)
    }
}

/// Approval-gated `browser.act` tool performing one validated action.
public struct BrowserActTool: Tool, Sendable {
    /// Stable tool name referenced by the LLM and memory.
    public let name = "browser.act"
    /// When the LLM should use this tool.
    /// Kept to two lines so the composed prompt stays within budget across the full registry.
    public let description =
        "Runs one validated action (click/fill/select/press/scroll) on a browser.navigate ref plus URL; "
            + "fill/select need text, press accepts key (Enter), scroll accepts direction (down/up/top/bottom or pixel count). Approval-gated. "
            + "Act URLs are SSRF-guarded like navigation: loopback, link-local, metadata, and private ranges stay denied."
    /// Function-calling contract for `action`, `ref`, optional `text`, and `url`.
    public let inputSchema =
        JSONSchema(
            rawValue: """
            {
              "type": "object",
              "properties": {
                "action": {
                  "type": "string",
                  "enum": ["click", "fill", "select", "press", "scroll"],
                  "description": "Single action: click, fill, select, press, or scroll"
                },
                "ref": {
                  "type": "string",
                  "description": "Snapshot element ref from browser.navigate (e.g. e12; integer 12 coerces via decoder)"
                },
                "text": {
                  "type": "string",
                  "description": "Value for fill/select, key for press (e.g. Enter), or direction for scroll (down, up, top, bottom, or pixel count)"
                },
                "url": {
                  "type": "string",
                  "description": "Snapshot page URL the ref came from"
                }
              },
              "required":["action","ref","url"],
              "additionalProperties": false
            }
            """
        )
    /// Gated: acting changes web state and always prompts without a trust grant.
    public let permissionLevel = PermissionLevel.requiresApproval
    /// Network-derived bytes may carry injected directives, so results enter as labeled data.
    public var contentTrustLevel: ContentTrustLevel {
        .untrustedExternal
    }

    /// Playwright gateway (subprocess bridge by default, stub in tests).
    private let gateway: any BrowserPlaywrightGateway
    /// Allowlisted origin and host patterns exempted from SSRF refusals.
    private let allowlistedOrigins: Set<String>
    /// Browser policy supplying the search origin exemption.
    private let browserConfig: BrowserConfig
    /// Media policy supplying Sonarr/Radarr auto-allowed origins.
    private let mediaConfig: MediaConfig?
    /// Configured model endpoints exempted from the loopback deny.
    private let llmServerURLs: [String]
    /// Outbound egress supervisor screening destination URLs against policy.toml.
    public let egressSupervisor: OutboundEgressSupervisor?

    /// Shared gateway for live-reload reuse so a settings PUT refreshes origins
    /// without dropping an injected test double.
    public var browserGateway: any BrowserPlaywrightGateway {
        gateway
    }

    /// Creates an act tool. Delegates to the designated config-bound init with a neutral policy,
    /// matching the navigate tool: the explicit set stays the only exemption source here.
    public init(
        gateway: any BrowserPlaywrightGateway? = nil,
        allowlistedOrigins: Set<String> = [],
        egressSupervisor: OutboundEgressSupervisor? = nil
    ) {
        self.init(
            gateway: gateway,
            browserConfig: BrowserConfig(searxngURL: ""),
            mediaConfig: nil,
            llmServerURLs: [],
            allowlistedOrigins: allowlistedOrigins,
            egressSupervisor: egressSupervisor
        )
    }

    /// Creates an act tool bound to the configured exemption set.
    public init(
        gateway: any BrowserPlaywrightGateway? = nil,
        browserConfig: BrowserConfig,
        mediaConfig: MediaConfig? = nil,
        llmServerURLs: [String] = [],
        allowlistedOrigins: Set<String> = [],
        egressSupervisor: OutboundEgressSupervisor? = nil
    ) {
        self.browserConfig = browserConfig
        self.mediaConfig = mediaConfig
        self.llmServerURLs = llmServerURLs
        self.allowlistedOrigins = allowlistedOrigins
        self.egressSupervisor = egressSupervisor
        self.gateway = gateway ?? SubprocessPlaywrightGateway(
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            llmServerURLs: llmServerURLs,
            allowlistedOrigins: allowlistedOrigins,
            egressSupervisor: egressSupervisor
        )
    }

    /// Validates and performs (or previews under dry-run) one action.
    public func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput {
        let args: BrowserActArgs
        do {
            args = try JSONDecoder().decode(BrowserActArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            return .failure(
                "Invalid browser.act arguments: expected {\"action\": \"click|fill|select|press|scroll\", \"ref\": \"e12\", \"url\": \"https://example.com\"}.",
                callID: input.callID
            )
        }

        // Pure shape checks run here for both paths; the stateful URL gate
        // lives in exactly one place per path below so a one-shot grant is
        // consumed once per call, never twice.
        let validatedAction: BrowserActAction
        do {
            validatedAction = try BrowserValidation.validateAction(args.trimmedAction)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
        do {
            // Integer-shaped refs already map to eNN during decoding; the
            // shape check here rejects invented selectors before any grant
            // or subprocess use.
            _ = try BrowserValidation.validateRef(args.trimmedRef)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
        do {
            _ = try BrowserValidation.validateActText(action: validatedAction, text: args.text)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
        // Act previews stay local: the would-act envelope returns without reaching the gateway, so
        // no browser context is opened and the gateway exposes no dry-run overload to go stale.
        if context.dryRun {
            do {
                let url = try BrowserValidation.validateURL(
                    args.trimmedURL,
                    browserConfig: browserConfig,
                    mediaConfig: mediaConfig,
                    llmServerURLs: llmServerURLs,
                    extraAllowlistedOrigins: allowlistedOrigins
                )
                let dryRef = try BrowserValidation.validateRef(args.trimmedRef)
                _ = try BrowserValidation.validateActText(action: validatedAction, text: args.text)
                return dryRunOutput(
                    action: validatedAction,
                    ref: dryRef,
                    url: url,
                    callID: input.callID
                )
            } catch {
                return .failure(error.localizedDescription, callID: input.callID)
            }
        }
        do {
            // Single stateful policy gate lives in the gateway's session-aware path, reached
            // dynamically through the protocol requirement so every bridge honors the calling
            // session's grants.
            _ = try await BrowserValidation.validateURLAsync(
                args.trimmedURL,
                browserConfig: browserConfig,
                mediaConfig: mediaConfig,
                llmServerURLs: llmServerURLs,
                extraAllowlistedOrigins: allowlistedOrigins,
                egressSupervisor: nil
            )
            let text = try BrowserValidation.validateActText(action: validatedAction, text: args.text)
            let ref = try BrowserValidation.validateRef(args.trimmedRef)
            let result = try await gateway.act(
                action: validatedAction,
                ref: ref,
                text: text,
                url: args.trimmedURL,
                sessionID: context.sessionID
            )
            _ = try await BrowserValidation.validateEgressURLAsync(
                result.url,
                browserConfig: browserConfig,
                mediaConfig: mediaConfig,
                llmServerURLs: llmServerURLs,
                extraAllowlistedOrigins: allowlistedOrigins,
                egressSupervisor: nil
            )
            let content = try actContent(for: result)
            return .success(content, callID: input.callID)
        } catch let browserError as BrowserError {
            return .failure(browserError.localizedDescription, callID: input.callID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
    }

    /// Builds the dry-run preview without touching the browser.
    private func dryRunOutput(action: BrowserActAction, ref: String, url: String, callID: String) -> ToolOutput {
        let envelope = BrowserActEnvelope(
            url: url,
            action: action.rawValue,
            ref: ref,
            ok: false,
            dryRun: true,
            downloads: [],
            note: "Dry run: would perform '\(action.rawValue)' on \(ref) at \(url) without acting."
        )
        do {
            let content = try ToolEnvelopeEncoding.encode(envelope)
            return .success(content, callID: callID)
        } catch {
            return .failure(error.localizedDescription, callID: callID)
        }
    }

    /// Encodes an act result with the manifest-only download note.
    private func actContent(for result: BrowserActResult) throws -> String {
        let note: String? = result.downloads.isEmpty
            ? nil
            : "Downloads are manifest-only; no file was written to the host."
        let envelope = BrowserActEnvelope(
            url: result.url,
            action: result.action.rawValue,
            ref: result.ref,
            ok: true,
            dryRun: false,
            downloads: result.downloads,
            note: note,
            title: result.title,
            text: result.text,
            refs: result.refs
        )
        return try ToolEnvelopeEncoding.encode(envelope)
    }
}

/// Factory for the interactive browser tools.
public enum BrowserTools {
    /// Tool names in registration order.
    public static let toolNames = ["browser.navigate", "browser.act"]

    /// Builds the browser tools sharing one gateway.
    /// Delegates to the config-bound builder with a neutral policy so one
    /// construction site owns the shared gateway plus navigate/act assembly.
    public static func makeTools(
        gateway: any BrowserPlaywrightGateway? = nil,
        allowlistedOrigins: Set<String> = [],
        egressSupervisor: OutboundEgressSupervisor? = nil
    ) -> [any Tool] {
        makeTools(
            gateway: gateway,
            browserConfig: BrowserConfig(searxngURL: ""),
            mediaConfig: nil,
            llmServerURLs: [],
            allowlistedOrigins: allowlistedOrigins,
            egressSupervisor: egressSupervisor
        )
    }

    /// Builds the browser tools sharing one gateway bound to the configured exemption set.
    public static func makeTools(
        gateway: any BrowserPlaywrightGateway? = nil,
        browserConfig: BrowserConfig,
        mediaConfig: MediaConfig? = nil,
        llmServerURLs: [String] = [],
        allowlistedOrigins: Set<String> = [],
        egressSupervisor: OutboundEgressSupervisor? = nil
    ) -> [any Tool] {
        let shared: any BrowserPlaywrightGateway = gateway ?? SubprocessPlaywrightGateway(
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            llmServerURLs: llmServerURLs,
            allowlistedOrigins: allowlistedOrigins,
            egressSupervisor: egressSupervisor
        )
        let navigate: any Tool = BrowserNavigateTool(
            gateway: shared,
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            llmServerURLs: llmServerURLs,
            allowlistedOrigins: allowlistedOrigins,
            egressSupervisor: egressSupervisor
        )
        let act: any Tool = BrowserActTool(
            gateway: shared,
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            llmServerURLs: llmServerURLs,
            allowlistedOrigins: allowlistedOrigins,
            egressSupervisor: egressSupervisor
        )
        return [navigate, act]
    }

    /// Registers the browser tools, replacing same-named entries.
    /// Delegates to the config-bound register with a neutral policy so one
    /// site owns registration.
    public static func register(
        on bus: ToolBus,
        gateway: any BrowserPlaywrightGateway? = nil,
        allowlistedOrigins: Set<String> = [],
        egressSupervisor: OutboundEgressSupervisor? = nil
    ) async {
        await register(
            on: bus,
            gateway: gateway,
            browserConfig: BrowserConfig(searxngURL: ""),
            mediaConfig: nil,
            llmServerURLs: [],
            allowlistedOrigins: allowlistedOrigins,
            egressSupervisor: egressSupervisor
        )
    }

    /// Registers the config-bound browser tools, replacing same-named entries.
    public static func register(
        on bus: ToolBus,
        gateway: any BrowserPlaywrightGateway? = nil,
        browserConfig: BrowserConfig,
        mediaConfig: MediaConfig? = nil,
        llmServerURLs: [String] = [],
        allowlistedOrigins: Set<String> = [],
        egressSupervisor: OutboundEgressSupervisor? = nil
    ) async {
        for tool in makeTools(
            gateway: gateway,
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            llmServerURLs: llmServerURLs,
            allowlistedOrigins: allowlistedOrigins,
            egressSupervisor: egressSupervisor
        ) {
            await bus.register(tool: tool)
        }
    }
}
