// Rune Weaver Tools — Isolated Playwright bridge for browser automation.
//
// `browser.navigate` (read-only open returning distilled text plus snapshot
// refs) and `browser.act` (approval-gated single validated action against one
// ref plus its snapshot URL) share one subprocess gateway but never share
// state: each call opens a fresh isolated context with no persistent profile,
// no stored credentials, and no cross-task storage, then closes it before
// returning. Act re-navigates to the snapshot URL and re-resolves the ref, so
// no handle or cookie outlives the call and refs never cross pages. Downloads
// stay manifest-only and never reach the host.
//
// The helper source lives single-source in `BrowserPlaywrightScript.swift`
// (ordered segments concatenating atomically) alongside the subprocess I/O
// and payload parsing here, so the screenshot budget and envelope shapes
// cannot drift across files; deny behavior is pinned single-source by the
// shared web-safety fixture. Fail-closed validation rejects non-web schemes
// and SSRF targets before the helper spawns; screenshots are opt-in per
// navigate call, downscaled to a 1280px longest edge and re-encoded to bounded
// JPEG under 500KB held in memory for the turn only (never written to disk),
// persisting just a content hash in the audit trail. Refs keep the `eNN`
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
    public static func validateURL(_ url: String) throws -> String {
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
        // Browser flows never dial local origins, so the empty exemption holds
        // the fail-closed line for every loopback and LAN spelling with no
        // config to forge; shares the single SSRF range table with the web
        // and API tools.
        if let refusal = ApiSSRFGuard.denyReason(for: trimmed, allowlistedOrigins: []) {
            throw BrowserError.invalidURL("Invalid URL: \(refusal)")
        }
        return trimmed
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
            return trimmed.isEmpty ? nil : trimmed
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
}

public extension BrowserPlaywrightGateway {
    /// Convenience honoring the text-only default (no screenshot).
    /// - Parameter url: Already-validated http(s) URL.
    /// - Returns: Bounded snapshot without screenshot bytes.
    func navigate(url: String) async throws -> BrowserSnapshot {
        try await navigate(url: url, includeScreenshot: false)
    }
}

/// Subprocess gateway shelling out to the `python3` Playwright helper.
public struct SubprocessPlaywrightGateway: BrowserPlaywrightGateway, Sendable {
    /// Environment variable overriding the Python executable.
    public static let pythonEnvVar = "RUNEWEAVER_PYTHON_BIN"

    /// Explicit Python executable path, if any.
    public let pythonExecutable: String?
    /// Seconds before the helper is terminated. Defaults to the shared container budget.
    public let timeoutSeconds: TimeInterval
    /// Maximum stdout bytes retained. Defaults to the shared detonation bound.
    public let maxOutputBytes: Int

    /// Creates a subprocess gateway.
    public init(
        pythonExecutable: String? = nil,
        timeoutSeconds: TimeInterval = ContainerMachineManager.defaultProcessTimeoutSeconds,
        maxOutputBytes: Int = ContainerMachineManager.maxProcessOutputBytes
    ) {
        if let pythonExecutable, !pythonExecutable.isEmpty {
            self.pythonExecutable = pythonExecutable
        } else if let configured = ProcessInfo.processInfo.environment[Self.pythonEnvVar] {
            if configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.pythonExecutable = nil
            } else {
                self.pythonExecutable = configured
            }
        } else {
            self.pythonExecutable = nil
        }
        self.timeoutSeconds = timeoutSeconds
        self.maxOutputBytes = maxOutputBytes
    }

    /// Navigates in a fresh isolated context and returns a bounded snapshot.
    public func navigate(url: String, includeScreenshot: Bool = false) async throws -> BrowserSnapshot {
        let validated = try BrowserValidation.validateURL(url)
        var payload: [String: Any] = ["op": "navigate", "url": validated]
        if includeScreenshot {
            payload["includeScreenshot"] = true
        }
        let data = try await run(payload: payload)
        return try BrowserBridgeParsing.parseSnapshotPayload(data, fallbackURL: validated)
    }

    /// Re-navigates in a fresh isolated context and performs one action.
    public func act(action: BrowserActAction, ref: String, text: String?, url: String) async throws -> BrowserActResult {
        let validatedURL = try BrowserValidation.validateURL(url)
        let validatedRef = try BrowserValidation.validateRef(ref)
        let validatedText = try BrowserValidation.validateActText(action: action, text: text)
        var payload: [String: Any] = [
            "op": "act",
            "url": validatedURL,
            "action": action.rawValue,
            "ref": validatedRef
        ]
        if let validatedText {
            payload["text"] = validatedText
        }
        let data = try await run(payload: payload)
        return try BrowserBridgeParsing.parseActPayload(data, action: action, ref: validatedRef, fallbackURL: validatedURL)
    }

    /// Runs the helper once with the given request document.
    func run(payload: [String: Any]) async throws -> Data {
        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw BrowserError.bridgeFailed("Could not encode browser request: \(error.localizedDescription)")
        }
        return try await BrowserSubprocessIO.runBridgeIO(
            scriptSource: BrowserPlaywrightScript.source,
            payload: body,
            pythonExecutable: pythonExecutable,
            timeoutSeconds: timeoutSeconds,
            maxOutputBytes: maxOutputBytes
        )
    }
}

