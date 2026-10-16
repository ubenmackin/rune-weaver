// Rune Weaver Server — Search lifecycle DTOs for the local SearXNG engine.

import Foundation
import RuneWeaverCore
import Vapor

/// One agreement point for search and browser DTO defaults.
private enum SearchDTOFields {
    /// In-flight stage worth rendering, so idle reads as absent everywhere.
    /// Shares the banner absence agreement rather than repeating it, so staged
    /// progress cannot drift from banner collapsing.
    static func normalizedStage(_ value: String?) -> String? {
        NormalizedText.value(value)
    }

    /// Validates a Unix-seconds Start time, dropping non-positive or non-finite values.
    /// A number (not a Date) keeps every dashboard decoding without a shared date strategy.
    static func normalizedStartedAt(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    /// Resolves the canonical base URL plus its dashboard alias.
    static func resolvedBaseURL(base: String?, alias: String?) -> (baseURL: String, url: String) {
        let resolved = base ?? alias ?? ""
        return (resolved, alias ?? resolved)
    }

    /// Resolves the collapsed status, defaulting to reachability when absent.
    /// Whitespace-only counts as absent like banners and stages, so a blank
    /// status cannot leak through while message and stage collapse to nil.
    static func resolvedStatus(_ status: String?, reachable: Bool) -> String {
        NormalizedText.value(status) ?? (reachable ? "running" : "stopped")
    }
}

/// Search engine health response for `GET /search/health`. Encodes both `baseURL` (canonical) and
/// `url` plus `status` so dashboard clients reading either contract keep the custom port instead of
/// falling back to the default.
public struct SearchHealthResponse: Content, Equatable {
    /// Whether the SearXNG base URL answered with 2xx/3xx.
    public let reachable: Bool
    /// Configured SearXNG base URL that was probed.
    public let baseURL: String
    /// Container name backing the lifecycle, when managed.
    public let containerName: String
    /// Alias of `baseURL` for dashboard clients expecting `url`.
    public let url: String
    /// Collapsed status (`"running"` when reachable, else `"stopped"`).
    public let status: String
    /// In-flight Start stage (`resolving`, `daemon`, `pulling`, `starting`,
    /// `waiting`), nil when no Start is running.
    public let stage: String?
    /// Unix seconds when the in-flight Start began, nil when idle.
    /// A number (not a Date) so every dashboard decodes it without sharing a
    /// date strategy with the engine.
    public let startedAt: Double?

    /// Creates a health response.
    public init(reachable: Bool, baseURL: String, containerName: String, url: String? = nil, status: String? = nil, stage: String? = nil, startedAt: Double? = nil) {
        self.reachable = reachable
        self.baseURL = baseURL
        self.containerName = containerName
        self.url = url ?? baseURL
        self.status = SearchDTOFields.resolvedStatus(status, reachable: reachable)
        self.stage = SearchDTOFields.normalizedStage(stage)
        self.startedAt = SearchDTOFields.normalizedStartedAt(startedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case reachable
        case baseURL
        case containerName
        case url
        case status
        case stage
        case startedAt
    }

    /// Decodes tolerantly across `baseURL`/`url` shapes plus optional stage keys.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reachable = try container.decode(Bool.self, forKey: .reachable)
        let resolved = try SearchDTOFields.resolvedBaseURL(
            base: container.decodeIfPresent(String.self, forKey: .baseURL),
            alias: container.decodeIfPresent(String.self, forKey: .url)
        )
        baseURL = resolved.baseURL
        url = resolved.url
        containerName = try container.decodeIfPresent(String.self, forKey: .containerName) ?? ""
        status = try SearchDTOFields.resolvedStatus(
            container.decodeIfPresent(String.self, forKey: .status),
            reachable: reachable
        )
        stage = try SearchDTOFields.normalizedStage(container.decodeIfPresent(String.self, forKey: .stage))
        startedAt = try SearchDTOFields.normalizedStartedAt(container.decodeIfPresent(Double.self, forKey: .startedAt))
    }

    /// Encodes both `baseURL` and `url` plus `status` for dual-contract reads.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(reachable, forKey: .reachable)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(url, forKey: .url)
        try container.encode(containerName, forKey: .containerName)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(stage, forKey: .stage)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
    }
}

