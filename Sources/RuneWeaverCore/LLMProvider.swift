// Rune Weaver Core — LLM provider protocols, response streams, and model metadata.

import CryptoKit
import Foundation

/// Describes a model behind an ``LLMProvider``.
public struct ModelInfo: Sendable, Codable, Equatable {
    /// Display name of the model (e.g. `"gemma-4-9b"`).
    public let name: String
    /// Provider identifier (e.g. `"mlx"`, `"openrouter"`).
    public let provider: String
    /// Maximum context window in tokens.
    public let contextLength: Int
    /// Whether the model supports function/tool calling.
    public let supportsTools: Bool
    /// Whether the provider can serve embeddings.
    public let supportsEmbeddings: Bool
    /// Whether the model accepts vision input (screenshots, images).
    public let supportsVision: Bool

    /// Creates model metadata.
    public init(
        name: String,
        provider: String,
        contextLength: Int,
        supportsTools: Bool = true,
        supportsEmbeddings: Bool = false,
        supportsVision: Bool = false
    ) {
        self.name = name
        self.provider = provider
        self.contextLength = contextLength
        self.supportsTools = supportsTools
        self.supportsEmbeddings = supportsEmbeddings
        self.supportsVision = supportsVision
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case provider
        case contextLength
        case supportsTools
        case supportsEmbeddings
        case supportsVision
    }

    /// Decodes metadata, defaulting absent vision flags to text-only.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.provider = try container.decode(String.self, forKey: .provider)
        self.contextLength = try container.decode(Int.self, forKey: .contextLength)
        self.supportsTools = try container.decodeIfPresent(Bool.self, forKey: .supportsTools) ?? true
        self.supportsEmbeddings = try container.decodeIfPresent(Bool.self, forKey: .supportsEmbeddings) ?? false
        self.supportsVision = try container.decodeIfPresent(Bool.self, forKey: .supportsVision) ?? false
    }

    /// Encodes metadata including the vision flag.
    /// - Parameter encoder: Destination encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(provider, forKey: .provider)
        try container.encode(contextLength, forKey: .contextLength)
        try container.encode(supportsTools, forKey: .supportsTools)
        try container.encode(supportsEmbeddings, forKey: .supportsEmbeddings)
        try container.encode(supportsVision, forKey: .supportsVision)
    }
}

/// Decides whether vision payloads may reach the active model.
public enum VisionGate: Sendable {
    /// Placeholder left where an image payload was removed.
    public static let strippedPlaceholder = "[image omitted: text-only model]"

    /// Whether screenshot parameters should be advertised to the model.
    public static func shouldAdvertiseScreenshot(supportsVision: Bool) -> Bool {
        supportsVision
    }

    /// Removes inline image payloads from one text turn.
    /// Matches contiguous base64 plus newline-wrapped chunks (long lines only)
    /// with missing `=` padding and base64url spellings tolerated, so
    /// text-only models never receive leaked pixels through a strict match.
    /// Also strips JSON image payload fields (`imageDataBase64`, `screenshotDataURL`).
    public static func strippedContent(_ content: String) -> String {
        var result = content

        // 1. Data URLs: data:image/jpeg;base64,...
        if result.contains("data:image") {
            if let pattern = try? NSRegularExpression(
                pattern: #"data:image/[a-zA-Z0-9.+\-]+;base64,[A-Za-z0-9+/\-_=]+(?:\r?\n[A-Za-z0-9+/\-_=]{16,})*"#,
                options: []
            ) {
                let range = NSRange(result.startIndex ..< result.endIndex, in: result)
                result = pattern.stringByReplacingMatches(
                    in: result,
                    options: [],
                    range: range,
                    withTemplate: strippedPlaceholder
                )
            }
        }

        // 2. JSON image fields: "imageDataBase64": "..." or "screenshotDataURL": "..."
        // Length-gated so empty values stay untouched and re-stripping stays stable.
        if result.contains("imageDataBase64") || result.contains("screenshotDataURL") {
            if let jsonPattern = try? NSRegularExpression(
                pattern: #"\"(imageDataBase64|screenshotDataURL)\"\s*:\s*\"[^\"]{16,}\""#,
                options: []
            ) {
                let range = NSRange(result.startIndex ..< result.endIndex, in: result)
                result = jsonPattern.stringByReplacingMatches(
                    in: result,
                    options: [],
                    range: range,
                    withTemplate: "\"$1\": \"\(strippedPlaceholder)\""
                )
            }
        }

        return result
    }

