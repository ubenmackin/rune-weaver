// Rune Weaver Tools — Playwright bridge for browser automation.

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
    /// Hovers over the element referenced by `ref`.
    case hover
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
    /// Page title after the action, if available.
    public let title: String?
    /// Distilled text after the action, if available.
    public let text: String?
    /// Interactive snapshot refs after the action, if available.
    public let refs: [BrowserElementRef]?
    /// Whether the text or refs were capped at the shared bounds.
    public let truncated: Bool

    /// Creates an act result.
    public init(
        url: String,
        action: BrowserActAction,
        ref: String,
        downloads: [BrowserDownloadManifest] = [],
        title: String? = nil,
        text: String? = nil,
        refs: [BrowserElementRef]? = nil,
        truncated: Bool = false
    ) {
        self.url = url
        self.action = action
        self.ref = ref
        self.downloads = downloads
        self.title = title
        self.text = text
        self.refs = refs
        self.truncated = truncated
    }
}

/// Shared bounds keeping browser payloads predictable for the model.
public enum BrowserBounds: Sendable {
    /// Maximum distilled text characters returned per snapshot.
    public static let maxTextChars = 5000
    /// Maximum snapshot refs returned per snapshot.
    public static let maxRefs = 100
    /// Maximum URL characters accepted before fail-closed rejection.
    public static let maxURLChars = 2048
    /// Maximum act `text` characters accepted (fill/select values, press keys, and scroll text).
    public static let maxActTextChars = 2000
    /// Maximum accessible-name characters kept per ref (mirrors the helper).
    public static let maxRefNameChars = 80
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

    /// Session-aware act threading the egress session grant. Declared as a requirement so the live
    /// gateway's grant-aware implementation dispatches dynamically; stubs inherit the session-less
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
    /// Single-sourced so inits cannot drift on trim versus env precedence;
    /// nil keeps the managed-venv fast path.
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
        // The helper surfaces its redirect chain, so every reported hop re-enters the allowlist
        // plus the canonical guard before the snapshot leaves the gateway; a public start cannot
        // launder a sensitive hop through the bridge.
        try await validateFreshRedirectChain(
            snapshot.redirectChain,
            finalURL: snapshot.url,
            entryURL: validated,
            sessionID: sessionID
        )
        return snapshot
    }

    /// Validates bridge-reported hops beyond the already-granted entry host.
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
        // Post-action navigation can land elsewhere (click-through or meta-refresh), so the
        // reported URL re-vets before the result leaves the gateway rather than trusting the
        // helper's landing page.
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
        // First navigate or act provisions the managed venv inline so Homebrew system pythons never
        // hit externally-managed-environment: the ensurer collapses concurrent callers onto one
        // flight and publishes staged progress for health polls, while explicit and env overrides.
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

/// Runs blocking Playwright subprocess I/O off the async executor.
enum BrowserSubprocessIO {
    /// Process-wide serial queue for helper spawns.
    private static let bridgeRunQueue = DispatchQueue(label: "com.runeweaver.browser.playwright-bridge", qos: .utility)

    /// Runs one blocking bridge operation on the serial profile queue.
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

    /// Builds the navigate request document sent to the helper. `timeoutMs` carries the configured
    /// budget so `page.goto` honors it instead of a hardcoded default literal; every navigate
    /// key stays assembled in one place.
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
    /// honor it instead of a hardcoded default literal.
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
        // Shared box lets cancellation terminate the live helper instead of leaking it: the
        // blocking wait publishes the child before waiting so a cancel racing the spawn still finds
        // and kills it.
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
                // Launch failures stay in the missing classification so the dashboard renders the
                // venv path plus manual fallback instead of a bare spawn error; timeout plus output
                // caps above stay on the bridge call, never on provisioning budgets.
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