/// Search engine ensure response for `POST /search/ensure`.
public struct SearchEnsureResponse: Content, Equatable {
    /// Whether the engine answers after the ensure attempt.
    public let reachable: Bool
    /// Configured SearXNG base URL that was ensured.
    public let baseURL: String
    /// Whether a start was attempted during this call.
    public let started: Bool
    /// Alias of `baseURL` for dashboard clients expecting `url`.
    public let url: String
    /// Collapsed status (`"running"` when reachable, else `"stopped"`).
    public let status: String
    /// Trimmed banner (terminal cause plus one remediation) when unreachable.
    public let message: String?
    /// Full per-stage detail for logs plus collapsed diagnostics, when unreachable.
    public let diagnostics: String?

    /// Creates an ensure response.
    public init(reachable: Bool, baseURL: String, started: Bool, url: String? = nil, status: String? = nil, message: String? = nil, diagnostics: String? = nil) {
        self.reachable = reachable
        self.baseURL = baseURL
        self.started = started
        self.url = url ?? baseURL
        self.status = SearchDTOFields.resolvedStatus(status, reachable: reachable)
        self.message = NormalizedText.value(message)
        self.diagnostics = NormalizedText.value(diagnostics)
    }

    private enum CodingKeys: String, CodingKey {
        case reachable
        case baseURL
        case started
        case url
        case status
        case message
        case diagnostics
    }

    /// Decodes tolerantly across `baseURL`/`url` shapes plus optional message and diagnostics.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reachable = try container.decode(Bool.self, forKey: .reachable)
        let resolved = try SearchDTOFields.resolvedBaseURL(
            base: container.decodeIfPresent(String.self, forKey: .baseURL),
            alias: container.decodeIfPresent(String.self, forKey: .url)
        )
        baseURL = resolved.baseURL
        url = resolved.url
        started = try container.decodeIfPresent(Bool.self, forKey: .started) ?? false
        status = try SearchDTOFields.resolvedStatus(
            container.decodeIfPresent(String.self, forKey: .status),
            reachable: reachable
        )
        message = try NormalizedText.value(container.decodeIfPresent(String.self, forKey: .message))
        diagnostics = try NormalizedText.value(container.decodeIfPresent(String.self, forKey: .diagnostics))
    }

    /// Encodes both `baseURL` and `url` plus `status` for dual-contract reads.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(reachable, forKey: .reachable)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(url, forKey: .url)
        try container.encode(started, forKey: .started)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(message, forKey: .message)
        try container.encodeIfPresent(diagnostics, forKey: .diagnostics)
    }
}

/// Search engine stop response for `POST /search/stop`.
public struct SearchStopResponse: Content, Equatable {
    /// Whether the container is stopped (honest re-probe: false when the engine still answers).
    public let stopped: Bool
    /// Container name that was stopped.
    public let containerName: String
    /// Whether the engine answers after the stop (honest re-probe; true when the stop failed or the engine still answers).
    public let reachable: Bool
    /// Configured SearXNG base URL for dashboard fallback display.
    public let baseURL: String
    /// Alias of `baseURL` for dashboard clients expecting `url`.
    public let url: String
    /// Collapsed status (honest re-probe: `"running"` when still reachable, else `"stopped"`).
    public let status: String
    /// Failure detail when the engine still answers after the stop.
    public let message: String?

    /// Creates a stop response.
    public init(stopped: Bool, containerName: String, reachable: Bool = false, baseURL: String = "", url: String? = nil, status: String? = nil, message: String? = nil) {
        self.stopped = stopped
        self.containerName = containerName
        self.reachable = reachable
        self.baseURL = baseURL
        self.url = url ?? baseURL
        self.status = SearchDTOFields.resolvedStatus(status, reachable: reachable)
        self.message = NormalizedText.value(message)
    }

    private enum CodingKeys: String, CodingKey {
        case stopped
        case containerName
        case reachable
        case baseURL
        case url
        case status
        case message
    }

