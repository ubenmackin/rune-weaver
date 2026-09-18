// Rune Weaver Tools — Interactive browser navigation plus unified act.
//
// `browser.navigate` (read-only open returning distilled text plus snapshot
// refs) and `browser.act` (approval-gated single validated action against one
// ref plus its snapshot URL) share one subprocess gateway but never share
// state: each call opens a fresh isolated context with no persistent profile,
// no stored credentials, and no cross-task storage, then closes it before
// returning. The unified act surface validates one verb (click, fill, select,
// press, scroll) plus integer-or-string ref aliases against the snapshot URL,
// parking every call with target plus URL. Screenshots are an opt-in
// `includeScreenshot` flag (default false) advertised only to vision-capable
// models and stripped from text-only history, with captures held in memory
// for the turn and only a content hash persisted.

import Foundation
import RuneWeaverCore

/// Arguments for the `browser.navigate` tool.
public struct BrowserNavigateArgs: Sendable, Equatable, Decodable {
    /// Page URL to open.
    public let url: String
    /// Whether to capture an opt-in screenshot for vision models.
    public let includeScreenshot: Bool

    /// Memberwise initializer.
    public init(url: String, includeScreenshot: Bool = false) {
        self.url = url
        self.includeScreenshot = includeScreenshot
    }

    private enum CodingKeys: String, CodingKey {
        case url
        case page
        case pageUrl
        case pageURL = "page_url"
        case includeScreenshot
        case screenshot
        case includeScreenshotSnake = "include_screenshot"
    }