    /// Strips vision payloads from history when the model is text-only.
    /// Copies through `withContent` so future `Message` fields survive the stripped path.
    public static func stripMessages(_ messages: [Message], supportsVision: Bool) -> [Message] {
        guard !supportsVision else { return messages }
        return messages.map { message in
            let stripped = strippedContent(message.content)
            guard stripped != message.content else { return message }
            return message.withContent(stripped)
        }
    }
}

/// Budget and handling policy for opt-in browser screenshots.
public enum BrowserScreenshotPolicy: Sendable {
    /// Tool carrying the opt-in flag.
    public static let navigateToolName = "browser.navigate"
    /// Opt-in argument name; absent or invalid decodes as false.
    public static let screenshotParamName = "includeScreenshot"
    /// Longest edge after downscaling, in pixels.
    public static let maxDimension = 1280
    /// Upper bound for the re-encoded JPEG, in bytes.
    public static let maxByteCount = 500 * 1024
    /// Fixed capture viewport width keeping opt-in shots at the longest-edge budget.
    public static let captureViewportWidth = 1280
    /// Fixed capture viewport height paired with the width above.
    public static let captureViewportHeight = 800

    /// Scales dimensions to fit within the longest-edge cap.
    /// Shared contract mirrored by the Playwright helper's PIL downscale:
    /// captures are resized so the longest edge is `maxDimension` before
    /// JPEG re-encoding, keeping payloads near the persistence budget.
    public static func scaledDimensions(width: Int, height: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (width, height) }
        let longest = max(width, height)
        guard longest > maxDimension else { return (width, height) }
        let scale = Double(maxDimension) / Double(longest)
        let scaledWidth = max(1, Int((Double(width) * scale).rounded()))
        let scaledHeight = max(1, Int((Double(height) * scale).rounded()))
        return (scaledWidth, scaledHeight)
    }

    /// Target capture size for a source viewport, applying the longest-edge cap.
    /// - Parameters:
    ///   - width: Source viewport width in pixels.
    ///   - height: Source viewport height in pixels.
    /// - Returns: Downscaled dimensions honoring `maxDimension`.
    public static func targetCaptureSize(width: Int, height: Int) -> (width: Int, height: Int) {
        scaledDimensions(width: width, height: height)
    }

    /// Whether an encoded capture fits the persistence budget.
    /// - Parameter byteCount: Encoded JPEG size in bytes.
    /// - Returns: True when the capture may be held in memory for the turn only.
    public static func isWithinBudget(byteCount: Int) -> Bool {
        byteCount >= 0 && byteCount <= maxByteCount
    }

    /// Whether the navigate arguments request a screenshot.
    /// Checks the canonical flag plus `screenshot`/`include_screenshot`
    /// aliases so renamed keys cannot silently drop a vision opt-in.
    public static func includeScreenshotRequested(argumentsJSON: String) -> Bool {
        guard let data = argumentsJSON.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: []),
              let object = parsed as? [String: Any]
        else { return false }
        for key in [screenshotParamName, "screenshot", "include_screenshot"] where (object[key] as? Bool) == true {
            return true
        }
        return false
    }

    /// Content identifier for the audit trail (SHA-256, never pixels).
    /// Matches `PluginSecurity.calculateDirectoryHash` strength so audit
    /// hashes stay collision-resistant.
    public static func auditHash(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// One step in a browser navigation redirect chain.
public struct BrowserRedirectStep: Sendable, Codable, Equatable {
    /// URL visited in this step.
    public let url: String
    /// HTTP status for this step, when known.
    public let status: Int?

    /// Creates a redirect step.
    public init(url: String, status: Int? = nil) {
        self.url = url
        self.status = status
    }
}

/// Single-source wire helpers for the `browser.navigate` document shared by
/// tool output (`BrowserNavigateEnvelope` in RuneWeaverTools) and display and
/// audit (`BrowserNavigateResult` here). Both decoders accept the same
/// `finalUrl`/`finalURL`/`final_url`, redirect-chain, `authRequired`,
/// text-snapshot, and screenshot aliases so the shape cannot drift; the tool
/// envelope reuses `BrowserNavigateResult` for those fields and keeps only its
/// envelope-only keys (title, refs, truncated, downloads, note) locally.
public enum BrowserNavigateWire: Sendable {
    /// Returns the first present value across alias keys.
    /// Single-sources alias-tolerant decoding for tool output, display, and
    /// audit so the three shapes cannot drift. Type mismatches are logged
    /// instead of silently skipped so corruption between tool output and
    /// display surfaces in diagnostics while alternative shapes still render.
    public static func decodeFirst<T: Decodable, K: CodingKey>(
        _ container: KeyedDecodingContainer<K>,
        keys: [K]
    ) -> T? {
        for key in keys {
            do {
                if let value = try container.decodeIfPresent(T.self, forKey: key) {
                    return value
                }
            } catch {
                RuneWeaverLog.tools.warning(
                    "BrowserNavigateWire: ignoring type mismatch for key '\(key.stringValue)': \(error.localizedDescription)"
                )
                continue
            }
        }
        return nil
    }

    /// Normalizes raw helper screenshot text to a data URL.
    /// Strict shared contract mirrored by the dashboard thumbnail gate:
    /// only `data:image/jpeg|png|webp|gif;base64` mounts, plus raw helper
    /// bytes starting with `/9j/` or `iVBOR`. Any other string (including
    /// bare base64 of any length) stays nil so engine and dashboard agree
    /// on what counts as an image.
    /// - Parameter raw: Helper `screenshot`/`thumbnail` field, if any.
    /// - Returns: Data URL, or nil when absent.
    public static func normalizedDataURL(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("data:image/") {
            if trimmed.hasPrefix("data:image/jpeg;base64,")
                || trimmed.hasPrefix("data:image/png;base64,")
                || trimmed.hasPrefix("data:image/webp;base64,")
                || trimmed.hasPrefix("data:image/gif;base64,")
            {
                return trimmed
            }
            return nil
        }
        // Raw base64 JPEG/PNG from the helper without a prefix.
        if trimmed.hasPrefix("/9j/") || trimmed.hasPrefix("iVBOR") {
            return "data:image/jpeg;base64,\(trimmed)"
        }
        return nil
    }
}

/// Structured view of a `browser.navigate` result for display and audit.
public struct BrowserNavigateResult: Sendable, Codable, Equatable {
    /// Final URL after redirects, when reported.
    public let finalUrl: String?
    /// Reported redirect count, when present.
    public let redirectCount: Int?
    /// Ordered redirect chain, when reported.
    public let redirectChain: [BrowserRedirectStep]?
    /// Whether the landing page demands authentication.
    public let authRequired: Bool?
    /// Captured text snapshot, when reported.
    public let textSnapshot: String?
    /// Content hash of the screenshot capture, when one was taken.
    public let screenshotHash: String?
    /// Transient data URL for the thumbnail lightbox, never persisted.
    public let screenshotDataURL: String?

    /// Creates a navigate result.
    public init(
        finalUrl: String? = nil,
        redirectCount: Int? = nil,
        redirectChain: [BrowserRedirectStep]? = nil,
        authRequired: Bool? = nil,
        textSnapshot: String? = nil,
        screenshotHash: String? = nil,
        screenshotDataURL: String? = nil
    ) {
        self.finalUrl = finalUrl
        self.redirectCount = redirectCount
        self.redirectChain = redirectChain
        self.authRequired = authRequired
        self.textSnapshot = textSnapshot
        self.screenshotHash = screenshotHash
        self.screenshotDataURL = screenshotDataURL
    }

    private enum CodingKeys: String, CodingKey {
        case finalUrl
        case finalURL
        // Snake-case aliases keep raw values so the case names stay alphanumeric.
        case finalUrlSnake = "final_url"
        case redirectCount
        case redirectCountSnake = "redirect_count"
        case redirectChain
        case redirectChainSnake = "redirect_chain"
        case redirects
        case authRequired
        case authRequiredSnake = "auth_required"
        case requiresAuth
        case textSnapshot
        case textSnapshotSnake = "text_snapshot"
        case text
        case snapshot
        case screenshotHash
        case screenshotHashSnake = "screenshot_hash"
        case imageHash
        case screenshot
        case thumbnail
        case imageDataURL
        case screenshotDataURL
        case thumbnailDataURL
    }

    /// Decodes tolerantly across plugin shape variations.
    /// Shared wire fields decode single-sourced through `BrowserNavigateWire`
    /// so tool output, display, and audit share one alias table; mismatched
    /// types are logged by the shared helper instead of silently skipped.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let finalRaw: String? = BrowserNavigateWire.decodeFirst(container, keys: [.finalUrl, .finalURL, .finalUrlSnake])
        if let finalRaw {
            let trimmed = finalRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty == false {
                self.finalUrl = finalRaw
            } else {
                self.finalUrl = nil
            }
        } else {
            self.finalUrl = nil
        }
        let decodedCount: Int? = BrowserNavigateWire.decodeFirst(container, keys: [.redirectCount, .redirectCountSnake])
        self.redirectCount = decodedCount
        let typedChain: [BrowserRedirectStep]? = BrowserNavigateWire.decodeFirst(
            container,
            keys: [.redirectChain, .redirectChainSnake, .redirects]
        )
        let stringChain: [String]? = BrowserNavigateWire.decodeFirst(
            container,
            keys: [.redirectChain, .redirectChainSnake, .redirects]
        )
        let chain: [BrowserRedirectStep]? = if let typedChain {
            typedChain
        } else if let stringChain {
            stringChain.map { BrowserRedirectStep(url: $0) }
        } else {
            nil
        }
        self.redirectChain = chain
        let decodedAuth: Bool? = BrowserNavigateWire.decodeFirst(
            container,
            keys: [.authRequired, .authRequiredSnake, .requiresAuth]
        )
        self.authRequired = decodedAuth
        let snapshotRaw: String? = BrowserNavigateWire.decodeFirst(
            container,
            keys: [.textSnapshot, .textSnapshotSnake, .snapshot, .text]
        )
        if let snapshotRaw {
            if snapshotRaw.isEmpty == false {
                self.textSnapshot = snapshotRaw
            } else {
                self.textSnapshot = nil
            }
        } else {
            self.textSnapshot = nil
        }
        let hashRaw: String? = BrowserNavigateWire.decodeFirst(
            container,
            keys: [.screenshotHash, .screenshotHashSnake, .imageHash]
        )
        self.screenshotHash = hashRaw
        let directDataURL: String? = BrowserNavigateWire.decodeFirst(
            container,
            keys: [.screenshotDataURL, .thumbnailDataURL, .imageDataURL]
        )
        let rawImage: String? = BrowserNavigateWire.decodeFirst(container, keys: [.screenshot, .thumbnail])
        let fallbackDataURL = Self.dataURL(from: rawImage)
        let resolvedDataURL: String? = if let directDataURL {
            directDataURL
        } else {
            fallbackDataURL
        }
        if let resolvedDataURL {
            if resolvedDataURL.isEmpty == false {
                self.screenshotDataURL = resolvedDataURL
            } else {
                self.screenshotDataURL = nil
            }
        } else {
            self.screenshotDataURL = nil
        }
    }

    /// Encodes the canonical camelCase shape with the hash only.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(finalUrl, forKey: .finalUrl)
        try container.encodeIfPresent(redirectCount, forKey: .redirectCount)
        try container.encodeIfPresent(redirectChain, forKey: .redirectChain)
        try container.encodeIfPresent(authRequired, forKey: .authRequired)
        try container.encodeIfPresent(textSnapshot, forKey: .textSnapshot)
        try container.encodeIfPresent(screenshotHash, forKey: .screenshotHash)
    }

    /// Parses a raw tool result, returning nil for non-browser payloads.
    public static func parse(_ content: String) -> BrowserNavigateResult? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
        let decoded: BrowserNavigateResult
        do {
            decoded = try JSONDecoder().decode(BrowserNavigateResult.self, from: data)
        } catch {
            RuneWeaverLog.tools.debug("BrowserNavigateResult.parse: not a BrowserNavigateResult or decode failed: \(error.localizedDescription)")
            return nil
        }
        guard decoded.finalUrl != nil || decoded.redirectChain != nil || decoded.redirectCount != nil
            || decoded.authRequired != nil || decoded.textSnapshot != nil
            || decoded.screenshotHash != nil || decoded.screenshotDataURL != nil else { return nil }
        return decoded
    }

    /// Effective redirect count preferring the explicit field.
    /// Collapses to chain length minus one (floor zero) to match the engine
    /// envelope and dashboard fallback single-source `-1` rule.
    public var effectiveRedirectCount: Int {
        if let redirectCount {
            return max(0, redirectCount)
        }
        guard let chain = redirectChain else { return 0 }
        return max(0, chain.count - 1)
    }

    /// Copy safe for durable history with transient pixels removed.
    public func strippedForPersistence() -> BrowserNavigateResult {
        BrowserNavigateResult(
            finalUrl: finalUrl,
            redirectCount: redirectCount,
            redirectChain: redirectChain,
            authRequired: authRequired,
            textSnapshot: textSnapshot,
            screenshotHash: screenshotHash,
            screenshotDataURL: nil
        )
    }

    private static func dataURL(from raw: String?) -> String? {
        BrowserNavigateWire.normalizedDataURL(raw)
    }
}