    /// Decodes tolerantly so dashboard `SearchHealthResponse` shapes still parse.
    /// An absent `stopped` derives from the honest `reachable` probe instead
    /// of optimistically assuming stopped on shape drift.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reachable = try container.decodeIfPresent(Bool.self, forKey: .reachable) ?? false
        stopped = try container.decodeIfPresent(Bool.self, forKey: .stopped) ?? !reachable
        containerName = try container.decodeIfPresent(String.self, forKey: .containerName) ?? ""
        let resolved = try SearchDTOFields.resolvedBaseURL(
            base: container.decodeIfPresent(String.self, forKey: .baseURL),
            alias: container.decodeIfPresent(String.self, forKey: .url)
        )
        baseURL = resolved.baseURL
        url = resolved.url
        status = try SearchDTOFields.resolvedStatus(
            container.decodeIfPresent(String.self, forKey: .status),
            reachable: reachable
        )
        message = try NormalizedText.value(container.decodeIfPresent(String.self, forKey: .message))
    }

    /// Encodes the full shape so health-style readers keep working.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stopped, forKey: .stopped)
        try container.encode(containerName, forKey: .containerName)
        try container.encode(reachable, forKey: .reachable)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(url, forKey: .url)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(message, forKey: .message)
    }
}

/// Search container remove response for `POST /search/remove`. Reports whether the managed entry is
/// gone plus an honest reachability re-probe, so the dashboard can keep the pill honest without a
/// second fetch.
public struct SearchRemoveResponse: Content, Equatable {
    /// Whether the container entry is gone (false when still reachable or still listed).
    public let removed: Bool
    /// Container name that was removed.
    public let containerName: String
    /// Whether the engine answers after the remove (honest re-probe; true when the halt or delete did not take).
    public let reachable: Bool
    /// Configured SearXNG base URL for dashboard fallback display.
    public let baseURL: String
    /// Alias of `baseURL` for dashboard clients expecting `url`.
    public let url: String
    /// Collapsed status (honest re-probe: `"running"` when still reachable, else `"stopped"`).
    public let status: String
    /// Guidance when the entry is not gone (still reachable, or stopped but still listed).
    public let message: String?

    /// Creates a remove response.
    public init(removed: Bool, containerName: String, reachable: Bool = false, baseURL: String = "", url: String? = nil, status: String? = nil, message: String? = nil) {
        self.removed = removed
        self.containerName = containerName
        self.reachable = reachable
        self.baseURL = baseURL
        self.url = url ?? baseURL
        self.status = SearchDTOFields.resolvedStatus(status, reachable: reachable)
        self.message = NormalizedText.value(message)
    }

    private enum CodingKeys: String, CodingKey {
        case removed
        case containerName
        case reachable
        case baseURL
        case url
        case status
        case message
    }

    /// Decodes tolerantly so dashboard `SearchHealthResponse` shapes still parse.
    /// An absent `removed` derives from the honest `reachable` probe instead
    /// of optimistically assuming removed on shape drift.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reachable = try container.decodeIfPresent(Bool.self, forKey: .reachable) ?? false
        removed = try container.decodeIfPresent(Bool.self, forKey: .removed) ?? !reachable
        containerName = try container.decodeIfPresent(String.self, forKey: .containerName) ?? ""
        let resolved = try SearchDTOFields.resolvedBaseURL(
            base: container.decodeIfPresent(String.self, forKey: .baseURL),
            alias: container.decodeIfPresent(String.self, forKey: .url)
        )
        baseURL = resolved.baseURL
        url = resolved.url
        status = try SearchDTOFields.resolvedStatus(
            container.decodeIfPresent(String.self, forKey: .status),
            reachable: reachable
        )
        message = try NormalizedText.value(container.decodeIfPresent(String.self, forKey: .message))
    }

    /// Encodes the full shape so health-style readers keep working.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(removed, forKey: .removed)
        try container.encode(containerName, forKey: .containerName)
        try container.encode(reachable, forKey: .reachable)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(url, forKey: .url)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(message, forKey: .message)
    }
}

/// Browser Python health response for `GET /browser/health`.
public struct BrowserPythonHealthResponse: Content, Equatable {
    /// Whether the effective interpreter can `import playwright`.
    public let ready: Bool
    /// Effective interpreter path (`RUNEWEAVER_PYTHON_BIN` override, managed
    /// venv, or PATH fallback probe result).
    public let pythonPath: String
    /// Managed venv directory display path (`~/.runeweaver/python`).
    public let venvPath: String
    /// In-flight provision stage, nil when no provision is running.
    public let stage: String?
    /// Unix seconds when the in-flight provision began, nil when idle.
    /// A number (not a Date) so every dashboard decodes it without sharing a
    /// date strategy with the engine.
    public let startedAt: Double?
    /// Actionable banner (venv path plus manual fallback) when not ready.
    public let message: String?