    /// Decodes arguments, accepting every documented URL alias plus screenshot aliases.
    /// - Parameter decoder: Decoder for the arguments document.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let direct = try container.decodeIfPresent(String.self, forKey: .url), !direct.isEmpty {
            url = direct
        } else if let page = try container.decodeIfPresent(String.self, forKey: .page), !page.isEmpty {
            url = page
        } else if let camel = try container.decodeIfPresent(String.self, forKey: .pageUrl), !camel.isEmpty {
            url = camel
        } else if let snake = try container.decodeIfPresent(String.self, forKey: .pageURL), !snake.isEmpty {
            url = snake
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
        let screenshotFlag: Bool? = (try? container.decodeIfPresent(Bool.self, forKey: .screenshot)) ?? nil
        let snakeFlag: Bool? = (try? container.decodeIfPresent(Bool.self, forKey: .includeScreenshotSnake)) ?? nil
        includeScreenshot = primaryFlag ?? screenshotFlag ?? snakeFlag ?? false
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
        case type
        case kind
        case ref
        case target
        case selector
        case element
        case elementRef
        case text
        case value
        case input
        case key
        case url
        case page
        case pageUrl
        case pageURL = "page_url"
    }

    /// Decodes arguments, accepting every documented alias plus integer refs.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let direct = try container.decodeIfPresent(String.self, forKey: .action), !direct.isEmpty {
            action = direct
        } else if let type = try container.decodeIfPresent(String.self, forKey: .type), !type.isEmpty {
            action = type
        } else if let kind = try container.decodeIfPresent(String.self, forKey: .kind), !kind.isEmpty {
            action = kind
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
            ?? container.decodeIfPresent(String.self, forKey: .value)
            ?? container.decodeIfPresent(String.self, forKey: .input)
            ?? container.decodeIfPresent(String.self, forKey: .key)
        if let direct = try container.decodeIfPresent(String.self, forKey: .url), !direct.isEmpty {
            url = direct
        } else if let page = try container.decodeIfPresent(String.self, forKey: .page), !page.isEmpty {
            url = page
        } else if let camel = try container.decodeIfPresent(String.self, forKey: .pageUrl), !camel.isEmpty {
            url = camel
        } else if let snake = try container.decodeIfPresent(String.self, forKey: .pageURL), !snake.isEmpty {
            url = snake
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

    /// Decodes the element ref from string or integer aliases.
    private static func decodeRef(from container: KeyedDecodingContainer<CodingKeys>) throws -> String {
        // Each alias probes strings with `try?` so an integer-shaped value
        // (for example `{"ref": 12}`) does not throw a type mismatch before
        // the integer pass maps it to snapshot shape (`"e12"`). Bare numeric
        // strings normalize through the shared validator so `"12"` behaves
        // like `12` under the `ref: [string, integer]` schema.
        for key in [CodingKeys.ref, .target, .selector, .element, .elementRef] {
            if let direct = try? container.decodeIfPresent(String.self, forKey: key),
               !direct.isEmpty
            {
                let trimmed = direct.trimmingCharacters(in: .whitespacesAndNewlines)
                return BrowserValidation.normalizedRef(trimmed.isEmpty ? direct : trimmed)
            }
        }
        for key in [CodingKeys.ref, .target, .selector, .element, .elementRef] {
            if let number = try? container.decodeIfPresent(Int.self, forKey: key) {
                return "e\(number)"
            }
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
    /// Shared wire fields (`finalUrl`, redirect chain and count,
    /// `authRequired`, text snapshot, screenshot hash and data URL) decode
    /// single-sourced through `BrowserNavigateResult` (backed by
    /// `BrowserNavigateWire`); only envelope-only keys decode locally so the
    /// shape cannot drift between tool output and display/audit.
    /// - Parameter decoder: Decoder for the envelope document.
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
    /// Screenshot stripping shares the display/audit contract: the shared
    /// view drops the data URL while keeping the hash, and the envelope
    /// mirrors that outcome so persisted tool output and history agree.
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

    /// Parses a raw tool output document, returning nil for non-browser payloads.
    /// Shares the `BrowserNavigateResult.parse` gate so tool output and
    /// display agree on what counts as a browser document.
    /// - Parameter content: Raw JSON tool output.
    /// - Returns: Decoded envelope, or nil when the payload is not browser JSON.
    public static func parse(_ content: String) -> BrowserNavigateEnvelope? {
        guard BrowserNavigateResult.parse(content) != nil else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BrowserNavigateEnvelope.self, from: data)
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

    /// Creates an act envelope.
    public init(
        url: String,
        action: String,
        ref: String,
        ok: Bool = true,
        dryRun: Bool = false,
        downloads: [BrowserDownloadManifest] = [],
        note: String? = nil
    ) {
        self.url = url
        self.action = action
        self.ref = ref
        self.ok = ok
        self.dryRun = dryRun
        self.downloads = downloads
        self.note = note
    }
}

/// Read-only `browser.navigate` tool over the isolated Playwright bridge.
public struct BrowserNavigateTool: Tool, Sendable {
    /// Stable tool name referenced by the LLM and memory.
    public let name = "browser.navigate"
    /// When the LLM should use this tool.
    /// Kept to one line so the composed prompt stays within budget across the full registry.
    public let description =
        "Opens a URL in a fresh isolated context; returns text plus refs (e.g. e12) for browser.act. "
            + "Auth walls escalate to human login; downloads are manifest-only."
    /// Function-calling contract for `url` (plus accepted aliases) and the screenshot opt-in.
    /// Every decoder alias is advertised so a compliant validator accepts
    /// exactly what the decoder handles.
    public let inputSchema =
        JSONSchema(
            rawValue: #"{"type":"object","properties":{"url":{"type":"string","description":"http(s) page URL "#
                + #"to open"},"page":{"type":"string","description":"Alias for url"}, "#
                + #""pageUrl":{"type":"string","description":"Alias for url"}, "#
                + #""page_url":{"type":"string","description":"Alias for url"}, "#
                + #""includeScreenshot":{"type":"boolean","description":"Capture "#
                + #"a downscaled JPEG screenshot for vision models "#
                + #"(default false; vision models only)","default":false}, "#
                + #""screenshot":{"type":"boolean","description":"Alias for includeScreenshot", "#
                + #""default":false},"include_screenshot":{"type":"boolean", "#
                + #""description":"Alias for includeScreenshot"}}, "#
                + #""anyOf":[{"required":["url"]}, {"required":["page"]}, "#
                + #"{"required":["pageUrl"]}, {"required":["page_url"]}],"#
                + #""additionalProperties":false}"#
        )
    /// Always allowed: navigation distills without changing web state.
    public let permissionLevel = PermissionLevel.readOnly

    /// Playwright gateway (subprocess bridge by default, stub in tests).
    private let gateway: any BrowserPlaywrightGateway

    /// Creates a navigate tool.
    /// - Parameter gateway: Playwright gateway. Defaults to the `python3` subprocess bridge.
    public init(gateway: (any BrowserPlaywrightGateway)? = nil) {
        self.gateway = gateway ?? SubprocessPlaywrightGateway()
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
        let url: String
        do {
            url = try await BrowserValidation.validateURLAsync(args.trimmedURL)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
        // Defense in depth: the raw flag and the policy parser must agree;
        // either true requests a capture so a renamed key cannot silently
        // drop a vision-model opt-in.
        let includeScreenshot = args.includeScreenshot
            || BrowserScreenshotPolicy.includeScreenshotRequested(argumentsJSON: input.argumentsJSON)
        do {
            let snapshot = try await gateway.navigate(url: url, includeScreenshot: includeScreenshot, dryRun: context.dryRun)
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
                "Page requires authentication (auth_required). Escalate to a human login via browser.navigate; "
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
        // Bounded captures live in memory for this turn only: the envelope
        // carries the transient data URL while durable history keeps only the
        // hash (`strippedForPersistence`). Pixels are never written to disk,
        // so no per-navigate temp directory accumulates; the helper already
        // downscales to the 1280px longest edge (`targetCaptureSize`) and
        // re-encodes to bounded JPEG, and this budget check is a fail-closed
        // last resort for still-over-budget payloads.
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
    /// Kept to one line so the composed prompt stays within budget across the full registry.
    public let description =
        "Runs one validated action (click/fill/select/press/scroll) on a browser.navigate ref plus URL; "
            + "fill/select need text, approval-gated, manifest-only downloads."
    /// Function-calling contract for `action`, `ref`, optional `text`, and `url`.
    /// Every decoder alias is advertised so a compliant validator accepts
    /// exactly what the decoder handles.
    public let inputSchema =
        JSONSchema(
            rawValue: #"{"type":"object","properties":{"action":{"type":"string", "#
                + #""description":"Single action: click, fill, select, press, or scroll"}, "#
                + #""type":{"type":"string","description":"Alias for action"}, "#
                + #""kind":{"type":"string","description":"Alias for action"}, "#
                + #""ref":{"type":["string","integer"],"description":"Snapshot element ref "#
                + #"from browser.navigate (e.g. e12 or 12)"}, "#
                + #""target":{"type":["string","integer"],"description":"Alias for ref"}, "#
                + #""selector":{"type":["string","integer"],"description":"Alias for ref"}, "#
                + #""element":{"type":["string","integer"],"description":"Alias for ref"}, "#
                + #""elementRef":{"type":["string","integer"],"description":"Alias for ref"}, "#
                + #""text":{"type":"string","description":"Value for fill/select "#
                + #"or key for press (e.g. Enter)"}, "#
                + #""value":{"type":"string","description":"Alias for text"}, "#
                + #""input":{"type":"string","description":"Alias for text"}, "#
                + #""key":{"type":"string","description":"Alias for text (press key)"}, "#
                + #""url":{"type":"string","description":"Snapshot page URL the ref "#
                + #"came from"}, "#
                + #""page":{"type":"string","description":"Alias for url"}, "#
                + #""pageUrl":{"type":"string","description":"Alias for url"}, "#
                + #""page_url":{"type":"string","description":"Alias for url"}}, "#
                + #""allOf":[{"anyOf":[{"required":["action"]}, "#
                + #"{"required":["type"]}, {"required":["kind"]}]}, "#
                + #"{"anyOf":[{"required":["ref"]}, {"required":["target"]}, "#
                + #"{"required":["selector"]}, {"required":["element"]}, "#
                + #"{"required":["elementRef"]}]}, "#
                + #"{"anyOf":[{"required":["url"]}, {"required":["page"]}, "#
                + #"{"required":["pageUrl"]}, {"required":["page_url"]}]}],"#
                + #""additionalProperties":false}"#
        )
    /// Gated: acting changes web state and always prompts without a trust grant.
    public let permissionLevel = PermissionLevel.requiresApproval

    /// Playwright gateway (subprocess bridge by default, stub in tests).
    private let gateway: any BrowserPlaywrightGateway

    /// Creates an act tool.
    /// - Parameter gateway: Playwright gateway. Defaults to the `python3` subprocess bridge.
    public init(gateway: (any BrowserPlaywrightGateway)? = nil) {
        self.gateway = gateway ?? SubprocessPlaywrightGateway()
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
        let action: BrowserActAction
        do {
            action = try BrowserValidation.validateAction(args.trimmedAction)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
        let ref: String
        do {
            // Integer-shaped refs already map to eNN during decoding; the
            // shape check here rejects invented selectors before any grant
            // or subprocess use.
            ref = try BrowserValidation.validateRef(args.trimmedRef)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
        let url: String
        do {
            url = try await BrowserValidation.validateURLAsync(args.trimmedURL)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
        // Raw text passes through untouched when nil so optional-text
        // actions distinguish omitted from blank; the validator enforces
        // required-versus-forbidden per action.
        let rawText: String? = args.text
        let text: String?
        do {
            text = try BrowserValidation.validateActText(action: action, text: rawText)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
        // Act previews stay local: the would-act envelope returns without
        // reaching the gateway, so no browser context is opened and the
        // gateway exposes no dry-run overload to go stale.
        if context.dryRun {
            return dryRunOutput(action: action, ref: ref, url: url, callID: input.callID)
        }
        do {
            let result = try await gateway.act(action: action, ref: ref, text: text, url: url)
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
            note: note
        )
        return try ToolEnvelopeEncoding.encode(envelope)
    }
}

/// Factory for the interactive browser tools.
public enum BrowserTools {
    /// Tool names in registration order.
    public static let toolNames = ["browser.navigate", "browser.act"]

    /// Builds the browser tools sharing one gateway.
    public static func makeTools(gateway: (any BrowserPlaywrightGateway)? = nil) -> [any Tool] {
        let shared: any BrowserPlaywrightGateway = gateway ?? SubprocessPlaywrightGateway()
        let navigate: any Tool = BrowserNavigateTool(gateway: shared)
        let act: any Tool = BrowserActTool(gateway: shared)
        return [navigate, act]
    }

    /// Registers the browser tools, replacing same-named entries.
    public static func register(on bus: ToolBus, gateway: (any BrowserPlaywrightGateway)? = nil) async {
        for tool in makeTools(gateway: gateway) {
            await bus.register(tool: tool)
        }
    }
}