/// A single streamed chunk of an LLM chat response.
public struct LLMResponse: Sendable, Equatable {
    /// Incremental text for this chunk.
    public let delta: String
    /// Whether this chunk ends the response.
    public let isFinished: Bool
    /// Failure detail when the stream terminated with an error. Nil on success.
    public let errorMessage: String?
    /// Billed tokens for the completed response, when the backend reports usage. Only set on the
    /// terminal (`isFinished`) chunk; text-only consumers accumulate it into the session total for
    /// the usage display.
    public let totalTokens: Int?
    /// Structured tool calls emitted by the model during this chunk.
    public let toolCalls: [ToolInput]

    /// Creates a response chunk.
    public init(
        delta: String,
        isFinished: Bool = false,
        errorMessage: String? = nil,
        totalTokens: Int? = nil,
        toolCalls: [ToolInput] = []
    ) {
        self.delta = delta
        self.isFinished = isFinished
        self.errorMessage = errorMessage
        self.totalTokens = totalTokens
        self.toolCalls = toolCalls
    }

    /// Whether this chunk reports a stream failure.
    public var isError: Bool {
        errorMessage != nil
    }
}

/// Abstraction over an LLM backend.
public protocol LLMProvider: Sendable {
    /// Metadata for the active model.
    var modelInfo: ModelInfo { get }

