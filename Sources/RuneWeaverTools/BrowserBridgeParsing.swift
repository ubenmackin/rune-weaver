// Rune Weaver Tools — Pure JSON parsing for the Playwright bridge payloads.

import Foundation
import RuneWeaverCore

// MARK: - Bridge Payload Parsing

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
        let url = NormalizedText.value(response.url, fallback: fallbackURL)
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
        let candidate = NormalizedText.value(direct) ?? normalizedDataURL(raw)
        guard let candidate, !candidate.isEmpty, let bytes = screenshotBytes(from: candidate) else { return (nil, nil) }
        // Over-budget captures stay text-only: pixels never enter history
        // past the persistence budget.
        guard BrowserScreenshotPolicy.isWithinBudget(byteCount: bytes.count) else { return (nil, nil) }
        let hash = NormalizedText.value(fallbackHash)
            ?? BrowserScreenshotPolicy.auditHash(for: bytes)
        return (candidate, hash)
    }

    /// Normalizes raw helper screenshot text to a data URL. Single-sourced through
    /// `BrowserNavigateWire` so bridge parsing, tool output, and display/audit share one screenshot
    /// shape.
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
        let url = NormalizedText.value(response.url, fallback: fallbackURL)
        return BrowserActResult(url: url, action: action, ref: ref, downloads: response.downloads ?? [])
    }

    /// Maps helper stderr text to the explicit missing-dependency error when Playwright is absent.
    public static func classifiedBridgeError(_ detail: String, isManagedCopy: Bool = false) -> BrowserError {
        if detail.contains("Playwright is not installed") || detail.contains("No module named playwright") {
            // Already actionable when the caller threaded the managed copy,
            // so pass it through instead of nesting the venv path twice.
            if isManagedCopy {
                return .playwrightMissing(detail)
            }
            return .playwrightMissing(PlaywrightPythonEnsurer.missingMessage(stage: nil, detail: detail))
        }
        if detail.contains("Could not launch python3") {
            if isManagedCopy {
                return .playwrightMissing(detail)
            }
            return .playwrightMissing(PlaywrightPythonEnsurer.missingMessage(stage: nil, detail: detail))
        }
        if detail.contains("SSRF denied") {
            return .invalidURL(detail)
        }
        return .bridgeFailed(detail)
    }
}