/// Explicit stub used when Playwright is unavailable and in tests.
public struct StubBrowserGateway: BrowserPlaywrightGateway, Sendable {
    /// Message surfaced instead of the marketplace canned stubs.
    public let message: String

    /// Creates a stub gateway.
    /// - Parameter message: Explicit missing-dependency message.
    public init(message: String = "Playwright is not installed (python3 -m pip install playwright && python3 -m playwright install chromium)") {
        self.message = message
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

/// Pure JSON parsing for the Playwright bridge payloads.
public enum BrowserBridgeParsing: Sendable {
    /// Bridge `navigate` response shape.
    struct NavigateResponse: Decodable {
        /// Whether the operation succeeded.
        let ok: Bool
        /// Error detail when `ok` is false.
        let error: String?
        /// Final URL after redirects.
        let url: String?
        /// Page title.
        let title: String?
        /// Distilled visible text.
        let text: String?
        /// Snapshot refs.
        let refs: [BrowserElementRef]?
        /// Login-wall signal.
        let authRequired: Bool?
        /// Manifest-only downloads.
        let downloads: [BrowserDownloadManifest]?
        /// Ordered redirect chain (typed steps or plain URL strings).
        let redirectChain: [BridgeRedirectEntry]?
        /// Explicit redirect count, when reported.
        let redirectCount: Int?
        /// Screenshot payload: data URL or raw base64 JPEG.
        let screenshot: String?
        /// Precomputed audit hash, when the helper supplies one.
        let screenshotHash: String?
        /// Explicit data URL variant.
        let screenshotDataURL: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: NavigateResponseKeys.self)
            ok = try container.decode(Bool.self, forKey: .ok)
            error = try container.decodeIfPresent(String.self, forKey: .error)
            url = try container.decodeIfPresent(String.self, forKey: .url)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            text = try container.decodeIfPresent(String.self, forKey: .text)
            refs = try container.decodeIfPresent([BrowserElementRef].self, forKey: .refs)
            authRequired = try container.decodeIfPresent(Bool.self, forKey: .authRequired)
            downloads = try container.decodeIfPresent([BrowserDownloadManifest].self, forKey: .downloads)
            // Chain tolerates typed steps, plain strings, and the `redirects` alias.
            // Single-sourced through `BrowserNavigateWire` so bridge parsing
            // shares one alias table with tool output and display; mismatches
            // are logged there instead of silently swallowed.
            let typedChain: [BridgeRedirectEntry]? = BrowserNavigateWire.decodeFirst(
                container,
                keys: [.redirectChain, .redirectChainSnake, .redirects]
            )
            var chain: [BridgeRedirectEntry]? = typedChain
            if chain == nil {
                let strings: [String]? = BrowserNavigateWire.decodeFirst(
                    container,
                    keys: [.redirectChain, .redirectChainSnake, .redirects]
                )
                if let strings {
                    chain = strings.map { BridgeRedirectEntry(url: $0, status: nil) }
                }
            }
            redirectChain = chain
            redirectCount = BrowserNavigateWire.decodeFirst(
                container,
                keys: [.redirectCount, .redirectCountSnake]
            )
            screenshot = try container.decodeIfPresent(String.self, forKey: .screenshot)
            screenshotHash = BrowserNavigateWire.decodeFirst(
                container,
                keys: [.screenshotHash, .screenshotHashSnake]
            )
            screenshotDataURL = try container.decodeIfPresent(String.self, forKey: .screenshotDataURL)
        }
    }