    /// Streams a chat completion for the given history and tools.
    func chat(messages: [Message], tools: [any Tool]) -> AsyncStream<LLMResponse>

    /// Streams a chat completion for one chat session.
    /// Lets backends with sticky prefix state keep the turn on the same slot
    /// so cached prefixes survive across turns; backends without sticky state
    /// fall back to the session-agnostic path.
    func chat(messages: [Message], tools: [any Tool], sessionID: String?) -> AsyncStream<LLMResponse>

    /// Streams a chat completion for callers holding the chat identifier directly.
    /// Normalizes to the string form so every backend shares one hashing path.
    func chat(messages: [Message], tools: [any Tool], session: UUID?) -> AsyncStream<LLMResponse>

    /// Embeds texts for semantic-memory indexing and retrieval.
    /// - Parameter text: Texts to embed.
    /// - Returns: One embedding vector per input text.
    func embeddings(text: [String]) async throws -> [[Float]]
}

public extension LLMProvider {
    /// Session-agnostic fallback so existing backends keep working while only
    /// slot-aware backends override with real pinning.
    func chat(messages: [Message], tools: [any Tool], sessionID _: String?) -> AsyncStream<LLMResponse> {
        chat(messages: messages, tools: tools)
    }

    /// UUID convenience forwarding to the string form.
    func chat(messages: [Message], tools: [any Tool], session: UUID?) -> AsyncStream<LLMResponse> {
        chat(messages: messages, tools: tools, sessionID: session?.uuidString)
    }
}