    /// Creates a browser health response.
    /// The venv display path defaults to the single-sourced managed location
    /// so health copy never drifts from provisioning.
    public init(
        ready: Bool,
        pythonPath: String = "",
        venvPath: String = BrowserConfig.managedPythonVenvDisplayPath(),
        stage: String? = nil,
        startedAt: Double? = nil,
        message: String? = nil
    ) {
        self.ready = ready
        self.pythonPath = pythonPath
        self.venvPath = venvPath
        self.stage = SearchDTOFields.normalizedStage(stage)
        self.startedAt = SearchDTOFields.normalizedStartedAt(startedAt)
        self.message = NormalizedText.value(message)
    }

    private enum CodingKeys: String, CodingKey {
        case ready
        case pythonPath
        case venvPath
        case stage
        case startedAt
        case message
    }

    /// Decodes tolerantly so older engines omitting staged keys still parse.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ready = try container.decodeIfPresent(Bool.self, forKey: .ready) ?? false
        pythonPath = try container.decodeIfPresent(String.self, forKey: .pythonPath) ?? ""
        venvPath = try container.decodeIfPresent(String.self, forKey: .venvPath) ?? BrowserConfig.managedPythonVenvDisplayPath()
        stage = try SearchDTOFields.normalizedStage(container.decodeIfPresent(String.self, forKey: .stage))
        startedAt = try SearchDTOFields.normalizedStartedAt(container.decodeIfPresent(Double.self, forKey: .startedAt))
        message = try NormalizedText.value(container.decodeIfPresent(String.self, forKey: .message))
    }

    /// Encodes the full shape, omitting staged keys when idle.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ready, forKey: .ready)
        try container.encode(pythonPath, forKey: .pythonPath)
        try container.encode(venvPath, forKey: .venvPath)
        try container.encodeIfPresent(stage, forKey: .stage)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(message, forKey: .message)
    }
}

/// Browser Python ensure response for `POST /browser/ensure`.
public struct BrowserPythonEnsureResponse: Content, Equatable {
    /// Whether the interpreter can `import playwright` after the attempt.
    public let ready: Bool
    /// Whether this call actually provisioned the managed venv.
    public let started: Bool
    /// Effective interpreter path after the attempt.
    public let pythonPath: String
    /// Managed venv directory display path.
    public let venvPath: String
    /// Trimmed banner (cause plus venv path plus fallback) when not ready.
    public let message: String?
    /// Capped per-stage detail for logs plus collapsed diagnostics.
    public let diagnostics: String?

    /// Creates a browser ensure response.
    /// The venv display path defaults to the single-sourced managed location
    /// so ensure copy never drifts from provisioning.
    public init(
        ready: Bool,
        started: Bool,
        pythonPath: String = "",
        venvPath: String = BrowserConfig.managedPythonVenvDisplayPath(),
        message: String? = nil,
        diagnostics: String? = nil
    ) {
        self.ready = ready
        self.started = started
        self.pythonPath = pythonPath
        self.venvPath = venvPath
        self.message = NormalizedText.value(message)
        self.diagnostics = NormalizedText.value(diagnostics)
    }

    private enum CodingKeys: String, CodingKey {
        case ready
        case started
        case pythonPath
        case venvPath
        case message
        case diagnostics
    }

    /// Decodes tolerantly across staged shapes plus optional diagnostics.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ready = try container.decodeIfPresent(Bool.self, forKey: .ready) ?? false
        started = try container.decodeIfPresent(Bool.self, forKey: .started) ?? false
        pythonPath = try container.decodeIfPresent(String.self, forKey: .pythonPath) ?? ""
        venvPath = try container.decodeIfPresent(String.self, forKey: .venvPath) ?? BrowserConfig.managedPythonVenvDisplayPath()
        message = try NormalizedText.value(container.decodeIfPresent(String.self, forKey: .message))
        diagnostics = try NormalizedText.value(container.decodeIfPresent(String.self, forKey: .diagnostics))
    }

    /// Encodes the full shape so either reader keeps working.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ready, forKey: .ready)
        try container.encode(started, forKey: .started)
        try container.encode(pythonPath, forKey: .pythonPath)
        try container.encode(venvPath, forKey: .venvPath)
        try container.encodeIfPresent(message, forKey: .message)
        try container.encodeIfPresent(diagnostics, forKey: .diagnostics)
    }
}