    /// Key set for `NavigateResponse`, kept beside (not inside) the struct
    /// so type nesting stays within the one-level budget.
    private enum NavigateResponseKeys: String, CodingKey {
        case ok
        case error
        case url
        case title
        case text
        case refs
        case authRequired
        case downloads
        case redirectChain
        // Snake-case aliases keep raw values so the case names stay alphanumeric.
        case redirectChainSnake = "redirect_chain"
        case redirects
        case redirectCount
        case redirectCountSnake = "redirect_count"
        case screenshot
        case screenshotHash
        case screenshotHashSnake = "screenshot_hash"
        case screenshotDataURL
    }

    /// One redirect entry tolerating string or object shapes.
    struct BridgeRedirectEntry: Decodable {
        /// Step URL.
        let url: String
        /// HTTP status, when known.
        let status: Int?

        init(url: String, status: Int? = nil) {
            self.url = url
            self.status = status
        }

        init(from decoder: Decoder) throws {
            // Plain strings decode as URL-only steps so older helpers keep working.
            if let single = try? decoder.singleValueContainer().decode(String.self) {
                self.url = single
                self.status = nil
                return
            }
            let container = try decoder.container(keyedBy: BridgeRedirectEntryKeys.self)
            url = try container.decode(String.self, forKey: .url)
            status = try container.decodeIfPresent(Int.self, forKey: .status)
        }
    }

    /// Key set for `BridgeRedirectEntry`, kept beside (not inside) the struct
    /// so type nesting stays within the one-level budget.
    private enum BridgeRedirectEntryKeys: String, CodingKey {
        case url
        case status
    }

    /// Bridge `act` response shape.
    struct ActResponse: Decodable {
        /// Whether the operation succeeded.
        let ok: Bool
        /// Error detail when `ok` is false.
        let error: String?
        /// Final URL after the action.
        let url: String?
        /// Echoed action.
        let action: String?
        /// Echoed ref.
        let ref: String?
        /// Manifest-only downloads.
        let downloads: [BrowserDownloadManifest]?
    }

    /// Decodes a `navigate` payload into a bounded snapshot.
    public static func parseSnapshotPayload(_ data: Data, fallbackURL: String) throws -> BrowserSnapshot {
        let response: NavigateResponse
        do {
            response = try JSONDecoder().decode(NavigateResponse.self, from: data)
        } catch {
            throw BrowserError.decodeFailed(error.localizedDescription)
        }
        guard response.ok else {
            throw classifiedBridgeError(response.error ?? "Browser navigation failed")
        }
        let url = (response.url?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackURL
        let title = response.title ?? ""
        let rawText = response.text ?? ""
        let bounded = BrowserValidation.boundedText(rawText)
        let rawRefs = (response.refs ?? []).filter { BrowserValidation.isValidRef($0.ref) }
        let capped = BrowserValidation.boundedRefs(rawRefs)
        // Chain falls back to a single-step hop so the collapsed-chain UI
        // always has an honest count even when the helper predates reporting.
        let chain: [BrowserRedirectStep] = if let entries = response.redirectChain, !entries.isEmpty {
            entries.map { BrowserRedirectStep(url: $0.url, status: $0.status) }
        } else {
            [BrowserRedirectStep(url: url)]
        }
        let screenshot = normalizedScreenshotDataURL(
            direct: response.screenshotDataURL,
            raw: response.screenshot,
            fallbackHash: response.screenshotHash
        )
        return BrowserSnapshot(
            url: url,
            title: title,
            text: bounded.text,
            refs: capped.refs,
            truncated: bounded.truncated || capped.truncated,
            authRequired: response.authRequired ?? false,
            downloads: response.downloads ?? [],
            redirectChain: chain,
            screenshotDataURL: screenshot.dataURL,
            screenshotHash: screenshot.hash
        )
    }

    /// Normalizes a screenshot payload to a budgeted data URL plus audit hash.
    static func normalizedScreenshotDataURL(
        direct: String?,
        raw: String?,
        fallbackHash: String?
    ) -> (dataURL: String?, hash: String?) {
        let candidate = (direct?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? normalizedDataURL(raw)
        guard let candidate, !candidate.isEmpty else { return (nil, nil) }
        guard let bytes = screenshotBytes(from: candidate) else { return (nil, nil) }
        // Over-budget captures stay text-only: pixels never enter history
        // past the persistence budget.
        guard BrowserScreenshotPolicy.isWithinBudget(byteCount: bytes.count) else { return (nil, nil) }
        let hash = (fallbackHash?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? BrowserScreenshotPolicy.auditHash(for: bytes)
        return (candidate, hash)
    }

    /// Normalizes raw helper screenshot text to a data URL.
    /// Single-sourced through `BrowserNavigateWire` so bridge parsing, tool
    /// output, and display/audit share one screenshot shape.
    /// - Parameter raw: Helper `screenshot` field, if any.
    /// - Returns: Data URL, or nil when absent.
    static func normalizedDataURL(_ raw: String?) -> String? {
        BrowserNavigateWire.normalizedDataURL(raw)
    }

    /// Decodes the bytes behind a data URL for budget and hash checks.
    /// - Parameter dataURL: Candidate data URL.
    /// - Returns: Decoded bytes, or nil when malformed.
    static func screenshotBytes(from dataURL: String) -> Data? {
        guard let comma = dataURL.firstIndex(of: ",") else { return nil }
        let payload = String(dataURL[dataURL.index(after: comma)...])
        guard !payload.isEmpty else { return nil }
        return Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
    }

    /// Decodes an `act` payload into a result.
    public static func parseActPayload(_ data: Data, action: BrowserActAction, ref: String, fallbackURL: String) throws -> BrowserActResult {
        let response: ActResponse
        do {
            response = try JSONDecoder().decode(ActResponse.self, from: data)
        } catch {
            throw BrowserError.decodeFailed(error.localizedDescription)
        }
        guard response.ok else {
            throw classifiedBridgeError(response.error ?? "Browser action failed")
        }
        let url = (response.url?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackURL
        return BrowserActResult(url: url, action: action, ref: ref, downloads: response.downloads ?? [])
    }

    /// Maps helper stderr text to the explicit missing-dependency error when Playwright is absent.
    public static func classifiedBridgeError(_ detail: String) -> BrowserError {
        if detail.contains("Playwright is not installed") || detail.contains("No module named playwright") {
            return .playwrightMissing(detail)
        }
        if detail.contains("Could not launch python3") {
            return .playwrightMissing(detail)
        }
        if detail.contains("SSRF denied") {
            return .invalidURL(detail)
        }
        return .bridgeFailed(detail)
    }
}

/// Runs blocking Playwright subprocess I/O off the async executor.
enum BrowserSubprocessIO {
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
        // so a cancel racing the spawn still finds and kills it.
        let box = BoundedProcessRunner.ProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        // Cancellation after this check still terminates via
                        // the box handler below instead of hanging the budget.
                        if Task.isCancelled {
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        try continuation.resume(returning: runBridgeBlocking(
                            scriptSource: scriptSource,
                            payload: payload,
                            pythonExecutable: pythonExecutable,
                            timeoutSeconds: timeoutSeconds,
                            maxOutputBytes: maxOutputBytes,
                            processBox: box
                        ))
                    } catch is CancellationError {
                        continuation.resume(throwing: CancellationError())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
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
                throw BrowserError.playwrightMissing(
                    "Could not launch python3 for browser automation: \(detail)"
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
                throw BrowserError.playwrightMissing(
                    "Playwright is not installed (python3 -m pip install playwright && python3 -m playwright install chromium)"
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
